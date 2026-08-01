//! Bulk piano-roll note operations (tools, mute, duplicate, overlap).
const std = @import("std");
const types = @import("../../../session/notes.zig");

const Note = types.Note;
const PianoRollClip = types.PianoRollClip;
const PianoRollState = types.PianoRollState;

fn timing(clip: *const PianoRollClip) types.ClipTiming {
    return .{
        .length = clip.length_beats,
        .play_start = clip.play_start_beats,
        .loop_start = clip.loop_start_beats,
        .loop_end = clip.loop_end_beats,
    };
}

pub fn captureNotes(allocator: std.mem.Allocator, clip: *const PianoRollClip) ![]Note {
    if (clip.notes.items.len == 0) return try allocator.alloc(Note, 0);
    return try allocator.dupe(Note, clip.notes.items);
}

/// After mutating `clip.notes`, emit a notes_replace undo request.
/// Frees `old_notes` on failure.
pub fn commitReplace(
    state: *PianoRollState,
    clip: *const PianoRollClip,
    track: usize,
    scene: usize,
    old_notes: []Note,
) void {
    commitReplaceWithTiming(state, clip, track, scene, old_notes, timing(clip));
}

pub fn commitReplaceWithTiming(
    state: *PianoRollState,
    clip: *const PianoRollClip,
    track: usize,
    scene: usize,
    old_notes: []Note,
    old_timing: types.ClipTiming,
) void {
    const new_notes = captureNotes(state.allocator, clip) catch {
        state.allocator.free(old_notes);
        return;
    };
    state.emitUndoRequest(.{
        .kind = .notes_replace,
        .track = track,
        .scene = scene,
        .old_notes = old_notes,
        .new_notes = new_notes,
        .old_timing = old_timing,
        .new_timing = timing(clip),
    });
}

/// Resolve same-pitch overlaps: selected notes win over non-selected.
/// Splits / trims / removes covered notes (Ableton-style monophonic per pitch).
pub fn resolveOverlaps(clip: *PianoRollClip, selected: []const usize) void {
    if (selected.len == 0) return;

    // Snapshot winners (values), then walk the list and mutate losers only.
    var winners: std.ArrayListUnmanaged(Note) = .empty;
    defer winners.deinit(clip.allocator);
    for (selected) |idx| {
        if (idx < clip.notes.items.len) {
            winners.append(clip.allocator, clip.notes.items[idx]) catch {};
        }
    }

    // Mark winner slots by pointer identity via a tag field is hard; use a
    // parallel "is_winner" mask rebuilt each pass by matching start+pitch+dur
    // of still-present winners, and never delete a note that is still a winner.

    for (winners.items) |winner| {
        const w_end = winner.start + winner.duration;
        var i: usize = 0;
        while (i < clip.notes.items.len) {
            const other = clip.notes.items[i];
            const is_winner = other.pitch == winner.pitch and
                other.start == winner.start and
                other.duration == winner.duration;
            if (is_winner or other.pitch != winner.pitch) {
                i += 1;
                continue;
            }
            const o_end = other.start + other.duration;
            if (!(winner.start < o_end and w_end > other.start)) {
                i += 1;
                continue;
            }

            if (winner.start <= other.start and w_end >= o_end) {
                _ = clip.notes.orderedRemove(i);
            } else if (winner.start > other.start and w_end < o_end) {
                const right = Note{
                    .pitch = other.pitch,
                    .start = w_end,
                    .duration = o_end - w_end,
                    .velocity = other.velocity,
                    .release_velocity = other.release_velocity,
                };
                clip.notes.items[i].duration = winner.start - other.start;
                clip.notes.append(clip.allocator, right) catch {};
                i += 1;
            } else if (winner.start <= other.start) {
                const new_dur = o_end - w_end;
                if (new_dur <= 0) {
                    _ = clip.notes.orderedRemove(i);
                } else {
                    clip.notes.items[i].start = w_end;
                    clip.notes.items[i].duration = new_dur;
                    i += 1;
                }
            } else {
                const new_dur = winner.start - other.start;
                if (new_dur <= 0) {
                    _ = clip.notes.orderedRemove(i);
                } else {
                    clip.notes.items[i].duration = new_dur;
                    i += 1;
                }
            }
        }
    }
}

pub fn duplicateSelected(state: *PianoRollState, clip: *PianoRollClip, track: usize, scene: usize, shift_time: bool) void {
    if (!state.hasSelection()) return;
    const old = captureNotes(state.allocator, clip) catch return;

    var to_add: std.ArrayListUnmanaged(Note) = .empty;
    defer to_add.deinit(clip.allocator);

    for (state.note_selection.keys()) |idx| {
        if (idx >= clip.notes.items.len) continue;
        var n = clip.notes.items[idx];
        if (shift_time) n.start = n.start + n.duration;
        to_add.append(clip.allocator, n) catch {};
    }

    state.clearSelection();
    for (to_add.items) |n| {
        const new_idx = clip.notes.items.len;
        clip.addFullNote(n) catch continue;
        state.selectNote(new_idx);
    }

    // End-to-end duplicate can land on same pitch overlaps with originals.
    if (shift_time) {
        var sel_buf: [256]usize = undefined;
        var sel_count: usize = 0;
        for (state.note_selection.keys()) |idx| {
            if (sel_count < sel_buf.len) {
                sel_buf[sel_count] = idx;
                sel_count += 1;
            }
        }
        resolveOverlaps(clip, sel_buf[0..sel_count]);
        // Re-select notes that match added set (indices may have shifted — select by content at end).
        // Safer: re-select by matching the duplicates we just wrote via start/pitch/duration.
        state.clearSelection();
        for (to_add.items) |want| {
            for (clip.notes.items, 0..) |have, i| {
                if (have.pitch == want.pitch and have.start == want.start and have.duration == want.duration) {
                    state.selectNote(i);
                    break;
                }
            }
        }
    }

    commitReplace(state, clip, track, scene, old);
}

pub fn scaleClipTime(state: *PianoRollState, clip: *PianoRollClip, track: usize, scene: usize, factor: f32) void {
    if (factor <= 0) return;
    const old = captureNotes(state.allocator, clip) catch return;
    const old_timing = timing(clip);
    for (clip.notes.items) |*n| {
        n.start *= factor;
        n.duration *= factor;
        if (n.duration < 0.0625) n.duration = 0.0625;
    }
    clip.length_beats = @max(1.0, clip.length_beats * factor);
    if (clip.loop_end_beats > 0) clip.loop_end_beats *= factor;
    clip.play_start_beats *= factor;
    clip.loop_start_beats *= factor;
    commitReplaceWithTiming(state, clip, track, scene, old, old_timing);
}

pub fn reverseNotes(state: *PianoRollState, clip: *PianoRollClip, track: usize, scene: usize) void {
    if (clip.notes.items.len == 0) return;
    const old = captureNotes(state.allocator, clip) catch return;
    const len = clip.length_beats;
    for (clip.notes.items) |*n| {
        const end = n.start + n.duration;
        n.start = @max(0, len - end);
    }
    commitReplace(state, clip, track, scene, old);
}

/// Mirror pitches around the midpoint of selected notes (or all notes if none selected).
pub fn invertPitches(state: *PianoRollState, clip: *PianoRollClip, track: usize, scene: usize) void {
    if (clip.notes.items.len == 0) return;
    const old = captureNotes(state.allocator, clip) catch return;

    var min_p: i32 = 127;
    var max_p: i32 = 0;
    var any = false;
    if (state.hasSelection()) {
        for (state.note_selection.keys()) |idx| {
            if (idx >= clip.notes.items.len) continue;
            const p: i32 = clip.notes.items[idx].pitch;
            min_p = @min(min_p, p);
            max_p = @max(max_p, p);
            any = true;
        }
    }
    if (!any) {
        for (clip.notes.items) |n| {
            const p: i32 = n.pitch;
            min_p = @min(min_p, p);
            max_p = @max(max_p, p);
            any = true;
        }
    }
    if (!any) {
        state.allocator.free(old);
        return;
    }
    const sum = min_p + max_p;

    if (state.hasSelection()) {
        for (state.note_selection.keys()) |idx| {
            if (idx >= clip.notes.items.len) continue;
            const p: i32 = clip.notes.items[idx].pitch;
            clip.notes.items[idx].pitch = @intCast(std.math.clamp(sum - p, 0, 127));
        }
    } else {
        for (clip.notes.items) |*n| {
            const p: i32 = n.pitch;
            n.pitch = @intCast(std.math.clamp(sum - p, 0, 127));
        }
    }
    commitReplace(state, clip, track, scene, old);
}

/// Extend each note to the start of the next note (by time), among selected or all.
pub fn legatoNotes(state: *PianoRollState, clip: *PianoRollClip, track: usize, scene: usize, min_duration: f32) void {
    if (clip.notes.items.len == 0) return;
    const old = captureNotes(state.allocator, clip) catch return;

    var indices: std.ArrayListUnmanaged(usize) = .empty;
    defer indices.deinit(clip.allocator);

    if (state.hasSelection()) {
        for (state.note_selection.keys()) |idx| {
            if (idx < clip.notes.items.len) indices.append(clip.allocator, idx) catch {};
        }
    } else {
        for (0..clip.notes.items.len) |i| {
            indices.append(clip.allocator, i) catch {};
        }
    }
    if (indices.items.len < 2) {
        state.allocator.free(old);
        return;
    }

    std.mem.sort(usize, indices.items, clip, struct {
        fn less(c: *PianoRollClip, a: usize, b: usize) bool {
            const na = c.notes.items[a];
            const nb = c.notes.items[b];
            if (na.start != nb.start) return na.start < nb.start;
            return na.pitch < nb.pitch;
        }
    }.less);

    var i: usize = 0;
    while (i + 1 < indices.items.len) : (i += 1) {
        const cur = indices.items[i];
        const nxt = indices.items[i + 1];
        const next_start = clip.notes.items[nxt].start;
        const start = clip.notes.items[cur].start;
        if (next_start > start) {
            clip.notes.items[cur].duration = @max(min_duration, next_start - start);
        }
    }
    commitReplace(state, clip, track, scene, old);
}

/// Apply random velocity offset in ±range (0..1) to selected notes (or all).
pub fn humanizeVelocity(state: *PianoRollState, clip: *PianoRollClip, track: usize, scene: usize, range: f32) void {
    if (clip.notes.items.len == 0 or range == 0) return;
    const old = captureNotes(state.allocator, clip) catch return;
    const amp = std.math.clamp(@abs(range), 0.0, 1.0);
    var seed: u64 = @intFromPtr(clip) ^ (@as(u64, @intFromFloat(clip.length_beats * 1000)) << 1);
    seed ^= @as(u64, clip.notes.items.len) *% 0x9e3779b97f4a7c15;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const apply = struct {
        fn go(n: *Note, amp_v: f32, r: std.Random) void {
            const delta = (r.float(f32) * 2.0 - 1.0) * amp_v;
            n.velocity = std.math.clamp(n.velocity + delta, 0.0, 1.0);
        }
    }.go;

    if (state.hasSelection()) {
        for (state.note_selection.keys()) |idx| {
            if (idx < clip.notes.items.len) apply(&clip.notes.items[idx], amp, random);
        }
    } else {
        for (clip.notes.items) |*n| apply(n, amp, random);
    }
    commitReplace(state, clip, track, scene, old);
}

pub fn deleteNotesAtIndices(state: *PianoRollState, clip: *PianoRollClip, track: usize, scene: usize, indices: []const usize) void {
    if (indices.len == 0) return;
    const old = captureNotes(state.allocator, clip) catch return;

    // Delete high indices first.
    var sorted: std.ArrayListUnmanaged(usize) = .empty;
    defer sorted.deinit(clip.allocator);
    sorted.appendSlice(clip.allocator, indices) catch {
        state.allocator.free(old);
        return;
    };
    std.mem.sort(usize, sorted.items, {}, std.sort.desc(usize));

    for (sorted.items) |idx| {
        if (idx < clip.notes.items.len) {
            _ = clip.notes.orderedRemove(idx);
        }
    }
    state.clearSelection();
    commitReplace(state, clip, track, scene, old);
}

test "scale clip undo snapshot includes notes and timing" {
    const allocator = std.testing.allocator;
    var state = PianoRollState.init(allocator);
    defer state.deinit();
    var clip = PianoRollClip.init(allocator);
    defer clip.deinit();
    try clip.addNote(60, 1, 2);
    clip.length_beats = 8;
    clip.play_start_beats = 1;
    clip.loop_start_beats = 2;
    clip.loop_end_beats = 6;

    scaleClipTime(&state, &clip, 0, 0, 2);

    try std.testing.expectEqual(@as(usize, 1), state.undo_request_count);
    const req = state.undo_requests[0];
    defer allocator.free(req.old_notes);
    defer allocator.free(req.new_notes);
    try std.testing.expectEqual(@as(f32, 8), req.old_timing.length);
    try std.testing.expectEqual(@as(f32, 16), req.new_timing.length);
    try std.testing.expectEqual(@as(f32, 1), req.old_notes[0].start);
    try std.testing.expectEqual(@as(f32, 2), req.new_notes[0].start);
    try std.testing.expectEqual(@as(f32, 1), req.old_timing.play_start);
    try std.testing.expectEqual(@as(f32, 2), req.new_timing.play_start);
    state.undo_request_count = 0;
}
