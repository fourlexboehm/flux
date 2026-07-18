//! Bitwig-style media dirs beside a thin `.dawproject` (samples/, recordings/).
//! Paths in XML are relative to the directory containing the project file.

const std = @import("std");
const Dir = std.Io.Dir;

pub const samples_dir = "samples";
pub const recordings_dir = "recordings";
/// In-pack member prefix for Pack export (Bitwig-friendly).
pub const pack_audio_dir = "audio";

pub fn projectDir(allocator: std.mem.Allocator, project_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(project_path) orelse ".";
    return try allocator.dupe(u8, dir);
}

pub fn joinRel(allocator: std.mem.Allocator, project_dir: []const u8, rel: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel)) return try allocator.dupe(u8, rel);
    return try Dir.path.join(allocator, &.{ project_dir, rel });
}

pub fn ensureMediaDirs(io: std.Io, project_dir: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    {
        const samples = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ project_dir, samples_dir });
        try Dir.cwd().createDirPath(io, samples);
    }
    {
        const recordings = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ project_dir, recordings_dir });
        try Dir.cwd().createDirPath(io, recordings);
    }
}

/// Reject absolute paths and `..` components.
pub fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "..")) return false;
        if (std.mem.eql(u8, part, ".")) continue;
    }
    // Also reject backslash-only traversal on Windows-style paths in archives.
    if (std.mem.indexOf(u8, path, "..\\") != null) return false;
    return true;
}

/// Strip directories and unsafe chars; keep a usable basename.
pub fn sanitizeBaseName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const base = std.fs.path.basename(name);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (base) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '-' or c == '_' or c == ' ';
        try out.append(allocator, if (ok) c else '_');
    }
    while (out.items.len > 0 and (out.items[0] == '.' or out.items[0] == ' ')) {
        _ = out.orderedRemove(0);
    }
    if (out.items.len == 0) {
        try out.appendSlice(allocator, "audio");
    }
    return try out.toOwnedSlice(allocator);
}

pub fn isMediaSubdirPath(rel: []const u8) bool {
    return std.mem.startsWith(u8, rel, samples_dir ++ "/") or
        std.mem.startsWith(u8, rel, recordings_dir ++ "/");
}

/// Pick `subdir/base`, or `subdir/stem-2.ext`, … without overwriting.
/// Reuse the preferred path only when its contents match `reuse_data`.
pub fn allocateUniqueRelPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    subdir: []const u8,
    preferred_name: []const u8,
    reuse_data: ?[]const u8,
) ![]u8 {
    const safe = try sanitizeBaseName(allocator, preferred_name);
    defer allocator.free(safe);

    const stem = std.fs.path.stem(safe);
    const ext = std.fs.path.extension(safe);

    var n: u32 = 0;
    while (n < 10_000) : (n += 1) {
        const rel = if (n == 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ subdir, safe })
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}-{d}{s}", .{ subdir, stem, n + 1, ext });

        const abs = try joinRel(allocator, project_dir, rel);
        defer allocator.free(abs);

        if (Dir.cwd().statFile(io, abs, .{})) |st| {
            if (n == 0) {
                if (reuse_data) |data| {
                    if (st.size == data.len and fileEqualsBytes(io, abs, data)) return rel;
                }
            }
            allocator.free(rel);
            continue;
        } else |_| {
            return rel;
        }
    }
    return error.UniqueNameExhausted;
}

pub fn writeBytesAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    abs_path: []const u8,
    data: []const u8,
) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{abs_path});
    defer allocator.free(tmp);

    if (std.fs.path.dirname(abs_path)) |parent| {
        try Dir.cwd().createDirPath(io, parent);
    }

    {
        var file = try Dir.cwd().createFile(io, tmp, .{ .truncate = true });
        defer file.close(io);
        var write_buf: [8192]u8 = undefined;
        var fw = file.writer(io, &write_buf);
        try fw.interface.writeAll(data);
        try fw.interface.flush();
    }

    try Dir.rename(Dir.cwd(), tmp, Dir.cwd(), abs_path, io);
}

pub fn readEntireFile(allocator: std.mem.Allocator, io: std.Io, abs_path: []const u8) ![]u8 {
    var file = try Dir.cwd().openFile(io, abs_path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    const data = try allocator.alloc(u8, st.size);
    errdefer allocator.free(data);
    const n = try file.readPositionalAll(io, data, 0);
    if (n != st.size) return error.UnexpectedEof;
    return data;
}

pub const FileIdentity = struct {
    size: u64 = 0,
    mtime_ns: i64 = 0,
};

pub fn statIdentity(io: std.Io, abs_path: []const u8) ?FileIdentity {
    const st = Dir.cwd().statFile(io, abs_path, .{}) catch return null;
    return .{
        .size = st.size,
        .mtime_ns = @intCast(st.mtime.toNanoseconds()),
    };
}

/// Ensure media is under samples/ (or recordings/). Returns owned relative path.
/// Reuses an existing preferred file only when its contents match `data`.
pub fn writeMediaUnique(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    subdir: []const u8,
    preferred_name: []const u8,
    data: []const u8,
) ![]u8 {
    const rel = try allocateUniqueRelPath(
        allocator,
        io,
        project_dir,
        subdir,
        preferred_name,
        data,
    );
    errdefer allocator.free(rel);
    const abs = try joinRel(allocator, project_dir, rel);
    defer allocator.free(abs);

    if (Dir.cwd().statFile(io, abs, .{})) |st| {
        if (st.size == data.len and fileEqualsBytes(io, abs, data)) {
            return rel;
        }
    } else |_| {}

    try writeBytesAtomic(allocator, io, abs, data);
    return rel;
}

/// True if `rel` exists under project_dir with exactly the given bytes.
pub fn mediaEqualsBytes(
    io: std.Io,
    project_dir: []const u8,
    rel: []const u8,
    data: []const u8,
) bool {
    const abs = joinRel(std.heap.page_allocator, project_dir, rel) catch return false;
    defer std.heap.page_allocator.free(abs);
    return fileEqualsBytes(io, abs, data);
}

fn fileEqualsBytes(io: std.Io, abs_path: []const u8, data: []const u8) bool {
    var file = Dir.cwd().openFile(io, abs_path, .{}) catch return false;
    defer file.close(io);
    const st = file.stat(io) catch return false;
    if (st.size != data.len) return false;

    var buf: [8192]u8 = undefined;
    var offset: usize = 0;
    while (offset < data.len) {
        const want = @min(buf.len, data.len - offset);
        const n = file.readPositionalAll(io, buf[0..want], offset) catch return false;
        if (n != want or !std.mem.eql(u8, buf[0..want], data[offset .. offset + want])) return false;
        offset += want;
    }
    return true;
}
