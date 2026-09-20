//! Browser sidebar: CLAP catalog, sample folders, and drag payloads onto tracks.
//!
//! Instruments / Audio Effects list plugins (click or drag). Sounds and other
//! sound categories list audio files from user Places folders. Drop targets:
//! session slots and arrangement lanes (`browser_item` drag name).

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../theme.zig");
const icons = @import("../icons.zig");
const tokens = @import("../tokens.zig");
const state_mod = @import("../state.zig");
const plugin_host = @import("../plugin_host.zig");
const host_mod = @import("../host.zig");
const media_drop = @import("../media_drop.zig");
const browser_files = @import("browser_files.zig");

var file_caches: [state_mod.max_browser_folders]browser_files.Cache = @splat(.{});
var captured_sample_id: ?usize = null;

pub fn deinit() void {
    for (&file_caches) |*cache| cache.deinit();
    captured_sample_id = null;
}

const Category = struct {
    tab: state_mod.BrowserTab,
    label: []const u8,
};

const categories = [_]Category{
    .{ .tab = .sounds, .label = "Sounds" },
    .{ .tab = .drums, .label = "Drums" },
    .{ .tab = .bass, .label = "Bass" },
    .{ .tab = .pad, .label = "Pads" },
    .{ .tab = .lead, .label = "Leads" },
    .{ .tab = .keys, .label = "Keys" },
    .{ .tab = .noise, .label = "Noise" },
    .{ .tab = .instruments, .label = "Instruments" },
    .{ .tab = .audio_effects, .label = "Audio Effects" },
};

const browser_drag_name = "browser_item";
const io: std.Io = std.Io.Threaded.global_single_threaded.io();

pub fn draw(state: *state_mod.State) void {
    if (!state.browser_open) return;

    // Clear stale drag payload once the gesture ends.
    if (state.browser_drag_kind != .none and !dvui.dragName(browser_drag_name)) {
        state.clearBrowserDrag();
        captured_sample_id = null;
    }

    var side = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = theme.panel,
        .expand = .both,
        .padding = dvui.Rect.all(tokens.pad_panel),
        .corners = .round(tokens.radius_md),
    });
    defer side.deinit();

    dvui.label(@src(), "Browser", .{}, .{
        .font = .theme(.heading),
        .color_text = theme.text,
    });

    // Search
    {
        var search_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = tokens.gap_tight },
        });
        defer search_row.deinit();

        icons.draw(@src(), .search, .{ .size = tokens.icon_md, .gravity_x = 0 });
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &state.browser_search },
            .placeholder = "Search…",
        }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = tokens.control_h },
        });
        const text = te.getText();
        state.browser_search_len = text.len;
        te.deinit();
        if (state.browser_search_len > 0 and icons.button(@src(), .close, .{})) {
            @memset(&state.browser_search, 0);
            state.browser_search_len = 0;
        }
    }

    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
    });
    defer body.deinit();

    drawNav(state);
    drawContent(state);
}

fn drawNav(state: *state_mod.State) void {
    var nav = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = theme.panel,
        .min_size_content = .{ .w = tokens.browser_nav_w },
        .expand = .vertical,
        .padding = dvui.Rect.all(tokens.gap_tight),
        .corners = .round(tokens.radius_sm),
        .margin = .{ .x = 0, .y = 0, .w = tokens.gap_tight, .h = 0 },
    });
    defer nav.deinit();

    var nav_scroll = dvui.scrollArea(@src(), .{
        .horizontal_bar = .hide,
        .vertical_bar = .auto,
    }, .{ .expand = .both });
    defer nav_scroll.deinit();

    dvui.label(@src(), "Categories", .{}, .{
        .color_text = theme.text_soft,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_xs },
    });

    for (categories, 0..) |cat, i| {
        const selected = state.browser_tab == cat.tab;
        const fill = if (selected) theme.accent else theme.panel;
        const text = if (selected) theme.bg else theme.text;
        if (icons.navigation(@src(), if (cat.tab == .audio_effects) .effect else .instrument, cat.label, .{
            .expand = .horizontal,
            .color_fill = fill,
            .color_text = text,
            .min_size_content = .{ .h = tokens.control_h - 2 },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            .corners = .round(tokens.radius_sm),
            .id_extra = i,
        })) {
            state.setBrowserTab(cat.tab);
        }
    }

    dvui.label(@src(), "Places", .{}, .{
        .color_text = theme.text_soft,
        .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = tokens.gap_xs },
    });

    if (icons.navigation(@src(), .plus, "Add folder", .{
        .expand = .horizontal,
        .color_fill = theme.panel,
        .color_text = theme.text,
        .min_size_content = .{ .h = tokens.control_h - 2 },
        .corners = .round(tokens.radius_sm),
    })) {
        addFolder(state);
    }

    for (0..state.browser_folder_count) |i| {
        const path = state.browserFolder(i);
        const base = std.fs.path.basename(path);
        const selected = state.browser_folder_selected == i;
        if (dvui.button(@src(), base, .{}, .{
            .expand = .horizontal,
            .color_fill = if (selected) theme.accent else theme.panel,
            .color_text = if (selected) theme.bg else theme.text,
            .min_size_content = .{ .h = tokens.control_h - 2 },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            .corners = .round(tokens.radius_sm),
            .id_extra = 100 + i,
        })) {
            state.browser_folder_selected = if (selected) null else i;
            // Sample categories surface folder contents.
            if (state.browser_tab == .instruments or state.browser_tab == .audio_effects) {
                state.setBrowserTab(.sounds);
            }
        }
    }
}

fn addFolder(state: *state_mod.State) void {
    const allocator = if (host_mod.ready()) host_mod.g.allocator else return;
    const path = dvui.dialogNativeFolderSelect(allocator, .{
        .title = "Add Audio Folder",
    }) catch null;
    const p = path orelse return;
    defer allocator.free(p);
    _ = state.addBrowserFolder(p);
    if (state.browser_folder_count > 0) {
        state.browser_folder_selected = state.browser_folder_count - 1;
    }
}

fn drawContent(state: *state_mod.State) void {
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = theme.cell,
        .expand = .both,
        .padding = dvui.Rect.all(tokens.pad_panel),
        .corners = .round(tokens.radius_sm),
    });
    defer content.deinit();

    const tab_name = categoryLabel(state.browser_tab);
    {
        var title_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer title_row.deinit();
        dvui.label(@src(), "{s}", .{tab_name}, .{
            .font = .theme(.heading),
            .color_text = theme.text,
            .gravity_y = 0.5,
        });
        if (icons.navigation(@src(), if (state.browser_sort_asc) .sort_up else .sort_down, "Name", .{
            .min_size_content = .{ .h = tokens.control_h },
            .margin = .{ .x = tokens.gap_group, .y = 0, .w = 0, .h = 0 },
            .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
            .corners = .round(tokens.radius_sm),
            .gravity_y = 0.5,
        })) {
            state.browser_sort_asc = !state.browser_sort_asc;
        }
    }

    if (state.browser_search_len > 0) {
        dvui.label(@src(), "Filter: \"{s}\"", .{state.searchSlice()}, .{
            .color_text = theme.text_dim,
            .margin = .{ .x = 0, .y = tokens.gap_xs, .w = 0, .h = 0 },
        });
    }

    switch (state.browser_tab) {
        .instruments => drawScrollable(state, .instruments),
        .audio_effects => drawScrollable(state, .audio_effects),
        else => drawScrollable(state, state.browser_tab),
    }
}

/// Single scroll container for the browser lists below the title/filter.
/// Previously only the plugin/sample lists had their own scrollArea while the
/// preset list grew unbounded, so Sounds/Drums/Bass/… overflowed with no
/// scroll or gesture handling. One shared scrollArea keeps the header pinned
/// and lets every big list scroll together.
fn drawScrollable(state: *state_mod.State, tab: state_mod.BrowserTab) void {
    var scroll = dvui.scrollArea(@src(), .{
        .horizontal_bar = .hide,
        .vertical_bar = .auto,
    }, .{
        .expand = .both,
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        .id_extra = @backingInt(tab),
    });
    defer scroll.deinit();

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
    });
    defer col.deinit();

    switch (tab) {
        .instruments => drawPluginRows(state, false),
        .audio_effects => {
            drawPresetRows(state, "sounds");
            drawPluginRows(state, true);
        },
        else => {
            drawPresetRows(state, categoryKey(tab));
            drawSampleRows(state);
        },
    }
}

fn categoryKey(tab: state_mod.BrowserTab) []const u8 {
    return switch (tab) {
        .sounds => "sounds",
        .drums => "drums",
        .bass => "bass",
        .pad => "pad",
        .lead => "lead",
        .keys => "keys",
        .noise => "noise",
        .instruments, .audio_effects => "sounds",
    };
}

fn drawPresetRows(state: *state_mod.State, category: []const u8) void {
    if (!plugin_host.ready()) return;
    const entries = plugin_host.g.queryPresets(state.searchSlice(), category, state.browser_sort_asc);
    if (entries.len == 0) return;

    dvui.label(@src(), "Presets", .{}, .{
        .color_text = theme.text_soft,
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = tokens.gap_xs },
    });

    // Show the full result list; the surrounding scrollArea handles overflow.
    for (entries, 0..) |entry, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.panel,
            .min_size_content = .{ .h = tokens.control_h - 2 },
            .corners = .round(tokens.radius_sm),
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
            .id_extra = i,
        });
        defer row.deinit();

        dvui.label(@src(), "{s}", .{entry.name}, .{
            .color_text = theme.text,
            .gravity_y = 0.5,
            .id_extra = i,
        });

        const wd = row.data();
        for (dvui.events()) |*e| {
            if (e.evt != .mouse) continue;
            const me = e.evt.mouse;
            if (!dvui.eventMatchSimple(e, wd)) continue;
            if (me.action == .press and me.button.pointer()) {
                e.handle(@src(), wd);
                plugin_host.g.loadPresetOnTrack(state.selected_track, entry);
                state.bottom_mode = .device;
                state.selectDeviceInstrument();
            }
        }
    }
}

fn drawPluginRows(state: *state_mod.State, fx: bool) void {
    if (!plugin_host.ready() or !plugin_host.g.catalog_ready) {
        dvui.label(@src(), "Plugin catalog not ready.", .{}, .{
            .color_text = theme.text_soft,
            .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = 0 },
        });
        return;
    }

    const ph = &plugin_host.g;
    const choices: []const i32 = if (fx) ph.fxChoices() else ph.instrumentChoices();
    const filter = state.searchSlice();
    const track = state.selected_track;

    var shown: usize = 0;
    for (choices, 0..) |choice, i| {
        if (!ph.matchesSearch(choice, filter)) continue;
        const name = ph.entryName(choice);
        if (name.len == 0) continue;
        shown += 1;
        drawPluginRow(state, name, choice, fx, track, i);
    }

    if (shown == 0) {
        dvui.label(@src(), "No matching plugins. Build clap bundles or install system CLAPs.", .{}, .{
            .color_text = theme.text_soft,
        });
    } else {
        dvui.label(@src(), "{d} plugins — click to load · drag onto tracks", .{shown}, .{
            .color_text = theme.text_dim,
            .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        });
    }
}

fn drawPluginRow(
    state: *state_mod.State,
    name: []const u8,
    choice: i32,
    is_fx: bool,
    track: usize,
    id_extra: usize,
) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.panel,
        .min_size_content = .{ .h = tokens.control_h - 2 },
        .corners = .round(tokens.radius_sm),
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
        .id_extra = id_extra,
    });
    defer row.deinit();

    dvui.label(@src(), "{s}", .{name}, .{
        .color_text = theme.text,
        .gravity_y = 0.5,
        .id_extra = id_extra,
    });

    const wd = row.data();
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        const captured = dvui.captured(wd.id);
        if (!captured and !dvui.eventMatchSimple(e, wd)) continue;
        switch (me.action) {
            .press => {
                if (!me.button.pointer()) continue;
                e.handle(@src(), wd);
                state.setBrowserPluginDrag(choice, is_fx);
                dvui.captureMouse(wd, e.num);
                dvui.dragPreStart(me.button, me.p, .{ .name = browser_drag_name });
            },
            .motion => if (captured) {
                e.handle(@src(), wd);
                if (dvui.dragging(me.p, browser_drag_name) != null) dvui.cursorSet(.hand);
            },
            .release => if (me.button.pointer() and captured) {
                e.handle(@src(), wd);
                const dragged = dvui.dragging(me.p, browser_drag_name) != null;
                dvui.captureMouse(null, e.num);
                if (dragged) {
                    _ = media_drop.applyBrowserDropAt(state, me.p);
                } else if (plugin_host.ready()) {
                    if (is_fx) {
                        if (plugin_host.g.addFxSlot(track, choice)) {
                            state.bottom_mode = .device;
                            state.selectDeviceFx(plugin_host.g.fx_counts[track] - 1);
                        }
                    } else {
                        plugin_host.g.setInstrumentChoice(track, choice);
                        state.bottom_mode = .device;
                        state.selectDeviceInstrument();
                    }
                }
                state.clearBrowserDrag();
                dvui.dragEnd();
            },
            .position => if (wd.borderRectScale().r.contains(me.p)) {
                dvui.cursorSet(.hand);
            },
            else => {},
        }
    }
}

fn drawSampleRows(state: *state_mod.State) void {
    if (state.browser_folder_count == 0) {
        dvui.label(@src(), "Add a Places folder to browse samples (wav/aiff/flac/ogg/mp3).", .{}, .{
            .color_text = theme.text_soft,
            .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = 0 },
        });
        dvui.label(@src(), "Click a file to load into the selected slot · drag onto session or arrangement.", .{}, .{
            .color_text = theme.text_dim,
            .margin = .{ .x = 0, .y = tokens.gap_xs, .w = 0, .h = 0 },
        });
        return;
    }

    const filter = state.searchSlice();
    var shown: usize = 0;
    var list_id: usize = 0;

    if (state.browser_folder_selected) |fi| {
        shown += listFolder(state, fi, filter, &list_id);
    } else {
        for (0..state.browser_folder_count) |fi| {
            const path = state.browserFolder(fi);
            const base = std.fs.path.basename(path);
            dvui.label(@src(), "{s}", .{base}, .{
                .color_text = theme.text_soft,
                .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = tokens.gap_xs },
                .id_extra = fi,
            });
            shown += listFolder(state, fi, filter, &list_id);
        }
    }

    if (shown == 0) {
        dvui.label(@src(), "No matching audio files in Places folders.", .{}, .{
            .color_text = theme.text_soft,
        });
    } else {
        dvui.label(@src(), "{d} files — click / drag onto tracks", .{shown}, .{
            .color_text = theme.text_dim,
            .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        });
    }
}

fn listFolder(state: *state_mod.State, folder_index: usize, filter: []const u8, list_id: *usize) usize {
    const dir_path = state.browserFolder(folder_index);
    if (dir_path.len == 0) return 0;

    const names = file_caches[folder_index].query(io, dir_path, filter, state.browser_sort_asc) catch return 0;
    const row_height = tokens.control_h;
    var list = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = row_height * @as(f32, @floatFromInt(names.len)) },
        .id_extra = folder_index,
    });
    defer list.deinit();
    const rs = list.data().contentRectScale();
    const clip = dvui.clipGet();
    const physical_height = row_height * rs.s;
    const first: usize = @intFromFloat(@min(@as(f32, @floatFromInt(names.len)), @max(0, @floor((clip.y - rs.r.y) / physical_height))));
    const end: usize = @intFromFloat(@min(@as(f32, @floatFromInt(names.len)), @max(0, @ceil((clip.y + clip.h - rs.r.y) / physical_height))));
    const base_id = list_id.*;
    list_id.* += names.len;
    // Keep a captured row alive even after it scrolls outside the viewport.
    const captured = if (captured_sample_id) |id| if (id >= base_id and id - base_id < names.len) id - base_id else null else null;
    var i = first;
    while (i < end) : (i += 1) {
        var path_buf: [state_mod.browser_path_cap]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, names[i] }) catch continue;
        drawSampleRow(state, names[i], full, base_id + i, .{ .y = row_height * @as(f32, @floatFromInt(i)), .w = list.data().contentRect().w, .h = row_height });
    }
    if (captured) |index| {
        if (index < first or index >= end) {
            var path_buf: [state_mod.browser_path_cap]u8 = undefined;
            const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, names[index] }) catch return names.len;
            drawSampleRow(state, names[index], full, base_id + index, .{ .y = row_height * @as(f32, @floatFromInt(index)), .w = list.data().contentRect().w, .h = row_height });
        }
    }
    return names.len;
}

fn drawSampleRow(state: *state_mod.State, name: []const u8, abs_path: []const u8, id_extra: usize, rect: dvui.Rect) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .rect = rect,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.panel,
        .min_size_content = .{ .h = tokens.control_h - 2 },
        .corners = .round(tokens.radius_sm),
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
        .id_extra = id_extra,
    });
    defer row.deinit();

    dvui.label(@src(), "{s}", .{name}, .{
        .color_text = theme.text,
        .gravity_y = 0.5,
        .id_extra = id_extra,
    });

    const wd = row.data();
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        const captured = dvui.captured(wd.id);
        if (!captured and !dvui.eventMatchSimple(e, wd)) continue;
        switch (me.action) {
            .press => {
                if (!me.button.pointer()) continue;
                e.handle(@src(), wd);
                state.setBrowserAudioDrag(abs_path);
                captured_sample_id = id_extra;
                dvui.captureMouse(wd, e.num);
                dvui.dragPreStart(me.button, me.p, .{ .name = browser_drag_name });
            },
            .motion => if (captured) {
                e.handle(@src(), wd);
                if (dvui.dragging(me.p, browser_drag_name) != null) dvui.cursorSet(.hand);
            },
            .release => if (me.button.pointer() and captured) {
                e.handle(@src(), wd);
                const dragged = dvui.dragging(me.p, browser_drag_name) != null;
                dvui.captureMouse(null, e.num);
                if (dragged) {
                    if (!media_drop.applyBrowserDropAt(state, me.p)) {
                        // Dropped nowhere: still load into selection (gentle fallback).
                        const path = state.browserDragPath();
                        if (path.len > 0) _ = media_drop.loadAudioAtSelection(state, path);
                    }
                } else {
                    const path = state.browserDragPath();
                    if (path.len > 0) _ = media_drop.loadAudioAtSelection(state, path);
                }
                state.clearBrowserDrag();
                captured_sample_id = null;
                dvui.dragEnd();
            },
            .position => if (wd.borderRectScale().r.contains(me.p)) {
                dvui.cursorSet(.hand);
            },
            else => {},
        }
    }
}

fn categoryLabel(tab: state_mod.BrowserTab) []const u8 {
    for (categories) |cat| {
        if (cat.tab == tab) return cat.label;
    }
    return "Browser";
}
