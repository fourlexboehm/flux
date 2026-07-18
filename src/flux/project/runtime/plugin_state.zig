const std = @import("std");
const clap = @import("clap-bindings");

const io_types = @import("../io_types.zig");

/// Capture plugin state for undo. Uses state_context extension with project context
/// when available, otherwise falls back to regular state extension.
pub fn capturePluginStateForUndo(allocator: std.mem.Allocator, plugin: *const clap.Plugin) ?[]u8 {
    var stream = MemoryOStream.init(allocator);
    stream.stream.context = &stream;

    // Try state_context extension first (allows plugin to provide optimized state for undo)
    if (plugin.getExtension(plugin, clap.ext.state_context.id)) |ext_raw| {
        const ext: *const clap.ext.state_context.Plugin = @ptrCast(@alignCast(ext_raw));
        if (ext.save(plugin, &stream.stream, .project)) {
            return allocator.dupe(u8, stream.buffer.items) catch {
                stream.buffer.deinit(allocator);
                return null;
            };
        }
        // If state_context.save failed, try regular state extension
        stream.buffer.clearRetainingCapacity();
    }

    // Fall back to regular state extension
    const state_ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse {
        stream.buffer.deinit(allocator);
        return null;
    };
    const state_ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(state_ext_raw));

    if (!state_ext.save(plugin, &stream.stream)) {
        stream.buffer.deinit(allocator);
        return null;
    }

    const data = allocator.dupe(u8, stream.buffer.items) catch {
        stream.buffer.deinit(allocator);
        return null;
    };
    stream.buffer.deinit(allocator);
    return data;
}

pub fn capturePluginStateForDawproject(
    allocator: std.mem.Allocator,
    plugin: *const clap.Plugin,
    track_index: usize,
    fx_index: ?usize,
) ?io_types.PluginStateFile {
    var stream = MemoryOStream.init(allocator);
    stream.stream.context = &stream;
    defer stream.buffer.deinit(allocator);

    if (plugin.getExtension(plugin, clap.ext.state_context.id)) |ext_raw| {
        const ext: *const clap.ext.state_context.Plugin = @ptrCast(@alignCast(ext_raw));
        if (!ext.save(plugin, &stream.stream, .project)) {
            stream.buffer.clearRetainingCapacity();
        }
    }

    if (stream.buffer.items.len == 0) {
        const ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse return null;
        const ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(ext_raw));
        if (!ext.save(plugin, &stream.stream)) {
            return null;
        }
    }

    // Build clap-preset container format:
    // [4 bytes: "clap" magic]
    // [4 bytes: plugin ID length (big-endian)]
    // [N bytes: plugin ID string]
    // [remaining: raw plugin state]
    const plugin_id = std.mem.span(plugin.descriptor.id);
    const plugin_id_len: u32 = @intCast(plugin_id.len);
    const header_size = 4 + 4 + plugin_id.len;
    const total_size = header_size + stream.buffer.items.len;

    var container = allocator.alloc(u8, total_size) catch return null;

    // Write magic "clap"
    container[0] = 'c';
    container[1] = 'l';
    container[2] = 'a';
    container[3] = 'p';

    // Write plugin ID length (big-endian)
    container[4] = @intCast((plugin_id_len >> 24) & 0xFF);
    container[5] = @intCast((plugin_id_len >> 16) & 0xFF);
    container[6] = @intCast((plugin_id_len >> 8) & 0xFF);
    container[7] = @intCast(plugin_id_len & 0xFF);

    // Write plugin ID
    @memcpy(container[8..][0..plugin_id.len], plugin_id);

    // Write raw plugin state
    @memcpy(container[header_size..], stream.buffer.items);

    var path_buf: [64]u8 = undefined;
    const plugin_path = if (fx_index) |fx_slot|
        std.fmt.bufPrint(&path_buf, "plugins/track{d}-fx{d}.clap-preset", .{ track_index, fx_slot }) catch return null
    else
        std.fmt.bufPrint(&path_buf, "plugins/track{d}.clap-preset", .{track_index}) catch return null;

    return .{
        .path = allocator.dupe(u8, plugin_path) catch return null,
        .data = container,
    };
}

pub fn loadPluginStateFromData(plugin: *const clap.Plugin, data: []const u8) void {
    const ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse return;
    const ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(ext_raw));

    const payload = stripClapPresetHeader(data) orelse data;
    var stream = MemoryIStream.init(payload);
    stream.stream.context = &stream;
    _ = ext.load(plugin, &stream.stream);
}

fn stripClapPresetHeader(data: []const u8) ?[]const u8 {
    if (data.len < 8) return null;
    if (!std.mem.eql(u8, data[0..4], "clap")) return null;
    const len: usize = (@as(usize, data[4]) << 24) |
        (@as(usize, data[5]) << 16) |
        (@as(usize, data[6]) << 8) |
        @as(usize, data[7]);
    if (data.len < 8 + len) return null;
    return data[(8 + len)..];
}

const MemoryOStream = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    stream: clap.OStream,

    pub fn init(allocator: std.mem.Allocator) MemoryOStream {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .stream = .{
                .context = undefined,
                .write = write,
            },
        };
    }

    fn write(stream: *const clap.OStream, buffer: *const anyopaque, size: u64) callconv(.c) clap.OStream.Result {
        const self: *MemoryOStream = @ptrCast(@alignCast(stream.context));
        const bytes = @as([*]const u8, @ptrCast(buffer))[0..@intCast(size)];
        self.buffer.appendSlice(self.allocator, bytes) catch return .write_error;
        return @enumFromInt(@as(i64, @intCast(bytes.len)));
    }
};

const MemoryIStream = struct {
    data: []const u8,
    offset: usize,
    stream: clap.IStream,

    pub fn init(data: []const u8) MemoryIStream {
        return .{
            .data = data,
            .offset = 0,
            .stream = .{
                .context = undefined,
                .read = read,
            },
        };
    }

    fn read(stream: *const clap.IStream, buffer: *anyopaque, size: u64) callconv(.c) clap.IStream.Result {
        const self: *MemoryIStream = @ptrCast(@alignCast(stream.context));
        if (self.offset >= self.data.len) {
            return .end_of_file;
        }

        const remaining = self.data.len - self.offset;
        const to_read = @min(remaining, @as(usize, @intCast(size)));
        const dest = @as([*]u8, @ptrCast(buffer))[0..to_read];
        @memcpy(dest, self.data[self.offset..][0..to_read]);
        self.offset += to_read;
        return @enumFromInt(@as(i64, @intCast(to_read)));
    }
};
