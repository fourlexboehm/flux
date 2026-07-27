const std = @import("std");
const arr_types = @import("types.zig");
const arr_clip = @import("clip.zig");
const arr_track = @import("track.zig");
const timeline = @import("timeline.zig");

const ArrangementView = arr_types.ArrangementView;
const ArrangementClip = arr_clip.ArrangementClip;
const ArrangementTrack = arr_track.ArrangementTrack;
const ClipKind = arr_clip.ClipKind;

pub fn createTrack(
    view: *ArrangementView,
    session_track_index: usize,
    name: []const u8,
    color: [4]f32,
) !void {
    try view.tracks.append(view.allocator, ArrangementTrack.init(name, session_track_index, color));
}

/// Create a placement plus a fresh pooled clip of `kind`. The placement holds
/// the sole reference to the new clip.
pub fn createClip(
    view: *ArrangementView,
    track_index: usize,
    kind: ClipKind,
    start_tick: i64,
    duration_ticks: i64,
    name: []const u8,
) !usize {
    if (track_index >= view.tracks.items.len) return error.InvalidTrack;
    if (duration_ticks <= 0) return error.InvalidDuration;
    const length_beats = @as(f32, @floatFromInt(duration_ticks)) / @as(f32, @floatFromInt(timeline.ppq));
    const id = view.addPooledClip(kind, length_beats);
    if (id.isNone()) return error.OutOfMemory;
    if (view.clip_pool.?.get(id)) |c| c.name.set(name);
    const clip: ArrangementClip = .{
        .clip = id,
        .start_tick = start_tick,
        .duration_ticks = duration_ticks,
    };
    view.tracks.items[track_index].clips.append(view.allocator, clip) catch |err| {
        view.releasePlacement(&clip);
        return err;
    };
    return view.tracks.items[track_index].clips.items.len - 1;
}

pub fn moveClip(
    clip: *ArrangementClip,
    new_start_tick: i64,
    snap_ticks: i64,
) void {
    const snapped = if (snap_ticks > 0) timeline.snapToGrid(new_start_tick, snap_ticks) else new_start_tick;
    clip.start_tick = @max(0, snapped);
}

pub fn moveClipToTrack(
    view: *ArrangementView,
    from_track: usize,
    clip_index: usize,
    to_track: usize,
) !usize {
    if (from_track >= view.tracks.items.len or to_track >= view.tracks.items.len) return error.InvalidTrack;
    if (clip_index >= view.tracks.items[from_track].clips.items.len) return error.InvalidClip;
    if (from_track == to_track) return clip_index;
    // Transfer the placement (and its pooled reference) to the destination —
    // no dupe, so the clip content travels intact.
    const moved = view.tracks.items[from_track].clips.items[clip_index];
    try view.tracks.items[to_track].clips.append(view.allocator, moved);
    _ = view.tracks.items[from_track].clips.orderedRemove(clip_index);
    return view.tracks.items[to_track].clips.items.len - 1;
}

/// Keep the pooled MIDI clip's intrinsic length in step with a placement's
/// duration (audio clips keep their sample-derived length).
fn syncMidiLength(view: *ArrangementView, clip: *ArrangementClip) void {
    if (view.placementMidi(clip)) |midi| {
        midi.length_beats = @as(f32, @floatFromInt(clip.duration_ticks)) / @as(f32, @floatFromInt(timeline.ppq));
    }
}

pub fn resizeClip(
    view: *ArrangementView,
    clip: *ArrangementClip,
    new_duration_ticks: i64,
    snap_ticks: i64,
) void {
    if (new_duration_ticks <= 0) return;
    clip.duration_ticks = if (snap_ticks > 0) timeline.snapToGrid(new_duration_ticks, snap_ticks) else new_duration_ticks;
    syncMidiLength(view, clip);
}

pub fn resizeClipLeft(
    view: *ArrangementView,
    clip: *ArrangementClip,
    new_start_tick: i64,
    snap_ticks: i64,
) void {
    if (new_start_tick >= clip.endTick()) return;
    const snapped = if (snap_ticks > 0) timeline.snapToGrid(new_start_tick, snap_ticks) else new_start_tick;
    const clamped = @max(0, snapped);
    if (clamped >= clip.endTick()) return;
    const delta = clip.start_tick - clamped;
    clip.start_tick = clamped;
    clip.duration_ticks += delta;
    syncMidiLength(view, clip);
}

pub fn deleteClip(
    view: *ArrangementView,
    track_index: usize,
    clip_index: usize,
) void {
    if (track_index >= view.tracks.items.len) return;
    var track = &view.tracks.items[track_index];
    if (clip_index >= track.clips.items.len) return;
    view.releasePlacement(&track.clips.items[clip_index]);
    _ = track.clips.orderedRemove(clip_index);
}

pub fn duplicateClip(
    view: *ArrangementView,
    track_index: usize,
    clip_index: usize,
) !usize {
    if (track_index >= view.tracks.items.len) return error.InvalidTrack;
    if (clip_index >= view.tracks.items[track_index].clips.items.len) return error.InvalidClip;
    const dst = try cloneClip(view, &view.tracks.items[track_index].clips.items[clip_index]);
    view.tracks.items[track_index].clips.append(view.allocator, dst) catch |err| {
        view.releasePlacement(&dst);
        return err;
    };
    return view.tracks.items[track_index].clips.items.len - 1;
}

/// Independent copy of a placement: `dupe`s the pooled content into a fresh
/// `ClipId` (Bitwig-style — edits do not propagate between the copies).
fn cloneClip(view: *ArrangementView, src: *const ArrangementClip) !ArrangementClip {
    const new_id = view.dupePooledClip(src.clip);
    if (new_id.isNone()) return error.OutOfMemory;
    return .{
        .clip = new_id,
        .start_tick = src.start_tick,
        .duration_ticks = src.duration_ticks,
        .source_offset_ticks = src.source_offset_ticks,
        .enabled = src.enabled,
        .selected = src.selected,
    };
}

pub fn splitClip(
    view: *ArrangementView,
    track_index: usize,
    clip_index: usize,
    split_tick: i64,
    snap_ticks: i64,
) !?usize {
    if (track_index >= view.tracks.items.len) return error.InvalidTrack;
    if (clip_index >= view.tracks.items[track_index].clips.items.len) return error.InvalidClip;
    const snapped = if (snap_ticks > 0) timeline.snapToGrid(split_tick, snap_ticks) else split_tick;
    const clip = &view.tracks.items[track_index].clips.items[clip_index];
    if (snapped <= clip.start_tick or snapped >= clip.endTick()) return null;

    const right_start = snapped;
    const right_duration = clip.endTick() - snapped;
    const split_offset = snapped - clip.start_tick;
    const is_midi = view.placementMidi(clip) != null;
    const new_idx = try duplicateClip(view, track_index, clip_index);
    const left_clip = &view.tracks.items[track_index].clips.items[clip_index];
    left_clip.duration_ticks = split_offset;
    syncMidiLength(view, left_clip);
    const right_clip = &view.tracks.items[track_index].clips.items[new_idx];
    right_clip.start_tick = right_start;
    right_clip.duration_ticks = right_duration;
    if (is_midi) {
        splitMidiNotes(view, left_clip, right_clip, split_offset);
    } else {
        right_clip.source_offset_ticks += split_offset;
    }
    return new_idx;
}

fn splitMidiNotes(view: *ArrangementView, left: *ArrangementClip, right: *ArrangementClip, split_ticks: i64) void {
    const split_beats = @as(f32, @floatFromInt(split_ticks)) / @as(f32, @floatFromInt(timeline.ppq));
    const left_midi = view.placementMidi(left) orelse return;
    const right_midi = view.placementMidi(right) orelse return;
    var i = left_midi.notes.items.len;
    while (i > 0) {
        i -= 1;
        const note = &left_midi.notes.items[i];
        if (note.start >= split_beats) {
            _ = left_midi.notes.orderedRemove(i);
        } else if (note.start + note.duration > split_beats) {
            note.duration = split_beats - note.start;
        }
    }
    i = right_midi.notes.items.len;
    while (i > 0) {
        i -= 1;
        const note = &right_midi.notes.items[i];
        const note_end = note.start + note.duration;
        if (note_end <= split_beats) {
            _ = right_midi.notes.orderedRemove(i);
        } else if (note.start < split_beats) {
            note.start = 0;
            note.duration = note_end - split_beats;
        } else {
            note.start -= split_beats;
        }
    }
    left_midi.length_beats = split_beats;
    right_midi.length_beats = @as(f32, @floatFromInt(right.duration_ticks)) / @as(f32, @floatFromInt(timeline.ppq));
}

pub fn deleteTrack(
    view: *ArrangementView,
    track_index: usize,
) void {
    if (track_index >= view.tracks.items.len) return;
    view.tracks.items[track_index].deinit(view.allocator, view.clip_pool, view.sample_store);
    _ = view.tracks.orderedRemove(track_index);
}

pub fn reorderTrack(
    view: *ArrangementView,
    from_index: usize,
    to_index: usize,
) void {
    if (from_index == to_index) return;
    if (from_index >= view.tracks.items.len or to_index >= view.tracks.items.len) return;
    const moved = view.tracks.items[from_index];
    const slice = view.tracks.items;
    if (from_index < to_index) {
        std.mem.copyForwards(ArrangementTrack, slice[from_index..to_index], slice[from_index + 1 .. to_index + 1]);
    } else {
        std.mem.copyBackwards(ArrangementTrack, slice[to_index + 1 .. from_index + 1], slice[to_index..from_index]);
    }
    slice[to_index] = moved;
}

pub fn selectClip(
    view: *ArrangementView,
    track_index: usize,
    clip_index: usize,
    shift_held: bool,
) void {
    if (shift_held) {
        view.tracks.items[track_index].clips.items[clip_index].selected =
            !view.tracks.items[track_index].clips.items[clip_index].selected;
    } else {
        view.clearSelection();
        view.tracks.items[track_index].clips.items[clip_index].selected = true;
    }
}

pub fn clipAtTick(
    track: *const ArrangementTrack,
    tick: i64,
) ?usize {
    for (track.clips.items, 0..) |clip, i| {
        if (tick >= clip.start_tick and tick < clip.endTick()) return i;
    }
    return null;
}

pub fn forEachSelected(
    view: *ArrangementView,
    comptime F: type,
    func: F,
) void {
    for (view.tracks.items, 0..) |*track, ti| {
        for (track.clips.items, 0..) |*clip, ci| {
            if (clip.selected) {
                @call(.auto, func, .{ ti, ci, clip });
            }
        }
    }
}

const testing = std.testing;
const clip_pool_mod = @import("../session/clip_pool.zig");
const SampleStore = @import("../audio/sample_store.zig").SampleStore;

// Build a standalone view backed by a real pool + sample store for tests.
const TestCtx = struct {
    view: ArrangementView,
    pool: clip_pool_mod.ClipPool,
    store: SampleStore,

    fn init(allocator: std.mem.Allocator) *TestCtx {
        const ctx = allocator.create(TestCtx) catch unreachable;
        ctx.pool = clip_pool_mod.ClipPool.init(allocator);
        ctx.store = SampleStore.init(allocator);
        ctx.view = ArrangementView.init(allocator);
        ctx.view.clip_pool = &ctx.pool;
        ctx.view.sample_store = &ctx.store;
        ctx.view.clearTracks();
        return ctx;
    }

    fn deinit(self: *TestCtx, allocator: std.mem.Allocator) void {
        self.view.deinit();
        self.pool.deinit(&self.store);
        self.store.deinit();
        allocator.destroy(self);
    }
};

test "split MIDI clip crops and rebases notes" {
    const allocator = testing.allocator;
    const ctx = TestCtx.init(allocator);
    defer ctx.deinit(allocator);
    const view = &ctx.view;
    try createTrack(view, 0, "Track", .{ 1, 1, 1, 1 });
    const clip_index = try createClip(view, 0, .midi, 0, timeline.ppq * 4, "MIDI");
    const midi = view.placementMidi(&view.tracks.items[0].clips.items[clip_index]).?;
    try midi.notes.append(allocator, .{ .pitch = 60, .start = 0.5, .duration = 1.0 });
    try midi.notes.append(allocator, .{ .pitch = 64, .start = 2.5, .duration = 0.5 });

    const right_index = (try splitClip(view, 0, clip_index, timeline.ppq, 0)).?;
    const left = view.placementMidi(&view.tracks.items[0].clips.items[clip_index]).?;
    const right = view.placementMidi(&view.tracks.items[0].clips.items[right_index]).?;
    try testing.expectEqual(@as(usize, 1), left.notes.items.len);
    try testing.expectEqual(@as(f32, 0.5), left.notes.items[0].duration);
    try testing.expectEqual(@as(usize, 2), right.notes.items.len);
    try testing.expectEqual(@as(f32, 0), right.notes.items[0].start);
    try testing.expectEqual(@as(f32, 0.5), right.notes.items[0].duration);
    try testing.expectEqual(@as(f32, 1.5), right.notes.items[1].start);
}

test "split audio clip advances source offset" {
    const allocator = testing.allocator;
    const ctx = TestCtx.init(allocator);
    defer ctx.deinit(allocator);
    const view = &ctx.view;
    try createTrack(view, 0, "Track", .{ 1, 1, 1, 1 });
    const clip_index = try createClip(view, 0, .audio, 0, timeline.ppq * 4, "Audio");
    const right_index = (try splitClip(view, 0, clip_index, timeline.ppq, 0)).?;
    try testing.expectEqual(timeline.ppq, view.tracks.items[0].clips.items[right_index].source_offset_ticks);
}
