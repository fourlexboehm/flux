//! Session / mixer document commands.
const std = @import("std");
const model = @import("model.zig");
const session_ops = @import("../session/ops.zig");
const session_playback = @import("../session/playback.zig");
const session_types = @import("../session/types.zig");
const arr_ops = @import("../arrangement/ops.zig");


/// Regular tracks (`0..track_count`) or the master bus slot.
pub fn isMixableTrack(store: *const model.Store, track: usize) bool {
    if (track == session_types.master_track_index) {
        return store.session.tracks[track].is_master;
    }
    return track < store.session.track_count;
}

const track_colors = [_][4]f32{
    .{ 0.85, 0.35, 0.30, 1 },
    .{ 0.35, 0.55, 0.90, 1 },
    .{ 0.40, 0.75, 0.45, 1 },
    .{ 0.90, 0.70, 0.30, 1 },
    .{ 0.65, 0.45, 0.85, 1 },
    .{ 0.40, 0.80, 0.80, 1 },
    .{ 0.90, 0.50, 0.65, 1 },
    .{ 0.55, 0.55, 0.60, 1 },
};

pub fn syncArrangementTracks(store: *model.Store) void {
    store.arrangement.clearTracks();
    for (0..store.session.track_count) |track| {
        const name = store.session.tracks[track].getName();
        const color = track_colors[track % track_colors.len];
        arr_ops.createTrack(&store.arrangement, track, name, color) catch {};
    }
    store.markChanged();
}

pub fn createClip(store: *model.Store, track: usize, scene: usize, beats_per_bar: f32) void {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return;
    session_ops.createClip(&store.session, track, scene, beats_per_bar);
    session_ops.selectOnly(&store.session, track, scene);
    store.markChanged();
}

pub fn toggleSlotPlayback(store: *model.Store, track: usize, scene: usize, transport_playing: bool) void {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return;
    session_playback.toggleClipPlayback(&store.session, track, scene, transport_playing);
    store.markChanged();
}

pub fn launchScene(store: *model.Store, scene: usize, transport_playing: bool) void {
    if (scene >= store.session.scene_count) return;
    session_playback.launchScene(&store.session, scene, transport_playing);
    store.markChanged();
}

pub fn selectSlot(store: *model.Store, track: usize, scene: usize) void {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return;
    session_ops.selectOnly(&store.session, track, scene);
}

/// Select a filled launcher slot. Clicking an already-selected clip preserves
/// a multi-selection so it can be dragged as one block.
pub fn selectSessionSlot(store: *model.Store, track: usize, scene: usize, additive: bool) void {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return;
    session_ops.handleClipClick(&store.session, track, scene, additive);
}

/// Set the destination used by Paste without treating an empty slot as clip
/// content. This mirrors Ableton's empty-cell selection behavior.
pub fn setSessionAnchor(store: *model.Store, track: usize, scene: usize, clear_selection: bool) void {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return;
    if (clear_selection) session_ops.clearSelection(&store.session);
    store.session.primary_track = track;
    store.session.primary_scene = scene;
}

pub fn sessionSlotSelected(store: *const model.Store, track: usize, scene: usize) bool {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return false;
    return session_ops.isSelected(&store.session, track, scene);
}

pub fn sessionHasSelection(store: *const model.Store) bool {
    return session_ops.hasSelection(&store.session);
}

pub fn sessionCanPaste(store: *const model.Store) bool {
    return store.session.clipboard.items.len > 0;
}

pub fn copySessionSelection(store: *model.Store) void {
    session_ops.copySelected(&store.session);
}

pub fn cutSessionSelection(store: *model.Store) bool {
    if (!session_ops.hasSelection(&store.session)) return false;
    session_ops.cutSelected(&store.session);
    store.markChanged();
    return true;
}

pub fn pasteSessionSelection(store: *model.Store) bool {
    if (store.session.clipboard.items.len == 0) return false;
    session_ops.paste(&store.session);
    store.markChanged();
    return true;
}

pub fn deleteSessionSelection(store: *model.Store) bool {
    if (!session_ops.hasSelection(&store.session)) return false;
    session_ops.deleteSelected(&store.session);
    store.markChanged();
    return true;
}

pub fn selectAllSessionClips(store: *model.Store) void {
    session_ops.selectAllClips(&store.session);
}

pub fn canMoveSessionSelection(store: *const model.Store, delta_track: i32, delta_scene: i32) bool {
    if ((delta_track == 0 and delta_scene == 0) or !session_ops.hasSelection(&store.session)) return false;
    for (0..store.session.track_count) |track| {
        for (0..store.session.scene_count) |scene| {
            if (!store.session.clip_selected[track][scene] or store.session.clips[track][scene].state == .empty) continue;
            const target_track = @as(i32, @intCast(track)) + delta_track;
            const target_scene = @as(i32, @intCast(scene)) + delta_scene;
            if (target_track < 0 or target_track >= @as(i32, @intCast(store.session.track_count))) return false;
            if (target_scene < 0 or target_scene >= @as(i32, @intCast(store.session.scene_count))) return false;
        }
    }
    return true;
}

pub fn moveSessionSelection(store: *model.Store, anchor_track: usize, anchor_scene: usize, delta_track: i32, delta_scene: i32) bool {
    if (!canMoveSessionSelection(store, delta_track, delta_scene)) return false;
    store.session.drag_start_track = anchor_track;
    store.session.drag_start_scene = anchor_scene;
    session_ops.moveSelectedClips(&store.session, delta_track, delta_scene);
    store.markChanged();
    return true;
}

/// Duplicate the selected rectangle into the following scene range, matching
/// launcher workflows while retaining the copied clips for subsequent Paste.
pub fn duplicateSessionSelection(store: *model.Store) bool {
    if (!session_ops.hasSelection(&store.session)) return false;
    var min_scene = store.session.scene_count;
    var max_scene: usize = 0;
    for (0..store.session.track_count) |track| {
        for (0..store.session.scene_count) |scene| {
            if (!store.session.clip_selected[track][scene] or store.session.clips[track][scene].state == .empty) continue;
            min_scene = @min(min_scene, scene);
            max_scene = @max(max_scene, scene);
        }
    }
    if (min_scene == store.session.scene_count) return false;
    const scene_delta = max_scene - min_scene + 1;
    if (!canMoveSessionSelection(store, 0, @intCast(scene_delta))) return false;
    session_ops.copySelected(&store.session);
    store.session.primary_scene += scene_delta;
    session_ops.paste(&store.session);
    store.markChanged();
    return true;
}

pub fn addTrack(store: *model.Store) bool {
    if (!session_ops.addTrack(&store.session)) return false;
    const track = store.session.track_count - 1;
    const name = store.session.tracks[track].getName();
    const color = track_colors[track % track_colors.len];
    arr_ops.createTrack(&store.arrangement, track, name, color) catch {
        _ = session_ops.deleteTrack(&store.session, track);
        return false;
    };
    store.markChanged();
    return true;
}

pub fn addScene(store: *model.Store) bool {
    if (!session_ops.addScene(&store.session)) return false;
    store.markChanged();
    return true;
}

pub fn deleteClip(store: *model.Store, track: usize, scene: usize) void {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return;
    session_ops.selectOnly(&store.session, track, scene);
    session_ops.deleteSelected(&store.session);
    store.markChanged();
}

pub fn setTrackVolume(store: *model.Store, track: usize, volume: f32) void {
    if (!isMixableTrack(store, track)) return;
    const value = std.math.clamp(volume, 0, 1.5);
    if (store.session.tracks[track].volume == value) return;
    const old = store.session.tracks[track].volume;
    store.session.tracks[track].volume = value;
    const cmd_undo = @import("cmd_undo.zig");
    cmd_undo.pushTrackVolume(store, track, old, value);
    store.markChanged();
}

pub fn setTrackPan(store: *model.Store, track: usize, pan: f32) void {
    if (!isMixableTrack(store, track)) return;
    const value = std.math.clamp(pan, -1, 1);
    if (store.session.tracks[track].pan == value) return;
    store.session.tracks[track].pan = value;
    store.markChanged();
}

pub fn toggleTrackMute(store: *model.Store, track: usize) void {
    if (!isMixableTrack(store, track)) return;
    const old = store.session.tracks[track].mute;
    store.session.tracks[track].mute = !old;
    const cmd_undo = @import("cmd_undo.zig");
    cmd_undo.pushTrackMute(store, track, old, !old);
    store.markChanged();
}

pub fn toggleTrackSolo(store: *model.Store, track: usize) void {
    if (track >= store.session.track_count) return;
    const old = store.session.tracks[track].solo;
    store.session.tracks[track].solo = !old;
    const cmd_undo = @import("cmd_undo.zig");
    cmd_undo.pushTrackSolo(store, track, old, !old);
    store.markChanged();
}

/// Prefer `document/cmd_recording.toggleTrackArm` (stops active take). Kept so
/// older call sites that only imported session commands still compile if any.
pub fn toggleTrackArmPlain(store: *model.Store, track: usize) void {
    if (track >= store.session.track_count) return;
    store.session.armed_track = if (store.session.armed_track == track) null else track;
    store.markChanged();
}

pub const PlaybackRequests = struct {
    start: bool,
    /// Always false here: `reset_playhead_request` is owned by `ui/recording.tick`
    /// so held notes can be seeded at the recording start boundary.
    reset_playhead: bool,
};

pub fn takePlaybackRequests(store: *model.Store) PlaybackRequests {
    const requests: PlaybackRequests = .{
        .start = store.session.start_playback_request,
        .reset_playhead = false,
    };
    store.session.start_playback_request = false;
    return requests;
}

pub fn processQuantizedSwitches(store: *model.Store) void {
    var has_queued = false;
    for (0..store.session.track_count) |track| {
        for (0..store.session.scene_count) |scene| {
            const state = store.session.clips[track][scene].state;
            if (state == .queued or state == .record_queued) has_queued = true;
        }
    }
    session_playback.processQuantizedSwitches(&store.session);
    if (has_queued) store.markChanged();
}

pub fn setPrimarySelection(store: *model.Store, track: usize, scene: usize) void {
    if (track < store.session.track_count) store.session.primary_track = track;
    if (scene < store.session.scene_count) store.session.primary_scene = scene;
}

/// Select every filled clip whose launcher cell intersects the track/scene range.
/// Used by session box multi-select. Selection itself is non-mutating for audio;
/// we do not bump revision (same as single-click select).
pub fn selectSessionSlotsInRange(
    store: *model.Store,
    track_min: usize,
    track_max: usize,
    scene_min: usize,
    scene_max: usize,
    additive: bool,
) void {
    const t0 = @min(track_min, track_max);
    const t1 = @max(track_min, track_max);
    const s0 = @min(scene_min, scene_max);
    const s1 = @max(scene_min, scene_max);
    if (!additive) session_ops.clearSelection(&store.session);
    var t = t0;
    while (t <= t1 and t < store.session.track_count) : (t += 1) {
        var s = s0;
        while (s <= s1 and s < store.session.scene_count) : (s += 1) {
            if (store.session.clips[t][s].state != .empty) {
                session_ops.selectClip(&store.session, t, s);
            }
        }
    }
}

