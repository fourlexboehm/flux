const std = @import("std");

pub const ZipWriter = struct {
    const FileEntry = struct {
        name: []const u8,
        data: []const u8,
        crc32: u32,
        offset: u32,
    };

    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    entries: std.ArrayList(FileEntry),

    pub fn init(allocator: std.mem.Allocator) ZipWriter {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *ZipWriter) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
    }

    // Helper to write little-endian values
    fn writeU16(self: *ZipWriter, val: u16) !void {
        try self.buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, val)));
    }

    fn writeU32(self: *ZipWriter, val: u32) !void {
        try self.buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, val)));
    }

    pub fn addFile(self: *ZipWriter, name: []const u8, data: []const u8) !void {
        const offset: u32 = @intCast(self.buffer.items.len);
        const crc = std.hash.Crc32.hash(data);
        const size: u32 = @intCast(data.len);

        // Write local file header (30 bytes + filename)
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 'P', 'K', 3, 4 }); // signature
        try self.writeU16(20); // version needed
        try self.writeU16(0); // flags
        try self.writeU16(0); // compression (store)
        try self.writeU16(0); // mod time
        try self.writeU16(0); // mod date
        try self.writeU32(crc); // crc32
        try self.writeU32(size); // compressed size
        try self.writeU32(size); // uncompressed size
        try self.writeU16(@intCast(name.len)); // filename length
        try self.writeU16(0); // extra field length
        try self.buffer.appendSlice(self.allocator, name); // filename
        try self.buffer.appendSlice(self.allocator, data); // file data

        // Store entry for central directory
        try self.entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .data = data,
            .crc32 = crc,
            .offset = offset,
        });
    }

    pub fn finish(self: *ZipWriter) ![]const u8 {
        const central_offset: u32 = @intCast(self.buffer.items.len);

        // Write central directory entries
        for (self.entries.items) |entry| {
            try self.buffer.appendSlice(self.allocator, &[_]u8{ 'P', 'K', 1, 2 }); // signature
            try self.writeU16(20); // version made by
            try self.writeU16(20); // version needed
            try self.writeU16(0); // flags
            try self.writeU16(0); // compression
            try self.writeU16(0); // mod time
            try self.writeU16(0); // mod date
            try self.writeU32(entry.crc32); // crc32
            try self.writeU32(@intCast(entry.data.len)); // compressed size
            try self.writeU32(@intCast(entry.data.len)); // uncompressed size
            try self.writeU16(@intCast(entry.name.len)); // filename length
            try self.writeU16(0); // extra field length
            try self.writeU16(0); // comment length
            try self.writeU16(0); // disk number start
            try self.writeU16(0); // internal file attributes
            try self.writeU32(0); // external file attributes
            try self.writeU32(entry.offset); // local header offset
            try self.buffer.appendSlice(self.allocator, entry.name); // filename
        }

        const central_size: u32 = @intCast(self.buffer.items.len - central_offset);
        const num_entries: u16 = @intCast(self.entries.items.len);

        // Write end of central directory (22 bytes)
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 'P', 'K', 5, 6 }); // signature
        try self.writeU16(0); // disk number
        try self.writeU16(0); // disk with central dir
        try self.writeU16(num_entries); // entries on this disk
        try self.writeU16(num_entries); // total entries
        try self.writeU32(central_size); // central directory size
        try self.writeU32(central_offset); // central directory offset
        try self.writeU16(0); // comment length

        return self.buffer.items;
    }
};
