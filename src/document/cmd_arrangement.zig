//! Arrangement and audio-import document commands.
const std = @import("std");
const model = @import("model.zig");
const session_ops = @import("../session/ops.zig");
const arr_ops = @import("../arrangement/ops.zig");
const audio_clip_mod = @import("../session/audio_clip.zig");
const arr_timeline = @import("../arrangement/timeline.zig");
const cmd_undo = @import("cmd_undo.zig");

pub const ArrangementLocation = struct {
    track: usize,
    clip: usize,
};

pub fn arrangementLocation(store: *const model.Store, global_index: usize) ?ArrangementLocation {
    var global: usize = 0;
    for (store.arrangement.tracks.items, 0..) |track, track_index| {
        for (track.clips.items, 0..) |_, clip_index| {
            if (global == global_index) return .{ .track = track_index, .clip = clip_index };
            global += 1;
        }
    }
    return null;
}

pub fn selectArrangementClip(store: *model.Store, global_index: usize, additive: bool) bool {
    const location = arrangementLocation(store, global_index) orelse return false;
    arr_ops.selectClip(&store.arrangement, location.track, location.clip, additive);
    return true;
}

pub fn selectAllArrangementClips(store: *model.Store) void {
    store.arrangement.selectAllClips();
}

pub fn deleteArrangementClip(store: *model.Store, global_index: usize) bool {
    const location = arrangementLocation(store, global_index) orelse return false;
    // Mark only this clip selected for a clean before-snapshot, then delete.
    store.arrangement.clearSelection();
    store.arrangement.tracks.items[location.track].clips.items[location.clip].selected = true;
    cmd_undo.pushArrangementDeleteSelected(store);
    arr_ops.deleteClip(&store.arrangement, location.track, location.clip);
    store.markChanged();
    return true;
}

pub fn duplicateArrangementClip(store: *model.Store, global_index: usize) ?usize {
    const location = arrangementLocation(store, global_index) orelse return null;
    const source = store.arrangement.tracks.items[location.track].clips.items[location.clip];
    const duplicate = arr_ops.duplicateClip(&store.arrangement, location.track, location.clip) catch return null;
    const clip = &store.arrangement.tracks.items[location.track].clips.items[duplicate];
    clip.start_tick = source.endTick();
    store.arrangement.clearSelection();
    clip.selected = true;
    cmd_undo.pushArrangementCreate(store, location.track, duplicate);
    store.markChanged();
    return arrangementGlobalIndex(store, location.track, duplicate);
}

pub fn moveArrangementClip(store: *model.Store, global_index: usize, delta_track: i32, delta_ticks: i64) ?usize {
    const location = arrangementLocation(store, global_index) orelse return null;
    const target_track_i = @as(i32, @intCast(location.track)) + delta_track;
    if (target_track_i < 0 or target_track_i >= @as(i32, @intCast(store.arrangement.tracks.items.len))) return null;
    const target_track: usize = @intCast(target_track_i);
    const orig_start = store.arrangement.tracks.items[location.track].clips.items[location.clip].start_tick;
    const orig_dur = store.arrangement.tracks.items[location.track].clips.items[location.clip].duration_ticks;
    var clip_index = location.clip;
    if (target_track != location.track) {
        clip_index = arr_ops.moveClipToTrack(&store.arrangement, location.track, location.clip, target_track) catch return null;
    }
    const clip = &store.arrangement.tracks.items[target_track].clips.items[clip_index];
    arr_ops.moveClip(clip, clip.start_tick + delta_ticks, store.arrangement.snap_division_ticks);
    cmd_undo.pushArrangementDrag(
        store,
        target_track,
        clip_index,
        location.track,
        location.clip,
        orig_start,
        orig_dur,
        false,
    );
    store.markChanged();
    return arrangementGlobalIndex(store, target_track, clip_index);
}

pub fn clearArrangementSelection(store: *model.Store) void {
    store.arrangement.clearSelection();
}

pub fn arrangementHasSelection(store: *const model.Store) bool {
    return store.arrangement.hasSelection();
}

pub fn arrangementClipSelected(store: *const model.Store, global_index: usize) bool {
    const location = arrangementLocation(store, global_index) orelse return false;
    return store.arrangement.tracks.items[location.track].clips.items[location.clip].selected;
}

/// Absolute placement geometry for live drag/resize. Does **not** bump revision;
/// call `commitArrangementEdit` once on gesture release when something changed.
pub fn setArrangementClipGeometry(
    store: *model.Store,
    global_index: usize,
    start_tick: i64,
    duration_ticks: i64,
    target_track: usize,
) ?usize {
    const location = arrangementLocation(store, global_index) orelse return null;
    if (target_track >= store.arrangement.tracks.items.len) return null;
    if (duration_ticks <= 0) return null;

    var clip_index = location.clip;
    var track = location.track;
    if (target_track != track) {
        clip_index = arr_ops.moveClipToTrack(&store.arrangement, track, clip_index, target_track) catch return null;
        track = target_track;
    }
    const clip = &store.arrangement.tracks.items[track].clips.items[clip_index];
    const snap = store.arrangement.snap_division_ticks;
    arr_ops.moveClip(clip, start_tick, snap);
    arr_ops.resizeClip(&store.arrangement, clip, duration_ticks, snap);
    return arrangementGlobalIndex(store, track, clip_index);
}

/// Live left-edge resize from an absolute start tick. No revision bump.
pub fn resizeArrangementClipLeft(store: *model.Store, global_index: usize, new_start_tick: i64) bool {
    const location = arrangementLocation(store, global_index) orelse return false;
    const clip = &store.arrangement.tracks.items[location.track].clips.items[location.clip];
    arr_ops.resizeClipLeft(&store.arrangement, clip, new_start_tick, store.arrangement.snap_division_ticks);
    return true;
}

/// Live right-edge resize to an absolute duration. No revision bump.
pub fn resizeArrangementClipRight(store: *model.Store, global_index: usize, new_duration_ticks: i64) bool {
    const location = arrangementLocation(store, global_index) orelse return false;
    const clip = &store.arrangement.tracks.items[location.track].clips.items[location.clip];
    arr_ops.resizeClip(&store.arrangement, clip, new_duration_ticks, store.arrangement.snap_division_ticks);
    return true;
}

pub fn commitArrangementEdit(store: *model.Store) void {
    store.markChanged();
}

/// Commit a pointer drag/resize/duplicate with one undo entry + revision.
pub fn commitArrangementDrag(
    store: *model.Store,
    track: usize,
    clip_index: usize,
    orig_track: usize,
    orig_clip_index: usize,
    orig_start_tick: i64,
    orig_duration_ticks: i64,
    duplicated: bool,
) void {
    cmd_undo.pushArrangementDrag(
        store,
        track,
        clip_index,
        orig_track,
        orig_clip_index,
        orig_start_tick,
        orig_duration_ticks,
        duplicated,
    );
    store.markChanged();
}

/// Duplicate in place (same start) for Ctrl/Cmd+drag. No revision until commit.
pub fn duplicateArrangementClipInPlace(store: *model.Store, global_index: usize) ?usize {
    const location = arrangementLocation(store, global_index) orelse return null;
    const duplicate = arr_ops.duplicateClip(&store.arrangement, location.track, location.clip) catch return null;
    store.arrangement.clearSelection();
    store.arrangement.tracks.items[location.track].clips.items[duplicate].selected = true;
    return arrangementGlobalIndex(store, location.track, duplicate);
}

pub fn createArrangementMidiClip(store: *model.Store, track: usize, start_tick: i64) ?usize {
    if (track >= store.arrangement.tracks.items.len) return null;
    const snap = store.arrangement.snap_division_ticks;
    const snapped = if (snap > 0) arr_timeline.snapToGrid(@max(0, start_tick), snap) else @max(0, start_tick);
    const default_dur = arr_timeline.ppq * 4 * 4; // 4 bars
    const clip_index = arr_ops.createClip(&store.arrangement, track, .midi, snapped, default_dur, "MIDI") catch return null;
    arr_ops.selectClip(&store.arrangement, track, clip_index, false);
    cmd_undo.pushArrangementCreate(store, track, clip_index);
    store.markChanged();
    return arrangementGlobalIndex(store, track, clip_index);
}

/// Load an audio file into a session launcher slot (browser / drop target).
pub fn loadAudioFileIntoSession(
    store: *model.Store,
    track: usize,
    scene: usize,
    abs_path: []const u8,
    beats_per_bar: f32,
    io: std.Io,
) bool {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return false;
    if (abs_path.len == 0) return false;
    const basename = std.fs.path.basename(abs_path);
    const sample_id = store.sample_store.loadFromPath(basename, abs_path, io) catch return false;
    const audio = ensureSlotAudio(store, track, scene) orelse {
        store.sample_store.release(sample_id);
        return false;
    };
    audio.setSample(&store.sample_store, sample_id);
    audio.name.set(basename);
    if (audio.length_beats <= 0) {
        audio.length_beats = @max(1.0, beats_per_bar * 4.0);
    }
    if (store.clip_pool.get(store.session.clips[track][scene].clip)) |clip| {
        clip.name.set(basename);
    }
    session_ops.selectOnly(&store.session, track, scene);
    store.session.mixer_target = .track;
    store.markChanged();
    return true;
}

/// Load an audio file as a new arrangement placement on `track` at `start_tick`.
pub fn loadAudioFileIntoArrangement(
    store: *model.Store,
    track: usize,
    abs_path: []const u8,
    start_tick: i64,
    bpm: f32,
    io: std.Io,
) ?usize {
    if (track >= store.arrangement.tracks.items.len) return null;
    if (abs_path.len == 0 or bpm <= 0) return null;
    const basename = std.fs.path.basename(abs_path);
    const sample_id = store.sample_store.loadFromPath(basename, abs_path, io) catch return null;
    const sample = store.sample_store.get(sample_id) orelse {
        store.sample_store.release(sample_id);
        return null;
    };
    const sample_duration_seconds = @as(f64, @floatFromInt(sample.frame_count)) /
        @as(f64, @floatFromInt(sample.sample_rate));
    const duration_ticks: i64 = @intFromFloat(sample_duration_seconds * bpm / 60.0 * @as(f64, @floatFromInt(arr_timeline.ppq)));
    const snap = store.arrangement.snap_division_ticks;
    const snapped = if (snap > 0) arr_timeline.snapToGrid(@max(0, start_tick), snap) else @max(0, start_tick);
    const clip_index = arr_ops.createClip(
        &store.arrangement,
        track,
        .audio,
        snapped,
        @max(1, duration_ticks),
        basename,
    ) catch {
        store.sample_store.release(sample_id);
        return null;
    };
    const placement = &store.arrangement.tracks.items[track].clips.items[clip_index];
    if (store.arrangement.placementAudio(placement)) |audio| {
        audio.setSample(&store.sample_store, sample_id);
        audio.name.set(basename);
    } else {
        store.sample_store.release(sample_id);
        arr_ops.deleteClip(&store.arrangement, track, clip_index);
        return null;
    }
    arr_ops.selectClip(&store.arrangement, track, clip_index, false);
    cmd_undo.pushArrangementCreate(store, track, clip_index);
    store.markChanged();
    return arrangementGlobalIndex(store, track, clip_index);
}

fn ensureSlotAudio(store: *model.Store, track: usize, scene: usize) ?*audio_clip_mod.AudioClip {
    const slot = &store.session.clips[track][scene];
    if (store.clip_pool.get(slot.clip)) |clip| {
        if (clip.content == .audio) return &clip.content.audio;
    }
    const prev_len: f32 = if (store.clip_pool.get(slot.clip)) |clip| clip.lengthBeats() else 0;
    if (!slot.clip.isNone()) {
        store.clip_pool.release(slot.clip, &store.sample_store);
        slot.* = .{};
    }
    var audio = audio_clip_mod.AudioClip.init(store.allocator);
    if (prev_len > 0) audio.length_beats = prev_len;
    const id = store.clip_pool.addAudio(audio) catch {
        audio.deinit(&store.sample_store);
        return null;
    };
    store.clip_pool.retain(id);
    slot.* = .{ .state = .stopped, .clip = id };
    return &store.clip_pool.get(id).?.content.audio;
}

pub fn deleteSelectedArrangementClips(store: *model.Store) bool {
    var any = false;
    for (store.arrangement.tracks.items) |track| {
        for (track.clips.items) |clip| {
            if (clip.selected) {
                any = true;
                break;
            }
        }
        if (any) break;
    }
    if (!any) return false;
    cmd_undo.pushArrangementDeleteSelected(store);
    var ti = store.arrangement.tracks.items.len;
    while (ti > 0) {
        ti -= 1;
        var ci = store.arrangement.tracks.items[ti].clips.items.len;
        while (ci > 0) {
            ci -= 1;
            if (store.arrangement.tracks.items[ti].clips.items[ci].selected) {
                arr_ops.deleteClip(&store.arrangement, ti, ci);
            }
        }
    }
    store.markChanged();
    return true;
}

pub fn setArrangementSelection(store: *model.Store, selected_globals: []const usize, additive: bool) void {
    if (!additive) store.arrangement.clearSelection();
    for (selected_globals) |global_index| {
        const location = arrangementLocation(store, global_index) orelse continue;
        store.arrangement.tracks.items[location.track].clips.items[location.clip].selected = true;
    }
}

fn arrangementGlobalIndex(store: *const model.Store, target_track: usize, target_clip: usize) usize {
    var global: usize = 0;
    for (store.arrangement.tracks.items, 0..) |track, track_index| {
        if (track_index == target_track) return global + target_clip;
        global += track.clips.items.len;
    }
    return global;
}

