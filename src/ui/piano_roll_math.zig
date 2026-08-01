//! Pure viewport math for the custom-drawn piano roll.

const std = @import("std");
const Note = @import("../session/notes.zig").Note;

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
