//! Piano-roll note edit ops, keyboard nudges, drag, clipboard (legacy zgui).
const zgui = @import("zgui");
const colors = @import("../../theme/colors.zig");
const widgets = @import("../../theme/widgets.zig");
const selection = @import("../../input/selection.zig");
const edit_actions = @import("../../input/edit_actions.zig");
const std = @import("std");
const clap = @import("clap-bindings");

const types = @import("../../../session/notes.zig");
const ops = @import("ops.zig");
const PianoRollState = types.PianoRollState;
const PianoRollClip = types.PianoRollClip;
const AutomationPoint = types.AutomationPoint;
const AutomationLane = types.AutomationLane;
const AutomationTargetKind = types.AutomationTargetKind;
const quantizeIndexToBeats = types.quantizeIndexToBeats;

pub const EditCtx = struct {
    state: *PianoRollState,
    clip: *PianoRollClip,
    track_index: usize,
    scene_index: usize,
    mouse: [2]f32,
    grid_pos: [2]f32,
    pixels_per_beat: f32,
    row_height: f32,
    quantize_beats: f32,
    min_note_duration: f32,
    in_grid: bool,
};

pub const MenuCtx = struct {
    state: *PianoRollState,
    clip: *PianoRollClip,
    track_index: usize,
    scene_index: usize,
    min_note_duration: f32,
};

pub fn editCopy(ctx: *EditCtx) void {
    copyNotes(ctx.state, ctx.clip);
}

pub fn editCut(ctx: *EditCtx) void {
    copyNotes(ctx.state, ctx.clip);
    deleteSelectedNotes(ctx.state, ctx.clip, ctx.track_index, ctx.scene_index);
}

pub fn editPaste(ctx: *EditCtx) void {
    if (ctx.state.clipboard.items.len == 0 or !ctx.in_grid) return;
    pasteNotes(
        ctx.state,
        ctx.clip,
        ctx.track_index,
        ctx.scene_index,
        ctx.mouse,
        ctx.grid_pos,
        ctx.pixels_per_beat,
        ctx.row_height,
        ctx.quantize_beats,
        ctx.min_note_duration,
    );
}

pub fn editDelete(ctx: *EditCtx) void {
    deleteSelectedNotes(ctx.state, ctx.clip, ctx.track_index, ctx.scene_index);
}

pub fn editSelectAll(ctx: *EditCtx) void {
    ctx.state.note_selection.clear();
    for (ctx.clip.notes.items, 0..) |_, idx| {
        ctx.state.note_selection.add(idx);
    }
    if (ctx.clip.notes.items.len > 0) {
        ctx.state.note_selection.primary = 0;
    }
}

pub fn menuCopy(ctx: *MenuCtx) void {
    copyNotes(ctx.state, ctx.clip);
}

pub fn menuCut(ctx: *MenuCtx) void {
    copyNotes(ctx.state, ctx.clip);
    deleteSelectedNotes(ctx.state, ctx.clip, ctx.track_index, ctx.scene_index);
}

pub fn menuPaste(ctx: *MenuCtx) void {
    if (ctx.state.clipboard.items.len == 0 or !ctx.state.context_in_grid) return;
    pasteNotesFromContextMenu(ctx.state, ctx.clip, ctx.track_index, ctx.scene_index, ctx.min_note_duration);
}

pub fn menuDelete(ctx: *MenuCtx) void {
    deleteSelectedNotes(ctx.state, ctx.clip, ctx.track_index, ctx.scene_index);
}

pub fn menuSelectAll(ctx: *MenuCtx) void {
    ctx.state.note_selection.clear();
    for (ctx.clip.notes.items, 0..) |_, idx| {
        ctx.state.note_selection.add(idx);
    }
    if (ctx.clip.notes.items.len > 0) {
        ctx.state.note_selection.primary = 0;
    }
}

pub fn quantizeSelectedNotes(
    state: *PianoRollState,
    clip: *PianoRollClip,
    quantize_beats: f32,
    track_index: usize,
    scene_index: usize,
) void {
    if (!state.hasSelection() or quantize_beats <= 0) return;

    for (state.note_selection.keys()) |idx| {
        if (idx >= clip.notes.items.len) continue;
        const note = &clip.notes.items[idx];
        const old_start = note.start;
        const max_start = @max(0.0, clip.length_beats - note.duration);
        const snapped = @round(old_start / quantize_beats) * quantize_beats;
        const new_start = std.math.clamp(snapped, 0.0, max_start);
        if (new_start == old_start) continue;

        note.start = new_start;
        state.emitUndoRequest(.{
            .kind = .note_move,
            .track = track_index,
            .scene = scene_index,
            .note_index = idx,
            .old_start = old_start,
            .old_pitch = note.pitch,
            .new_start = new_start,
            .new_pitch = note.pitch,
        });
    }
}

pub fn copyNotes(state: *PianoRollState, clip: *const PianoRollClip) void {
    if (!state.hasSelection()) return;

    state.clipboard.clearRetainingCapacity();
    var min_start: f32 = std.math.floatMax(f32);
    for (state.note_selection.keys()) |idx| {
        if (idx < clip.notes.items.len) {
            min_start = @min(min_start, clip.notes.items[idx].start);
        }
    }
    for (state.note_selection.keys()) |idx| {
        if (idx < clip.notes.items.len) {
            var note_copy = clip.notes.items[idx];
            note_copy.start -= min_start;
            state.clipboard.append(state.allocator, note_copy) catch {};
        }
    }
}

pub pub fn pasteNotesFromContextMenu(
    state: *PianoRollState,
    clip: *PianoRollClip,
    track_index: usize,
    scene_index: usize,
    min_duration: f32,
) void {
    const snapped_start = state.context_start;
    const first_pitch: i32 = @intCast(state.clipboard.items[0].pitch);
    const pitch_offset = @as(i32, state.context_pitch) - first_pitch;

    state.clearSelection();
    for (state.clipboard.items) |copied| {
        const new_start = snapped_start + copied.start;
        if (new_start >= 0 and new_start < clip.length_beats) {
            const duration = @min(copied.duration, clip.length_beats - new_start);
            if (duration >= min_duration) {
                var new_pitch_i: i32 = @as(i32, copied.pitch) + pitch_offset;
                new_pitch_i = std.math.clamp(new_pitch_i, 0, 127);
                clip.addNote(@intCast(new_pitch_i), new_start, duration) catch {};
                if (clip.notes.items.len > 0) {
                    const note_index = clip.notes.items.len - 1;
                    const note = clip.notes.items[note_index];
                    state.emitUndoRequest(.{
                        .kind = .note_add,
                        .track = track_index,
                        .scene = scene_index,
                        .note_index = note_index,
                        .note = note,
                    });
                    state.selectNote(note_index);
                }
            }
        }
    }
}

pub fn deleteSelectedNotes(state: *PianoRollState, clip: *PianoRollClip, track_index: usize, scene_index: usize) void {
    if (!state.hasSelection()) return;

    var indices: std.ArrayListUnmanaged(usize) = .empty;
    defer indices.deinit(state.allocator);
    for (state.note_selection.keys()) |idx| {
        indices.append(state.allocator, idx) catch {};
    }
    selection.sortDescending(indices.items);
    for (indices.items) |idx| {
        if (idx < clip.notes.items.len) {
            const note = clip.notes.items[idx];
            // Emit undo request before removing
            state.emitUndoRequest(.{
                .kind = .note_remove,
                .track = track_index,
                .scene = scene_index,
                .note_index = idx,
                .note = note,
            });
            _ = clip.notes.orderedRemove(idx);
        }
    }
    state.clearSelection();
}

fn pasteNotes(
    state: *PianoRollState,
    clip: *PianoRollClip,
    track_index: usize,
    scene_index: usize,
    mouse: [2]f32,
    grid_pos: [2]f32,
    pixels_per_beat: f32,
    row_height: f32,
    quantize_beats: f32,
    min_duration: f32,
) void {
    const click_beat = mouseToBeat(mouse[0], grid_pos[0], state.scroll_x, pixels_per_beat);
    const click_pitch_i = rowToPitch(mouseToRow(mouse[1], grid_pos[1], state.scroll_y, row_height));
    const snapped_start = selection.snapToStep(click_beat, quantize_beats);

    const first_pitch: i32 = @intCast(state.clipboard.items[0].pitch);
    const pitch_offset = click_pitch_i - first_pitch;

    state.clearSelection();
    for (state.clipboard.items) |copied| {
        const new_start = snapped_start + copied.start;
        if (new_start >= 0 and new_start < clip.length_beats) {
            const duration = @min(copied.duration, clip.length_beats - new_start);
            if (duration >= min_duration) {
                var new_pitch_i: i32 = @as(i32, copied.pitch) + pitch_offset;
                new_pitch_i = std.math.clamp(new_pitch_i, 0, 127);
                clip.addNote(@intCast(new_pitch_i), new_start, duration) catch {};
                if (clip.notes.items.len > 0) {
                    const note_index = clip.notes.items.len - 1;
                    const note = clip.notes.items[note_index];
                    state.emitUndoRequest(.{
                        .kind = .note_add,
                        .track = track_index,
                        .scene = scene_index,
                        .note_index = note_index,
                        .note = note,
                    });
                    state.selectNote(note_index);
                }
            }
        }
    }
}

pub fn handleArrowKeys(
    state: *PianoRollState,
    clip: *PianoRollClip,
    shift_down: bool,
    quantize_beats: f32,
    min_duration: f32,
    track_index: usize,
    scene_index: usize,
) void {
    if (shift_down) {
        if (zgui.isKeyPressed(.left_arrow, true)) {
            nudgeSelected(state, clip, track_index, "duration", quantize_beats, .left, min_duration);
        }
        if (zgui.isKeyPressed(.right_arrow, true)) {
            nudgeSelected(state, clip, track_index, "duration", quantize_beats, .right, undefined);
        }
        if (zgui.isKeyPressed(.up_arrow, true)) {
            transposeSelectedNotesBy(state, clip, 12, track_index, scene_index);
        }
        if (zgui.isKeyPressed(.down_arrow, true)) {
            transposeSelectedNotesBy(state, clip, -12, track_index, scene_index);
        }
    } else {
        if (zgui.isKeyPressed(.left_arrow, true)) {
            nudgeSelected(state, clip, track_index, "start", quantize_beats, .left, 0);
        }
        if (zgui.isKeyPressed(.right_arrow, true)) {
            nudgeSelected(state, clip, track_index, "start", quantize_beats, .right, undefined);
        }
        if (zgui.isKeyPressed(.up_arrow, true)) {
            transposeSelectedNotesBy(state, clip, 1, track_index, scene_index);
        }
        if (zgui.isKeyPressed(.down_arrow, true)) {
            transposeSelectedNotesBy(state, clip, -1, track_index, scene_index);
        }
    }
}

const NudgeDirection = enum { left, right };

pub fn nudgeSelected(
    state: *PianoRollState,
    clip: *PianoRollClip,
    track_index: usize,
    comptime field_name: []const u8,
    quantize_beats: f32,
    comptime direction: NudgeDirection,
    min_bound: f32,
) void {
    var preview_pitch: ?u8 = null;
    var moved = false;
    for (state.note_selection.keys()) |idx| {
        if (idx < clip.notes.items.len) {
            const note = &clip.notes.items[idx];
            const old_val = @field(note, field_name);
            const new_val = switch (direction) {
                .left => @max(min_bound, old_val - quantize_beats),
                .right => blk: {
                    const other: f32 = if (comptime std.mem.eql(u8, field_name, "start")) note.duration else note.start;
                    break :blk @min(clip.length_beats - other, old_val + quantize_beats);
                },
            };
            if (new_val != old_val) {
                @field(note, field_name) = new_val;
                if (preview_pitch == null) preview_pitch = note.pitch;
                moved = true;
            }
        }
    }
    if (moved and preview_pitch != null) {
        state.preview_pitch = preview_pitch;
        state.preview_track = track_index;
    }
}

pub fn transposeSelectedNotesBy(
    state: *PianoRollState,
    clip: *PianoRollClip,
    semitones: i32,
    track_index: usize,
    scene_index: usize,
) void {
    var preview_pitch: ?u8 = null;
    var moved = false;
    for (state.note_selection.keys()) |idx| {
        if (idx < clip.notes.items.len) {
            const note = &clip.notes.items[idx];
            const old_pitch = note.pitch;
            const new_pitch_i = if (semitones > 0)
                @min(127, @as(i32, old_pitch) + semitones)
            else
                @max(0, @as(i32, old_pitch) + semitones);
            if (new_pitch_i != old_pitch) {
                note.pitch = @intCast(new_pitch_i);
                if (preview_pitch == null) preview_pitch = note.pitch;
                moved = true;
                state.emitUndoRequest(.{
                    .kind = .note_move,
                    .track = track_index,
                    .scene = scene_index,
                    .note_index = idx,
                    .old_start = note.start,
                    .old_pitch = old_pitch,
                    .new_start = note.start,
                    .new_pitch = note.pitch,
                });
            }
        }
    }
    if (moved and preview_pitch != null) {
        state.preview_pitch = preview_pitch;
        state.preview_track = track_index;
    }
}

pub fn handleDrag(
    state: *PianoRollState,
    clip: *PianoRollClip,
    mouse: [2]f32,
    grid_pos: [2]f32,
    pixels_per_beat: f32,
    row_height: f32,
    min_duration: f32,
    beats_per_bar_in: f32,
) void {
    switch (state.drag.mode) {
        .resize_clip => {
            const current_beat = mouseToBeat(mouse[0], grid_pos[0], state.scroll_x, pixels_per_beat);
            var new_length = @floor(current_beat * 4) / 4;
            new_length = @max(beats_per_bar_in, new_length);
            new_length = @min(256, new_length);
            clip.length_beats = new_length;
        },
        .move => {
            if (state.drag.note_index < clip.notes.items.len) {
                const current_beat = mouseToBeat(mouse[0], grid_pos[0], state.scroll_x, pixels_per_beat);
                const new_start = @floor((current_beat - state.drag.grab_offset_beats) * 4) / 4;
                const new_pitch_i = rowToPitch(mouseToRow(mouse[1], grid_pos[1], state.scroll_y, row_height));

                const delta_start = new_start - state.drag.original_start;
                const delta_pitch = new_pitch_i - @as(i32, state.drag.original_pitch);

                for (state.note_selection.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        const note = &clip.notes.items[idx];
                        note.start = @max(0, @min(note.start + delta_start, clip.length_beats - note.duration));
                        note.pitch = @intCast(std.math.clamp(@as(i32, note.pitch) + delta_pitch, 0, 127));
                    }
                }

                state.drag.original_start = new_start;
                state.drag.original_pitch = @intCast(new_pitch_i);
            }
        },
        .velocity => {
            const velocity_per_pixel: f32 = 0.005;
            const delta = (state.drag.drag_start_mouse_y - mouse[1]) * velocity_per_pixel;
            for (state.velocity_drag_notes.items) |entry| {
                if (entry.index < clip.notes.items.len) {
                    const new_velocity = std.math.clamp(entry.velocity + delta, 0.0, 1.0);
                    clip.notes.items[entry.index].velocity = new_velocity;
                }
            }
        },
        .resize_right, .create => {
            if (state.drag.note_index < clip.notes.items.len) {
                const note = &clip.notes.items[state.drag.note_index];
                const current_beat = mouseToBeat(mouse[0], grid_pos[0], state.scroll_x, pixels_per_beat);

                var new_end = current_beat;
                new_end = @max(note.start + min_duration, new_end);
                new_end = @min(new_end, clip.length_beats);
                new_end = @ceil(new_end * 16) / 16;
                note.duration = new_end - note.start;
            }
        },
        .select_rect => {
            state.drag_select.update(mouse);
        },
        .none => {},
    }
}

pub fn finalizeRectSelection(
    state: *PianoRollState,
    clip: *const PianoRollClip,
    grid_pos: [2]f32,
    pixels_per_beat: f32,
    row_height: f32,
    scroll_x: f32,
    scroll_y: f32,
) void {
    const rect = state.drag_select.getRect();
    const sel_x1 = rect.min[0];
    const sel_y1 = rect.min[1];
    const sel_x2 = rect.max[0];
    const sel_y2 = rect.max[1];

    for (clip.notes.items, 0..) |note, idx| {
        const note_row = 127 - @as(usize, note.pitch);
        const note_x = grid_pos[0] + note.start * pixels_per_beat - scroll_x;
        const note_y = grid_pos[1] + @as(f32, @floatFromInt(note_row)) * row_height - scroll_y;
        const note_w = note.duration * pixels_per_beat;

        if (note_x < sel_x2 and note_x + note_w > sel_x1 and note_y < sel_y2 and note_y + row_height > sel_y1) {
            state.selectNote(idx);
        }
    }
}
