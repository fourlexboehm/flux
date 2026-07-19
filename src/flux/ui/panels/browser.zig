const std = @import("std");
const zgui = @import("zgui");
const colors = @import("../theme/colors.zig");
const tokens = @import("../theme/tokens.zig");
const file_dialog = @import("../../app/file_dialog.zig");
const presets = @import("../../plugin/presets.zig");

const Colors = colors.Colors;
const ui_io: std.Io = std.Io.Threaded.global_single_threaded.io();

pub const BrowserTab = enum { sounds, drums, instruments, audio_effects, plugins };

pub const PluginSelection = struct {
    catalog_index: i32,
    is_fx: bool,
};

pub fn draw(
    open: *bool,
    width: *f32,
    active_tab: *BrowserTab,
    search_buf: [:0]u8,
    sort_asc: *bool,
    folders: *std.ArrayListUnmanaged([]u8),
    plugin_instrument_items: [:0]const u8,
    plugin_instrument_indices: []const i32,
    plugin_fx_items: [:0]const u8,
    plugin_fx_indices: []const i32,
    preset_entries: []const presets.PresetEntry,
    preset_selected: *?usize,
    plugin_selected: *?PluginSelection,
    alloc: std.mem.Allocator,
    ui_scale: f32,
) void {
    if (!open.*) {
        if (zgui.button(">", .{ .w = tokens.s(32, ui_scale), .h = tokens.s(25, ui_scale) })) open.* = true;
        return;
    }

    const available_w = zgui.getContentRegionAvail()[0];
    const max_w = available_w * 0.6;
    const min_w = @min(tokens.s(600, ui_scale), max_w);
    width.* = std.math.clamp(width.*, min_w, max_w);

    if (zgui.beginChild("##browser", .{
        .w = width.*,
        .h = zgui.getContentRegionAvail()[1],
        .child_flags = .{ .resize_x = true, .border = true },
        .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true },
    })) {
        defer {
            zgui.endChild();
            width.* = std.math.clamp(zgui.getItemRectSize()[0], min_w, max_w);
        }

        if (zgui.button("<", .{ .w = tokens.s(32, ui_scale), .h = zgui.getFrameHeight() })) open.* = false;

        zgui.sameLine(.{ .spacing = tokens.s(5, ui_scale) });
        zgui.setNextItemWidth(zgui.getContentRegionAvail()[0]);
        _ = zgui.inputTextWithHint("##browser_search", .{ .hint = "Search...", .buf = search_buf, .flags = .{ .auto_select_all = true } });

        zgui.separatorText("Browser");
        if (!zgui.beginTable("sidebar_columns", .{
            .column = 2,
            .flags = .{ .resizable = true, .borders = .{ .inner_v = true }, .sizing = .fixed_fit },
            .outer_size = .{ 0, zgui.getContentRegionAvail()[1] },
        })) return;
        defer zgui.endTable();
        zgui.tableSetupColumn("##sidebar_nav", .{
            .flags = .{ .width_fixed = true },
            .init_width_or_height = @min(tokens.s(190, ui_scale), width.* * 0.5),
        });
        zgui.tableSetupColumn("##sidebar_content", .{ .flags = .{ .width_stretch = true } });

        _ = zgui.tableNextColumn();
        sideLeft(active_tab, folders, alloc, ui_scale);
        _ = zgui.tableNextColumn();
        sideRight(active_tab, sort_asc, folders, plugin_instrument_items, plugin_instrument_indices, plugin_fx_items, plugin_fx_indices, preset_entries, preset_selected, plugin_selected, search_buf);
    }
}

fn sideLeft(active_tab: *BrowserTab, folders: *std.ArrayListUnmanaged([]u8), alloc: std.mem.Allocator, ui_scale: f32) void {
    sectionLabel("Collections");
    const clrs = [_][4]f32{
        .{ 1, 0.02, 0.02, 1 },    .{ 1, 0.65, 0.16, 1 },    .{ 1, 0.94, 0.20, 1 },
        .{ 0.15, 1, 0.66, 1 },    .{ 0.06, 0.64, 0.93, 1 }, .{ 0.72, 0.55, 1, 1 },
        .{ 0.66, 0.66, 0.66, 1 },
    };
    const coll_names = [_][:0]const u8{ "Favorites", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray" };
    for (clrs, 0..) |c, i| {
        zgui.pushStyleColor4f(.{ .idx = .text, .c = c });
        zgui.textUnformatted("■");
        zgui.popStyleColor(.{ .count = 1 });
        zgui.sameLine(.{ .spacing = tokens.s(5, ui_scale) });
        _ = zgui.selectable(coll_names[i], .{});
    }

    zgui.spacing();
    sectionLabel("Categories");
    const cats = [_]struct { name: [:0]const u8, tab: BrowserTab }{
        .{ .name = "Sounds", .tab = .sounds },
        .{ .name = "Drums", .tab = .drums },
        .{ .name = "Instruments", .tab = .instruments },
        .{ .name = "Audio Effects", .tab = .audio_effects },
        .{ .name = "Plug-Ins", .tab = .plugins },
    };
    for (cats) |cat| {
        const sel = active_tab.* == cat.tab;
        if (sel) zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.accent });
        if (zgui.selectable(cat.name, .{ .selected = sel })) active_tab.* = cat.tab;
        if (sel) zgui.popStyleColor(.{ .count = 1 });
    }

    zgui.spacing();
    sectionLabel("Places");
    if (zgui.selectable("+ Add Folder...", .{})) {
        if (file_dialog.openFolder(alloc, ui_io, "Add Audio Folder") catch null) |p| {
            folders.append(alloc, @constCast(p)) catch {};
        }
    }
    if (zgui.isItemHovered(.{})) zgui.setMouseCursor(.hand);

    for (folders.items) |f_path| {
        var buf: [256]u8 = undefined;
        const n = std.fs.path.basename(f_path);
        const label = std.fmt.bufPrintSentinel(&buf, "{s}##pl_{d}", .{ n, @intFromPtr(f_path.ptr) }, 0) catch continue;
        _ = zgui.selectable(label, .{});
    }
}

fn sideRight(
    active_tab: *BrowserTab,
    sort_asc: *bool,
    folders: *std.ArrayListUnmanaged([]u8),
    plugin_instrument_items: [:0]const u8,
    plugin_instrument_indices: []const i32,
    plugin_fx_items: [:0]const u8,
    plugin_fx_indices: []const i32,
    preset_entries: []const presets.PresetEntry,
    preset_selected: *?usize,
    plugin_selected: *?PluginSelection,
    search_buf: [:0]const u8,
) void {
    if (zgui.beginChild("sidebar_right", .{ .w = 0, .h = 0, .window_flags = .{ .menu_bar = true } })) {
        _ = zgui.beginMenuBar();
        const sort_label = if (sort_asc.*) " Name ^" else " Name v";
        if (zgui.selectable(sort_label, .{})) sort_asc.* = !sort_asc.*;
        zgui.endMenuBar();

        switch (active_tab.*) {
            .sounds, .drums => placehold("Not implemented"),
            .instruments => {
                sectionLabel("Presets");
                drawPresets(preset_entries, preset_selected, search_buf);
                zgui.separator();
                sectionLabel("Plugins");
                drawPluginList(plugin_instrument_items, plugin_instrument_indices, false, plugin_selected, search_buf);
            },
            .audio_effects => drawPluginList(plugin_fx_items, plugin_fx_indices, true, plugin_selected, search_buf),
            .plugins => {
                drawPluginList(plugin_instrument_items, plugin_instrument_indices, false, plugin_selected, search_buf);
                zgui.separator();
                drawPluginList(plugin_fx_items, plugin_fx_indices, true, plugin_selected, search_buf);
            },
        }

        for (folders.items) |f_path| listDir(f_path) catch {};
    }
    zgui.endChild();
}

fn drawPluginList(items: [:0]const u8, indices: []const i32, is_fx: bool, plugin_selected: *?PluginSelection, filter: [:0]const u8) void {
    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    var idx: usize = 0;
    while (pos < items.len and items[pos] != 0) : (pos += 1) {
        const end = std.mem.indexOfScalarPos(u8, items, pos, 0) orelse items.len;
        const name = items[pos..end];
        const len = @min(name.len, buf.len - 1);
        @memcpy(buf[0..len], name[0..len]);
        buf[len] = 0;

        if (filter[0] != 0 and !containsIgnoreCase(name, std.mem.sliceTo(filter[0..], 0))) {
            pos = end;
            idx += 1;
            continue;
        }

        if (zgui.selectable(buf[0..len :0], .{})) {
            if (idx < indices.len) plugin_selected.* = .{ .catalog_index = indices[idx], .is_fx = is_fx };
        }
        pos = end;
        idx += 1;
    }
}

fn drawPresets(entries: []const presets.PresetEntry, preset_selected: *?usize, filter: [:0]const u8) void {
    const f: []const u8 = if (filter[0] != 0) std.mem.sliceTo(filter[0..], 0) else "";
    var buf: [256]u8 = undefined;
    for (entries, 0..) |entry, idx| {
        if (f.len > 0 and !containsIgnoreCase(entry.name, f) and !containsIgnoreCase(entry.plugin_name, f)) continue;
        const len = @min(entry.name.len, buf.len - 1);
        @memcpy(buf[0..len], entry.name[0..len]);
        buf[len] = 0;
        if (zgui.selectable(buf[0..len :0], .{})) preset_selected.* = idx;
        if (zgui.isItemHovered(.{})) {
            if (zgui.beginTooltip()) {
                zgui.textUnformatted(entry.plugin_name);
                zgui.endTooltip();
            }
        }
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn placehold(msg: []const u8) void {
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_soft });
    zgui.textUnformatted(msg);
    zgui.popStyleColor(.{ .count = 1 });
}

fn sectionLabel(text: []const u8) void {
    zgui.pushStyleColor4f(.{ .idx = .text, .c = .{ 0.8, 0.8, 0.8, 1 } });
    zgui.textUnformatted(text);
    zgui.popStyleColor(.{ .count = 1 });
}

fn listDir(dir_path: []const u8) !void {
    var dir = try std.Io.Dir.openDirAbsolute(ui_io, dir_path, .{ .iterate = true });
    defer dir.close(ui_io);
    var iter = dir.iterateAssumeFirstIteration();
    var buf: [512]u8 = undefined;
    while (try iter.next(ui_io)) |entry| {
        if (entry.kind != .file or !hasAudioMidiExt(entry.name)) continue;
        const label = std.fmt.bufPrintSentinel(&buf, "{s}##dir", .{entry.name}, 0) catch continue;
        _ = zgui.selectable(label, .{});
    }
}

fn hasAudioMidiExt(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    inline for (.{ ".wav", ".mp3", ".mid", ".ogg", ".flac", ".aiff", ".aif", ".WAV", ".MP3", ".MID" }) |e| {
        if (std.mem.eql(u8, ext, e)) return true;
    }
    return false;
}
