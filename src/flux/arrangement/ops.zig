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
    if (clip.audio_path) |old| allocator.free(old);
    clip.audio_path = try allocator.dupe(u8, path);
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
    const src = view.tracks.items[from_track].clips.items[clip_index];
    var dst = ArrangementClip.init(view.allocator, src.kind, src.start_tick, src.duration_ticks);
    dst.color = src.color;
    dst.name = src.name;
    dst.enabled = src.enabled;
    dst.midi_session_track = src.midi_session_track;
    dst.midi_session_scene = src.midi_session_scene;
    dst.selected = src.selected;
    if (src.midi) |*midi| dst.midi.?.copyFrom(midi);
    if (src.audio_path) |path| {
        dst.audio_path = try view.allocator.dupe(u8, path);
    }
    var from_clip = &view.tracks.items[from_track].clips.items[clip_index];
    from_clip.deinit(view.allocator);
    _ = view.tracks.items[from_track].clips.orderedRemove(clip_index);
    try view.tracks.items[to_track].clips.append(view.allocator, dst);
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
    const src = view.tracks.items[track_index].clips.items[clip_index];
    var dst = ArrangementClip.init(view.allocator, src.kind, src.start_tick, src.duration_ticks);
    dst.color = src.color;
    dst.name = src.name;
    dst.enabled = src.enabled;
    dst.midi_session_track = src.midi_session_track;
    dst.midi_session_scene = src.midi_session_scene;
    if (src.midi) |*midi| dst.midi.?.copyFrom(midi);
    if (src.audio_path) |path| {
        dst.audio_path = try view.allocator.dupe(u8, path);
    }
    try view.tracks.items[track_index].clips.append(view.allocator, dst);
    return view.tracks.items[track_index].clips.items.len - 1;
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
    clip.duration_ticks = snapped - clip.start_tick;

    const new_idx = try duplicateClip(view, track_index, clip_index);
    const right_clip = &view.tracks.items[track_index].clips.items[new_idx];
    right_clip.start_tick = right_start;
    right_clip.duration_ticks = right_duration;
    return new_idx;
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
