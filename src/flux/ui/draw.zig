const std = @import("std");
const zgui = @import("zgui");

const colors = @import("theme/colors.zig");
const style = @import("theme/style.zig");
const selection = @import("input/selection.zig");
const device_panel = @import("panels/device.zig");
const undo_requests = @import("undo_requests.zig");
const state_mod = @import("state.zig");
const session_constants = @import("../session/constants.zig");
const session_ops = @import("../session/ops.zig");
const session_draw = @import("views/session/draw.zig");
const piano_roll_draw = @import("views/piano_roll/draw.zig");
const audio_clip_viewer = @import("views/audio_clip/draw_viewer.zig");
const widgets = @import("theme/widgets.zig");
const tokens = @import("theme/tokens.zig");

const Colors = colors.Colors;
const State = state_mod.State;

const max_tracks = session_constants.max_tracks;

const quantize_items: [:0]const u8 = "1/4\x001/2\x001\x002\x004\x00";
const buffer_items = "64\x00128\x00256\x00512\x001024\x00\x00";
const time_signature_items = "2/4\x003/4\x004/4\x005/4\x006/8\x007/8\x009/8\x0012/8\x00\x00";
const time_signatures = [_][2]u8{
    .{ 2, 4 }, .{ 3, 4 }, .{ 4, 4 }, .{ 5, 4 },
    .{ 6, 8 }, .{ 7, 8 }, .{ 9, 8 }, .{ 12, 8 },
};

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
        zgui.dummy(.{ .w = 0, .h = tokens.s(4, ui_scale) });
        const avail = zgui.getContentRegionAvail();
        const splitter_h = tokens.s(5, ui_scale);
        const min_bottom = tokens.s(100, ui_scale);
        const max_bottom = avail[1] - tokens.s(100, ui_scale);
        const bottom_height = std.math.clamp(state.bottom_panel_height * ui_scale, min_bottom, max_bottom);
        const top_height = @max(0.0, avail[1] - bottom_height - splitter_h);

        // Clip grid area
        const session_child_pos = zgui.getCursorScreenPos();
        if (zgui.beginChild("clip_area##root", .{ .w = 0, .h = top_height, .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
            // Only steal focus when the pointer is actually over this pane (not
            // while dragging a bottom-panel control that wandered upward).
            if (zgui.isWindowHovered(.{ .child_windows = true, .allow_when_blocked_by_active_item = false }) and
                zgui.isMouseClicked(.left) and !zgui.isAnyItemActive())
            {
                state.focused_pane = .session;
            }
            drawClipGrid(state, ui_scale);
        }
        zgui.endChild();
        widgets.focusFrame(
            session_child_pos,
            .{ session_child_pos[0] + avail[0], session_child_pos[1] + top_height },
            state.focused_pane == .session,
            ui_scale,
        );

        // Splitter handle with grip
        const splitter_pos = zgui.getCursorScreenPos();
        const avail_w = zgui.getContentRegionAvail()[0];
        const draw_list = zgui.getWindowDrawList();

        _ = zgui.invisibleButton("##splitter", .{ .w = avail_w, .h = splitter_h });
        const is_hovered = zgui.isItemHovered(.{});
        const is_active = zgui.isItemActive();
        if (is_hovered or is_active) zgui.setMouseCursor(.resize_ns);

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
        // Grip dots
        const grip_col = zgui.colorConvertFloat4ToU32(Colors.current.text_soft);
        const mid_x = splitter_pos[0] + avail_w * 0.5;
        const mid_y = splitter_pos[1] + splitter_h * 0.5;
        const gap = tokens.s(5, ui_scale);
        for ([_]f32{ -1, 0, 1 }) |i| {
            draw_list.addCircleFilled(.{
                .p = .{ mid_x + i * gap, mid_y },
                .r = tokens.s(1.2, ui_scale),
                .col = grip_col,
            });
        }

        if (zgui.isItemActivated()) {
            state.splitter_drag_start = state.bottom_panel_height;
        }
        if (is_active) {
            const drag_delta = zgui.getMouseDragDelta(.left, .{});
            const max_bottom_unscaled = max_bottom / ui_scale;
            state.bottom_panel_height = std.math.clamp(state.splitter_drag_start - drag_delta[1] / ui_scale, 100.0, max_bottom_unscaled);
        }

        // Bottom panel
        const bottom_child_pos = zgui.getCursorScreenPos();
        if (zgui.beginChild("bottom_panel##root", .{ .w = 0, .h = bottom_height, .child_flags = .{ .border = true }, .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
            // Capture focus on press/hover so horizontal slider drags don't
            // fall through to session track selection behind the panel.
            const bottom_hover = zgui.isWindowHovered(.{
                .child_windows = true,
                .allow_when_blocked_by_active_item = true,
            });
            if (bottom_hover and (zgui.isMouseClicked(.left) or zgui.isMouseDown(.left))) {
                state.focused_pane = .bottom;
            }
            drawBottomPanel(state, ui_scale);
            if (bottom_hover and zgui.isAnyItemActive()) {
                state.focused_pane = .bottom;
            }
        }
        zgui.endChild();
        widgets.focusFrame(
            bottom_child_pos,
            .{ bottom_child_pos[0] + avail_w, bottom_child_pos[1] + bottom_height },
            state.focused_pane == .bottom,
            ui_scale,
        );
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
    const transport_h = tokens.transportH(ui_scale);
    const control_h = zgui.getFrameHeight();
    const tight = tokens.gapTight(ui_scale);
    const group = tokens.gapGroup(ui_scale);

    const draw_list = zgui.getWindowDrawList();
    const bar_screen = zgui.getCursorScreenPos();
    const bar_start_y = zgui.getCursorPosY();
    const avail_w = zgui.getContentRegionAvail()[0];
    draw_list.addRectFilled(.{
        .pmin = .{ bar_screen[0], bar_screen[1] },
        .pmax = .{ bar_screen[0] + avail_w, bar_screen[1] + transport_h },
        .col = zgui.colorConvertFloat4ToU32(Colors.current.bg_header),
        .rounding = tokens.radius(.md, ui_scale),
    });

    // Single baseline so every control (play, combos, save) sits on one row.
    const row_y = tokens.centerInBar(bar_start_y, transport_h, control_h);
    zgui.setCursorPosY(row_y);
    zgui.setCursorPosX(zgui.getCursorPosX() + tokens.s(8, ui_scale));

    // --- Transport icons ---
    const play_kind: widgets.Icon = if (state.playing) .stop else .play;
    const play_col = if (state.playing) Colors.current.transport_stop else Colors.current.transport_play;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = Colors.current.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.current.bg_cell_active });
    const play_pos = zgui.getCursorScreenPos();
    if (zgui.button("##play_btn", .{ .w = control_h, .h = control_h })) {
        state.playing = !state.playing;
        state.playhead_beat = 0;
    }
    widgets.itemTooltip(if (state.playing) "Stop" else "Play");
    // Draw play/stop with transport color (override default dim icon)
    {
        // re-draw icon in transport color over the button
        const pad = control_h * 0.28;
        const cx = play_pos[0] + control_h * 0.5;
        const cy = play_pos[1] + control_h * 0.5;
        const col = zgui.colorConvertFloat4ToU32(play_col);
        if (state.playing) {
            const half = control_h * 0.16;
            draw_list.addRectFilled(.{ .pmin = .{ cx - half, cy - half }, .pmax = .{ cx + half, cy + half }, .col = col });
        } else {
            draw_list.addTriangleFilled(.{
                .p1 = .{ cx - control_h * 0.14, cy - control_h * 0.18 },
                .p2 = .{ cx - control_h * 0.14, cy + control_h * 0.18 },
                .p3 = .{ cx + control_h * 0.2, cy },
                .col = col,
            });
        }
        _ = pad;
        _ = play_kind;
    }

    zgui.sameLine(.{ .spacing = tight });
    zgui.setCursorPosY(row_y);
    const metro_pos = zgui.getCursorScreenPos();
    if (zgui.button("##metronome", .{ .w = control_h, .h = control_h })) {
        state.metronome_enabled = !state.metronome_enabled;
    }
    widgets.itemTooltip("Metronome");
    {
        const signature_pulse = state.playhead_beat * @as(f32, @floatFromInt(state.time_signature_denominator)) / 4.0;
        const active_dot: usize = if (state.playing) @intFromFloat(@mod(@floor(signature_pulse), 2.0)) else 0;
        const dot_radius = tokens.s(3.2, ui_scale);
        const dot_gap = tokens.s(9, ui_scale);
        const dot_y = metro_pos[1] + control_h * 0.5;
        for (0..2) |dot| {
            const dot_color = if (state.metronome_enabled and dot == active_dot)
                Colors.current.accent
            else
                Colors.current.text_soft;
            draw_list.addCircleFilled(.{
                .p = .{ metro_pos[0] + control_h * 0.5 + (@as(f32, @floatFromInt(dot)) - 0.5) * dot_gap, dot_y },
                .r = dot_radius,
                .col = zgui.colorConvertFloat4ToU32(dot_color),
            });
        }
    }
    zgui.popStyleColor(.{ .count = 3 });

    // --- Time / tempo group ---
    widgets.toolbarSeparator(ui_scale, control_h);
    zgui.setCursorPosY(row_y);

    var time_signature_index: i32 = 2;
    for (time_signatures, 0..) |signature, index| {
        if (signature[0] == state.time_signature_numerator and signature[1] == state.time_signature_denominator) {
            time_signature_index = @intCast(index);
            break;
        }
    }
    const time_sig_labels = [_][]const u8{ "2/4", "3/4", "4/4", "5/4", "6/8", "7/8", "9/8", "12/8" };
    zgui.setNextItemWidth(widgets.comboContentWidthForLabels(&time_sig_labels, ui_scale));
    if (zgui.combo("##transport_time_signature", .{
        .current_item = &time_signature_index,
        .items_separated_by_zeros = time_signature_items,
    })) {
        const signature = time_signatures[@intCast(time_signature_index)];
        state.time_signature_numerator = signature[0];
        state.time_signature_denominator = signature[1];
    }
    widgets.itemTooltip("Time signature");

    zgui.sameLine(.{ .spacing = group });
    zgui.setCursorPosY(row_y);
    zgui.alignTextToFramePadding();
    widgets.dimLabel("BPM");
    zgui.sameLine(.{ .spacing = tight });
    zgui.setCursorPosY(row_y);
    zgui.setNextItemWidth(tokens.s(88, ui_scale));
    const bpm_before = state.bpm;
    _ = zgui.sliderFloat("##transport_bpm", .{
        .v = &state.bpm,
        .min = 40.0,
        .max = 200.0,
        .cfmt = "%.0f",
    });
    if (zgui.isItemActive()) {
        if (!state.bpm_drag_active) {
            state.bpm_drag_active = true;
            state.bpm_drag_start = bpm_before;
        }
    } else if (state.bpm_drag_active) {
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

    // --- Quantize / buffer ---
    widgets.toolbarSeparator(ui_scale, control_h);
    zgui.setCursorPosY(row_y);
    zgui.alignTextToFramePadding();
    widgets.dimLabel("Q");
    widgets.itemTooltip("Quantize");
    zgui.sameLine(.{ .spacing = tight });
    zgui.setCursorPosY(row_y);
    const quantize_labels = [_][]const u8{ "1/4", "1/2", "1", "2", "4" };
    zgui.setNextItemWidth(widgets.comboContentWidthForLabels(&quantize_labels, ui_scale));
    _ = zgui.combo("##transport_quantize", .{
        .current_item = &state.quantize_index,
        .items_separated_by_zeros = quantize_items,
    });
    if (state.quantize_index != state.quantize_last) {
        state.undo_history.push(.{
            .quantize_change = .{
                .old_index = state.quantize_last,
                .new_index = state.quantize_index,
            },
        });
        state.quantize_last = state.quantize_index;
    }

    zgui.sameLine(.{ .spacing = group });
    zgui.setCursorPosY(row_y);
    zgui.alignTextToFramePadding();
    widgets.dimLabel("Buf");
    widgets.itemTooltip("Buffer size");
    zgui.sameLine(.{ .spacing = tight });
    zgui.setCursorPosY(row_y);
    var buffer_index: i32 = 0;
    for (state_mod.buffer_frame_options, 0..) |frames, idx| {
        if (state.buffer_frames == frames) {
            buffer_index = @intCast(idx);
            break;
        }
    }
    const buffer_labels = [_][]const u8{ "64", "128", "256", "512", "1024" };
    zgui.setNextItemWidth(widgets.comboContentWidthForLabels(&buffer_labels, ui_scale));
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

    zgui.sameLine(.{ .spacing = group });
    zgui.setCursorPosY(row_y);
    zgui.alignTextToFramePadding();
    var dsp_buf: [16]u8 = undefined;
    const dsp_label = std.fmt.bufPrint(&dsp_buf, "DSP {d}%", .{state.dsp_load_pct}) catch "DSP";
    widgets.dimLabel(dsp_label);

    // --- File actions: same row height, right-aligned on the bar ---
    const file_gap = tight;
    const file_btn_count: f32 = 4.0;
    const file_total_w = control_h * file_btn_count + file_gap * (file_btn_count - 1.0);
    const right_pad = tokens.s(8, ui_scale);
    zgui.sameLine(.{ .spacing = 0 });
    {
        const x = zgui.getCursorPosX();
        const remain = zgui.getContentRegionAvail()[0];
        const target_x = x + remain - file_total_w - right_pad;
        zgui.setCursorPosX(if (target_x > x + tight) target_x else x + tight);
    }
    zgui.setCursorPosY(row_y);
    if (widgets.iconButton("##load_project", .folder, ui_scale, "Load project")) {
        state.load_project_request = true;
    }
    zgui.sameLine(.{ .spacing = file_gap });
    zgui.setCursorPosY(row_y);
    if (widgets.iconButton("##save_project", .save, ui_scale, if (state.isProjectDirty()) "Save project •" else "Save project")) {
        state.save_project_request = true;
    }
    zgui.sameLine(.{ .spacing = file_gap });
    zgui.setCursorPosY(row_y);
    if (widgets.iconButton("##save_project_as", .save_as, ui_scale, "Save project as…")) {
        state.save_project_as_request = true;
    }
    zgui.sameLine(.{ .spacing = file_gap });
    zgui.setCursorPosY(row_y);
    if (widgets.iconButton("##pack_project", .open_window, ui_scale, "Pack Project… (embedded audio)")) {
        state.pack_project_request = true;
    }

    // Consume full bar height so following layout starts below the transport.
    zgui.setCursorPosY(bar_start_y + transport_h);
}

fn drawClipGrid(state: *State, ui_scale: f32) void {
    // Draw session view
    const is_focused = state.focused_pane == .session;
    session_draw.draw(
        &state.session,
        ui_scale,
        state.playing,
        is_focused,
        state.playhead_beat,
        state.beatsPerBar(),
        .{
            .audio_clips = &state.audio_clips,
            .sample_store = &state.sample_store,
        },
    );
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
    // Hybrid slot exclusivity: MIDI recording/edit drops sample on this cell
    if (state.session.claim_midi_slot_request) |req| {
        state.session.claim_midi_slot_request = null;
        state.claimSlotForMidi(req.track, req.scene);
    }
    // Handle request to clear piano clip (when starting new recording on empty slot)
    if (state.session.clear_piano_clip_request) |req| {
        state.session.clear_piano_clip_request = null;
        state.piano_clips[req.track][req.scene].clear();
        state.piano_clips[req.track][req.scene].length_beats = state.session.clips[req.track][req.scene].length_beats;
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
    const device_active = state.bottom_mode == .device;
    const seq_active = state.bottom_mode == .sequencer;

    if (widgets.segmentedTab("##tab_device", .device, "Device", ui_scale, device_active)) {
        state.bottom_mode = .device;
    }
    zgui.sameLine(.{ .spacing = tokens.s(4, ui_scale) });
    if (widgets.segmentedTab("##tab_clip", .clip, "Clip", ui_scale, seq_active)) {
        state.bottom_mode = .sequencer;
    }

    zgui.sameLine(.{ .spacing = tokens.gapGroup(ui_scale) });
    {
        var track_buf: [64]u8 = undefined;
        const track_info = if (state.session.mixer_target == .master)
            std.fmt.bufPrint(&track_buf, "Master", .{}) catch "Master"
        else
            std.fmt.bufPrint(&track_buf, "Track {d} · Scene {d}", .{ state.selectedTrack() + 1, state.selectedScene() + 1 }) catch "";
        widgets.statusPill(track_info, ui_scale);
    }

    zgui.separator();

    switch (state.bottom_mode) {
        .device => {
            device_panel.drawDevicePanel(state, ui_scale);
        },
        .sequencer => {
            const track_idx = state.selectedTrack();
            const scene_idx = state.selectedScene();
            const clip_slot = state.session.clips[track_idx][scene_idx];
            const audio = &state.audio_clips[track_idx][scene_idx];
            if (clip_slot.state == .empty) {
                widgets.emptyState("No clip", "Double-click a slot in the session grid to create one", ui_scale);
            } else if (audio.hasAudio()) {
                // Audio clip detail: waveform + format / I/O (not the piano roll)
                const is_focused = state.focused_pane == .bottom;
                audio_clip_viewer.draw(
                    audio,
                    &state.sample_store,
                    state.currentClipLabel(),
                    state.playhead_beat,
                    state.playing,
                    state.beatsPerBar(),
                    ui_scale,
                    is_focused,
                );
            } else {
                const is_focused = state.focused_pane == .bottom;
                const instrument_plugin = state.track_plugin_ptrs[track_idx];
                const fx_plugins = state.track_fx_plugin_ptrs[track_idx][0..state.track_fx_slot_count[track_idx]];
                piano_roll_draw.drawSequencer(
                    &state.piano_state,
                    state.currentClip(),
                    state.currentClipLabel(),
                    state.playhead_beat,
                    state.playing,
                    state.quantize_index,
                    state.beatsPerBar(),
                    ui_scale,
                    is_focused,
                    track_idx,
                    scene_idx,
                    &state.live_key_states[track_idx],
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
