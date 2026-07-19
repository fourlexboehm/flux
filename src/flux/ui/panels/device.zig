const std = @import("std");
const zgui = @import("zgui");
const clap = @import("clap-bindings");

const colors = @import("../theme/colors.zig");
const filters = @import("filters.zig");
const embedded_views = @import("embedded_views.zig");
const selection = @import("../input/selection.zig");
const controller_mapping = @import("../../midi/controller_mapping.zig");
const session_view = @import("../../session/types.zig");
const session_constants = @import("../../session/constants.zig");
const state_mod = @import("../state.zig");
const widgets = @import("../theme/widgets.zig");
const tokens = @import("../theme/tokens.zig");
const State = state_mod.State;

const Colors = colors.Colors;

const label_col_w = 80.0;
const search_col_w = 140.0;
const combo_col_w = 200.0;

pub fn drawDevicePanel(state: *State, ui_scale: f32) void {
    const is_master = state.session.mixer_target == .master;
    const track_idx = if (is_master) session_view.master_track_index else state.selectedTrack();

    // Keep device target on the selected track.
    if (state.device_target_track != track_idx) {
        state.device_target_track = track_idx;
        state.device_target_kind = if (is_master) .fx else .instrument;
        state.device_target_fx = 0;
    }
    if (is_master) {
        state.device_target_kind = .fx;
        if (state.device_target_fx >= state.track_fx_slot_count[track_idx]) {
            state.device_target_fx = 0;
        }
    }

    // ── Device chain (horizontal scroll): Inst | FX1 | FX2 | … ────────────
    // Selection drives the embed area; chip highlight = selected device.
    // No separate "open window" toggle fighting selection for stock FX.
    drawDeviceChain(state, track_idx, is_master, ui_scale);
    zgui.spacing();

    // ── Inspectors for the selected chain slot ────────────────────────────
    switch (state.device_target_kind) {
        .instrument => if (!is_master) drawInstrumentInspector(state, track_idx, ui_scale),
        .fx => drawFxInspector(state, track_idx, ui_scale),
    }

    zgui.spacing();
    // Instrument open (moved above Smart 8 — same control as before, new place)
    if (!is_master) {
        const track_plugin = &state.track_plugins[track_idx];
        const instrument_ready = state.track_plugin_ptrs[track_idx] != null;
        const inst_tip = if (track_plugin.gui_open) "Close instrument window" else "Open instrument window";
        if (widgets.iconToggle("##instrument_open", .open_window, ui_scale, inst_tip, track_plugin.gui_open, !instrument_ready)) {
            const opening = !track_plugin.gui_open;
            if (opening) {
                for (0..state_mod.max_fx_slots) |fx_index| {
                    state.track_fx[track_idx][fx_index].gui_open = false;
                }
                track_plugin.gui_open = true;
            } else {
                track_plugin.gui_open = false;
            }
            state.device_target_kind = .instrument;
            state.device_target_fx = 0;
        }
    }
    drawControllerSummary(state, ui_scale);
    zgui.separator();

    // ── Selected device body ──────────────────────────────────────────────
    switch (state.device_kind) {
        .plugin => {
            if (state.device_clap_plugin) |plugin| {
                if (embedded_views.getEmbeddedView(plugin)) |draw_fn| {
                    if (zgui.beginChild("plugin_embed##device", .{ .w = 0, .h = 0 })) {
                        draw_fn(plugin);
                    }
                    zgui.endChild();
                } else {
                    drawClapDevice(state, ui_scale);
                }
            } else {
                drawNoDevice();
            }
        },
        .none => drawNoDevice(),
    }
}

/// Horizontal chain of devices — click a chip to select (and show) it.
fn drawDeviceChain(state: *State, track_idx: usize, is_master: bool, ui_scale: f32) void {
    const chip_h = tokens.controlH(.md, ui_scale);
    const chain_h = chip_h + tokens.s(10, ui_scale);

    if (!zgui.beginChild("##device_chain", .{
        .w = 0,
        .h = chain_h,
        .child_flags = .{ .border = false },
        .window_flags = .{ .horizontal_scrollbar = true, .no_scroll_with_mouse = false },
    })) {
        zgui.endChild();
        return;
    }
    defer zgui.endChild();

    var first = true;

    if (!is_master) {
        const inst = &state.track_plugins[track_idx];
        const name = pluginDisplayName(
            state.plugin_instrument_items,
            state.plugin_instrument_indices,
            inst.choice_index,
            "Instrument",
        );
        var lab_buf: [96]u8 = undefined;
        const lab = if (inst.choice_index == 0)
            std.fmt.bufPrintSentinel(&lab_buf, "Inst##chain_inst", .{}, 0) catch "Inst"
        else
            std.fmt.bufPrintSentinel(&lab_buf, "{s}##chain_inst", .{name}, 0) catch "Inst";
        const selected = state.device_target_kind == .instrument;
        if (chainChip(lab, selected, inst.choice_index != 0, chip_h, ui_scale)) {
            selectDevice(state, track_idx, .instrument, 0, is_master);
        }
        first = false;
    }

    const fx_slot_count = state.track_fx_slot_count[track_idx];
    for (0..fx_slot_count) |fx_index| {
        if (!first) {
            zgui.sameLine(.{ .spacing = tokens.s(4, ui_scale) });
            // Small chevron between stages
            zgui.alignTextToFramePadding();
            zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_soft });
            zgui.textUnformatted("›");
            zgui.popStyleColor(.{ .count = 1 });
            zgui.sameLine(.{ .spacing = tokens.s(4, ui_scale) });
        }
        first = false;

        const fx = &state.track_fx[track_idx][fx_index];
        const name = pluginDisplayName(state.plugin_fx_items, state.plugin_fx_indices, fx.choice_index, "FX");
        var lab_buf: [96]u8 = undefined;
        const lab = if (fx.choice_index == 0)
            std.fmt.bufPrintSentinel(&lab_buf, "FX {d}##chain_fx{d}", .{ fx_index + 1, fx_index }, 0) catch "FX"
        else
            std.fmt.bufPrintSentinel(&lab_buf, "{s}##chain_fx{d}", .{ name, fx_index }, 0) catch "FX";
        const selected = state.device_target_kind == .fx and state.device_target_fx == fx_index;
        if (chainChip(lab, selected, fx.choice_index != 0, chip_h, ui_scale)) {
            selectDevice(state, track_idx, .fx, fx_index, is_master);
        }
    }
}

fn chainChip(label: [:0]const u8, selected: bool, loaded: bool, height: f32, ui_scale: f32) bool {
    const pad_x = tokens.s(12, ui_scale);
    // Visible part of the label (before ##)
    const visible: []const u8 = if (std.mem.indexOfScalar(u8, label, '#')) |hash|
        label[0..hash]
    else
        label;
    const text_w = zgui.calcTextSize(visible, .{})[0];
    const w = @max(text_w + pad_x * 2, tokens.s(56, ui_scale));

    const bg = if (selected)
        Colors.current.accent_dim
    else if (loaded)
        Colors.current.bg_cell
    else
        Colors.current.bg_panel;
    const bg_hover = if (selected) Colors.current.accent else Colors.current.bg_cell_hover;
    const text_col = if (selected)
        Colors.current.text_bright
    else if (loaded)
        Colors.current.text_dim
    else
        Colors.current.text_soft;

    zgui.pushStyleColor4f(.{ .idx = .button, .c = bg });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = bg_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.current.accent_dim });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = text_col });
    defer zgui.popStyleColor(.{ .count = 4 });

    return zgui.button(label, .{ .w = w, .h = height });
}

/// Point the device panel at a chain slot. For external CLAP plugins, open
/// their floating window; stock/embedded views just switch the embed body.
fn selectDevice(state: *State, track_idx: usize, kind: state_mod.DeviceTargetKind, fx_index: usize, is_master: bool) void {
    state.device_target_track = track_idx;
    state.device_target_kind = kind;
    state.device_target_fx = fx_index;

    // Clear open flags, then open only the selected external CLAP (if any).
    if (!is_master) state.track_plugins[track_idx].gui_open = false;
    for (0..session_constants.max_tracks) |t| {
        for (0..state_mod.max_fx_slots) |i| {
            state.track_fx[t][i].gui_open = false;
        }
    }

    switch (kind) {
        .instrument => {
            if (state.track_plugin_ptrs[track_idx]) |plugin| {
                // Only force gui_open for plugins without an embedded view.
                if (embedded_views.getEmbeddedView(plugin) == null) {
                    state.track_plugins[track_idx].gui_open = true;
                }
            }
        },
        .fx => {
            if (state.track_fx_plugin_ptrs[track_idx][fx_index]) |plugin| {
                if (embedded_views.getEmbeddedView(plugin) == null) {
                    state.track_fx[track_idx][fx_index].gui_open = true;
                }
            }
        },
    }
}

fn drawInstrumentInspector(state: *State, track_idx: usize, ui_scale: f32) void {
    const track_plugin = &state.track_plugins[track_idx];

    if (zgui.beginTable("device_rows##inst", .{
        .column = 3,
        .flags = .{
            .sizing = .fixed_fit,
            .no_pad_outer_x = true,
        },
    })) {
        zgui.tableSetupColumn("label", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = label_col_w * ui_scale });
        zgui.tableSetupColumn("search", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = search_col_w * ui_scale });
        zgui.tableSetupColumn("combo", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = combo_col_w * ui_scale });

        // Instrument row
        zgui.tableNextRow(.{});
        _ = zgui.tableNextColumn();
        dimLabel("Instrument");
        _ = zgui.tableNextColumn();
        if (state.instrument_filter_items_z.len == 0) {
            filters.rebuildInstrumentFilter(state);
        }
        zgui.setNextItemWidth(-1);
        if (zgui.inputTextWithHint("##instrument_search", .{
            .hint = "Search…",
            .buf = state.instrument_search_buf[0..],
        })) {
            filters.rebuildInstrumentFilter(state);
        }
        _ = zgui.tableNextColumn();
        zgui.setNextItemWidth(-1);
        var instrument_list_index: i32 = filters.findPluginListIndex(state.instrument_filter_indices, track_plugin.choice_index);
        if (zgui.combo("##device_select", .{
            .current_item = &instrument_list_index,
            .items_separated_by_zeros = state.instrument_filter_items_z,
        })) {
            if (filters.catalogIndexFromList(state.instrument_filter_indices, instrument_list_index)) |new_choice| {
                state.clearMissingTrackPlugin(track_idx);
                track_plugin.choice_index = new_choice;
                track_plugin.gui_open = false;
                track_plugin.preset_choice_index = null;
                selectDevice(state, track_idx, .instrument, 0, false);
            }
        }

        // Preset row
        zgui.tableNextRow(.{});
        _ = zgui.tableNextColumn();
        dimLabel("Preset");
        _ = zgui.tableNextColumn();
        if (state.preset_filter_items_z.len == 0) {
            filters.rebuildPresetFilter(state);
        }
        zgui.setNextItemWidth(-1);
        if (zgui.inputTextWithHint("##preset_search", .{
            .hint = "Search…",
            .buf = state.preset_search_buf[0..],
        })) {
            filters.rebuildPresetFilter(state);
        }
        _ = zgui.tableNextColumn();
        const preset_w = std.math.clamp(state.preset_combo_width * ui_scale, 180.0 * ui_scale, 420.0 * ui_scale);
        zgui.setNextItemWidth(@min(preset_w, @max(combo_col_w * ui_scale, zgui.getContentRegionAvail()[0])));
        var preset_list_index: i32 = filters.findPresetListIndex(state.preset_filter_indices, track_plugin.preset_choice_index);
        if (zgui.combo("##preset_select", .{
            .current_item = &preset_list_index,
            .items_separated_by_zeros = state.preset_filter_items_z,
        })) {
            if (filters.presetIndexFromList(state.preset_filter_indices, preset_list_index)) |preset_index| {
                if (state.preset_catalog) |catalog| {
                    if (preset_index < catalog.entries.items.len) {
                        if (catalog.resolve(preset_index) catch null) |entry| {
                            track_plugin.preset_choice_index = preset_index;
                            if (entry.catalog_index >= 0 and entry.catalog_index != track_plugin.choice_index) {
                                state.clearMissingTrackPlugin(track_idx);
                                track_plugin.choice_index = entry.catalog_index;
                                track_plugin.gui_open = false;
                                selectDevice(state, track_idx, .instrument, 0, false);
                            }
                            state.preset_load_request = .{
                                .track_index = track_idx,
                                .plugin_id = entry.plugin_id,
                                .location_kind = entry.location_kind,
                                .location = entry.location_z,
                                .load_key = entry.load_key_z,
                            };
                        }
                    }
                }
            }
        }

        zgui.endTable();
    }

    if (state.missing_track_plugins[track_idx]) |missing| {
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.danger });
        zgui.text("Missing instrument: {s}", .{missing.device_name});
        zgui.popStyleColor(.{ .count = 1 });
        zgui.sameLine(.{ .spacing = tokens.gapTight(ui_scale) });
        if (zgui.button("Remove##instrument", .{})) {
            state.clearMissingTrackPlugin(track_idx);
        }
    }
}

fn drawFxInspector(state: *State, track_idx: usize, ui_scale: f32) void {
    const fx_index = state.device_target_fx;
    if (fx_index >= state.track_fx_slot_count[track_idx]) return;
    var fx_slot = &state.track_fx[track_idx][fx_index];

    widgets.sectionChrome("Audio FX", ui_scale);

    if (zgui.beginTable("device_rows##fx_sel", .{
        .column = 2,
        .flags = .{
            .sizing = .fixed_fit,
            .no_pad_outer_x = true,
        },
    })) {
        zgui.tableSetupColumn("label", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = label_col_w * ui_scale });
        zgui.tableSetupColumn("combo", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = combo_col_w * ui_scale });

        zgui.tableNextRow(.{});
        _ = zgui.tableNextColumn();
        var slot_buf: [16]u8 = undefined;
        const slot_lab = std.fmt.bufPrint(&slot_buf, "FX {d}", .{fx_index + 1}) catch "FX";
        dimLabel(slot_lab);
        _ = zgui.tableNextColumn();
        zgui.setNextItemWidth(-1);
        var fx_list_index: i32 = filters.findPluginListIndex(state.plugin_fx_indices, fx_slot.choice_index);
        var combo_id_buf: [24]u8 = undefined;
        const combo_id = std.fmt.bufPrintSentinel(&combo_id_buf, "##fx_sel{d}", .{fx_index}, 0) catch "##fx";
        if (zgui.combo(combo_id, .{
            .current_item = &fx_list_index,
            .items_separated_by_zeros = state.plugin_fx_items,
        })) {
            if (filters.catalogIndexFromList(state.plugin_fx_indices, fx_list_index)) |new_choice| {
                state.clearMissingTrackFx(track_idx, fx_index);
                fx_slot.choice_index = new_choice;
                fx_slot.gui_open = false;
                selectDevice(state, track_idx, .fx, fx_index, state.session.mixer_target == .master);

                const fx_slot_count = state.track_fx_slot_count[track_idx];
                if (new_choice != 0 and fx_index == fx_slot_count - 1 and fx_slot_count < state_mod.max_fx_slots) {
                    state.track_fx_slot_count[track_idx] += 1;
                }
            }
        }
        zgui.endTable();
    }

    if (state.missing_track_fx[track_idx][fx_index]) |missing| {
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.danger });
        zgui.text("Missing: {s}", .{missing.device_name});
        zgui.popStyleColor(.{ .count = 1 });
        zgui.sameLine(.{ .spacing = tokens.gapTight(ui_scale) });
        var remove_buf: [48]u8 = undefined;
        const remove_label = std.fmt.bufPrintSentinel(&remove_buf, "Remove##fx_missing_{d}", .{fx_index}, 0) catch "Remove";
        if (zgui.button(remove_label, .{})) {
            state.clearMissingTrackFx(track_idx, fx_index);
        }
    }
}

fn dimLabel(text: []const u8) void {
    widgets.dimLabel(text);
}

fn pluginDisplayName(items_z: [:0]const u8, indices: []const i32, choice_index: i32, fallback: []const u8) []const u8 {
    const list_i = filters.findPluginListIndex(indices, choice_index);
    if (list_i < 0) return fallback;
    return nameAtItemsZ(items_z, @intCast(list_i)) orelse fallback;
}

fn nameAtItemsZ(items: [:0]const u8, index: usize) ?[]const u8 {
    var i: usize = 0;
    var start: usize = 0;
    while (start < items.len) {
        // Double-null terminates the list
        if (items[start] == 0) return null;
        const end = std.mem.indexOfScalarPos(u8, items, start, 0) orelse items.len;
        if (i == index) return items[start..end];
        start = end + 1;
        i += 1;
    }
    return null;
}

fn drawNoDevice() void {
    zgui.spacing();
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_soft });
    zgui.textUnformatted("No device loaded — pick an instrument or effect in the chain above.");
    zgui.popStyleColor(.{ .count = 1 });
}

fn drawClapDevice(state: *State, ui_scale: f32) void {
    const plugin = state.device_clap_plugin;
    const plugin_ready = plugin != null;

    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_bright });
    const is_master = state.session.mixer_target == .master;
    const device_label = if (is_master)
        "Master FX"
    else switch (state.device_target_kind) {
        .instrument => "Instrument",
        .fx => "FX",
    };
    zgui.text("{s}: {s}", .{ device_label, state.device_clap_name });
    zgui.popStyleColor(.{ .count = 1 });

    // Instrument open lives above Smart 8; FX external open still here when selected.
    if (state.device_target_kind == .fx) {
        const track_idx = if (is_master) session_view.master_track_index else state.selectedTrack();
        const target = &state.track_fx[track_idx][state.device_target_fx];
        const tip = if (target.gui_open) "Close plugin window" else "Open plugin window";
        zgui.sameLine(.{ .spacing = 12.0 * ui_scale });
        if (widgets.iconToggle("##device_open", .open_window, ui_scale, tip, target.gui_open, !plugin_ready)) {
            const opening = !target.gui_open;
            if (opening) {
                selectDevice(state, track_idx, .fx, state.device_target_fx, is_master);
                target.gui_open = true;
            } else {
                target.gui_open = false;
            }
        }
    }

    if (plugin_ready) {
        if (zgui.collapsingHeader("Parameters", .{})) {
            drawClapParamDump(plugin.?);
        }
    } else {
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
        zgui.textUnformatted("Loading plugin…");
        zgui.popStyleColor(.{ .count = 1 });
    }
}

fn drawClapParamDump(plugin: *const clap.Plugin) void {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse {
        zgui.textUnformatted("No CLAP parameters exposed.");
        return;
    };
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const count = params.count(plugin);
    if (count == 0) {
        zgui.textUnformatted("No CLAP parameters exposed.");
        return;
    }

    const child_open = zgui.beginChild("clap_param_dump##device", .{
        .w = 0,
        .h = 0,
        .child_flags = .{ .border = true },
    });
    defer zgui.endChild();
    if (!child_open) return;

    if (!zgui.beginTable("clap_param_table##device", .{
        .column = 4,
        .flags = .{ .row_bg = true, .borders = .{ .inner_v = true, .inner_h = true } },
    })) {
        return;
    }
    defer zgui.endTable();

    zgui.tableSetupColumn("Parameter", .{});
    zgui.tableSetupColumn("ID", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 80 });
    zgui.tableSetupColumn("Default", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 110 });
    zgui.tableSetupColumn("Range", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 160 });
    zgui.tableHeadersRow();

    for (0..count) |i| {
        var info: clap.ext.params.Info = undefined;
        if (!params.getInfo(plugin, @intCast(i), &info)) continue;

        const name = selection.sliceToNull(info.name[0..]);
        const module = selection.sliceToNull(info.module[0..]);

        zgui.tableNextRow(.{});
        _ = zgui.tableNextColumn();
        if (module.len > 0) {
            var label_buf: [256]u8 = undefined;
            const label = std.fmt.bufPrintSentinel(&label_buf, "{s}/{s}", .{ module, name }, 0) catch "";
            zgui.textUnformatted(label);
        } else {
            zgui.textUnformatted(name);
        }

        _ = zgui.tableNextColumn();
        zgui.text("{d}", .{info.id});

        _ = zgui.tableNextColumn();
        zgui.text("{d:.4}", .{info.default_value});

        _ = zgui.tableNextColumn();
        zgui.text("{d:.4} .. {d:.4}", .{ info.min_value, info.max_value });
    }
}

fn drawControllerSummary(state: *State, ui_scale: f32) void {
    _ = ui_scale;
    const page_count = controller_mapping.smartPageCount(state);
    if (page_count == 0) {
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_soft });
        zgui.textUnformatted("Controller Smart 8 · no parameters");
        zgui.popStyleColor(.{ .count = 1 });
        return;
    }

    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
    zgui.text("Controller Smart 8 · page {d}/{d}", .{ state.controller.smart_page + 1, page_count });
    zgui.popStyleColor(.{ .count = 1 });

    if (zgui.collapsingHeader("Smart 8 mapping", .{})) {
        for (0..state_mod.controller_smart_slots) |slot_index| {
            var row_buf: [160]u8 = undefined;
            const label = controller_mapping.smartParamLabel(state, slot_index);
            const row = std.fmt.bufPrintSentinel(&row_buf, "K{d}: {s}", .{ slot_index + 1, label }, 0) catch "K";
            zgui.textUnformatted(row);
        }
    }
}
