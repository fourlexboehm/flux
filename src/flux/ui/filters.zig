const std = @import("std");
const zgui = @import("zgui");
const State = @import("state.zig").State;

pub fn findPluginListIndex(indices: []const i32, choice_index: i32) i32 {
    for (indices, 0..) |catalog_index, list_index| {
        if (catalog_index == choice_index) {
            return @intCast(list_index);
        }
    }
    return 0;
}

pub fn findPresetListIndex(indices: []const i32, choice_index: ?usize) i32 {
    if (choice_index == null) return 0;
    const target: i32 = @intCast(choice_index.?);
    for (indices, 0..) |preset_index, list_index| {
        if (preset_index == target) {
            return @intCast(list_index);
        }
    }
    return 0;
}

pub fn catalogIndexFromList(indices: []const i32, list_index: i32) ?i32 {
    if (indices.len == 0) return null;
    const idx: usize = @intCast(list_index);
    if (idx >= indices.len) return null;
    return indices[idx];
}

pub fn presetIndexFromList(indices: []const i32, list_index: i32) ?usize {
    if (indices.len == 0) return null;
    const idx: usize = @intCast(list_index);
    if (idx >= indices.len) return null;
    if (indices[idx] < 0) return null;
    return @intCast(indices[idx]);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn sanitizePresetName(name: []const u8) []const u8 {
    const slash_pos = std.mem.lastIndexOfScalar(u8, name, '/') orelse std.mem.lastIndexOfScalar(u8, name, '\\');
    const base = if (slash_pos) |idx| name[idx + 1 ..] else name;
    const ext = std.fs.path.extension(base);
    if (ext.len == 0) return base;
    return base[0 .. base.len - ext.len];
}

pub fn rebuildInstrumentFilter(state: *State) void {
    const filter = std.mem.sliceTo(&state.instrument_search_buf, 0);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(state.allocator);
    var indices: std.ArrayList(i32) = .empty;
    defer indices.deinit(state.allocator);

    var list_index: usize = 0;
    var start: usize = 0;
    while (start < state.plugin_instrument_items.len) {
        const end = std.mem.indexOfScalarPos(u8, state.plugin_instrument_items, start, 0) orelse break;
        if (end == start) break;
        const item = state.plugin_instrument_items[start..end];
        if (containsIgnoreCase(item, filter)) {
            buffer.appendSlice(state.allocator, item) catch {};
            buffer.append(state.allocator, 0) catch {};
            if (list_index < state.plugin_instrument_indices.len) {
                indices.append(state.allocator, state.plugin_instrument_indices[list_index]) catch {};
            }
        }
        list_index += 1;
        start = end + 1;
    }
    buffer.append(state.allocator, 0) catch {};

    if (state.instrument_filter_items_z.len > 0) {
        state.allocator.free(state.instrument_filter_items_z);
    }
    if (state.instrument_filter_indices.len > 0) {
        state.allocator.free(state.instrument_filter_indices);
    }
    state.instrument_filter_items_z = state.allocator.dupeZ(u8, buffer.items) catch &[_:0]u8{};
    state.instrument_filter_indices = indices.toOwnedSlice(state.allocator) catch &[_]i32{};
}

pub fn rebuildPresetFilter(state: *State) void {
    const filter = std.mem.sliceTo(&state.preset_search_buf, 0);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(state.allocator);
    var indices: std.ArrayList(i32) = .empty;
    defer indices.deinit(state.allocator);

    var max_width: f32 = 0.0;
    if (state.preset_catalog) |catalog| {
        const fonts_ready = zgui.io.getFontsTexRef().tex_data != null;
        // Compute max width from all presets so the combo width is stable.
        for (catalog.entries.items) |entry| {
            const clean_name = sanitizePresetName(entry.name);
            var label_buf: [256]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{s} - {s}", .{ clean_name, entry.plugin_name }) catch clean_name;
            if (fonts_ready) {
                const text_size = zgui.calcTextSize(label, .{});
                if (text_size[0] > max_width) max_width = text_size[0];
            }
        }
        for (catalog.entries.items, 0..) |entry, idx| {
            const clean_name = sanitizePresetName(entry.name);
            if (!containsIgnoreCase(clean_name, filter) and !containsIgnoreCase(entry.plugin_name, filter)) continue;
            var label_buf: [256]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{s} - {s}", .{ clean_name, entry.plugin_name }) catch clean_name;
            buffer.appendSlice(state.allocator, label) catch {};
            buffer.append(state.allocator, 0) catch {};
            indices.append(state.allocator, @intCast(idx)) catch {};
        }
    }
    buffer.append(state.allocator, 0) catch {};

    if (state.preset_filter_items_z.len > 0) {
        state.allocator.free(state.preset_filter_items_z);
    }
    if (state.preset_filter_indices.len > 0) {
        state.allocator.free(state.preset_filter_indices);
    }
    state.preset_filter_items_z = state.allocator.dupeZ(u8, buffer.items) catch &[_:0]u8{};
    state.preset_filter_indices = indices.toOwnedSlice(state.allocator) catch &[_]i32{};
    state.preset_combo_width = @max(260.0, max_width + 24.0);
}
