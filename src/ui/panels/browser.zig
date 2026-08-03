//! Browser sidebar: CLAP catalog, sample folders, and drag payloads onto tracks.
//!
//! Instruments / Audio Effects list plugins (click or drag). Sounds and other
//! sound categories list audio files from user Places folders. Drop targets:
//! session slots and arrangement lanes (`browser_item` drag name).

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const state_mod = @import("../state.zig");
const plugin_host = @import("../plugin_host.zig");
const host_mod = @import("../host.zig");
const media_drop = @import("../media_drop.zig");

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
const max_listed_files: usize = 200;

pub fn draw(state: *state_mod.State) void {
    if (!state.browser_open) return;

    // Clear stale drag payload once the gesture ends.
    if (state.browser_drag_kind != .none and !dvui.dragName(browser_drag_name)) {
        state.clearBrowserDrag();
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
        .color_fill = theme.cell,
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
        if (dvui.button(@src(), cat.label, .{}, .{
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

    if (dvui.button(@src(), "+ Add Folder…", .{}, .{
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
        if (dvui.button(@src(), if (state.browser_sort_asc) "Name ↑" else "Name ↓", .{}, .{
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
        .instruments => drawPluginList(state, false),
        .audio_effects => {
            drawPresetList(state, "sounds");
            drawPluginList(state, true);
        },
        else => {
            drawPresetList(state, categoryKey(state.browser_tab));
            drawSampleList(state);
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

fn drawPresetList(state: *state_mod.State, category: []const u8) void {
    if (!plugin_host.ready()) return;
    const entries = plugin_host.g.queryPresets(state.searchSlice(), category, state.browser_sort_asc);
    if (entries.len == 0) return;

    dvui.label(@src(), "Presets", .{}, .{
        .color_text = theme.text_soft,
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = tokens.gap_xs },
    });

    var list_column = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = tokens.plugin_list_w },
        .max_size_content = .width(tokens.plugin_list_w),
    });
    defer list_column.deinit();

    const max_show: usize = @min(entries.len, 80);
    for (entries[0..max_show], 0..) |entry, i| {
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
    if (entries.len > max_show) {
        dvui.label(@src(), "… {d} more (refine search)", .{entries.len - max_show}, .{
            .color_text = theme.text_dim,
        });
    }
}

fn drawPluginList(state: *state_mod.State, fx: bool) void {
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

    var list_column = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = tokens.plugin_list_w },
        .max_size_content = .width(tokens.plugin_list_w),
        .expand = .both,
    });
    defer list_column.deinit();

    var scroll = dvui.scrollArea(@src(), .{
        .horizontal_bar = .hide,
        .vertical_bar = .auto,
    }, .{
        .expand = .both,
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
    });
    defer scroll.deinit();

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

fn drawSampleList(state: *state_mod.State) void {
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

    var list_column = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
    });
    defer list_column.deinit();

    var scroll = dvui.scrollArea(@src(), .{
        .horizontal_bar = .hide,
        .vertical_bar = .auto,
    }, .{
        .expand = .both,
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
    });
    defer scroll.deinit();

    const filter = state.searchSlice();
    var shown: usize = 0;
    var list_id: usize = 0;

    if (state.browser_folder_selected) |fi| {
        shown += listFolder(state, fi, filter, &list_id);
    } else {
        for (0..state.browser_folder_count) |fi| {
            if (shown >= max_listed_files) break;
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

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var names: [max_listed_files][256]u8 = undefined;
    var name_lens: [max_listed_files]usize = undefined;
    var count: usize = 0;

    var iter = dir.iterateAssumeFirstIteration();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file or !hasAudioExt(entry.name)) continue;
        if (filter.len > 0 and !containsIgnoreCase(entry.name, filter)) continue;
        if (count >= max_listed_files) break;
        const n = @min(entry.name.len, names[count].len);
        @memcpy(names[count][0..n], entry.name[0..n]);
        name_lens[count] = n;
        count += 1;
    }

    sortNames(names[0..count], name_lens[0..count], state.browser_sort_asc);

    var shown: usize = 0;
    for (0..count) |i| {
        const name = names[i][0..name_lens[i]];
        var path_buf: [state_mod.browser_path_cap]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        const id = list_id.*;
        list_id.* += 1;
        drawSampleRow(state, name, full, id);
        shown += 1;
    }
    return shown;
}

fn drawSampleRow(state: *state_mod.State, name: []const u8, abs_path: []const u8, id_extra: usize) void {
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
                state.setBrowserAudioDrag(abs_path);
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
                dvui.dragEnd();
            },
            .position => if (wd.borderRectScale().r.contains(me.p)) {
                dvui.cursorSet(.hand);
            },
            else => {},
        }
    }
}



fn sortNames(names: [][256]u8, lens: []usize, ascending: bool) void {
    var i: usize = 0;
    while (i + 1 < names.len) : (i += 1) {
        var j = i + 1;
        while (j < names.len) : (j += 1) {
            const a = names[i][0..lens[i]];
            const b = names[j][0..lens[j]];
            const cmp = std.ascii.orderIgnoreCase(a, b);
            const swap = if (ascending) cmp == .gt else cmp == .lt;
            if (swap) {
                const tmp_name = names[i];
                const tmp_len = lens[i];
                names[i] = names[j];
                lens[i] = lens[j];
                names[j] = tmp_name;
                lens[j] = tmp_len;
            }
        }
    }
}

fn hasAudioExt(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    inline for (.{
        ".wav",  ".mp3",  ".ogg",  ".flac", ".aiff", ".aif",
        ".WAV",  ".MP3",  ".OGG",  ".FLAC", ".AIFF", ".AIF",
    }) |e| {
        if (std.mem.eql(u8, ext, e)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn categoryLabel(tab: state_mod.BrowserTab) []const u8 {
    for (categories) |cat| {
        if (cat.tab == tab) return cat.label;
    }
    return "Browser";
}
