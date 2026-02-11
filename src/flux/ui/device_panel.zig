const std = @import("std");
const zgui = @import("zgui");
const clap = @import("clap-bindings");

const colors = @import("colors.zig");
const filters = @import("filters.zig");
const embedded_views = @import("embedded_views.zig");
const controller_mapping = @import("../midi/controller_mapping.zig");
const session_view = @import("session_view.zig");
const session_constants = @import("session_view/constants.zig");
const state_mod = @import("state.zig");
const State = state_mod.State;

const Colors = colors.Colors;

pub fn drawDevicePanel(state: *State, ui_scale: f32) void {
    const is_master = state.session.mixer_target == .master;
    const track_idx = if (is_master) session_view.master_track_index else state.selectedTrack();

    if (!is_master) {
        // Track device selector
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
        zgui.textUnformatted("Instrument:");
        zgui.popStyleColor(.{ .count = 1 });

        zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
        zgui.setNextItemWidth(140.0 * ui_scale);
        if (state.instrument_filter_items_z.len == 0) {
            filters.rebuildInstrumentFilter(state);
        }
        if (zgui.inputTextWithHint("##instrument_search", .{
            .hint = "Search instruments",
            .buf = state.instrument_search_buf[0..],
        })) {
            filters.rebuildInstrumentFilter(state);
        }

        zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
        zgui.setNextItemWidth(200.0 * ui_scale);

        if (state.device_target_track != track_idx) {
            state.device_target_track = track_idx;
            state.device_target_kind = .instrument;
            state.device_target_fx = 0;
        }
        const track_plugin = &state.track_plugins[track_idx];

        // Convert catalog index to instrument list index for display
        var instrument_list_index: i32 = filters.findPluginListIndex(state.instrument_filter_indices, track_plugin.choice_index);

        if (zgui.combo("##device_select", .{
            .current_item = &instrument_list_index,
            .items_separated_by_zeros = state.instrument_filter_items_z,
        })) {
            // Selection changed - convert back to catalog index
            if (filters.catalogIndexFromList(state.instrument_filter_indices, instrument_list_index)) |new_choice| {
                track_plugin.choice_index = new_choice;
                track_plugin.gui_open = false;
                track_plugin.preset_choice_index = null;
                state.device_target_kind = .instrument;
                state.device_target_fx = 0;
            }
        }

        zgui.sameLine(.{ .spacing = 12.0 * ui_scale });
        const instrument_ready = state.track_plugin_ptrs[track_idx] != null;
        const inst_open_label = "Open Instrument";
        const inst_close_label = "Close Instrument";
        const inst_button_w = calcToggleButtonWidth(inst_open_label, inst_close_label, ui_scale);
        const inst_button_label = if (track_plugin.gui_open) inst_close_label else inst_open_label;
        var inst_button_buf: [64]u8 = undefined;
        const inst_button_text = std.fmt.bufPrintZ(&inst_button_buf, "{s}##instrument_open", .{inst_button_label}) catch "##instrument_open";
        zgui.beginDisabled(.{ .disabled = !instrument_ready });
        if (zgui.button(inst_button_text, .{ .w = inst_button_w, .h = 0 })) {
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
        zgui.endDisabled();

        zgui.spacing();
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
        zgui.textUnformatted("Preset:");
        zgui.popStyleColor(.{ .count = 1 });

        zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
        zgui.setNextItemWidth(180.0 * ui_scale);
        if (state.preset_filter_items_z.len == 0) {
            filters.rebuildPresetFilter(state);
        }
        if (zgui.inputTextWithHint("##preset_search", .{
            .hint = "Search presets",
            .buf = state.preset_search_buf[0..],
        })) {
            filters.rebuildPresetFilter(state);
        }

        zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
        zgui.setNextItemWidth(260.0 * ui_scale);
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

        zgui.separator();
    } else {
        state.device_target_track = track_idx;
        state.device_target_kind = .fx;
        if (state.device_target_fx >= state.track_fx_slot_count[track_idx]) {
            state.device_target_fx = 0;
        }
    }

    zgui.spacing();
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
    zgui.textUnformatted(if (is_master) "Master FX:" else "Audio FX:");
    zgui.popStyleColor(.{ .count = 1 });

    // Dynamic FX slots - show only the number of slots currently in use for this track
    const fx_slot_count = state.track_fx_slot_count[track_idx];
    for (0..fx_slot_count) |fx_index| {
        var fx_slot = &state.track_fx[track_idx][fx_index];
        var fx_label_buf: [16]u8 = undefined;
        const fx_label = std.fmt.bufPrintZ(&fx_label_buf, "FX {d}", .{fx_index + 1}) catch "FX";
        zgui.textUnformatted(fx_label);
        zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
        var label_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "##fx{d}", .{fx_index}) catch "##fx";
        zgui.setNextItemWidth(200.0 * ui_scale);
        var fx_list_index: i32 = filters.findPluginListIndex(state.plugin_fx_indices, fx_slot.choice_index);
        if (zgui.combo(label, .{
            .current_item = &fx_list_index,
            .items_separated_by_zeros = state.plugin_fx_items,
        })) {
            if (filters.catalogIndexFromList(state.plugin_fx_indices, fx_list_index)) |new_choice| {
                fx_slot.choice_index = new_choice;
                fx_slot.gui_open = false;
                state.device_target_kind = .fx;
                state.device_target_fx = fx_index;

                // If the last slot was used, add another slot (up to max)
                if (new_choice != 0 and fx_index == fx_slot_count - 1 and fx_slot_count < state_mod.max_fx_slots) {
                    state.track_fx_slot_count[track_idx] += 1;
                }
            }
        }

        zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
        const is_selected = state.device_target_kind == .fx and state.device_target_fx == fx_index;
        const open_label = "Open Window";
        const close_label = "Close Window";
        const button_w = calcToggleButtonWidth(open_label, close_label, ui_scale);
        const button_label = if (fx_slot.gui_open) close_label else open_label;
        var button_buf: [64]u8 = undefined;
        const button_text = std.fmt.bufPrintZ(&button_buf, "{s}##fx_open_{d}", .{ button_label, fx_index }) catch "##fx_open";
        const fx_ready = state.track_fx_plugin_ptrs[track_idx][fx_index] != null;
        zgui.beginDisabled(.{ .disabled = !fx_ready });
        if (zgui.button(button_text, .{ .w = button_w, .h = 0 })) {
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
        zgui.endDisabled();
        if (is_selected) {
            // Keep selection sticky when clicking elsewhere in the row.
            state.device_target_kind = .fx;
            state.device_target_fx = fx_index;
        }
    }

    drawControllerSummary(state, ui_scale);
    zgui.separator();
    switch (state.device_kind) {
        .plugin => {
            if (state.device_clap_plugin) |plugin| {
                // Check if plugin has an embedded view (builtin plugins)
                if (embedded_views.getEmbeddedView(plugin)) |draw_fn| {
                    if (zgui.beginChild("plugin_embed##device", .{ .w = 0, .h = 0 })) {
                        draw_fn(plugin);
                    }
                    zgui.endChild();
                } else {
                    // External CLAP plugin - show "Open Window" button
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

fn drawNoDevice() void {
    zgui.spacing();
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
    zgui.textUnformatted("No device loaded. Select a plugin from the track header.");
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
    const style = zgui.getStyle();
    const open_label = "Open Window";
    const close_label = "Close Window";
    const max_label_w = @max(
        zgui.calcTextSize(open_label, .{})[0],
        zgui.calcTextSize(close_label, .{})[0],
    );
    const button_w = max_label_w + style.frame_padding[0] * 2.0 + 6.0 * ui_scale;
    const button_label = if (target.gui_open) close_label else open_label;
    var button_buf: [64]u8 = undefined;
    const button_text = std.fmt.bufPrintZ(&button_buf, "{s}##device_open", .{button_label}) catch "##device_open";
    zgui.beginDisabled(.{ .disabled = !plugin_ready });
    if (zgui.button(button_text, .{ .w = button_w, .h = 0 })) {
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
    zgui.endDisabled();

    zgui.separator();
    if (plugin_ready) {
        drawClapParamDump(plugin.?);
    } else {
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
        zgui.textUnformatted("Loading plugin...");
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

        const name = sliceToNull(info.name[0..]);
        const module = sliceToNull(info.module[0..]);

        zgui.tableNextRow(.{});
        _ = zgui.tableNextColumn();
        if (module.len > 0) {
            var label_buf: [256]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{s}/{s}", .{ module, name }) catch "";
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

fn sliceToNull(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

fn calcToggleButtonWidth(open_label: []const u8, close_label: []const u8, ui_scale: f32) f32 {
    const style = zgui.getStyle();
    const max_label_w = @max(
        zgui.calcTextSize(open_label, .{})[0],
        zgui.calcTextSize(close_label, .{})[0],
    );
    return max_label_w + style.frame_padding[0] * 2.0 + 6.0 * ui_scale;
}

fn drawControllerSummary(state: *State, ui_scale: f32) void {
    _ = ui_scale;
    const page_count = controller_mapping.smartPageCount(state);
    if (page_count == 0) {
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
        zgui.textUnformatted("Controller Smart 8: no parameters available");
        zgui.popStyleColor(.{ .count = 1 });
        return;
    }

    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
    zgui.text("Controller Smart 8 - Page {d}/{d}", .{ state.controller.smart_page + 1, page_count });
    zgui.popStyleColor(.{ .count = 1 });

    for (0..state_mod.controller_smart_slots) |slot_index| {
        var row_buf: [160]u8 = undefined;
        const label = controller_mapping.smartParamLabel(state, slot_index);
        const row = std.fmt.bufPrintZ(&row_buf, "K{d}: {s}", .{ slot_index + 1, label }) catch "K";
        zgui.textUnformatted(row);
    }
}
