//! Cached sample directory listings. Owned by the browser, never by the audio thread.
const std = @import("std");

pub const Cache = struct {
    storage: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    selection: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    path: []const u8 = "",
    mtime: ?std.Io.Timestamp = null,
    names: std.ArrayList([]const u8) = .empty,
    matches: std.ArrayList([]const u8) = .empty,
    filter: ?[]const u8 = null,
    ascending: bool = true,

    pub fn deinit(self: *Cache) void {
        self.storage.deinit();
        self.selection.deinit();
        self.* = .{};
    }

    pub fn query(self: *Cache, io: std.Io, path: []const u8, filter: []const u8, ascending: bool) ![]const []const u8 {
        // Directory mtime changes on additions, removals and renames. Avoid
        // enumerating/allocating/sorting on ordinary redraws.
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
            self.deinit();
            return &.{};
        };
        if (!std.mem.eql(u8, self.path, path) or self.mtime == null or
            self.mtime.?.nanoseconds != stat.mtime.nanoseconds)
        {
            self.deinit();
            errdefer self.deinit();
            const arena = self.storage.allocator();
            self.path = try arena.dupe(u8, path);
            var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
            defer dir.close(io);
            var iter = dir.iterateAssumeFirstIteration();
            while (try iter.next(io)) |entry| {
                if (entry.kind != .file or !hasAudioExt(entry.name)) continue;
                try self.names.append(arena, try arena.dupe(u8, entry.name));
            }
            std.sort.heap([]const u8, self.names.items, {}, lessThan);
            self.mtime = stat.mtime;
        }
        if (self.filter == null or !std.mem.eql(u8, self.filter.?, filter) or self.ascending != ascending) {
            _ = self.selection.reset(.retain_capacity);
            self.matches = .empty;
            self.filter = null;
            const arena = self.selection.allocator();
            for (0..self.names.items.len) |i| {
                const index = if (ascending) i else self.names.items.len - 1 - i;
                const name = self.names.items[index];
                if (filter.len == 0 or containsIgnoreCase(name, filter)) try self.matches.append(arena, name);
            }
            self.filter = try arena.dupe(u8, filter);
            self.ascending = ascending;
        }
        return self.matches.items;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    const order = std.ascii.orderIgnoreCase(a, b);
    return order == .lt or (order == .eq and std.mem.order(u8, a, b) == .lt);
}

fn hasAudioExt(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    inline for (.{ ".wav", ".mp3", ".ogg", ".flac", ".aiff", ".aif" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

test "folder cache reuses listings, filters, sorts and detects directory changes" {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try dir.dir.realPath(io, &path_buf)];
    try dir.dir.writeFile(io, .{ .sub_path = "Zulu.wav", .data = "" });
    try dir.dir.writeFile(io, .{ .sub_path = "alpha.WaV", .data = "" });
    try dir.dir.writeFile(io, .{ .sub_path = "ignore.txt", .data = "" });
    var cache = Cache{};
    defer cache.deinit();
    const first = try cache.query(io, path, "", true);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqualStrings("alpha.WaV", first[0]);
    const again = try cache.query(io, path, "", true);
    try std.testing.expectEqual(first.ptr, again.ptr);
    const descending = try cache.query(io, path, "", false);
    try std.testing.expectEqualStrings("Zulu.wav", descending[0]);
    const filtered = try cache.query(io, path, "ALP", true);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqualStrings("alpha.WaV", filtered[0]);
    try dir.dir.writeFile(io, .{ .sub_path = "beta.flac", .data = "" });
    // Make the stored timestamp older explicitly; no filesystem clock-resolution dependency.
    cache.mtime.?.nanoseconds -= 1;
    const changed = try cache.query(io, path, "", true);
    try std.testing.expectEqual(@as(usize, 3), changed.len);
    try std.testing.expectEqualStrings("beta.flac", changed[1]);
}
