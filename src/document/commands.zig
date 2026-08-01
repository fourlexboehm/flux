//! UI-neutral mutations for the editable document.
//!
//! Views emit these commands instead of editing session/arrangement storage.
//! Every successful mutation advances `Store.revision`, allowing projections
//! to become generation-driven without changing the document representation.

const std = @import("std");
const model = @import("model.zig");
const session_ops = @import("../session/ops.zig");
const session_playback = @import("../session/playback.zig");
const arr_ops = @import("../arrangement/ops.zig");

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
    store.markChanged();
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
    if (track >= store.session.track_count) return;
    const value = std.math.clamp(volume, 0, 1.5);
    if (store.session.tracks[track].volume == value) return;
    store.session.tracks[track].volume = value;
    store.markChanged();
}

pub fn setTrackPan(store: *model.Store, track: usize, pan: f32) void {
    if (track >= store.session.track_count) return;
    const value = std.math.clamp(pan, -1, 1);
    if (store.session.tracks[track].pan == value) return;
    store.session.tracks[track].pan = value;
    store.markChanged();
}

pub fn toggleTrackMute(store: *model.Store, track: usize) void {
    if (track >= store.session.track_count) return;
    store.session.tracks[track].mute = !store.session.tracks[track].mute;
    store.markChanged();
}

pub fn toggleTrackSolo(store: *model.Store, track: usize) void {
    if (track >= store.session.track_count) return;
    store.session.tracks[track].solo = !store.session.tracks[track].solo;
    store.markChanged();
}

pub const PlaybackRequests = struct {
    start: bool,
    reset_playhead: bool,
};

pub fn takePlaybackRequests(store: *model.Store) PlaybackRequests {
    const requests: PlaybackRequests = .{
        .start = store.session.start_playback_request,
        .reset_playhead = store.session.reset_playhead_request,
    };
    store.session.start_playback_request = false;
    store.session.reset_playhead_request = false;
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

test "commands mutate the store and advance its revision" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    syncArrangementTracks(&store);
    const before = store.revision;
    createClip(&store, 0, 0, 4);
    try std.testing.expect(store.revision > before);
    try std.testing.expect(!store.session.clips[0][0].clip.isNone());
}

test "persistent mixer and structure commands advance exactly on change" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();

    const initial = store.revision;
    setTrackVolume(&store, 0, store.session.tracks[0].volume);
    try std.testing.expectEqual(initial, store.revision);

    setTrackVolume(&store, 0, 0.5);
    const after_volume = store.revision;
    try std.testing.expect(after_volume > initial);

    setTrackPan(&store, 0, -0.25);
    toggleTrackMute(&store, 0);
    toggleTrackSolo(&store, 0);
    try std.testing.expect(store.revision >= after_volume + 3);

    const before_structure = store.revision;
    try std.testing.expect(addTrack(&store));
    try std.testing.expect(addScene(&store));
    try std.testing.expect(store.revision >= before_structure + 2);
}
