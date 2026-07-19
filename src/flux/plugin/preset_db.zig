const std = @import("std");
const c = @import("sqlite3");

pub const Record = struct {
    db_id: i64 = 0,
    name: []const u8,
    plugin_id: []const u8,
    plugin_name: []const u8,
    provider_id: []const u8,
    location_kind: u32,
    location: [:0]const u8,
    load_key: ?[:0]const u8,
    category: []const u8 = "sounds",
};

pub const Db = struct {
    conn: *c.sqlite3,
    allocator: std.mem.Allocator,
    path: [:0]u8,

    pub fn open(allocator: std.mem.Allocator, io: std.Io) !Db {
        const cache_dir = try cacheDirPath(allocator);
        defer allocator.free(cache_dir);
        try std.Io.Dir.cwd().createDirPath(io, cache_dir);
        const path = try std.Io.Dir.path.join(allocator, &.{ cache_dir, "flux.db" });
        defer allocator.free(path);
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        errdefer allocator.free(path_z);

        var conn: ?*c.sqlite3 = null;
        try check(c.sqlite3_open_v2(
            path_z.ptr,
            &conn,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_EXRESCODE,
            null,
        ));
        errdefer _ = c.sqlite3_close_v2(conn);
        try check(c.sqlite3_busy_timeout(conn, 1000));
        try exec(conn.?,
            \\pragma foreign_keys = on;
            \\pragma journal_mode = wal;
            \\create table if not exists preset_binaries (
            \\  path text primary key,
            \\  mtime_ns integer not null
            \\);
            \\create table if not exists presets (
            \\  binary_path text not null references preset_binaries(path) on delete cascade,
            \\  ordinal integer not null,
            \\  name text not null,
            \\  plugin_id text not null,
            \\  plugin_name text not null,
            \\  provider_id text not null,
            \\  location_kind integer not null,
            \\  location text not null,
            \\  load_key text,
            \\  category text not null default 'sounds',
            \\  primary key (binary_path, ordinal)
            \\);
            \\create index if not exists presets_plugin_id on presets(plugin_id);
            \\create index if not exists presets_name on presets(name collate nocase);
        );
        if (try ensureColumn(conn.?, "presets", "category", "text not null default 'sounds'")) {
            // One-time backfill for indexes which predate CLAP feature capture.
            try exec(conn.?,
                \\update presets set category = 'drums' where
                \\  lower(name) like '%drum%' or lower(name) like '%kick%' or lower(name) like '%snare%'
                \\  or lower(name) like '%hihat%' or lower(name) like '%hi-hat%' or lower(name) like '%percussion%'
                \\  or lower(location) like '%drum%' or lower(location) like '%percussion%';
            );
        }
        return .{ .conn = conn.?, .allocator = allocator, .path = path_z };
    }

    pub fn deinit(self: *Db) void {
        _ = c.sqlite3_close_v2(self.conn);
        self.allocator.free(self.path);
    }

    pub fn matches(self: *const Db, path: []const u8, mtime_ns: i64) !bool {
        const stmt = try prepare(self.conn, "select 1 from preset_binaries where path = ?1 and mtime_ns = ?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, path);
        try check(c.sqlite3_bind_int64(stmt, 2, mtime_ns));
        return switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |rc| {
                try check(rc);
                unreachable;
            },
        };
    }

    pub fn load(self: *const Db, allocator: std.mem.Allocator, path: []const u8) ![]Record {
        const stmt = try prepare(self.conn,
            \\select name, plugin_id, plugin_name, provider_id, location_kind, location, load_key, category
            \\from presets where binary_path = ?1 order by ordinal
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, path);
        var records: std.ArrayList(Record) = .empty;
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => try records.append(allocator, .{
                .name = try allocator.dupe(u8, columnText(stmt, 0)),
                .plugin_id = try allocator.dupe(u8, columnText(stmt, 1)),
                .plugin_name = try allocator.dupe(u8, columnText(stmt, 2)),
                .provider_id = try allocator.dupe(u8, columnText(stmt, 3)),
                .location_kind = @intCast(c.sqlite3_column_int64(stmt, 4)),
                .location = try allocator.dupeSentinel(u8, columnText(stmt, 5), 0),
                .load_key = if (c.sqlite3_column_type(stmt, 6) == c.SQLITE_NULL)
                    null
                else
                    try allocator.dupeSentinel(u8, columnText(stmt, 6), 0),
                .category = try allocator.dupe(u8, columnText(stmt, 7)),
            }),
            c.SQLITE_DONE => break,
            else => |rc| try check(rc),
        };
        return records.toOwnedSlice(allocator);
    }

    pub fn searchTitles(self: *const Db, allocator: std.mem.Allocator, text: []const u8, category: []const u8, ascending: bool) ![]Record {
        const sql = if (ascending)
            \\select rowid, name, plugin_name from presets
            \\where (?1 = '' or category = ?1) and (?2 = '' or name like '%' || ?2 || '%' collate nocase
            \\  or plugin_name like '%' || ?2 || '%' collate nocase)
            \\order by name collate nocase asc
        else
            \\select rowid, name, plugin_name from presets
            \\where (?1 = '' or category = ?1) and (?2 = '' or name like '%' || ?2 || '%' collate nocase
            \\  or plugin_name like '%' || ?2 || '%' collate nocase)
            \\order by name collate nocase desc
        ;
        const stmt = try prepare(self.conn, sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, category);
        try bindText(stmt, 2, text);
        var records: std.ArrayList(Record) = .empty;
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => try records.append(allocator, .{
                .db_id = c.sqlite3_column_int64(stmt, 0),
                .name = try allocator.dupe(u8, columnText(stmt, 1)),
                .plugin_id = "",
                .plugin_name = try allocator.dupe(u8, columnText(stmt, 2)),
                .provider_id = "",
                .location_kind = 0,
                .location = "",
                .load_key = null,
                .category = category,
            }),
            c.SQLITE_DONE => break,
            else => |rc| try check(rc),
        };
        return records.toOwnedSlice(allocator);
    }

    pub fn loadById(self: *const Db, allocator: std.mem.Allocator, id: i64) !?Record {
        const stmt = try prepare(self.conn,
            \\select rowid, name, plugin_id, plugin_name, provider_id, location_kind, location, load_key, category
            \\from presets where rowid = ?1
        );
        defer _ = c.sqlite3_finalize(stmt);
        try check(c.sqlite3_bind_int64(stmt, 1, id));
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{
            .db_id = c.sqlite3_column_int64(stmt, 0),
            .name = try allocator.dupe(u8, columnText(stmt, 1)),
            .plugin_id = try allocator.dupe(u8, columnText(stmt, 2)),
            .plugin_name = try allocator.dupe(u8, columnText(stmt, 3)),
            .provider_id = try allocator.dupe(u8, columnText(stmt, 4)),
            .location_kind = @intCast(c.sqlite3_column_int64(stmt, 5)),
            .location = try allocator.dupeSentinel(u8, columnText(stmt, 6), 0),
            .load_key = if (c.sqlite3_column_type(stmt, 7) == c.SQLITE_NULL) null else try allocator.dupeSentinel(u8, columnText(stmt, 7), 0),
            .category = try allocator.dupe(u8, columnText(stmt, 8)),
        };
    }

    pub fn markEffectPlugin(self: *Db, plugin_id: []const u8) !void {
        const stmt = try prepare(self.conn, "update presets set category = 'effects' where plugin_id = ?1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, plugin_id);
        try stepDone(stmt);
    }

    pub fn classifyLegacyRows(self: *Db) !void {
        try exec(self.conn,
            \\update presets set category = 'bass' where category = 'sounds' and
            \\  (lower(name) like '%bass%' or lower(location) like '%bass%');
            \\update presets set category = 'pad' where category = 'sounds' and
            \\  (lower(name) like '%pad%' or lower(location) like '%pad%');
            \\update presets set category = 'lead' where category = 'sounds' and
            \\  (lower(name) like '%lead%' or lower(location) like '%lead%');
            \\update presets set category = 'keys' where category = 'sounds' and (
            \\  lower(name) like '%piano%' or lower(name) like '%organ%' or lower(name) like '%rhodes%'
            \\  or lower(name) like '%keyboard%' or lower(name) like '%clav%'
            \\  or lower(location) like '%piano%' or lower(location) like '%keys%');
            \\update presets set category = 'noise' where category = 'sounds' and
            \\  (lower(name) like '%noise%' or lower(name) like '%texture%' or lower(location) like '%noise%');
        );
    }

    pub fn replace(self: *Db, path: []const u8, mtime_ns: i64, records: []const Record) !void {
        try exec(self.conn, "begin");
        errdefer exec(self.conn, "rollback") catch {};
        var stmt = try prepare(self.conn, "delete from preset_binaries where path = ?1");
        try bindText(stmt, 1, path);
        try stepDone(stmt);
        _ = c.sqlite3_finalize(stmt);

        stmt = try prepare(self.conn, "insert into preset_binaries(path, mtime_ns) values (?1, ?2)");
        try bindText(stmt, 1, path);
        try check(c.sqlite3_bind_int64(stmt, 2, mtime_ns));
        try stepDone(stmt);
        _ = c.sqlite3_finalize(stmt);

        stmt = try prepare(self.conn,
            \\insert into presets(
            \\  binary_path, ordinal, name, plugin_id, plugin_name, provider_id,
            \\  location_kind, location, load_key, category
            \\) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        );
        defer _ = c.sqlite3_finalize(stmt);
        for (records, 0..) |record, ordinal| {
            try bindText(stmt, 1, path);
            try check(c.sqlite3_bind_int64(stmt, 2, @intCast(ordinal)));
            try bindText(stmt, 3, record.name);
            try bindText(stmt, 4, record.plugin_id);
            try bindText(stmt, 5, record.plugin_name);
            try bindText(stmt, 6, record.provider_id);
            try check(c.sqlite3_bind_int64(stmt, 7, record.location_kind));
            try bindText(stmt, 8, record.location);
            if (record.load_key) |key| try bindText(stmt, 9, key) else try check(c.sqlite3_bind_null(stmt, 9));
            try bindText(stmt, 10, record.category);
            try stepDone(stmt);
            try check(c.sqlite3_reset(stmt));
            try check(c.sqlite3_clear_bindings(stmt));
        }
        try exec(self.conn, "commit");
    }
};

fn ensureColumn(conn: *c.sqlite3, table: []const u8, column: []const u8, declaration: []const u8) !bool {
    var sql_buf: [256]u8 = undefined;
    const pragma = try std.fmt.bufPrint(&sql_buf, "pragma table_info({s})", .{table});
    const stmt = try prepare(conn, pragma);
    defer _ = c.sqlite3_finalize(stmt);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (std.mem.eql(u8, columnText(stmt, 1), column)) return false;
    }
    const alter = try std.fmt.bufPrintSentinel(&sql_buf, "alter table {s} add column {s} {s}", .{ table, column, declaration }, 0);
    try exec(conn, alter);
    return true;
}

fn cacheDirPath(allocator: std.mem.Allocator) ![]const u8 {
    const home_c = std.c.getenv("HOME") orelse return error.MissingHome;
    return std.Io.Dir.path.join(allocator, &.{ std.mem.span(home_c), ".cache", "flux" });
}

fn check(rc: c_int) !void {
    if (rc != c.SQLITE_OK) return error.Sqlite;
}

fn exec(conn: *c.sqlite3, sql: [*:0]const u8) !void {
    try check(c.sqlite3_exec(conn, sql, null, null, null));
}

fn prepare(conn: *c.sqlite3, sql: []const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    try check(c.sqlite3_prepare_v2(conn, sql.ptr, @intCast(sql.len), &stmt, null));
    return stmt.?;
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    // Bound slices remain alive until sqlite3_step; null selects SQLITE_STATIC.
    try check(c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null));
}

fn stepDone(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.Sqlite;
}

fn columnText(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, index);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
    if (len == 0) return "";
    return ptr[0..len];
}
