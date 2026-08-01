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
const notes = @import("../session/notes.zig");

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

pub fn toggleTrackArm(store: *model.Store, track: usize) void {
    if (track >= store.session.track_count) return;
    store.session.armed_track = if (store.session.armed_track == track) null else track;
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

fn midiClip(store: *model.Store, track: usize, scene: usize) ?*notes.PianoRollClip {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return null;
    const id = store.session.clips[track][scene].clip;
    const clip = store.clip_pool.get(id) orelse return null;
    return if (clip.content == .midi) &clip.content.midi else null;
}

pub fn addMidiNote(store: *model.Store, track: usize, scene: usize, note: notes.Note) ?usize {
    const clip = midiClip(store, track, scene) orelse return null;
    clip.addFullNote(note) catch return null;
    store.markChanged();
    return clip.notes.items.len - 1;
}

pub fn addMidiNotes(store: *model.Store, track: usize, scene: usize, new_notes: []const notes.Note) ?usize {
    if (new_notes.len == 0) return null;
    const clip = midiClip(store, track, scene) orelse return null;
    const first = clip.notes.items.len;
    clip.notes.ensureUnusedCapacity(clip.allocator, new_notes.len) catch return null;
    for (new_notes) |note| clip.notes.appendAssumeCapacity(note);
    store.markChanged();
    return first;
}

pub fn removeMidiNote(store: *model.Store, track: usize, scene: usize, index: usize) bool {
    const clip = midiClip(store, track, scene) orelse return false;
    if (index >= clip.notes.items.len) return false;
    clip.removeNoteAt(index);
    store.markChanged();
    return true;
}

pub fn removeMidiNotes(store: *model.Store, track: usize, scene: usize, indices: []const usize) bool {
    const clip = midiClip(store, track, scene) orelse return false;
    var removed = false;
    var i = clip.notes.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.indexOfScalar(usize, indices, i) != null) {
            clip.removeNoteAt(i);
            removed = true;
        }
    }
    if (removed) store.markChanged();
    return removed;
}

pub fn commitMidiNoteEdit(store: *model.Store, track: usize, scene: usize) void {
    if (midiClip(store, track, scene) != null) store.markChanged();
}

pub const MidiTransform = enum { quantize, duplicate, reverse, invert, legato, resolve_overlaps, humanize, half_time, double_time };

fn selected(index: usize, indices: []const usize) bool {
    if (indices.len == 0) return true;
    return std.mem.indexOfScalar(usize, indices, index) != null;
}

/// Applies the legacy piano-roll bulk tools. An empty selection means all notes.
pub fn transformMidiNotes(store: *model.Store, track: usize, scene: usize, indices: []const usize, transform: MidiTransform, step: f32) bool {
    const clip = midiClip(store, track, scene) orelse return false;
    if (clip.notes.items.len == 0) return false;
    var changed = false;
    switch (transform) {
        .quantize => for (clip.notes.items, 0..) |*note, i| {
            if (!selected(i, indices)) continue;
            const value = @max(0, @round(note.start / step) * step);
            changed = changed or value != note.start;
            note.start = value;
        },
        .duplicate => {
            const original_len = clip.notes.items.len;
            var min_start = std.math.floatMax(f32);
            var max_end: f32 = 0;
            for (clip.notes.items[0..original_len], 0..) |note, i| if (selected(i, indices)) {
                min_start = @min(min_start, note.start);
                max_end = @max(max_end, note.start + note.duration);
            };
            if (min_start == std.math.floatMax(f32)) return false;
            const shift = @max(step, max_end - min_start);
            for (clip.notes.items[0..original_len], 0..) |note, i| if (selected(i, indices)) {
                var copy = note;
                copy.start += shift;
                clip.notes.append(clip.allocator, copy) catch return false;
                changed = true;
            };
        },
        .reverse => for (clip.notes.items, 0..) |*note, i| {
            if (!selected(i, indices)) continue;
            note.start = @max(0, clip.length_beats - (note.start + note.duration));
            changed = true;
        },
        .invert => {
            var low: u8 = 127;
            var high: u8 = 0;
            for (clip.notes.items, 0..) |note, i| if (selected(i, indices)) {
                low = @min(low, note.pitch);
                high = @max(high, note.pitch);
            };
            if (high < low) return false;
            for (clip.notes.items, 0..) |*note, i| if (selected(i, indices)) {
                note.pitch = @intCast(@as(u16, low) + high - note.pitch);
                changed = true;
            };
        },
        .legato => {
            for (clip.notes.items, 0..) |*note, i| {
                if (!selected(i, indices)) continue;
                var next = clip.length_beats;
                for (clip.notes.items, 0..) |other, j| {
                    if (i != j and selected(j, indices) and other.start > note.start) next = @min(next, other.start);
                }
                if (next > note.start) {
                    const duration = @max(0.0625, next - note.start);
                    changed = changed or duration != note.duration;
                    note.duration = duration;
                }
            }
        },
        .resolve_overlaps => {
            for (clip.notes.items, 0..) |*note, i| {
                if (!selected(i, indices)) continue;
                var next = note.start + note.duration;
                for (clip.notes.items, 0..) |other, j| {
                    if (i == j or !selected(j, indices) or other.pitch != note.pitch or other.start <= note.start) continue;
                    next = @min(next, other.start);
                }
                const duration = @max(0.0625, next - note.start);
                changed = changed or duration != note.duration;
                note.duration = duration;
            }
        },
        .humanize => {
            var prng = std.Random.DefaultPrng.init(@as(u64, clip.notes.items.len) *% 0x9e3779b97f4a7c15 +% store.revision);
            const random = prng.random();
            for (clip.notes.items, 0..) |*note, i| {
                if (!selected(i, indices)) continue;
                note.velocity = std.math.clamp(note.velocity + (random.float(f32) * 2 - 1) * 0.08, 0, 1);
                changed = true;
            }
        },
        .half_time, .double_time => {
            const factor: f32 = if (transform == .half_time) 0.5 else 2;
            for (clip.notes.items, 0..) |*note, i| if (selected(i, indices)) {
                note.start *= factor;
                note.duration = @max(0.0625, note.duration * factor);
                changed = true;
            };
            clip.length_beats = @max(step, clip.length_beats * factor);
        },
    }
    if (changed) store.markChanged();
    return changed;
}

pub fn setMidiClipLength(store: *model.Store, track: usize, scene: usize, length: f32) bool {
    const clip = midiClip(store, track, scene) orelse return false;
    const value = @max(0.125, length);
    if (!clip.resizeKeepingLoop(value)) return false;
    if (clip.play_start_beats > value) clip.play_start_beats = value;
    store.markChanged();
    return true;
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
    toggleTrackArm(&store, 0);
    try std.testing.expectEqual(@as(?usize, 0), store.session.armed_track);
    try std.testing.expect(store.revision >= after_volume + 4);

    const before_structure = store.revision;
    try std.testing.expect(addTrack(&store));
    try std.testing.expect(addScene(&store));
    try std.testing.expect(store.revision >= before_structure + 2);
}

test "piano-roll commands mutate notes and revision" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    createClip(&store, 0, 0, 4);
    const before = store.revision;
    const index = addMidiNote(&store, 0, 0, .{ .pitch = 60, .start = 1, .duration = 0.5 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), index);
    try std.testing.expect(store.revision == before + 1);
    try std.testing.expect(removeMidiNote(&store, 0, 0, index));
    try std.testing.expect(store.revision == before + 2);
}

test "piano-roll bulk transforms preserve a single revision boundary" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    createClip(&store, 0, 0, 4);
    _ = addMidiNote(&store, 0, 0, .{ .pitch = 60, .start = 0.3, .duration = 0.5 });
    _ = addMidiNote(&store, 0, 0, .{ .pitch = 64, .start = 1.2, .duration = 0.5 });
    const before = store.revision;
    try std.testing.expect(transformMidiNotes(&store, 0, 0, &.{ 0, 1 }, .quantize, 0.5));
    try std.testing.expectEqual(before + 1, store.revision);
    try std.testing.expect(transformMidiNotes(&store, 0, 0, &.{ 0, 1 }, .duplicate, 0.5));
    try std.testing.expectEqual(@as(usize, 4), midiClip(&store, 0, 0).?.notes.items.len);
}
