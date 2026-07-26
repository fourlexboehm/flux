const std = @import("std");
const arr_types = @import("types.zig");
const arr_clip = @import("clip.zig");
const arr_track = @import("track.zig");
const timeline = @import("timeline.zig");

const ArrangementView = arr_types.ArrangementView;
const ArrangementClip = arr_clip.ArrangementClip;
const ArrangementTrack = arr_track.ArrangementTrack;

pub fn createTrack(
    view: *ArrangementView,
    session_track_index: usize,
    name: []const u8,
    color: [4]f32,
) !void {
    try view.tracks.append(view.allocator, ArrangementTrack.init(name, session_track_index, color));
}

pub fn createClip(
    view: *ArrangementView,
    track_index: usize,
    kind: arr_clip.ClipKind,
    start_tick: i64,
    duration_ticks: i64,
    name: []const u8,
) !usize {
    if (track_index >= view.tracks.items.len) return error.InvalidTrack;
    if (duration_ticks <= 0) return error.InvalidDuration;
    var clip = ArrangementClip.init(view.allocator, kind, start_tick, duration_ticks);
    clip.name.set(name);
    try view.tracks.items[track_index].clips.append(view.allocator, clip);
    return view.tracks.items[track_index].clips.items.len - 1;
}

pub fn setClipAudioPath(clip: *ArrangementClip, allocator: std.mem.Allocator, path: []const u8) !void {
    const replacement = try allocator.dupe(u8, path);
    if (clip.audio_path) |old| allocator.free(old);
    clip.audio_path = replacement;
    clip.kind = .audio;
}

pub fn setClipMidiSource(clip: *ArrangementClip, session_track: usize, session_scene: usize) void {
    clip.midi_session_track = session_track;
    clip.midi_session_scene = session_scene;
    clip.kind = .midi;
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
    var dst = try cloneClip(view.allocator, &view.tracks.items[from_track].clips.items[clip_index]);
    errdefer dst.deinit(view.allocator);
    try view.tracks.items[to_track].clips.append(view.allocator, dst);
    var removed = view.tracks.items[from_track].clips.orderedRemove(clip_index);
    removed.deinit(view.allocator);
    return view.tracks.items[to_track].clips.items.len - 1;
}

pub fn resizeClip(
    clip: *ArrangementClip,
    new_duration_ticks: i64,
    snap_ticks: i64,
) void {
    if (new_duration_ticks <= 0) return;
    clip.duration_ticks = if (snap_ticks > 0) timeline.snapToGrid(new_duration_ticks, snap_ticks) else new_duration_ticks;
    if (clip.midi) |*midi| midi.length_beats = @as(f32, @floatFromInt(clip.duration_ticks)) / @as(f32, @floatFromInt(timeline.ppq));
}

pub fn resizeClipLeft(
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
    if (clip.midi) |*midi| midi.length_beats = @as(f32, @floatFromInt(clip.duration_ticks)) / @as(f32, @floatFromInt(timeline.ppq));
}

pub fn deleteClip(
    view: *ArrangementView,
    track_index: usize,
    clip_index: usize,
) void {
    if (track_index >= view.tracks.items.len) return;
    var track = &view.tracks.items[track_index];
    if (clip_index >= track.clips.items.len) return;
    var clip = &track.clips.items[clip_index];
    clip.deinit(view.allocator);
    _ = track.clips.orderedRemove(clip_index);
}

pub fn duplicateClip(
    view: *ArrangementView,
    track_index: usize,
    clip_index: usize,
) !usize {
    if (track_index >= view.tracks.items.len) return error.InvalidTrack;
    if (clip_index >= view.tracks.items[track_index].clips.items.len) return error.InvalidClip;
    var dst = try cloneClip(view.allocator, &view.tracks.items[track_index].clips.items[clip_index]);
    errdefer dst.deinit(view.allocator);
    try view.tracks.items[track_index].clips.append(view.allocator, dst);
    return view.tracks.items[track_index].clips.items.len - 1;
}

fn cloneClip(allocator: std.mem.Allocator, src: *const ArrangementClip) !ArrangementClip {
    var dst = ArrangementClip.init(allocator, src.kind, src.start_tick, src.duration_ticks);
    errdefer dst.deinit(allocator);
    dst.color = src.color;
    dst.source_offset_ticks = src.source_offset_ticks;
    dst.name = src.name;
    dst.enabled = src.enabled;
    dst.midi_session_track = src.midi_session_track;
    dst.midi_session_scene = src.midi_session_scene;
    dst.selected = src.selected;
    if (src.midi) |*midi| try dst.midi.?.copyFromFallible(midi);
    if (src.audio_path) |path| dst.audio_path = try allocator.dupe(u8, path);
    return dst;
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
    const new_idx = try duplicateClip(view, track_index, clip_index);
    const left_clip = &view.tracks.items[track_index].clips.items[clip_index];
    left_clip.duration_ticks = snapped - left_clip.start_tick;
    if (left_clip.midi) |*midi| midi.length_beats = @as(f32, @floatFromInt(left_clip.duration_ticks)) / @as(f32, @floatFromInt(timeline.ppq));
    const right_clip = &view.tracks.items[track_index].clips.items[new_idx];
    right_clip.start_tick = right_start;
    right_clip.duration_ticks = right_duration;
    if (left_clip.midi != null) {
        splitMidiNotes(left_clip, right_clip, snapped - left_clip.start_tick);
    } else {
        right_clip.source_offset_ticks += snapped - left_clip.start_tick;
    }
    return new_idx;
}

fn splitMidiNotes(left: *ArrangementClip, right: *ArrangementClip, split_ticks: i64) void {
    const split_beats = @as(f32, @floatFromInt(split_ticks)) / @as(f32, @floatFromInt(timeline.ppq));
    const left_midi = &(left.midi orelse return);
    const right_midi = &(right.midi orelse return);
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
    view.tracks.items[track_index].deinit(view.allocator);
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

test "split MIDI clip crops and rebases notes" {
    const allocator = std.testing.allocator;
    var view = ArrangementView.init(allocator);
    defer view.deinit();
    view.clearTracks();
    try createTrack(&view, 0, "Track", .{ 1, 1, 1, 1 });
    const clip_index = try createClip(&view, 0, .midi, 0, timeline.ppq * 4, "MIDI");
    const midi = &view.tracks.items[0].clips.items[clip_index].midi.?;
    try midi.notes.append(allocator, .{ .pitch = 60, .start = 0.5, .duration = 1.0 });
    try midi.notes.append(allocator, .{ .pitch = 64, .start = 2.5, .duration = 0.5 });

    const right_index = (try splitClip(&view, 0, clip_index, timeline.ppq, 0)).?;
    const left = view.tracks.items[0].clips.items[clip_index].midi.?;
    const right = view.tracks.items[0].clips.items[right_index].midi.?;
    try std.testing.expectEqual(@as(usize, 1), left.notes.items.len);
    try std.testing.expectEqual(@as(f32, 0.5), left.notes.items[0].duration);
    try std.testing.expectEqual(@as(usize, 2), right.notes.items.len);
    try std.testing.expectEqual(@as(f32, 0), right.notes.items[0].start);
    try std.testing.expectEqual(@as(f32, 0.5), right.notes.items[0].duration);
    try std.testing.expectEqual(@as(f32, 1.5), right.notes.items[1].start);
}

test "split audio clip advances source offset" {
    const allocator = std.testing.allocator;
    var view = ArrangementView.init(allocator);
    defer view.deinit();
    view.clearTracks();
    try createTrack(&view, 0, "Track", .{ 1, 1, 1, 1 });
    const clip_index = try createClip(&view, 0, .audio, 0, timeline.ppq * 4, "Audio");
    const right_index = (try splitClip(&view, 0, clip_index, timeline.ppq, 0)).?;
    try std.testing.expectEqual(timeline.ppq, view.tracks.items[0].clips.items[right_index].source_offset_ticks);
}
