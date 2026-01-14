const std = @import("std");
const zgui = @import("zgui");
const zsynth = @import("zsynth-core");
const zsynth_view = zsynth.View;

pub const track_count = 4;
pub const scene_count = 8;

pub const ClipState = enum {
    empty,
    stopped,
    queued,
    playing,
};

pub const ClipSlot = struct {
    label: []const u8,
    state: ClipState,
};

pub const Track = struct {
    name: []const u8,
    volume: f32,
    mute: bool,
    solo: bool,
};

pub const BottomMode = enum {
    device,
    sequencer,
};

pub const TrackPluginUI = struct {
    choice_index: i32,
    gui_open: bool,
};

pub const seq_steps = 16;
pub const seq_rows = 12;

const seq_step_width = 28.0;

pub const SequencerClip = struct {
    length_steps: u8,
    notes: [seq_rows][seq_steps]u8,
};

const DragState = struct {
    active: bool,
    track: usize,
    scene: usize,
    start_len: u8,
};

const NoteDragState = struct {
    const Mode = enum {
        create,
        resize,
    };

    active: bool,
    track: usize,
    scene: usize,
    row: usize,
    start_step: u8,
    start_len: u8,
    mode: Mode,
};

pub const State = struct {
    playing: bool,
    bpm: f32,
    quantize_index: i32,
    bottom_mode: BottomMode,
    zsynth: ?*zsynth.Plugin,
    selected_track: usize,
    selected_scene: usize,
    playhead_step: u8,
    step_accum: f64,
    drag: DragState,
    note_drag: NoteDragState,
    tracks: [track_count]Track,
    track_plugins: [track_count]TrackPluginUI,
    clips: [track_count][scene_count]ClipSlot,
    sequencer: [track_count][scene_count]SequencerClip,

    pub fn init() State {
        const tracks: [track_count]Track = .{
            .{ .name = "Track 1", .volume = 0.8, .mute = false, .solo = false },
            .{ .name = "Track 2", .volume = 0.8, .mute = false, .solo = false },
            .{ .name = "Track 3", .volume = 0.8, .mute = false, .solo = false },
            .{ .name = "Track 4", .volume = 0.8, .mute = false, .solo = false },
        };
        var clips: [track_count][scene_count]ClipSlot = undefined;
        for (&clips, 0..) |*track_clips, t| {
            for (track_clips, 0..) |*slot, s| {
                slot.* = .{
                    .label = switch (s) {
                        0 => "Intro",
                        1 => "Verse",
                        2 => "Build",
                        3 => "Chorus",
                        4 => "Bridge",
                        5 => "Drop",
                        6 => "Outro",
                        else => "Clip",
                    },
                    .state = if (t == 0 and s == 0) .playing else .stopped,
                };
            }
        }
        var track_plugins: [track_count]TrackPluginUI = undefined;
        for (&track_plugins) |*plugin| {
            plugin.* = .{
                .choice_index = 0,
                .gui_open = false,
            };
        }
        var sequencer: [track_count][scene_count]SequencerClip = undefined;
        for (&sequencer) |*track_clips| {
            for (track_clips) |*clip| {
                clip.* = .{
                    .length_steps = seq_steps,
                    .notes = [_][seq_steps]u8{[_]u8{0} ** seq_steps} ** seq_rows,
                };
            }
        }

        return .{
            .playing = true,
            .bpm = 120.0,
            .quantize_index = 2,
            .bottom_mode = .device,
            .zsynth = null,
            .selected_track = 0,
            .selected_scene = 0,
            .playhead_step = 0,
            .step_accum = 0,
            .drag = .{
                .active = false,
                .track = 0,
                .scene = 0,
                .start_len = seq_steps,
            },
            .note_drag = .{
                .active = false,
                .track = 0,
                .scene = 0,
                .row = 0,
                .start_step = 0,
                .start_len = 0,
                .mode = .create,
            },
            .tracks = tracks,
            .track_plugins = track_plugins,
            .clips = clips,
            .sequencer = sequencer,
        };
    }
};

const quantize_items: [:0]const u8 = "1/4\x001/2\x001\x002\x004\x00";
const plugin_items: [:0]const u8 = "None\x00ZSynth\x00";

pub fn draw(state: *State, ui_scale: f32) void {
    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = display[1], .cond = .always });

    if (zgui.begin("zdaw##root", .{ .flags = .{
        .no_collapse = true,
        .no_resize = true,
        .no_move = true,
        .no_title_bar = true,
    } })) {
        drawTransport(state, ui_scale);
        zgui.separator();
        const avail = zgui.getContentRegionAvail();
        const desired_bottom = 600.0 * ui_scale;
        const bottom_height = @min(desired_bottom, avail[1] * 0.6);
        const top_height = @max(0.0, avail[1] - bottom_height - (8.0 * ui_scale));
        if (zgui.beginChild("clip_area##root", .{ .w = 0, .h = top_height })) {
            drawClipGrid(state, ui_scale);
        }
        zgui.endChild();
        zgui.spacing();
        if (zgui.beginChild("bottom_panel##root", .{ .w = 0, .h = bottom_height })) {
            drawBottomPanel(state, ui_scale);
        }
        zgui.endChild();
    }
    zgui.end();
}

pub fn tick(state: *State, dt: f64) void {
    if (!state.playing) {
        return;
    }
    const seconds_per_step = 60.0 / state.bpm / 4.0;
    state.step_accum += dt;
    while (state.step_accum >= seconds_per_step) {
        state.step_accum -= seconds_per_step;
        state.playhead_step = @intCast((state.playhead_step + 1) % seq_steps);
    }
}

fn drawTransport(state: *State, ui_scale: f32) void {
    const spacing = 12.0 * ui_scale;
    const item_w = 160.0 * ui_scale;
    zgui.text("Transport", .{});
    zgui.sameLine(.{ .spacing = spacing });
    if (zgui.button(if (state.playing) "Stop##transport" else "Play##transport", .{ .w = 80, .h = 0 })) {
        state.playing = !state.playing;
        state.playhead_step = 0;
        state.step_accum = 0;
    }
    zgui.sameLine(.{ .spacing = spacing });
    zgui.textUnformatted("BPM");
    zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
    zgui.setNextItemWidth(item_w);
    _ = zgui.sliderFloat("##transport_bpm", .{ .v = &state.bpm, .min = 40.0, .max = 200.0 });
    zgui.sameLine(.{ .spacing = spacing });
    zgui.textUnformatted("Quantize");
    zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
    zgui.setNextItemWidth(120.0 * ui_scale);
    _ = zgui.combo("##transport_quantize", .{ .current_item = &state.quantize_index, .items_separated_by_zeros = quantize_items });
}

fn drawClipGrid(state: *State, ui_scale: f32) void {
    const row_height = 64.0 * ui_scale;
    if (!zgui.beginTable("clip_grid", .{
        .column = track_count + 1,
        .flags = .{ .borders = .all, .row_bg = true },
    })) {
        return;
    }
    defer zgui.endTable();

    zgui.tableNextRow(.{ .min_row_height = 0 });
    _ = zgui.tableNextColumn();
    zgui.text("Scenes", .{});
    for (state.tracks, 0..) |track, t| {
        _ = t;
        _ = zgui.tableNextColumn();
        zgui.textUnformatted(track.name);
    }

    zgui.tableNextRow(.{ .min_row_height = 0 });
    _ = zgui.tableNextColumn();
    zgui.textUnformatted("Plugin");
    for (&state.track_plugins, 0..) |*plugin_ui, t| {
        var label_buf: [32]u8 = undefined;
        var button_buf: [32]u8 = undefined;
        const select_label = std.fmt.bufPrintZ(&label_buf, "##plugin_select_t{d}", .{t}) catch "##plugin_select";
        const button_label = std.fmt.bufPrintZ(
            &button_buf,
            "{s}##plugin_t{d}",
            .{ if (plugin_ui.gui_open) "Close" else "Open", t },
        ) catch "Open##plugin";
        _ = zgui.tableNextColumn();
        zgui.setNextItemWidth(140.0 * ui_scale);
        _ = zgui.combo(select_label, .{
            .current_item = &plugin_ui.choice_index,
            .items_separated_by_zeros = plugin_items,
        });
        zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
        if (zgui.button(button_label, .{
            .w = 70.0 * ui_scale,
            .h = 0,
        })) {
            plugin_ui.gui_open = !plugin_ui.gui_open;
        }
    }

    for (0..scene_count) |scene_index| {
        zgui.tableNextRow(.{ .min_row_height = row_height });
        _ = zgui.tableNextColumn();
        zgui.text("Scene {}", .{scene_index + 1});
        zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
        var launch_buf: [32]u8 = undefined;
        const launch_label = std.fmt.bufPrintZ(&launch_buf, "Launch##scene{d}", .{scene_index}) catch "Launch##scene";
        if (zgui.button(launch_label, .{ .w = 70.0 * ui_scale, .h = 0 })) {
            for (0..track_count) |track_index| {
                for (0..scene_count) |slot_index| {
                    state.clips[track_index][slot_index].state = if (slot_index == scene_index) .playing else .stopped;
                }
            }
        }

        for (0..track_count) |track_index| {
            _ = zgui.tableNextColumn();
            const slot = &state.clips[track_index][scene_index];
            const play_w = 34.0 * ui_scale;
            const clip_w = 140.0 * ui_scale - play_w - (6.0 * ui_scale);
            const clip_h = 56.0 * ui_scale;
            const selected_clicked = clipButton(state, slot, track_index, scene_index, clip_w, clip_h, ui_scale);
            zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
            var play_buf: [32]u8 = undefined;
            const play_label = std.fmt.bufPrintZ(&play_buf, "Play##t{d}s{d}", .{ track_index, scene_index }) catch "Play##clip";
            const play_clicked = zgui.button(play_label, .{ .w = play_w, .h = clip_h });

            if (selected_clicked or play_clicked) {
                state.selected_track = track_index;
                state.selected_scene = scene_index;
            }
            if (play_clicked) {
                if (slot.state == .playing) {
                    slot.state = .stopped;
                } else {
                    for (0..scene_count) |slot_index| {
                        state.clips[track_index][slot_index].state = if (slot_index == scene_index) .playing else .stopped;
                    }
                }
            }
        }
    }
}

fn clipButton(
    state: *State,
    slot: *ClipSlot,
    track_index: usize,
    scene_index: usize,
    width: f32,
    height: f32,
    ui_scale: f32,
) bool {
    const is_selected = state.selected_track == track_index and state.selected_scene == scene_index;
    const base_w = width;
    const base_h = height;
    const button_w = base_w;
    const button_h = base_h;
    const base_color = switch (slot.state) {
        .empty => [4]f32{ 0.18, 0.18, 0.2, 1.0 },
        .stopped => [4]f32{ 0.25, 0.25, 0.27, 1.0 },
        .queued => [4]f32{ 0.85, 0.55, 0.15, 1.0 },
        .playing => [4]f32{ 0.2, 0.7, 0.3, 1.0 },
    };
    const select_boost: f32 = if (is_selected) 0.2 else 0.0;
    const button_color = .{
        @min(1.0, base_color[0] + select_boost),
        @min(1.0, base_color[1] + select_boost),
        @min(1.0, base_color[2] + select_boost),
        1.0,
    };
    zgui.pushStyleColor4f(.{ .idx = .button, .c = button_color });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ button_color[0] + 0.05, button_color[1] + 0.05, button_color[2] + 0.05, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = .{ button_color[0] + 0.1, button_color[1] + 0.1, button_color[2] + 0.1, 1.0 } });
    defer zgui.popStyleColor(.{ .count = 3 });

    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(
        &label_buf,
        "{s}##t{d}s{d}",
        .{ slot.label, track_index, scene_index },
    ) catch "Clip##fallback";
    const clicked = zgui.button(label, .{ .w = button_w, .h = button_h });

    if (is_selected) {
        const handle_w = 10.0 * ui_scale;
        zgui.sameLine(.{ .spacing = -handle_w });
        var handle_buf: [32]u8 = undefined;
        const handle_label = std.fmt.bufPrintZ(&handle_buf, "##clip_resize_t{d}s{d}", .{ track_index, scene_index }) catch "##clip_resize";
        _ = zgui.invisibleButton(handle_label, .{ .w = handle_w, .h = button_h });
        if (zgui.isItemHovered(.{})) {
            zgui.setMouseCursor(.resize_ew);
        }
        if (zgui.isItemActivated()) {
            state.drag = .{
                .active = true,
                .track = track_index,
                .scene = scene_index,
                .start_len = state.sequencer[track_index][scene_index].length_steps,
            };
        }
        if (state.drag.active and state.drag.track == track_index and state.drag.scene == scene_index and zgui.isItemActive()) {
            const delta = zgui.getMouseDragDelta(.left, .{});
            const delta_steps: i32 = @intFromFloat(@floor(delta[0] / (seq_step_width * ui_scale)));
            var new_len: i32 = @as(i32, state.drag.start_len) + delta_steps;
            new_len = std.math.clamp(new_len, 1, seq_steps);
            state.sequencer[track_index][scene_index].length_steps = @intCast(new_len);
        }
        if (state.drag.active and state.drag.track == track_index and state.drag.scene == scene_index and zgui.isItemDeactivated()) {
            state.drag.active = false;
            zgui.resetMouseDragDelta(.left);
        }
    }

    return clicked;
}

fn drawBottomPanel(state: *State, ui_scale: f32) void {
    zgui.textUnformatted("Panel");
    zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
    if (zgui.button("Device##bottom", .{ .w = 90.0 * ui_scale, .h = 0 })) {
        state.bottom_mode = .device;
    }
    zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
    if (zgui.button("Sequencer##bottom", .{ .w = 110.0 * ui_scale, .h = 0 })) {
        state.bottom_mode = .sequencer;
    }
    zgui.separator();

    switch (state.bottom_mode) {
        .device => {
            if (state.zsynth) |plugin| {
                if (zgui.beginChild("zsynth_embed##device", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
                    zsynth_view.drawEmbedded(plugin, .{ .notify_host = false });
                }
                zgui.endChild();
            } else {
                zgui.textUnformatted("Device view (zsynth not loaded).");
            }
        },
        .sequencer => {
            drawSequencer(state, ui_scale);
        },
    }
}

fn drawSequencer(state: *State, ui_scale: f32) void {
    const track_index = state.selected_track;
    const scene_index = state.selected_scene;
    const clip = &state.sequencer[track_index][scene_index];
    const clip_label = state.clips[track_index][scene_index].label;
    const length_steps = @max(@as(u8, 1), @min(clip.length_steps, seq_steps));

    zgui.text("Sequencer: Track {d} / {s}", .{ track_index + 1, clip_label });
    zgui.sameLine(.{ .spacing = 12.0 * ui_scale });
    zgui.text("Length: {d} steps", .{length_steps});
    zgui.separator();

    const row_height = 30.0 * ui_scale;
    const step_width = 32.0 * ui_scale;

    if (!zgui.beginTable("sequencer_grid", .{
        .column = seq_steps + 1,
        .flags = .{ .borders = .all },
    })) {
        return;
    }
    defer zgui.endTable();

    const note_labels = [_][]const u8{
        "C4",
        "C#4",
        "D4",
        "D#4",
        "E4",
        "F4",
        "F#4",
        "G4",
        "G#4",
        "A4",
        "A#4",
        "B4",
    };

    const playhead = @as(usize, @intCast(state.playhead_step % length_steps));

    for (0..seq_rows) |row| {
        zgui.tableNextRow(.{ .min_row_height = row_height });
        _ = zgui.tableNextColumn();
        const note_row = seq_rows - 1 - row;
        zgui.textUnformatted(note_labels[note_row]);

        for (0..seq_steps) |step| {
            _ = zgui.tableNextColumn();
            if (state.playing and step == playhead) {
                const bg = zgui.colorConvertFloat4ToU32(.{ 0.16, 0.22, 0.32, 0.9 });
                zgui.tableSetBgColor(.{ .target = .cell_bg, .color = bg });
            }
            const within_length = step < length_steps;
            const note_start = findNoteStart(clip, note_row, step, length_steps);
            const pos = zgui.getCursorScreenPos();
            const bg_color = if (!within_length)
                zgui.colorConvertFloat4ToU32(.{ 0.12, 0.12, 0.14, 1.0 })
            else
                zgui.colorConvertFloat4ToU32(.{ 0.18, 0.18, 0.22, 1.0 });

            if (note_start != null and note_start.? == step) {
                const note_len = noteLength(clip, note_row, step, length_steps);
                const note_w = step_width * @as(f32, @floatFromInt(note_len));
                const note_color = zgui.colorConvertFloat4ToU32(.{ 0.3, 0.75, 0.45, 1.0 });
                const draw_list = zgui.getWindowDrawList();
                draw_list.addRectFilled(.{
                    .pmin = pos,
                    .pmax = .{ pos[0] + note_w, pos[1] + row_height },
                    .col = note_color,
                    .rounding = 4.0 * ui_scale,
                    .flags = zgui.DrawFlags.round_corners_all,
                });

                var body_buf: [48]u8 = undefined;
                const body_id = std.fmt.bufPrintZ(&body_buf, "##note_body_t{d}s{d}r{d}st{d}", .{
                    state.selected_track,
                    state.selected_scene,
                    note_row,
                    step,
                }) catch "##note_body";
                _ = zgui.invisibleButton(body_id, .{ .w = step_width, .h = row_height });
                const mouse = zgui.getMousePos();
                const handle_w = 8.0 * ui_scale;
                const near_edge = mouse[0] >= (pos[0] + note_w - handle_w) and mouse[0] <= (pos[0] + note_w);
                if (zgui.isItemHovered(.{}) and near_edge) {
                    zgui.setMouseCursor(.resize_ew);
                }
                if (zgui.isItemActivated() and near_edge) {
                    state.note_drag = .{
                        .active = true,
                        .track = state.selected_track,
                        .scene = state.selected_scene,
                        .row = note_row,
                        .start_step = @intCast(step),
                        .start_len = note_len,
                        .mode = .resize,
                    };
                }
                if (state.note_drag.active and state.note_drag.mode == .resize and state.note_drag.track == state.selected_track and state.note_drag.scene == state.selected_scene and state.note_drag.row == note_row and state.note_drag.start_step == step and zgui.isItemActive()) {
                    const delta = zgui.getMouseDragDelta(.left, .{});
                    const delta_steps: i32 = @intFromFloat(@floor(delta[0] / step_width));
                    const max_len = @as(i32, length_steps) - @as(i32, @intCast(step));
                    var new_len: i32 = @as(i32, state.note_drag.start_len) + delta_steps;
                    new_len = std.math.clamp(new_len, 1, max_len);
                    clearNotesInRange(clip, note_row, step, @intCast(new_len));
                    clip.notes[note_row][step] = @intCast(new_len);
                }
                if (state.note_drag.active and state.note_drag.mode == .resize and state.note_drag.track == state.selected_track and state.note_drag.scene == state.selected_scene and state.note_drag.row == note_row and state.note_drag.start_step == step and zgui.isItemDeactivated()) {
                    state.note_drag.active = false;
                    zgui.resetMouseDragDelta(.left);
                }
                if (!near_edge and zgui.isItemClicked(.left)) {
                    clip.notes[note_row][step] = 0;
                }
            } else if (note_start != null) {
                var body_buf: [48]u8 = undefined;
                const body_id = std.fmt.bufPrintZ(&body_buf, "##note_mid_t{d}s{d}r{d}st{d}", .{
                    state.selected_track,
                    state.selected_scene,
                    note_row,
                    step,
                }) catch "##note_mid";
                if (zgui.invisibleButton(body_id, .{ .w = step_width, .h = row_height })) {
                    const start = note_start.?;
                    clip.notes[note_row][start] = 0;
                }
            } else {
                const draw_list = zgui.getWindowDrawList();
                draw_list.addRectFilled(.{
                    .pmin = pos,
                    .pmax = .{ pos[0] + step_width, pos[1] + row_height },
                    .col = bg_color,
                });
                var label_buf: [32]u8 = undefined;
                const label = std.fmt.bufPrintZ(&label_buf, "##s{d}r{d}", .{ step, row }) catch "##seq";
                if (zgui.invisibleButton(label, .{ .w = step_width, .h = row_height })) {
                    if (within_length) {
                        clearNoteAtStep(clip, note_row, step, length_steps);
                        clip.notes[note_row][step] = 1;
                    }
                }
                if (within_length and zgui.isItemActivated()) {
                    clearNoteAtStep(clip, note_row, step, length_steps);
                    clip.notes[note_row][step] = 1;
                    state.note_drag = .{
                        .active = true,
                        .track = state.selected_track,
                        .scene = state.selected_scene,
                        .row = note_row,
                        .start_step = @intCast(step),
                        .start_len = 1,
                        .mode = .create,
                    };
                }
                if (state.note_drag.active and state.note_drag.mode == .create and state.note_drag.track == state.selected_track and state.note_drag.scene == state.selected_scene and state.note_drag.row == note_row and state.note_drag.start_step == step and zgui.isItemActive()) {
                    const delta = zgui.getMouseDragDelta(.left, .{});
                    const delta_steps: i32 = @intFromFloat(@floor(delta[0] / step_width));
                    const max_len = @as(i32, length_steps) - @as(i32, @intCast(step));
                    var new_len: i32 = @as(i32, state.note_drag.start_len) + delta_steps;
                    new_len = std.math.clamp(new_len, 1, max_len);
                    clearNotesInRange(clip, note_row, step, @intCast(new_len));
                    clip.notes[note_row][step] = @intCast(new_len);
                }
                if (state.note_drag.active and state.note_drag.mode == .create and state.note_drag.track == state.selected_track and state.note_drag.scene == state.selected_scene and state.note_drag.row == note_row and state.note_drag.start_step == step and zgui.isItemDeactivated()) {
                    state.note_drag.active = false;
                    zgui.resetMouseDragDelta(.left);
                }
            }
        }
    }
}

fn findNoteStart(clip: *const SequencerClip, row: usize, step: usize, length_steps: u8) ?usize {
    var idx: i32 = @intCast(step);
    while (idx >= 0) : (idx -= 1) {
        const start: usize = @intCast(idx);
        const len = clip.notes[row][start];
        if (len == 0) continue;
        if (start >= length_steps) return null;
        const max_len = length_steps - @as(u8, @intCast(start));
        const clamped_len = if (len > max_len) max_len else len;
        if (step < start + clamped_len) {
            return start;
        }
    }
    return null;
}

fn noteLength(clip: *const SequencerClip, row: usize, start: usize, length_steps: u8) u8 {
    const len = clip.notes[row][start];
    if (start >= length_steps) return 0;
    const max_len = length_steps - @as(u8, @intCast(start));
    return if (len > max_len) max_len else len;
}

fn clearNoteAtStep(clip: *SequencerClip, row: usize, step: usize, length_steps: u8) void {
    if (findNoteStart(clip, row, step, length_steps)) |start| {
        clip.notes[row][start] = 0;
    }
}

fn clearNotesInRange(clip: *SequencerClip, row: usize, start: usize, len: usize) void {
    const end = start + len;
    for (start..end) |idx| {
        if (idx >= seq_steps) break;
        if (idx == start) continue;
        clip.notes[row][idx] = 0;
    }
}
