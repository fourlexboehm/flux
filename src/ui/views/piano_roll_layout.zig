//! Shared piano-roll constants and geometry helpers.

const std = @import("std");
const dvui = @import("dvui");
const state_mod = @import("../state.zig");
const document_model = @import("../../document/model.zig");
const notes_mod = @import("../../session/notes.zig");
const piano_math = @import("../piano_roll_math.zig");

pub const keyboard_w: f32 = 42;
pub const velocity_h: f32 = 34;
pub const ruler_h: f32 = 20;
pub const fine_time_step = piano_math.fine_time_step;
pub const max_automation_lane_ui: usize = 16;
pub const max_param_choices: usize = 64;
pub const automation_point_radius: f32 = 4;

pub fn quantizeStep(state: *const state_mod.State) f32 {
    const bpb = state.beatsPerBar();
    const steps = [_]f32{ 0.125, 0.25, 0.5, 1, 2, bpb, bpb * 2, bpb * 4, bpb * 8 };
    return steps[@min(state.quantize_index, steps.len - 1)];
}

pub fn quantize(value: f32, step: f32) f32 {
    return @max(0, @round(value / step) * step);
}

pub fn gridArea(state: *const state_mod.State, area: dvui.Rect.Physical, scale: f32) dvui.Rect.Physical {
    const top = @min(area.h, ruler_h * scale);
    const bottom = if (state.piano_velocity_open) @min(area.h - top, velocity_h * scale) else 0;
    return .{ .x = area.x, .y = area.y + top, .w = area.w, .h = @max(1, area.h - top - bottom) };
}

pub fn rulerArea(area: dvui.Rect.Physical, scale: f32) dvui.Rect.Physical {
    return .{ .x = area.x, .y = area.y, .w = area.w, .h = @min(area.h, ruler_h * scale) };
}

pub fn velocityArea(state: *const state_mod.State, area: dvui.Rect.Physical, scale: f32) dvui.Rect.Physical {
    if (!state.piano_velocity_open) return .{ .x = area.x, .y = area.y + area.h, .w = area.w, .h = 0 };
    const h = @min(area.h, velocity_h * scale);
    return .{ .x = area.x, .y = area.y + area.h - h, .w = area.w, .h = h };
}

pub const HorizontalMetrics = struct {
    max_beats: f32,
    visible_beats: f32,
    max_scroll: f32,
};

pub fn horizontalMetrics(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, viewport_w: f32, scale: f32) HorizontalMetrics {
    const timeline_w = @max(1, viewport_w - keyboard_w * scale);
    const visible_beats = timeline_w / @max(1, state.piano_pixels_per_beat * scale);
    const max_beats = @max(64, clip.length_beats + 16);
    return .{
        .max_beats = max_beats,
        .visible_beats = visible_beats,
        .max_scroll = piano_math.maxHorizontalScroll(clip.length_beats, viewport_w, keyboard_w, state.piano_pixels_per_beat, scale),
    };
}

pub fn clampHorizontalScroll(state: *state_mod.State, clip: *const notes_mod.PianoRollClip, viewport_w: f32, scale: f32) void {
    const metrics = horizontalMetrics(state, clip, viewport_w, scale);
    state.piano_scroll_beat = std.math.clamp(state.piano_scroll_beat, 0, metrics.max_scroll);
}

pub fn selectedClip(state: *const state_mod.State) ?*notes_mod.PianoRollClip {
    if (!document_model.ready()) return null;
    return document_model.g.slotMidiClip(state.selected_track, state.selected_scene);
}

pub fn beatX(state: *const state_mod.State, beat: f32, area: dvui.Rect.Physical, scale: f32) f32 {
    return area.x + keyboard_w * scale + (beat - state.piano_scroll_beat) * state.piano_pixels_per_beat * scale;
}

pub fn beatAtX(state: *const state_mod.State, x: f32, area: dvui.Rect.Physical, scale: f32) f32 {
    const key_w = keyboard_w * scale;
    return state.piano_scroll_beat + @max(0, x - area.x - key_w) / @max(1, state.piano_pixels_per_beat * scale);
}

pub fn containsPoint(area: dvui.Rect.Physical, point: dvui.Point.Physical) bool {
    return point.x >= area.x and point.x <= area.x + area.w and point.y >= area.y and point.y <= area.y + area.h;
}

pub fn intersects(a: dvui.Rect.Physical, b: dvui.Rect.Physical) bool {
    return a.x + a.w >= b.x and a.x <= b.x + b.w and a.y + a.h >= b.y and a.y <= b.y + b.h;
}

pub fn bottomVisiblePitch(state: *const state_mod.State, area: dvui.Rect.Physical, scale: f32) f32 {
    const visible_rows = @max(1, area.h / @max(1, state.piano_row_height * scale));
    return std.math.clamp(state.piano_scroll_pitch - visible_rows * 0.5, 0, @max(0, 128 - visible_rows));
}

pub fn noteRect(state: *const state_mod.State, note: notes_mod.Note, area: dvui.Rect.Physical, scale: f32) dvui.Rect.Physical {
    const row_h = state.piano_row_height * scale;
    const beat_w = state.piano_pixels_per_beat * scale;
    const bottom_pitch = bottomVisiblePitch(state, area, scale);
    return .{
        .x = area.x + keyboard_w * scale + (note.start - state.piano_scroll_beat) * beat_w,
        .y = area.y + area.h - (@as(f32, @floatFromInt(note.pitch)) - bottom_pitch + 1) * row_h + scale,
        .w = @max(3 * scale, note.duration * beat_w),
        .h = @max(2 * scale, row_h - 2 * scale),
    };
}

pub fn pitchAtY(state: *const state_mod.State, y: f32, area: dvui.Rect.Physical, scale: f32) ?u8 {
    if (y < area.y or y > area.y + area.h) return null;
    const row_h = state.piano_row_height * scale;
    const row_from_bottom: i32 = @intFromFloat(@floor((area.y + area.h - y) / row_h));
    const pitch_f = bottomVisiblePitch(state, area, scale) + @as(f32, @floatFromInt(row_from_bottom));
    const pitch_i: i32 = @intFromFloat(@floor(pitch_f));
    if (pitch_i < 0 or pitch_i > 127) return null;
    return @intCast(pitch_i);
}

pub fn clipEndX(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, scale: f32) f32 {
    return area.x + keyboard_w * scale + (clip.length_beats - state.piano_scroll_beat) * state.piano_pixels_per_beat * scale;
}

pub fn isBlackKey(pitch: u8) bool {
    return switch (pitch % 12) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

pub fn selectionCount(state: *const state_mod.State, note_len: usize) usize {
    var count: usize = 0;
    for (state.piano_note_selected[0..@min(note_len, state_mod.max_piano_notes)]) |on| if (on) {
        count += 1;
    };
    return count;
}

pub fn selectedIndices(state: *const state_mod.State, note_len: usize, out: []usize) []const usize {
    var count: usize = 0;
    for (state.piano_note_selected[0..@min(note_len, state_mod.max_piano_notes)], 0..) |on, i| if (on and count < out.len) {
        out[count] = i;
        count += 1;
    };
    return out[0..count];
}

pub fn selectAll(state: *state_mod.State, note_len: usize) void {
    state.piano_note_selected = @splat(false);
    for (state.piano_note_selected[0..@min(note_len, state_mod.max_piano_notes)]) |*on| on.* = true;
    state.piano_selected_note = if (note_len > 0) 0 else null;
}

pub fn syncSelectionClip(state: *state_mod.State, note_len: usize) void {
    if (state.piano_selection_track != state.selected_track or state.piano_selection_scene != state.selected_scene) {
        state.piano_note_selected = @splat(false);
        state.piano_selected_note = null;
        state.piano_selection_track = state.selected_track;
        state.piano_selection_scene = state.selected_scene;
    }
    if (state.piano_selected_note) |i| {
        if (i >= note_len) state.piano_selected_note = null;
    }
}
