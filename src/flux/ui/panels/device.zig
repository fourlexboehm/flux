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

    // Hybrid tracks: every non-master channel has instrument + audio player + FX.
    // Clip content (MIDI vs sample) is per-slot, not a track type.
    if (!is_master) {
        if (state.device_target_track != track_idx) {
            state.device_target_track = track_idx;
            state.device_target_kind = .instrument;
            state.device_target_fx = 0;
        }
        const track_plugin = &state.track_plugins[track_idx];

        if (zgui.beginTable("device_rows##inst", .{
            .column = 4,
            .flags = .{
                .sizing = .fixed_fit,
                .no_pad_outer_x = true,
            },
        })) {
            zgui.tableSetupColumn("label", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = label_col_w * ui_scale });
            zgui.tableSetupColumn("search", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = search_col_w * ui_scale });
            zgui.tableSetupColumn("combo", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = combo_col_w * ui_scale });
            zgui.tableSetupColumn("action", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = widgets.iconButtonSize(ui_scale) + 4.0 * ui_scale });

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
                    state.device_target_kind = .instrument;
                    state.device_target_fx = 0;
                }
            }
            _ = zgui.tableNextColumn();
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
                            const entry = catalog.entries.items[preset_index];
                            track_plugin.preset_choice_index = preset_index;
                            if (entry.catalog_index >= 0 and entry.catalog_index != track_plugin.choice_index) {
                                state.clearMissingTrackPlugin(track_idx);
                                track_plugin.choice_index = entry.catalog_index;
                                track_plugin.gui_open = false;
                                state.device_target_kind = .instrument;
                                state.device_target_fx = 0;
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
            _ = zgui.tableNextColumn();
            // empty action cell for preset

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

        zgui.spacing();
    } else {
        state.device_target_track = track_idx;
        state.device_target_kind = .fx;
        if (state.device_target_fx >= state.track_fx_slot_count[track_idx]) {
            state.device_target_fx = 0;
        }
    }

    widgets.sectionChrome(if (is_master) "Master FX" else "Audio FX", ui_scale);

    const fx_slot_count = state.track_fx_slot_count[track_idx];
    if (zgui.beginTable("device_rows##fx", .{
        .column = 4,
        .flags = .{
            .sizing = .fixed_fit,
            .no_pad_outer_x = true,
        },
    })) {
        zgui.tableSetupColumn("label", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = label_col_w * ui_scale });
        zgui.tableSetupColumn("search", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = search_col_w * ui_scale });
        zgui.tableSetupColumn("combo", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = combo_col_w * ui_scale });
        zgui.tableSetupColumn("action", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = widgets.iconButtonSize(ui_scale) + 4.0 * ui_scale });

        for (0..fx_slot_count) |fx_index| {
            var fx_slot = &state.track_fx[track_idx][fx_index];
            var fx_label_buf: [16]u8 = undefined;
            const fx_label = std.fmt.bufPrintSentinel(&fx_label_buf, "FX {d}", .{fx_index + 1}, 0) catch "FX";

            zgui.tableNextRow(.{});
            _ = zgui.tableNextColumn();
            dimLabel(fx_label);
            _ = zgui.tableNextColumn();
            // empty search cell keeps combo column aligned with instrument/preset
            _ = zgui.tableNextColumn();
            var label_buf: [32]u8 = undefined;
            const label = std.fmt.bufPrintSentinel(&label_buf, "##fx{d}", .{fx_index}, 0) catch "##fx";
            zgui.setNextItemWidth(-1);
            var fx_list_index: i32 = filters.findPluginListIndex(state.plugin_fx_indices, fx_slot.choice_index);
            if (zgui.combo(label, .{
                .current_item = &fx_list_index,
                .items_separated_by_zeros = state.plugin_fx_items,
            })) {
                if (filters.catalogIndexFromList(state.plugin_fx_indices, fx_list_index)) |new_choice| {
                    state.clearMissingTrackFx(track_idx, fx_index);
                    fx_slot.choice_index = new_choice;
                    fx_slot.gui_open = false;
                    state.device_target_kind = .fx;
                    state.device_target_fx = fx_index;

                    if (new_choice != 0 and fx_index == fx_slot_count - 1 and fx_slot_count < state_mod.max_fx_slots) {
                        state.track_fx_slot_count[track_idx] += 1;
                    }
                }
            }
            _ = zgui.tableNextColumn();
            const is_selected = state.device_target_kind == .fx and state.device_target_fx == fx_index;
            const fx_ready = state.track_fx_plugin_ptrs[track_idx][fx_index] != null;
            const fx_tip = if (fx_slot.gui_open) "Close effect window" else "Open effect window";
            var open_id_buf: [32]u8 = undefined;
            const open_id = std.fmt.bufPrintSentinel(&open_id_buf, "##fx_open_{d}", .{fx_index}, 0) catch "##fx_open";
            if (widgets.iconToggle(open_id, .open_window, ui_scale, fx_tip, fx_slot.gui_open, !fx_ready)) {
                const opening = !fx_slot.gui_open;
                if (opening) {
                    if (!is_master) {
                        state.track_plugins[track_idx].gui_open = false;
                    }
                    for (0..session_constants.max_tracks) |t| {
                        for (0..state_mod.max_fx_slots) |other_fx| {
                            if (t != track_idx or other_fx != fx_index) {
                                state.track_fx[t][other_fx].gui_open = false;
                            }
                        }
                    }
                    fx_slot.gui_open = true;
                } else {
                    fx_slot.gui_open = false;
                }
                state.device_target_kind = .fx;
                state.device_target_fx = fx_index;
            }
            if (is_selected) {
                state.device_target_kind = .fx;
                state.device_target_fx = fx_index;
            }

            if (state.missing_track_fx[track_idx][fx_index]) |missing| {
                zgui.tableNextRow(.{});
                _ = zgui.tableNextColumn();
                _ = zgui.tableNextColumn();
                zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.danger });
                zgui.text("Missing: {s}", .{missing.device_name});
                zgui.popStyleColor(.{ .count = 1 });
                _ = zgui.tableNextColumn();
                var remove_buf: [48]u8 = undefined;
                const remove_label = std.fmt.bufPrintSentinel(&remove_buf, "Remove##fx_missing_{d}", .{fx_index}, 0) catch "Remove";
                if (zgui.button(remove_label, .{})) {
                    state.clearMissingTrackFx(track_idx, fx_index);
                }
                _ = zgui.tableNextColumn();
            }
        }
        zgui.endTable();
    }

    zgui.spacing();
    drawControllerSummary(state, ui_scale);
    zgui.separator();
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
        .none => {
            drawNoDevice();
        },
    }
}

fn dimLabel(text: []const u8) void {
    widgets.dimLabel(text);
}

fn drawNoDevice() void {
    // Caller supplies ui_scale via empty state elsewhere; keep compact here.
    zgui.spacing();
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_soft });
    zgui.textUnformatted("No device loaded - pick an instrument or effect above.");
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

    zgui.sameLine(.{ .spacing = 12.0 * ui_scale });
    const track_idx = if (is_master) session_view.master_track_index else state.selectedTrack();
    const target = switch (state.device_target_kind) {
        .instrument => &state.track_plugins[track_idx],
        .fx => &state.track_fx[track_idx][state.device_target_fx],
    };
    const tip = if (target.gui_open) "Close plugin window" else "Open plugin window";
    if (widgets.iconToggle("##device_open", .open_window, ui_scale, tip, target.gui_open, !plugin_ready)) {
        const opening = !target.gui_open;
        if (opening) {
            switch (state.device_target_kind) {
                .instrument => {
                    for (0..state_mod.max_fx_slots) |fx_index| {
                        state.track_fx[track_idx][fx_index].gui_open = false;
                    }
                },
                .fx => {
                    if (!is_master) {
                        state.track_plugins[track_idx].gui_open = false;
                    }
                    for (0..session_constants.max_tracks) |t| {
                        for (0..state_mod.max_fx_slots) |fx_index| {
                            if (t != track_idx or fx_index != state.device_target_fx) {
                                state.track_fx[t][fx_index].gui_open = false;
                            }
                        }
                    }
                },
            }
            target.gui_open = true;
        } else {
            target.gui_open = false;
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
    if (!child_open) {
        return;
    }

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
