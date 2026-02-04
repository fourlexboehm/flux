const std = @import("std");
const zgui = @import("zgui");

const colors = @import("colors.zig");
const style = @import("style.zig");
const selection = @import("selection.zig");
const device_panel = @import("device_panel.zig");
const undo_requests = @import("undo_requests.zig");
const state_mod = @import("state.zig");
const session_constants = @import("session_view/constants.zig");
const session_ops = @import("session_view/ops.zig");
const session_draw = @import("session_view/draw.zig");
const piano_roll_draw = @import("piano_roll/draw.zig");

const Colors = colors.Colors;
const State = state_mod.State;

const max_tracks = session_constants.max_tracks;

const quantize_items: [:0]const u8 = "1/4\x001/2\x001\x002\x004\x00";
const buffer_items = "64\x00128\x00256\x00512\x001024\x00\x00";

pub fn draw(state: *State, ui_scale: f32) void {
    state.piano_state.preview_pitch = null;
    state.piano_state.preview_track = null;

    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = display[1], .cond = .always });

    style.applyMinimalStyle(ui_scale);
    style.pushAbletonStyle();
    defer style.popAbletonStyle();

    if (zgui.begin("flux##root", .{ .flags = .{
        .no_collapse = true,
        .no_resize = true,
        .no_move = true,
        .no_title_bar = true,
        .no_scrollbar = true,
        .no_scroll_with_mouse = true,
    } })) {
        // Tab key toggles between Device and Clip views
        if (zgui.isKeyPressed(.tab, false)) {
            state.bottom_mode = switch (state.bottom_mode) {
                .device => .sequencer,
                .sequencer => .device,
            };
        }

        drawTransport(state, ui_scale);
        zgui.spacing();
        const avail = zgui.getContentRegionAvail();
        const splitter_h = 6.0 * ui_scale;
        const min_bottom = 100.0 * ui_scale;
        const max_bottom = avail[1] - 100.0 * ui_scale;
        const bottom_height = std.math.clamp(state.bottom_panel_height * ui_scale, min_bottom, max_bottom);
        const top_height = @max(0.0, avail[1] - bottom_height - splitter_h);

        // Clip grid area
        if (zgui.beginChild("clip_area##root", .{ .w = 0, .h = top_height, .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
            // Track focus
            if (zgui.isWindowHovered(.{ .child_windows = true }) and zgui.isMouseClicked(.left)) {
                state.focused_pane = .session;
            }
            drawClipGrid(state, ui_scale);
        }
        zgui.endChild();

        // Splitter handle
        const splitter_pos = zgui.getCursorScreenPos();
        const avail_w = zgui.getContentRegionAvail()[0];
        const draw_list = zgui.getWindowDrawList();

        _ = zgui.invisibleButton("##splitter", .{ .w = avail_w, .h = splitter_h });
        const is_hovered = zgui.isItemHovered(.{});
        const is_active = zgui.isItemActive();

        if (is_hovered or is_active) {
            zgui.setMouseCursor(.resize_ns);
        }

        const splitter_color = if (is_active)
            Colors.current.accent
        else if (is_hovered)
            Colors.current.accent_dim
        else
            Colors.current.border;
        draw_list.addRectFilled(.{
            .pmin = splitter_pos,
            .pmax = .{ splitter_pos[0] + avail_w, splitter_pos[1] + splitter_h },
            .col = zgui.colorConvertFloat4ToU32(splitter_color),
        });

        if (zgui.isItemActivated()) {
            state.splitter_drag_start = state.bottom_panel_height;
        }
        if (is_active) {
            const drag_delta = zgui.getMouseDragDelta(.left, .{});
            const max_bottom_unscaled = max_bottom / ui_scale;
            state.bottom_panel_height = std.math.clamp(state.splitter_drag_start - drag_delta[1] / ui_scale, 100.0, max_bottom_unscaled);
        }

        // Bottom panel
        if (zgui.beginChild("bottom_panel##root", .{ .w = 0, .h = bottom_height, .child_flags = .{ .border = true }, .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
            // Track focus
            if (zgui.isWindowHovered(.{ .child_windows = true }) and zgui.isMouseClicked(.left)) {
                state.focused_pane = .bottom;
            }
            drawBottomPanel(state, ui_scale);
        }
        zgui.endChild();
    }

    // Undo/Redo shortcuts (Cmd+Z / Cmd+Shift+Z on Mac, Ctrl+Z / Ctrl+Shift+Z on other platforms)
    // Placed at end of frame so undo requests from this frame are already processed
    const mod_down = selection.isModifierDown();
    if (mod_down and zgui.isKeyPressed(.z, false)) {
        if (selection.isShiftDown()) {
            _ = state.performRedo();
        } else {
            _ = state.performUndo();
        }
    }

    zgui.end();
}

fn drawTransport(state: *State, ui_scale: f32) void {
    const transport_h = 52.0 * ui_scale;
    const btn_size = 36.0 * ui_scale;
    const spacing = 20.0 * ui_scale;

    const draw_list = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    const avail_w = zgui.getContentRegionAvail()[0];
    draw_list.addRectFilled(.{
        .pmin = .{ pos[0], pos[1] },
        .pmax = .{ pos[0] + avail_w, pos[1] + transport_h },
        .col = zgui.colorConvertFloat4ToU32(Colors.current.bg_header),
    });

    zgui.setCursorPosY(zgui.getCursorPosY() + 6.0 * ui_scale);
    zgui.setCursorPosX(zgui.getCursorPosX() + 8.0 * ui_scale);

    const play_color = if (state.playing) Colors.current.transport_play else Colors.current.text_dim;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = Colors.current.bg_header });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.current.bg_cell_active });
    defer zgui.popStyleColor(.{ .count = 3 });

    const btn_pos = zgui.getCursorScreenPos();
    if (zgui.button("##play_btn", .{ .w = btn_size, .h = btn_size })) {
        state.playing = !state.playing;
        state.playhead_beat = 0;
    }

    if (state.playing) {
        const sq_size = 14.0 * ui_scale;
        const cx = btn_pos[0] + btn_size / 2.0;
        const cy = btn_pos[1] + btn_size / 2.0;
        draw_list.addRectFilled(.{
            .pmin = .{ cx - sq_size / 2.0, cy - sq_size / 2.0 },
            .pmax = .{ cx + sq_size / 2.0, cy + sq_size / 2.0 },
            .col = zgui.colorConvertFloat4ToU32(play_color),
        });
    } else {
        const tri_size = 16.0 * ui_scale;
        const cx = btn_pos[0] + btn_size / 2.0 + 2.0 * ui_scale;
        const cy = btn_pos[1] + btn_size / 2.0;
        draw_list.addTriangleFilled(.{
            .p1 = .{ cx - tri_size / 2.0, cy - tri_size / 2.0 },
            .p2 = .{ cx - tri_size / 2.0, cy + tri_size / 2.0 },
            .p3 = .{ cx + tri_size / 2.0, cy },
            .col = zgui.colorConvertFloat4ToU32(play_color),
        });
    }

    zgui.sameLine(.{ .spacing = spacing });

    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
    zgui.textUnformatted("BPM");
    zgui.popStyleColor(.{ .count = 1 });
    zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
    zgui.setNextItemWidth(100.0 * ui_scale);
    const bpm_before = state.bpm;
    _ = zgui.sliderFloat("##transport_bpm", .{
        .v = &state.bpm,
        .min = 40.0,
        .max = 200.0,
        .cfmt = "%.0f",
    });

    // Track BPM drag for undo
    if (zgui.isItemActive()) {
        if (!state.bpm_drag_active) {
            state.bpm_drag_active = true;
            state.bpm_drag_start = bpm_before;
        }
    } else if (state.bpm_drag_active) {
        // Drag ended - emit undo if changed
        if (state.bpm != state.bpm_drag_start) {
            state.undo_history.push(.{
                .bpm_change = .{
                    .old_bpm = state.bpm_drag_start,
                    .new_bpm = state.bpm,
                },
            });
        }
        state.bpm_drag_active = false;
    }

    zgui.sameLine(.{ .spacing = spacing });

    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
    zgui.textUnformatted("Quantize");
    zgui.popStyleColor(.{ .count = 1 });
    zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
    const quantize_label_size = zgui.calcTextSize("1/4", .{});
    const frame_height = zgui.getFrameHeight();
    const frame_padding = zgui.getStyle().frame_padding;
    const quantize_width = quantize_label_size[0] + frame_height + frame_padding[0] * 2.0 + 6.0 * ui_scale;
    zgui.setNextItemWidth(quantize_width);
    _ = zgui.combo("##transport_quantize", .{
        .current_item = &state.quantize_index,
        .items_separated_by_zeros = quantize_items,
    });

    // Track quantize change for undo
    if (state.quantize_index != state.quantize_last) {
        state.undo_history.push(.{
            .quantize_change = .{
                .old_index = state.quantize_last,
                .new_index = state.quantize_index,
            },
        });
        state.quantize_last = state.quantize_index;
    }

    zgui.sameLine(.{ .spacing = spacing });

    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
    zgui.textUnformatted("Buffer");
    zgui.popStyleColor(.{ .count = 1 });
    zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
    var buffer_index: i32 = 0;
    for (state_mod.buffer_frame_options, 0..) |frames, idx| {
        if (state.buffer_frames == frames) {
            buffer_index = @intCast(idx);
            break;
        }
    }
    var max_buffer_label_w: f32 = 0.0;
    var label_buf: [16]u8 = undefined;
    for (state_mod.buffer_frame_options) |frames| {
        const label = std.fmt.bufPrint(&label_buf, "{d}", .{frames}) catch unreachable;
        const label_size = zgui.calcTextSize(label, .{});
        if (label_size[0] > max_buffer_label_w) {
            max_buffer_label_w = label_size[0];
        }
    }
    const buffer_width = max_buffer_label_w + frame_height + frame_padding[0] * 2.0 + 6.0 * ui_scale;
    zgui.setNextItemWidth(buffer_width);
    if (zgui.combo("##transport_buffer", .{
        .current_item = &buffer_index,
        .items_separated_by_zeros = buffer_items,
    })) {
        const new_frames = state_mod.buffer_frame_options[@intCast(buffer_index)];
        if (new_frames != state.buffer_frames) {
            state.buffer_frames = new_frames;
            state.buffer_frames_requested = true;
        }
    }

    zgui.sameLine(.{ .spacing = 10.0 * ui_scale });
    var dsp_buf: [16]u8 = undefined;
    const dsp_label = std.fmt.bufPrint(&dsp_buf, "DSP {d}%", .{state.dsp_load_pct}) catch "DSP";
    const dsp_size = zgui.calcTextSize(dsp_label, .{});
    const dsp_max_w = zgui.calcTextSize("DSP 100%", .{})[0];
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
    zgui.textUnformatted(dsp_label);
    zgui.popStyleColor(.{ .count = 1 });

    // Load/Save buttons (right-aligned, centered vertically)
    const dsp_pad = @max(0.0, dsp_max_w - dsp_size[0]);
    zgui.sameLine(.{ .spacing = spacing * 2.0 + dsp_pad });

    // Move buttons up to center in transport bar
    const save_y = zgui.getCursorPosY();
    zgui.setCursorPosY(save_y - 4.0 * ui_scale);

    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 16.0 * ui_scale, 8.0 * ui_scale } });
    if (zgui.button("Load", .{})) {
        state.load_project_request = true;
    }

    zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
    zgui.setCursorPosY(save_y - 4.0 * ui_scale);

    if (zgui.button("Save", .{})) {
        state.save_project_request = true;
    }

    zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
    zgui.setCursorPosY(save_y - 4.0 * ui_scale);

    if (zgui.button("Save As", .{})) {
        state.save_project_as_request = true;
    }
    zgui.popStyleVar(.{ .count = 1 });

    zgui.setCursorPosY(save_y + transport_h - 6.0 * ui_scale);
}

fn drawClipGrid(state: *State, ui_scale: f32) void {
    // Draw session view
    const is_focused = state.focused_pane == .session;
    session_draw.draw(&state.session, ui_scale, state.playing, is_focused, state.playhead_beat);
    // Lock selection to the active recording clip to avoid cross-clip input confusion.
    if (state.session.recording.isRecording()) {
        if (state.session.recording.track) |track| {
            if (state.session.recording.scene) |scene| {
                if (state.session.primary_track != track or state.session.primary_scene != scene) {
                    session_ops.selectOnly(&state.session, track, scene);
                }
            }
        }
    }
    if (state.session.open_clip_request) |req| {
        state.session.open_clip_request = null;
        state.session.primary_track = req.track;
        state.session.primary_scene = req.scene;
        state.bottom_mode = .sequencer;
        state.focused_pane = .bottom;
    }
    // Handle request to clear piano clip (when starting new recording on empty slot)
    if (state.session.clear_piano_clip_request) |req| {
        state.session.clear_piano_clip_request = null;
        state.piano_clips[req.track][req.scene].clear();
    }
    if (state.session.start_playback_request) {
        state.session.start_playback_request = false;
        state.playing = true;
    }

    // Process undo requests from session view and piano roll operations
    undo_requests.processUndoRequests(state);
    undo_requests.processPianoRollUndoRequests(state);
}

fn drawBottomPanel(state: *State, ui_scale: f32) void {
    // Device tab
    const device_active = state.bottom_mode == .device;
    const device_color = if (device_active) Colors.current.accent else Colors.current.bg_header;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = device_color });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (device_active) Colors.current.accent else Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.current.accent_dim });
    if (zgui.button("Device", .{})) {
        state.bottom_mode = .device;
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.sameLine(.{});

    // Clip tab
    const seq_active = state.bottom_mode == .sequencer;
    const seq_color = if (seq_active) Colors.current.accent else Colors.current.bg_header;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = seq_color });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (seq_active) Colors.current.accent else Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.current.accent_dim });
    if (zgui.button("Clip", .{})) {
        state.bottom_mode = .sequencer;
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.sameLine(.{});
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
    var track_buf: [64]u8 = undefined;
    const track_info = if (state.session.mixer_target == .master)
        std.fmt.bufPrintZ(&track_buf, "  Master", .{}) catch "  Master"
    else
        std.fmt.bufPrintZ(&track_buf, "  Track {d} / Scene {d}", .{ state.selectedTrack() + 1, state.selectedScene() + 1 }) catch "";
    zgui.textUnformatted(track_info);
    zgui.popStyleColor(.{ .count = 1 });

    zgui.separator();

    switch (state.bottom_mode) {
        .device => {
            device_panel.drawDevicePanel(state, ui_scale);
        },
        .sequencer => {
            // Only show piano roll if there's a clip at this position
            const clip_slot = state.session.clips[state.selectedTrack()][state.selectedScene()];
            if (clip_slot.state == .empty) {
                zgui.spacing();
                zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
                zgui.textUnformatted("No clip. Double-click in session view to create one.");
                zgui.popStyleColor(.{ .count = 1 });
            } else {
                const is_focused = state.focused_pane == .bottom;
                const track_idx = state.selectedTrack();
                const instrument_plugin = state.track_plugin_ptrs[track_idx];
                const fx_plugins = state.track_fx_plugin_ptrs[track_idx][0..state.track_fx_slot_count[track_idx]];
                piano_roll_draw.drawSequencer(
                    &state.piano_state,
                    state.currentClip(),
                    state.currentClipLabel(),
                    state.playhead_beat,
                    state.playing,
                    state.quantize_index,
                    ui_scale,
                    is_focused,
                    state.selectedTrack(),
                    state.selectedScene(),
                    &state.live_key_states[state.selectedTrack()],
                    instrument_plugin,
                    fx_plugins,
                );
                if (state.piano_state.preview_pitch) |pitch| {
                    if (state.piano_state.preview_track) |track| {
                        if (track < max_tracks) {
                            state.live_key_states[track][pitch] = true;
                            state.live_key_velocities[track][pitch] = 0.8;
                        }
                    }
                }
            }
        },
    }
}
