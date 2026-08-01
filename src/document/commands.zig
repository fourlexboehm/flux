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
    store.markChanged();
    return arrangementGlobalIndex(store, location.track, duplicate);
}

pub fn moveArrangementClip(store: *model.Store, global_index: usize, delta_track: i32, delta_ticks: i64) ?usize {
    const location = arrangementLocation(store, global_index) orelse return null;
    const target_track_i = @as(i32, @intCast(location.track)) + delta_track;
    if (target_track_i < 0 or target_track_i >= @as(i32, @intCast(store.arrangement.tracks.items.len))) return null;
    const target_track: usize = @intCast(target_track_i);
    var clip_index = location.clip;
    if (target_track != location.track) {
        clip_index = arr_ops.moveClipToTrack(&store.arrangement, location.track, location.clip, target_track) catch return null;
    }
    const clip = &store.arrangement.tracks.items[target_track].clips.items[clip_index];
    arr_ops.moveClip(clip, clip.start_tick + delta_ticks, store.arrangement.snap_division_ticks);
    store.markChanged();
    return arrangementGlobalIndex(store, target_track, clip_index);
}

fn arrangementGlobalIndex(store: *const model.Store, target_track: usize, target_clip: usize) usize {
    var global: usize = 0;
    for (store.arrangement.tracks.items, 0..) |track, track_index| {
        if (track_index == target_track) return global + target_clip;
        global += track.clips.items.len;
    }
    return global;
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

test "session edit commands duplicate move copy paste and delete pooled clips" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();

    createClip(&store, 0, 0, 4);
    const original = store.session.clips[0][0].clip;
    try std.testing.expect(duplicateSessionSelection(&store));
    const duplicate = store.session.clips[0][1].clip;
    try std.testing.expect(!duplicate.isNone());
    try std.testing.expect(!duplicate.eql(original));

    try std.testing.expect(moveSessionSelection(&store, 0, 1, 1, 1));
    try std.testing.expect(store.session.clips[0][1].clip.isNone());
    try std.testing.expect(store.session.clips[1][2].clip.eql(duplicate));

    copySessionSelection(&store);
    setSessionAnchor(&store, 2, 3, true);
    try std.testing.expect(pasteSessionSelection(&store));
    const pasted = store.session.clips[2][3].clip;
    try std.testing.expect(!pasted.isNone());
    try std.testing.expect(!pasted.eql(duplicate));
    try std.testing.expect(deleteSessionSelection(&store));
    try std.testing.expect(store.session.clips[2][3].clip.isNone());
}

test "arrangement edit commands duplicate and nudge placements" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    syncArrangementTracks(&store);

    _ = try arr_ops.createClip(&store.arrangement, 0, .midi, 0, 960, "Seed");
    const duplicate = duplicateArrangementClip(&store, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), duplicate);
    try std.testing.expectEqual(@as(i64, 960), store.arrangement.tracks.items[0].clips.items[1].start_tick);

    const moved = moveArrangementClip(&store, duplicate, 1, 240) orelse return error.TestUnexpectedResult;
    const location = arrangementLocation(&store, moved) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), location.track);
    try std.testing.expectEqual(@as(i64, 1200), store.arrangement.tracks.items[1].clips.items[location.clip].start_tick);
}
