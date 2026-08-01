//! Pure viewport math for the custom-drawn piano roll.

const std = @import("std");
const Note = @import("../session/notes.zig").Note;

pub const min_note_duration: f32 = 0.0625;
pub const fine_time_step: f32 = 0.0625;
pub const clip_resize_step: f32 = 0.25;

pub const Viewport = struct {
    first_beat: f32,
    beat_span: f32,
    first_pitch: f32,
    pitch_span: f32,
};

pub fn visible(view: Viewport, note: Note) bool {
    const note_end = note.start + note.duration;
    const beat_end = view.first_beat + view.beat_span;
    const pitch = @as(f32, @floatFromInt(note.pitch));
    return note_end >= view.first_beat and note.start <= beat_end and
        pitch >= view.first_pitch and pitch <= view.first_pitch + view.pitch_span;
}

pub fn countVisible(view: Viewport, notes: []const Note) usize {
    var count: usize = 0;
    for (notes) |note| if (visible(view, note)) {
        count += 1;
    };
    return count;
}

/// Legacy zgui note-edge behavior: 1/16-beat precision independent of the
/// selected creation/movement quantize value, with the end bounded by the clip.
pub fn resizedNoteDuration(start: f32, duration: f32, beat_delta: f32, clip_length: f32) f32 {
    const raw_end = start + duration + beat_delta;
    const snapped_end = @ceil(raw_end / fine_time_step) * fine_time_step;
    const min_end = start + min_note_duration;
    const max_end = @max(min_end, clip_length);
    return std.math.clamp(snapped_end, min_end, max_end) - start;
}

/// Pointer movement is deliberately free-time. Quantization is an explicit
/// edit command and must not destroy an off-grid note start during a drag.
pub fn movedNoteStart(original_start: f32, beat_delta: f32, duration: f32, clip_length: f32) f32 {
    return std.math.clamp(original_start + beat_delta, 0, @max(0, clip_length - duration));
}

/// Legacy zgui clip-edge behavior: quarter-beat precision with a one-bar floor.
pub fn resizedClipLength(original_length: f32, beat_delta: f32, beats_per_bar: f32) f32 {
    const snapped = @floor((original_length + beat_delta) / clip_resize_step) * clip_resize_step;
    return std.math.clamp(snapped, beats_per_bar, 256);
}

pub fn maxHorizontalScroll(clip_length: f32, viewport_w: f32, keyboard_w: f32, pixels_per_beat: f32, scale: f32) f32 {
    const timeline_w = @max(1, viewport_w - keyboard_w * scale);
    const visible_beats = timeline_w / @max(1, pixels_per_beat * scale);
    return @max(0, @max(64, clip_length + 16) - visible_beats);
}

/// Return the start of the grid cell containing `beat`. This is deliberately
/// different from nearest-grid quantization: pointer creation must never jump
/// to the cell to the right of the click.
pub fn containingGridStart(beat: f32, step: f32) f32 {
    if (step <= 0) return @max(0, beat);
    return @max(0, @floor(beat / step) * step);
}

test "dense piano-roll fixture culls to viewport" {
    var notes: [4096]Note = undefined;
    for (&notes, 0..) |*note, i| {
        note.* = .{
            .pitch = @intCast(24 + (i % 80)),
            .start = @as(f32, @floatFromInt(i % 512)) * 0.25,
            .duration = 0.2,
        };
    }
    const count = countVisible(.{
        .first_beat = 16,
        .beat_span = 8,
        .first_pitch = 48,
        .pitch_span = 24,
    }, &notes);
    try std.testing.expect(count > 0);
    try std.testing.expect(count < notes.len / 4);
}

test "note resizing uses fine precision instead of creation quantize" {
    try std.testing.expectEqual(@as(f32, 0.5625), resizedNoteDuration(1, 0.5, 0.04, 8));
    try std.testing.expectEqual(min_note_duration, resizedNoteDuration(1, 0.5, -10, 8));
    try std.testing.expectEqual(@as(f32, 1), resizedNoteDuration(7, 0.5, 10, 8));
}

test "pointer movement preserves off-grid note starts" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.37), movedNoteStart(1.12, 0.25, 0.5, 8), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), movedNoteStart(0.1, -1, 0.5, 8));
    try std.testing.expectEqual(@as(f32, 7.5), movedNoteStart(7, 2, 0.5, 8));
}

test "clip resizing and horizontal scroll remain bounded" {
    try std.testing.expectEqual(@as(f32, 4), resizedClipLength(8, -100, 4));
    try std.testing.expectEqual(@as(f32, 8.25), resizedClipLength(8, 0.49, 4));
    try std.testing.expectEqual(@as(f32, 256), resizedClipLength(8, 1000, 4));
    try std.testing.expectEqual(@as(f32, 0), maxHorizontalScroll(8, 1400, 42, 20, 1));
    try std.testing.expect(maxHorizontalScroll(64, 320, 42, 64, 1) > 0);
}

test "pointer creation selects the containing grid cell" {
    try std.testing.expectEqual(@as(f32, 1), containingGridStart(1.99, 1));
    try std.testing.expectEqual(@as(f32, 1.75), containingGridStart(1.99, 0.25));
    try std.testing.expectEqual(@as(f32, 2), containingGridStart(2, 1));
}
