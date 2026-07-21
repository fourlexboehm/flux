//! Device chain panel — horizontal rack of device cards.
//! Instrument first, then FX in signal order. Built-in devices render their
//! full UI inline in the card; external CLAP plugins show a compact card with
//! an open-window control. Cards select on click, drag to reorder, and the
//! whole strip accepts plugin drops from the browser.

const std = @import("std");
const zgui = @import("zgui");
const clap = @import("clap-bindings");

const colors = @import("../theme/colors.zig");
const filters = @import("filters.zig");
const embedded_views = @import("embedded_views.zig");
const browser = @import("browser.zig");
const selection = @import("../input/selection.zig");
const session_view = @import("../../session/types.zig");
const session_constants = @import("../../session/constants.zig");
const state_mod = @import("../state.zig");
const widgets = @import("../theme/widgets.zig");
const tokens = @import("../theme/tokens.zig");
const State = state_mod.State;

const Colors = colors.Colors;

/// Payload for reordering FX cards inside the chain.
const FxDragPayload = extern struct {
    track: u32,
    fx: u32,
};

const header_h_logical: f32 = 26.0;

// Middle-mouse panning bookkeeping.
var pan_active: bool = false;
var pan_start_scroll: f32 = 0;

pub fn drawDevicePanel(state: *State, ui_scale: f32) void {
    const is_master = state.session.mixer_target == .master;
    const track_idx = if (is_master) session_view.master_track_index else state.selectedTrack();

    // Keep device target on the selected track.
    if (state.device_target_track != track_idx) {
        state.device_target_track = track_idx;
        state.device_target_kind = if (is_master) .fx else .instrument;
        state.device_target_fx = 0;
    }
    if (is_master) state.device_target_kind = .fx;
    clampSelection(state, track_idx, is_master);

    handleChainShortcuts(state, track_idx, is_master);

    if (!zgui.beginChild("##device_chain_strip", .{
        .w = 0,
        .h = 0,
        .window_flags = .{ .horizontal_scrollbar = true },
    })) {
        zgui.endChild();
        return;
    }
    defer zgui.endChild();

    // Middle-mouse pan for long chains.
    if (zgui.isWindowHovered(.{ .child_windows = true }) and zgui.isMouseDown(.middle)) {
        if (!pan_active) {
            pan_active = true;
            pan_start_scroll = zgui.getScrollX();
        }
        const delta = zgui.getMouseDragDelta(.middle, .{});
        zgui.setScrollX(@max(0, pan_start_scroll - delta[0]));
        zgui.setMouseCursor(.resize_all);
    } else {
        pan_active = false;
    }

    const scrollbar_pad = tokens.s(14, ui_scale);
    const card_h = @max(zgui.getContentRegionAvail()[1] - scrollbar_pad, tokens.s(120, ui_scale));
    const chain_gap = tokens.s(8, ui_scale);

    var device_count: usize = 0;

    if (!is_master) {
        drawInstrumentCard(state, track_idx, card_h, ui_scale);
        device_count += 1;
    }

    const fx_count = occupiedFxCount(state, track_idx);
    for (0..fx_count) |fx_index| {
        if (device_count > 0) chainChevron(card_h, chain_gap, ui_scale);
        drawFxCard(state, track_idx, is_master, fx_index, card_h, ui_scale);
        device_count += 1;
    }

    if (fx_count < state_mod.max_fx_slots) {
        if (device_count > 0) chainChevron(card_h, chain_gap, ui_scale);
        drawAddCard(state, track_idx, is_master, card_h, ui_scale);
    }

    drawTrailingDropRegion(state, track_idx, is_master, fx_count, card_h, ui_scale);
}

// ── Chain layout helpers ─────────────────────────────────────────────────────

/// FX slots holding a device (loaded or missing); chains are kept packed.
fn occupiedFxCount(state: *const State, track: usize) usize {
    var count: usize = 0;
    for (0..state_mod.max_fx_slots) |i| {
        if (state.track_fx[track][i].choice_index != 0 or state.missing_track_fx[track][i] != null) count += 1;
    }
    return count;
}

fn recomputeSlotCount(state: *State, track: usize) void {
    state.track_fx_slot_count[track] = @min(occupiedFxCount(state, track) + 1, state_mod.max_fx_slots);
}

fn clampSelection(state: *State, track_idx: usize, is_master: bool) void {
    if (state.device_target_kind != .fx) return;
    const fx_count = occupiedFxCount(state, track_idx);
    if (state.device_target_fx >= fx_count) {
        if (fx_count > 0) {
            state.device_target_fx = fx_count - 1;
        } else {
            state.device_target_fx = 0;
            if (!is_master) state.device_target_kind = .instrument;
        }
    }
}

fn selectDevice(state: *State, track_idx: usize, kind: state_mod.DeviceTargetKind, fx_index: usize) void {
    state.device_target_track = track_idx;
    state.device_target_kind = kind;
    state.device_target_fx = fx_index;
}

/// Open/close an external plugin window; only one device window at a time.
fn setDeviceWindowOpen(state: *State, track_idx: usize, kind: state_mod.DeviceTargetKind, fx_index: usize, open: bool) void {
    for (0..session_constants.max_tracks) |t| {
        state.track_plugins[t].gui_open = false;
        for (0..state_mod.max_fx_slots) |i| {
            state.track_fx[t][i].gui_open = false;
        }
    }
    if (!open) return;
    switch (kind) {
        .instrument => state.track_plugins[track_idx].gui_open = true,
        .fx => state.track_fx[track_idx][fx_index].gui_open = true,
    }
}

fn chainChevron(card_h: f32, gap: f32, ui_scale: f32) void {
    zgui.sameLine(.{ .spacing = gap });
    const pos = zgui.getCursorScreenPos();
    const w = tokens.s(10, ui_scale);
    const draw_list = zgui.getWindowDrawList();
    const sz = zgui.calcTextSize("›", .{});
    draw_list.addText(
        .{ pos[0] + (w - sz[0]) * 0.5, pos[1] + (card_h - sz[1]) * 0.5 },
        zgui.colorConvertFloat4ToU32(Colors.current.text_soft),
        "›",
        .{},
    );
    zgui.dummy(.{ .w = w, .h = card_h });
    zgui.sameLine(.{ .spacing = gap });
}

// ── Shortcuts ────────────────────────────────────────────────────────────────

fn handleChainShortcuts(state: *State, track_idx: usize, is_master: bool) void {
    if (state.focused_pane != .bottom) return;
    if (zgui.io.getWantTextInput()) return;
    if (zgui.isPopupOpen("##add_fx_popup", .{})) return;

    const fx_count = occupiedFxCount(state, track_idx);
    const fx_selected = state.device_target_kind == .fx and fx_count > 0;
    const mod = selection.isModifierDown();

    if (zgui.isKeyPressed(.delete, false) or zgui.isKeyPressed(.back_space, false)) {
        if (fx_selected) {
            state.chain_op_request = .{ .remove_fx = .{ .track = track_idx, .fx_index = state.device_target_fx } };
        } else if (!is_master and state.device_target_kind == .instrument) {
            removeInstrument(state, track_idx);
        }
        return;
    }

    if (mod and zgui.isKeyPressed(.d, false)) {
        if (fx_selected and state.missing_track_fx[track_idx][state.device_target_fx] == null) {
            state.chain_op_request = .{ .duplicate_fx = .{ .track = track_idx, .fx_index = state.device_target_fx } };
        }
        return;
    }

    // Plain arrows walk the chain; with the modifier they move the device.
    if (zgui.isKeyPressed(.left_arrow, false)) {
        if (mod) {
            if (fx_selected and state.device_target_fx > 0) {
                state.chain_op_request = .{ .move_fx = .{
                    .track = track_idx,
                    .from = state.device_target_fx,
                    .to = state.device_target_fx - 1,
                } };
            }
        } else if (fx_selected) {
            if (state.device_target_fx > 0) {
                selectDevice(state, track_idx, .fx, state.device_target_fx - 1);
            } else if (!is_master) {
                selectDevice(state, track_idx, .instrument, 0);
            }
        }
    } else if (zgui.isKeyPressed(.right_arrow, false)) {
        if (mod) {
            if (fx_selected and state.device_target_fx + 1 < fx_count) {
                state.chain_op_request = .{ .move_fx = .{
                    .track = track_idx,
                    .from = state.device_target_fx,
                    .to = state.device_target_fx + 1,
                } };
            }
        } else if (state.device_target_kind == .instrument and fx_count > 0) {
            selectDevice(state, track_idx, .fx, 0);
        } else if (fx_selected and state.device_target_fx + 1 < fx_count) {
            selectDevice(state, track_idx, .fx, state.device_target_fx + 1);
        }
    }
}

fn removeInstrument(state: *State, track_idx: usize) void {
    state.clearMissingTrackPlugin(track_idx);
    const inst = &state.track_plugins[track_idx];
    inst.choice_index = 0;
    inst.gui_open = false;
    inst.preset_choice_index = null;
    inst.enabled = true;
    state.markProjectDirty();
}

// ── Cards ────────────────────────────────────────────────────────────────────

const HeaderAction = struct {
    select: bool = false,
    open_window: bool = false,
    toggle_enable: bool = false,
    remove: bool = false,
};

/// Card chrome: header strip with enable LED, name (drag handle for FX),
/// optional window button, and a remove button. Returns what was clicked.
fn cardHeader(
    label: []const u8,
    selected: bool,
    enabled: bool,
    show_window_btn: bool,
    window_open: bool,
    is_missing: bool,
    fx_drag: ?FxDragPayload,
    ui_scale: f32,
) HeaderAction {
    var action: HeaderAction = .{};
    const draw_list = zgui.getWindowDrawList();
    const header_h = tokens.s(header_h_logical, ui_scale);
    const origin = zgui.getCursorScreenPos();
    const card_w = zgui.getContentRegionAvail()[0];

    const header_bg = if (is_missing)
        Colors.current.danger
    else if (selected)
        Colors.current.accent_dim
    else
        Colors.current.bg_header;
    draw_list.addRectFilled(.{
        .pmin = .{ origin[0] - tokens.s(4, ui_scale), origin[1] - tokens.s(2, ui_scale) },
        .pmax = .{ origin[0] + card_w + tokens.s(4, ui_scale), origin[1] + header_h },
        .col = zgui.colorConvertFloat4ToU32(header_bg),
    });

    const on_fill = selected or is_missing;
    const text_col = if (on_fill) Colors.textOn(header_bg) else Colors.current.text_dim;

    // Enable LED
    const led_btn = tokens.s(18, ui_scale);
    const led_pos = zgui.getCursorScreenPos();
    if (zgui.invisibleButton("##led", .{ .w = led_btn, .h = header_h - tokens.s(4, ui_scale) })) {
        action.toggle_enable = true;
    }
    widgets.itemTooltip(if (enabled) "Bypass device" else "Enable device");
    {
        const cx = led_pos[0] + led_btn * 0.5;
        const cy = led_pos[1] + (header_h - tokens.s(4, ui_scale)) * 0.5;
        const r = tokens.s(4.5, ui_scale);
        if (enabled) {
            const led_col = if (zgui.isItemHovered(.{})) Colors.current.accent else Colors.current.accent_dim;
            draw_list.addCircleFilled(.{ .p = .{ cx, cy }, .r = r, .col = zgui.colorConvertFloat4ToU32(led_col) });
        } else {
            draw_list.addCircle(.{
                .p = .{ cx, cy },
                .r = r,
                .col = zgui.colorConvertFloat4ToU32(if (on_fill) text_col else Colors.current.text_soft),
                .thickness = @max(1.2 * ui_scale, 1.0),
            });
        }
    }

    // Right-side header buttons
    const btn = header_h - tokens.s(6, ui_scale);
    var right_btns: f32 = 1;
    if (show_window_btn) right_btns += 1;
    const right_w = right_btns * (btn + tokens.s(2, ui_scale));

    // Name = select target + drag handle
    zgui.sameLine(.{ .spacing = tokens.s(2, ui_scale) });
    const name_w = @max(card_w - led_btn - right_w - tokens.s(8, ui_scale), tokens.s(24, ui_scale));
    const name_pos = zgui.getCursorScreenPos();
    if (zgui.invisibleButton("##card_grab", .{ .w = name_w, .h = header_h - tokens.s(4, ui_scale) })) {
        action.select = true;
    }
    if (show_window_btn and zgui.isItemHovered(.{}) and zgui.isMouseDoubleClicked(.left)) {
        action.open_window = true;
    }
    if (fx_drag) |payload| {
        if (zgui.beginDragDropSource(.{})) {
            _ = zgui.setDragDropPayload("FLUX_FX_SLOT", std.mem.asBytes(&payload), .always);
            zgui.textUnformatted(label);
            zgui.endDragDropSource();
        }
    }
    {
        const sz = zgui.calcTextSize(label, .{});
        const ty = name_pos[1] + (header_h - tokens.s(4, ui_scale) - sz[1]) * 0.5;
        // Clip the name to the grab region so long titles don't spill over buttons.
        draw_list.pushClipRect(.{
            .pmin = .{ name_pos[0], name_pos[1] },
            .pmax = .{ name_pos[0] + name_w, name_pos[1] + header_h },
            .intersect_with_current = true,
        });
        draw_list.addText(.{ name_pos[0] + tokens.s(2, ui_scale), ty }, zgui.colorConvertFloat4ToU32(text_col), "{s}", .{label});
        draw_list.popClipRect();
    }

    // Window (external editor) button
    if (show_window_btn) {
        zgui.sameLine(.{ .spacing = tokens.s(2, ui_scale) });
        const wpos = zgui.getCursorScreenPos();
        if (zgui.invisibleButton("##card_window", .{ .w = btn, .h = btn })) {
            action.open_window = true;
        }
        widgets.itemTooltip(if (window_open) "Close plugin window" else "Open plugin window");
        const hover = zgui.isItemHovered(.{});
        const col = zgui.colorConvertFloat4ToU32(if (window_open)
            Colors.current.accent
        else if (hover)
            (if (on_fill) Colors.textOn(header_bg) else Colors.current.text_bright)
        else
            text_col);
        const pad = btn * 0.22;
        const t = @max(1.2 * ui_scale, 1.0);
        draw_list.addRect(.{
            .pmin = .{ wpos[0] + pad, wpos[1] + pad + btn * 0.08 },
            .pmax = .{ wpos[0] + btn - pad, wpos[1] + btn - pad },
            .col = col,
            .thickness = t,
            .rounding = tokens.s(1.5, ui_scale),
        });
        draw_list.addLine(.{
            .p1 = .{ wpos[0] + pad, wpos[1] + pad + btn * 0.22 },
            .p2 = .{ wpos[0] + btn - pad, wpos[1] + pad + btn * 0.22 },
            .col = col,
            .thickness = t,
        });
    }

    // Remove button
    zgui.sameLine(.{ .spacing = tokens.s(2, ui_scale) });
    const xpos = zgui.getCursorScreenPos();
    if (zgui.invisibleButton("##card_remove", .{ .w = btn, .h = btn })) {
        action.remove = true;
    }
    widgets.itemTooltip("Remove device");
    {
        const hover = zgui.isItemHovered(.{});
        const col = zgui.colorConvertFloat4ToU32(if (hover) Colors.current.danger else text_col);
        const pad = btn * 0.3;
        const t = @max(1.2 * ui_scale, 1.0);
        draw_list.addLine(.{ .p1 = .{ xpos[0] + pad, xpos[1] + pad }, .p2 = .{ xpos[0] + btn - pad, xpos[1] + btn - pad }, .col = col, .thickness = t });
        draw_list.addLine(.{ .p1 = .{ xpos[0] + pad, xpos[1] + btn - pad }, .p2 = .{ xpos[0] + btn - pad, xpos[1] + pad }, .col = col, .thickness = t });
    }

    // Divider under the header
    const y = origin[1] + header_h;
    draw_list.addLine(.{
        .p1 = .{ origin[0] - tokens.s(4, ui_scale), y },
        .p2 = .{ origin[0] + card_w + tokens.s(4, ui_scale), y },
        .col = zgui.colorConvertFloat4ToU32(Colors.current.border),
        .thickness = 1.0,
    });
    zgui.setCursorScreenPos(.{ origin[0], y + tokens.s(6, ui_scale) });
    // ImGui requires an item after SetCursorScreenPos when it extends the
    // window boundary; a zero-size dummy keeps the error check happy.
    zgui.dummy(.{ .w = 0, .h = 0 });

    return action;
}

/// Card width by device: built-ins get room for their inline UI, external
/// CLAP plugins a compact info card.
fn cardWidthFor(plugin: ?*const clap.Plugin, ui_scale: f32) f32 {
    const p = plugin orelse return tokens.s(230, ui_scale);
    const id = std.mem.sliceTo(p.descriptor.id, 0);
    if (std.mem.eql(u8, id, "com.flux.builtin.equalizer")) return tokens.s(540, ui_scale);
    if (std.mem.startsWith(u8, id, "com.flux.builtin.")) return tokens.s(400, ui_scale);
    if (embedded_views.getEmbeddedView(p) != null) return tokens.s(640, ui_scale);
    return tokens.s(230, ui_scale);
}

fn drawInstrumentCard(state: *State, track_idx: usize, card_h: f32, ui_scale: f32) void {
    const inst = &state.track_plugins[track_idx];
    const missing = state.missing_track_plugins[track_idx];
    const has_device = inst.choice_index != 0 or missing != null;
    const plugin = state.track_plugin_ptrs[track_idx];
    const selected = state.device_target_kind == .instrument;

    const card_w = if (!has_device)
        tokens.s(280, ui_scale)
    else if (missing != null)
        tokens.s(230, ui_scale)
    else
        cardWidthFor(plugin, ui_scale);

    if (!zgui.beginChild("##inst_card", .{
        .w = card_w,
        .h = card_h,
        .child_flags = .{ .border = true },
    })) {
        zgui.endChild();
        return;
    }

    if (zgui.isWindowHovered(.{ .child_windows = true }) and zgui.isMouseClicked(.left)) {
        selectDevice(state, track_idx, .instrument, 0);
    }

    inst_body: {
        if (!has_device) {
            widgets.dimLabel("Instrument");
            zgui.separator();
            drawInstrumentPicker(state, track_idx, ui_scale);
            break :inst_body;
        }

        const external = plugin != null and embedded_views.getEmbeddedView(plugin.?) == null;
        const name = if (missing) |m|
            m.device_name
        else
            pluginDisplayName(state.plugin_instrument_items, state.plugin_instrument_indices, inst.choice_index, "Instrument");

        const action = cardHeader(
            name,
            selected,
            inst.enabled,
            external,
            inst.gui_open,
            missing != null,
            null,
            ui_scale,
        );
        if (action.select) selectDevice(state, track_idx, .instrument, 0);
        if (action.toggle_enable) {
            inst.enabled = !inst.enabled;
            state.markProjectDirty();
        }
        if (action.remove) {
            removeInstrument(state, track_idx);
            break :inst_body;
        }
        if (action.open_window and external) {
            selectDevice(state, track_idx, .instrument, 0);
            setDeviceWindowOpen(state, track_idx, .instrument, 0, !inst.gui_open);
        }

        if (missing != null) {
            zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.danger });
            zgui.textWrapped("Missing plugin — kept in the project until removed.", .{});
            zgui.popStyleColor(.{ .count = 1 });
            break :inst_body;
        }

        drawPresetRow(state, track_idx, ui_scale);
        zgui.separator();

        if (plugin) |p| {
            if (embedded_views.getEmbeddedView(p)) |draw_fn| {
                if (zgui.beginChild("##inst_embed", .{ .w = 0, .h = 0 })) {
                    draw_fn(p);
                }
                zgui.endChild();
            } else {
                drawExternalBody(p, ui_scale);
            }
        } else {
            widgets.dimLabel("Loading plugin…");
        }
    }

    zgui.endChild();
    // Dropping an instrument from the browser loads/replaces it.
    if (zgui.beginDragDropTarget()) {
        if (zgui.acceptDragDropPayload("FLUX_PLUGIN", .{})) |payload| {
            if (payloadAs(browser.PluginDragPayload, payload)) |plugin_payload| {
                if (plugin_payload.is_fx == 0) {
                    dropPluginOnChain(state, track_idx, plugin_payload, null);
                }
            }
        }
        zgui.endDragDropTarget();
    }
}

fn drawFxCard(state: *State, track_idx: usize, is_master: bool, fx_index: usize, card_h: f32, ui_scale: f32) void {
    _ = is_master;
    const fx = &state.track_fx[track_idx][fx_index];
    const missing = state.missing_track_fx[track_idx][fx_index];
    const plugin = state.track_fx_plugin_ptrs[track_idx][fx_index];
    const selected = state.device_target_kind == .fx and state.device_target_fx == fx_index;

    const card_w = if (missing != null) tokens.s(230, ui_scale) else cardWidthFor(plugin, ui_scale);

    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintSentinel(&id_buf, "##fx_card{d}", .{fx_index}, 0) catch "##fx_card";

    if (!zgui.beginChild(id, .{
        .w = card_w,
        .h = card_h,
        .child_flags = .{ .border = true },
    })) {
        zgui.endChild();
        return;
    }

    if (zgui.isWindowHovered(.{ .child_windows = true }) and zgui.isMouseClicked(.left)) {
        selectDevice(state, track_idx, .fx, fx_index);
    }

    const external = plugin != null and embedded_views.getEmbeddedView(plugin.?) == null;
    const name = if (missing) |m|
        m.device_name
    else
        pluginDisplayName(state.plugin_fx_items, state.plugin_fx_indices, fx.choice_index, "FX");

    const action = cardHeader(
        name,
        selected,
        fx.enabled,
        external,
        fx.gui_open,
        missing != null,
        .{ .track = @intCast(track_idx), .fx = @intCast(fx_index) },
        ui_scale,
    );
    if (action.select) selectDevice(state, track_idx, .fx, fx_index);
    if (action.toggle_enable) {
        fx.enabled = !fx.enabled;
        state.markProjectDirty();
    }
    if (action.remove) {
        state.chain_op_request = .{ .remove_fx = .{ .track = track_idx, .fx_index = fx_index } };
    }
    if (action.open_window and external) {
        selectDevice(state, track_idx, .fx, fx_index);
        setDeviceWindowOpen(state, track_idx, .fx, fx_index, !fx.gui_open);
    }

    if (missing != null) {
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.danger });
        zgui.textWrapped("Missing plugin — kept in the project until removed.", .{});
        zgui.popStyleColor(.{ .count = 1 });
    } else if (plugin) |p| {
        if (embedded_views.getEmbeddedView(p)) |draw_fn| {
            if (zgui.beginChild("##fx_embed", .{ .w = 0, .h = 0 })) {
                draw_fn(p);
            }
            zgui.endChild();
        } else {
            drawExternalBody(p, ui_scale);
        }
    } else {
        widgets.dimLabel("Loading plugin…");
    }

    zgui.endChild();
    acceptCardDrop(state, track_idx, fx_index);
}

/// Compact info body for external CLAP plugins (their UI lives in a window).
fn drawExternalBody(plugin: *const clap.Plugin, ui_scale: f32) void {
    _ = ui_scale;
    widgets.dimLabel("External CLAP");
    if (plugin.descriptor.vendor) |vendor_z| {
        const vendor = std.mem.sliceTo(vendor_z, 0);
        if (vendor.len > 0) {
            zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_soft });
            zgui.textUnformatted(vendor);
            zgui.popStyleColor(.{ .count = 1 });
        }
    }
    if (plugin.getExtension(plugin, clap.ext.params.id)) |ext_raw| {
        const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_soft });
        zgui.text("{d} parameters", .{params.count(plugin)});
        zgui.popStyleColor(.{ .count = 1 });
    }
    zgui.spacing();
    widgets.dimLabel("Double-click the title to open");
}

fn drawAddCard(state: *State, track_idx: usize, is_master: bool, card_h: f32, ui_scale: f32) void {
    _ = is_master;
    const card_w = tokens.s(64, ui_scale);
    if (!zgui.beginChild("##add_device_card", .{
        .w = card_w,
        .h = card_h,
        .child_flags = .{ .border = true },
    })) {
        zgui.endChild();
        return;
    }

    const avail = zgui.getContentRegionAvail();
    const btn = tokens.s(28, ui_scale);
    zgui.setCursorPos(.{ (avail[0] - btn) * 0.5, (avail[1] - btn) * 0.5 });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = Colors.current.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.current.accent_dim });
    const clicked = zgui.button("+##add_device", .{ .w = btn, .h = btn });
    zgui.popStyleColor(.{ .count = 3 });
    widgets.itemTooltip("Add audio effect");
    if (clicked) {
        state.fx_search_buf[0] = 0;
        zgui.openPopup("##add_fx_popup", .{});
    }

    drawAddFxPopup(state, track_idx, ui_scale);

    zgui.endChild();
    // Dropping a browser plugin on the add card appends it.
    if (zgui.beginDragDropTarget()) {
        if (zgui.acceptDragDropPayload("FLUX_PLUGIN", .{})) |payload| {
            if (payloadAs(browser.PluginDragPayload, payload)) |plugin_payload| {
                dropPluginOnChain(state, track_idx, plugin_payload, null);
            }
        }
        zgui.endDragDropTarget();
    }
}

fn drawAddFxPopup(state: *State, track_idx: usize, ui_scale: f32) void {
    if (!zgui.beginPopup("##add_fx_popup", .{})) return;
    defer zgui.endPopup();

    if (zgui.isWindowAppearing()) zgui.setKeyboardFocusHere(0);
    zgui.setNextItemWidth(tokens.s(220, ui_scale));
    _ = zgui.inputTextWithHint("##add_fx_search", .{
        .hint = "Search effects…",
        .buf = state.fx_search_buf[0..],
    });
    zgui.separator();

    const filter = std.mem.sliceTo(&state.fx_search_buf, 0);
    if (zgui.beginChild("##add_fx_list", .{ .w = tokens.s(220, ui_scale), .h = tokens.s(200, ui_scale) })) {
        var name_buf: [128]u8 = undefined;
        var pos: usize = 0;
        var idx: usize = 0;
        const items = state.plugin_fx_items;
        while (pos < items.len and items[pos] != 0) {
            const end = std.mem.indexOfScalarPos(u8, items, pos, 0) orelse items.len;
            const name = items[pos..end];
            defer {
                pos = end + 1;
                idx += 1;
            }
            if (idx >= state.plugin_fx_indices.len) break;
            const catalog_index = state.plugin_fx_indices[idx];
            if (catalog_index <= 0) continue; // skip "None"/dividers
            if (filter.len > 0 and !containsIgnoreCase(name, filter)) continue;

            const len = @min(name.len, name_buf.len - 1);
            @memcpy(name_buf[0..len], name[0..len]);
            name_buf[len] = 0;
            if (zgui.selectable(name_buf[0..len :0], .{})) {
                _ = appendFx(state, track_idx, catalog_index);
                zgui.closeCurrentPopup();
            }
        }
    }
    zgui.endChild();
}

/// Remaining strip space: drop target for browser plugins / chain reorder to
/// the end, plus the empty-state hint.
fn drawTrailingDropRegion(state: *State, track_idx: usize, is_master: bool, fx_count: usize, card_h: f32, ui_scale: f32) void {
    zgui.sameLine(.{ .spacing = tokens.s(8, ui_scale) });
    const w = @max(zgui.getContentRegionAvail()[0], tokens.s(60, ui_scale));
    const pos = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("##chain_tail", .{ .w = w, .h = card_h });
    if (zgui.beginDragDropTarget()) {
        if (zgui.acceptDragDropPayload("FLUX_PLUGIN", .{})) |payload| {
            if (payloadAs(browser.PluginDragPayload, payload)) |plugin_payload| {
                dropPluginOnChain(state, track_idx, plugin_payload, null);
            }
        }
        if (zgui.acceptDragDropPayload("FLUX_FX_SLOT", .{})) |payload| {
            if (payloadAs(FxDragPayload, payload)) |fx_payload| {
                if (fx_payload.track == track_idx and fx_count > 0) {
                    state.chain_op_request = .{ .move_fx = .{
                        .track = track_idx,
                        .from = fx_payload.fx,
                        .to = fx_count - 1,
                    } };
                }
            }
        }
        zgui.endDragDropTarget();
    }

    const has_instrument = !is_master and
        (state.track_plugins[track_idx].choice_index != 0 or state.missing_track_plugins[track_idx] != null);
    if (fx_count == 0 and !has_instrument) {
        const hint = if (is_master)
            "Drop audio effects here"
        else
            "Drop instruments or audio effects here";
        const sz = zgui.calcTextSize(hint, .{});
        const draw_list = zgui.getWindowDrawList();
        draw_list.addText(
            .{ pos[0] + @max((w - sz[0]) * 0.5, 0), pos[1] + (card_h - sz[1]) * 0.5 },
            zgui.colorConvertFloat4ToU32(Colors.current.text_soft),
            "{s}",
            .{hint},
        );
    }
}

/// Card-level drop: reorder FX onto this slot, or insert a browser plugin here.
fn acceptCardDrop(state: *State, track_idx: usize, fx_index: usize) void {
    if (!zgui.beginDragDropTarget()) return;
    defer zgui.endDragDropTarget();

    if (zgui.acceptDragDropPayload("FLUX_FX_SLOT", .{})) |payload| {
        if (payloadAs(FxDragPayload, payload)) |fx_payload| {
            if (fx_payload.track == track_idx and fx_payload.fx != fx_index) {
                state.chain_op_request = .{ .move_fx = .{
                    .track = track_idx,
                    .from = fx_payload.fx,
                    .to = fx_index,
                } };
            }
        }
    }
    if (zgui.acceptDragDropPayload("FLUX_PLUGIN", .{})) |payload| {
        if (payloadAs(browser.PluginDragPayload, payload)) |plugin_payload| {
            dropPluginOnChain(state, track_idx, plugin_payload, fx_index);
        }
    }
}

fn payloadAs(comptime T: type, payload: *zgui.Payload) ?T {
    const data = payload.data orelse return null;
    if (payload.data_size != @sizeOf(T)) return null;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), @as([*]const u8, @ptrCast(data))[0..@sizeOf(T)]);
    return value;
}

/// Browser plugin dropped on the chain. FX append (then move to `insert_at`);
/// instruments replace the track instrument.
fn dropPluginOnChain(state: *State, track_idx: usize, payload: browser.PluginDragPayload, insert_at: ?usize) void {
    if (payload.catalog_index <= 0) return;
    if (payload.is_fx != 0) {
        const appended = appendFx(state, track_idx, payload.catalog_index) orelse return;
        if (insert_at) |target| {
            if (target < appended) {
                state.chain_op_request = .{ .move_fx = .{ .track = track_idx, .from = appended, .to = target } };
            }
        }
    } else if (state.session.mixer_target != .master) {
        state.clearMissingTrackPlugin(track_idx);
        const inst = &state.track_plugins[track_idx];
        inst.choice_index = payload.catalog_index;
        inst.gui_open = false;
        inst.preset_choice_index = null;
        inst.enabled = true;
        selectDevice(state, track_idx, .instrument, 0);
        state.markProjectDirty();
    }
}

/// Append an FX to the first free slot; returns the slot used.
pub fn appendFx(state: *State, track_idx: usize, catalog_index: i32) ?usize {
    if (catalog_index <= 0) return null;
    const slot_index = occupiedFxCount(state, track_idx);
    if (slot_index >= state_mod.max_fx_slots) return null;

    state.clearMissingTrackFx(track_idx, slot_index);
    const slot = &state.track_fx[track_idx][slot_index];
    slot.choice_index = catalog_index;
    slot.gui_open = false;
    slot.enabled = true;
    recomputeSlotCount(state, track_idx);
    selectDevice(state, track_idx, .fx, slot_index);
    state.markProjectDirty();
    return slot_index;
}

// ── Instrument picker & presets ──────────────────────────────────────────────

fn drawInstrumentPicker(state: *State, track_idx: usize, ui_scale: f32) void {
    _ = ui_scale;
    if (state.instrument_filter_items_z.len == 0) {
        filters.rebuildInstrumentFilter(state);
    }
    zgui.setNextItemWidth(-1);
    if (zgui.inputTextWithHint("##instrument_search", .{
        .hint = "Search instruments…",
        .buf = state.instrument_search_buf[0..],
    })) {
        filters.rebuildInstrumentFilter(state);
    }

    if (zgui.beginChild("##instrument_pick_list", .{ .w = 0, .h = 0 })) {
        var name_buf: [128]u8 = undefined;
        var pos: usize = 0;
        var idx: usize = 0;
        const items = state.instrument_filter_items_z;
        while (pos < items.len and items[pos] != 0) {
            const end = std.mem.indexOfScalarPos(u8, items, pos, 0) orelse items.len;
            const name = items[pos..end];
            defer {
                pos = end + 1;
                idx += 1;
            }
            if (idx >= state.instrument_filter_indices.len) break;
            const catalog_index = state.instrument_filter_indices[idx];
            if (catalog_index <= 0) continue;

            const len = @min(name.len, name_buf.len - 1);
            @memcpy(name_buf[0..len], name[0..len]);
            name_buf[len] = 0;
            if (zgui.selectable(name_buf[0..len :0], .{})) {
                state.clearMissingTrackPlugin(track_idx);
                const inst = &state.track_plugins[track_idx];
                inst.choice_index = catalog_index;
                inst.gui_open = false;
                inst.preset_choice_index = null;
                inst.enabled = true;
                selectDevice(state, track_idx, .instrument, 0);
                state.markProjectDirty();
            }
        }
    }
    zgui.endChild();
}

fn drawPresetRow(state: *State, track_idx: usize, ui_scale: f32) void {
    const track_plugin = &state.track_plugins[track_idx];
    if (state.preset_filter_items_z.len == 0) {
        filters.rebuildPresetFilter(state);
    }

    zgui.alignTextToFramePadding();
    widgets.dimLabel("Preset");
    zgui.sameLine(.{ .spacing = tokens.gapTight(ui_scale) });
    zgui.setNextItemWidth(tokens.s(110, ui_scale));
    if (zgui.inputTextWithHint("##preset_search", .{
        .hint = "Search…",
        .buf = state.preset_search_buf[0..],
    })) {
        filters.rebuildPresetFilter(state);
    }
    zgui.sameLine(.{ .spacing = tokens.gapTight(ui_scale) });
    zgui.setNextItemWidth(-1);
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
}

// ── Shared helpers ───────────────────────────────────────────────────────────

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

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
