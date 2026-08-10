//! Global document undo/redo — bridges session undo_requests, MIDI notes_replace,
//! arrangement edits, and mixer toggles into `undo_mod.UndoHistory` on `document.Store`.

const std = @import("std");
const model = @import("model.zig");
const undo_mod = @import("../undo/root.zig");
const session_types = @import("../session/types.zig");
const session_constants = @import("../session/constants.zig");
const notes = @import("../session/notes.zig");
const audio_clip_types = @import("../session/audio_clip.zig");
const clip_pool_mod = @import("../session/clip_pool.zig");
const arr_undo = @import("../arrangement/undo.zig");
const arr_ops = @import("../arrangement/ops.zig");
const midi_history = @import("midi_history.zig");

const max_tracks = session_constants.max_tracks;
const max_scenes = session_constants.max_scenes;
const ClipId = clip_pool_mod.ClipId;
const AudioClipSnapshot = audio_clip_types.AudioClipSnapshot;
const Direction = enum { undo, redo };

const ClipContentSnapshot = struct {
    notes: []const undo_mod.Note,
    audio: AudioClipSnapshot,
};

// ── Public API ───────────────────────────────────────────────────────────────

pub fn canUndo(store: *const model.Store) bool {
    return store.undo_history.canUndo();
}

pub fn canRedo(store: *const model.Store) bool {
    return store.undo_history.canRedo();
}

pub fn undoDescription(store: *const model.Store) ?[]const u8 {
    return store.undo_history.getUndoDescription();
}

pub fn redoDescription(store: *const model.Store) ?[]const u8 {
    return store.undo_history.getRedoDescription();
}

/// Drain session-view undo_requests (and clip moves) into the global history.
/// Safe to call when the queue is empty. Skipped while applying undo/redo.
pub fn flushSessionRequests(store: *model.Store) void {
    if (store.suppress_undo_capture) {
        dropSessionRequests(store);
        return;
    }
    processSessionUndoRequests(store);
}

pub fn undo(store: *model.Store) bool {
    flushSessionRequests(store);
    const cmd = store.undo_history.popForUndo() orelse return false;
    store.suppress_undo_capture = true;
    executeCommand(store, cmd, .undo);
    store.suppress_undo_capture = false;
    dropSessionRequests(store);
    store.undo_history.confirmUndo();
    store.markChanged();
    return true;
}

pub fn redo(store: *model.Store) bool {
    flushSessionRequests(store);
    const cmd = store.undo_history.popForRedo() orelse return false;
    store.suppress_undo_capture = true;
    executeCommand(store, cmd, .redo);
    store.suppress_undo_capture = false;
    dropSessionRequests(store);
    store.undo_history.confirmRedo();
    store.markChanged();
    return true;
}

/// Record a notes_replace entry (piano-roll discrete edits and gesture commit).
pub fn pushNotesReplace(
    store: *model.Store,
    track: usize,
    scene: usize,
    old_notes: []const notes.Note,
    new_notes: []const notes.Note,
    old_timing: notes.ClipTiming,
    new_timing: notes.ClipTiming,
) void {
    if (store.suppress_undo_capture) return;
    if (notesEqual(old_notes, new_notes) and timingsEqual(old_timing, new_timing)) return;
    const owned_old = store.allocator.dupe(notes.Note, old_notes) catch return;
    errdefer store.allocator.free(owned_old);
    const owned_new = store.allocator.dupe(notes.Note, new_notes) catch {
        store.allocator.free(owned_old);
        return;
    };
    store.undo_history.push(.{
        .notes_replace = .{
            .track = track,
            .scene = scene,
            .old_notes = owned_old,
            .new_notes = owned_new,
            .old_timing = old_timing,
            .new_timing = new_timing,
        },
    });
}

pub fn pushTrackVolume(store: *model.Store, track: usize, old_volume: f32, new_volume: f32) void {
    if (store.suppress_undo_capture) return;
    if (old_volume == new_volume) return;
    store.undo_history.push(.{
        .track_volume = .{
            .track_index = track,
            .old_volume = old_volume,
            .new_volume = new_volume,
        },
    });
}

pub fn pushTrackMute(store: *model.Store, track: usize, old_mute: bool, new_mute: bool) void {
    if (store.suppress_undo_capture) return;
    if (old_mute == new_mute) return;
    store.undo_history.push(.{
        .track_mute = .{
            .track_index = track,
            .old_mute = old_mute,
            .new_mute = new_mute,
        },
    });
}

pub fn pushTrackSolo(store: *model.Store, track: usize, old_solo: bool, new_solo: bool) void {
    if (store.suppress_undo_capture) return;
    if (old_solo == new_solo) return;
    store.undo_history.push(.{
        .track_solo = .{
            .track_index = track,
            .old_solo = old_solo,
            .new_solo = new_solo,
        },
    });
}

/// Push a single-clip arrangement create (after side only).
pub fn pushArrangementCreate(store: *model.Store, track: usize, clip_index: usize) void {
    if (store.suppress_undo_capture) return;
    if (track >= store.arrangement.tracks.items.len) return;
    if (clip_index >= store.arrangement.tracks.items[track].clips.items.len) return;
    const after = arr_undo.captureClip(
        &store.arrangement,
        track,
        clip_index,
        &store.arrangement.tracks.items[track].clips.items[clip_index],
    ) catch return;
    const changes = store.allocator.alloc(undo_mod.ArrangementClipChange, 1) catch {
        arr_undo.deinitCaptured(store.allocator, after);
        return;
    };
    changes[0] = .{ .after = after };
    store.undo_history.push(.{ .arrangement_edit = .{ .changes = changes } });
}

/// Push arrangement deletes for all currently selected clips (call before delete).
pub fn pushArrangementDeleteSelected(store: *model.Store) void {
    if (store.suppress_undo_capture) return;
    var list: std.ArrayListUnmanaged(undo_mod.ArrangementClipChange) = .empty;
    errdefer arr_undo.deinitChanges(store.allocator, list.items);
    for (store.arrangement.tracks.items, 0..) |track, ti| {
        for (track.clips.items, 0..) |clip, ci| {
            if (!clip.selected) continue;
            const before = arr_undo.captureClip(&store.arrangement, ti, ci, &clip) catch continue;
            list.append(store.allocator, .{ .before = before }) catch {
                arr_undo.deinitCaptured(store.allocator, before);
                continue;
            };
        }
    }
    if (list.items.len == 0) return;
    const changes = list.toOwnedSlice(store.allocator) catch {
        arr_undo.deinitChanges(store.allocator, list.items);
        list.deinit(store.allocator);
        return;
    };
    store.undo_history.push(.{ .arrangement_edit = .{ .changes = changes } });
}

/// Commit a drag/resize/duplicate gesture as one arrangement_edit.
/// Content is captured from the live placement; `before` uses original track/index/geometry.
pub fn pushArrangementDrag(
    store: *model.Store,
    track: usize,
    clip_index: usize,
    orig_track: usize,
    orig_clip_index: usize,
    orig_start_tick: i64,
    orig_duration_ticks: i64,
    duplicated: bool,
) void {
    if (store.suppress_undo_capture) return;
    if (track >= store.arrangement.tracks.items.len) return;
    if (clip_index >= store.arrangement.tracks.items[track].clips.items.len) return;
    const clip = &store.arrangement.tracks.items[track].clips.items[clip_index];
    const changed = duplicated or track != orig_track or clip_index != orig_clip_index or
        clip.start_tick != orig_start_tick or clip.duration_ticks != orig_duration_ticks;
    if (!changed) return;

    const after = arr_undo.captureClip(&store.arrangement, track, clip_index, clip) catch return;
    var change: undo_mod.ArrangementClipChange = .{ .after = after };
    if (!duplicated) {
        // Content from live clip; location/geometry from gesture origin (zgui parity).
        var before = arr_undo.captureClip(&store.arrangement, orig_track, orig_clip_index, clip) catch {
            arr_undo.deinitCaptured(store.allocator, after);
            return;
        };
        before.track = orig_track;
        before.index = orig_clip_index;
        before.clip.start_tick = orig_start_tick;
        before.clip.duration_ticks = orig_duration_ticks;
        change.before = before;
    }

    const changes = store.allocator.alloc(undo_mod.ArrangementClipChange, 1) catch {
        if (change.before) |before| arr_undo.deinitCaptured(store.allocator, before);
        arr_undo.deinitCaptured(store.allocator, after);
        return;
    };
    changes[0] = change;
    store.undo_history.push(.{ .arrangement_edit = .{ .changes = changes } });
}

// ── Session request processing ───────────────────────────────────────────────

fn dropSessionRequests(store: *model.Store) void {
    // Release any orphaned clip handles that session ops left alive for undo_mod.
    for (store.session.undo_requests.items) |req| {
        switch (req.kind) {
            .clip_delete, .clip_paste => {
                store.clip_pool.release(req.old_clip.clip, &store.sample_store);
            },
            .track_delete => {
                for (req.track_clips) |snapshot| {
                    store.clip_pool.release(snapshot.clip, &store.sample_store);
                }
            },
            .scene_delete => {
                for (req.scene_clips) |snapshot| {
                    store.clip_pool.release(snapshot.clip, &store.sample_store);
                }
            },
            else => {},
        }
    }
    store.session.undo_requests.clearRetainingCapacity();
    store.session.clip_move_count = 0;
    store.session.pending_piano_moves = false;
    store.session.pending_piano_copies = false;
    store.session.piano_copy_count = 0;
}

fn processSessionUndoRequests(store: *model.Store) void {
    for (store.session.undo_requests.items) |req| {
        switch (req.kind) {
            .clip_create => {
                store.undo_history.push(.{
                    .clip_create = .{
                        .track = req.track,
                        .scene = req.scene,
                        .length_beats = req.length_beats,
                    },
                });
            },
            .clip_delete => {
                const snap = snapshotClip(store, req.old_clip.clip) catch {
                    store.clip_pool.release(req.old_clip.clip, &store.sample_store);
                    continue;
                };
                store.undo_history.push(.{
                    .clip_delete = .{
                        .track = req.track,
                        .scene = req.scene,
                        .length_beats = req.length_beats,
                        .name = clipName(store, req.old_clip.clip),
                        .notes = snap.notes,
                        .audio = snap.audio,
                    },
                });
                store.clip_pool.release(req.old_clip.clip, &store.sample_store);
            },
            .clip_paste => {
                const new_id = store.session.clips[req.track][req.scene].clip;
                const old_len = clipLength(store, req.old_clip.clip);
                var old_snap = snapshotClip(store, req.old_clip.clip) catch {
                    store.clip_pool.release(req.old_clip.clip, &store.sample_store);
                    continue;
                };
                const new_snap = snapshotClip(store, new_id) catch {
                    old_snap.audio.deinit();
                    if (old_snap.notes.len > 0) store.allocator.free(old_snap.notes);
                    store.clip_pool.release(req.old_clip.clip, &store.sample_store);
                    continue;
                };
                store.undo_history.push(.{
                    .clip_paste = .{
                        .track = req.track,
                        .scene = req.scene,
                        .old_clip = .{
                            .has_clip = req.old_clip.state != .empty,
                            .length_beats = old_len,
                            .name = clipName(store, req.old_clip.clip),
                        },
                        .new_clip = .{
                            .has_clip = true,
                            .length_beats = req.length_beats,
                            .name = clipName(store, new_id),
                        },
                        .old_notes = old_snap.notes,
                        .new_notes = new_snap.notes,
                        .old_audio = old_snap.audio,
                        .new_audio = new_snap.audio,
                    },
                });
                store.clip_pool.release(req.old_clip.clip, &store.sample_store);
            },
            .track_add => {
                const track = &store.session.tracks[req.track];
                store.undo_history.push(.{
                    .track_add = .{
                        .track_index = req.track,
                        .name = track.name,
                    },
                });
            },
            .track_delete => {
                pushColumnDelete(store, req) catch {};
            },
            .scene_add => {
                const scene = &store.session.scenes[req.scene];
                store.undo_history.push(.{
                    .scene_add = .{
                        .scene_index = req.scene,
                        .name = scene.name,
                    },
                });
            },
            .scene_delete => {
                pushRowDelete(store, req) catch {};
            },
            .track_volume => {
                store.undo_history.push(.{
                    .track_volume = .{
                        .track_index = req.track,
                        .old_volume = req.old_volume,
                        .new_volume = req.new_volume,
                    },
                });
            },
            .scene_rename => {
                store.undo_history.push(.{
                    .scene_rename = .{
                        .scene_index = req.scene,
                        .old_name = req.old_name,
                        .new_name = req.new_name,
                    },
                });
            },
            .clip_rename => {
                store.undo_history.push(.{
                    .clip_rename = .{
                        .track = req.track,
                        .scene = req.scene,
                        .old_name = req.old_name,
                        .new_name = req.new_name,
                    },
                });
            },
        }
    }
    store.session.undo_requests.clearRetainingCapacity();

    if (store.session.clip_move_count > 0) {
        if (store.allocator.alloc(undo_mod.command.ClipMoveCmd.ClipMove, store.session.clip_move_count)) |moves| {
            for (store.session.clip_move_requests[0..store.session.clip_move_count], 0..) |req, i| {
                moves[i] = .{
                    .src_track = req.src_track,
                    .src_scene = req.src_scene,
                    .dst_track = req.dst_track,
                    .dst_scene = req.dst_scene,
                };
            }
            store.undo_history.push(.{ .clip_move = .{ .moves = moves } });
        } else |_| {}
        store.session.clip_move_count = 0;
    }
    store.session.pending_piano_moves = false;
    store.session.pending_piano_copies = false;
    store.session.piano_copy_count = 0;
}

fn snapshotClip(store: *model.Store, id: ClipId) !ClipContentSnapshot {
    if (store.clip_pool.get(id)) |c| {
        switch (c.content) {
            .audio => |*a| {
                const audio = try AudioClipSnapshot.capture(a, &store.sample_store);
                return .{ .notes = &.{}, .audio = audio };
            },
            .midi => |*m| {
                const note_slice = store.allocator.dupe(undo_mod.Note, m.notes.items) catch &.{};
                return .{ .notes = note_slice, .audio = try emptyAudioSnapshot(store) };
            },
        }
    }
    return .{ .notes = &.{}, .audio = try emptyAudioSnapshot(store) };
}

fn emptyAudioSnapshot(store: *model.Store) !AudioClipSnapshot {
    var empty = audio_clip_types.AudioClip.init(store.allocator);
    defer empty.deinit(&store.sample_store);
    return try AudioClipSnapshot.capture(&empty, &store.sample_store);
}

fn clipName(store: *model.Store, id: ClipId) session_types.NameField {
    if (store.clip_pool.get(id)) |c| return c.name;
    return .{};
}

fn clipLength(store: *model.Store, id: ClipId) f32 {
    if (store.clip_pool.get(id)) |c| return c.lengthBeats();
    return 0;
}

fn pushColumnDelete(store: *model.Store, req: session_types.UndoRequest) !void {
    var audio: [max_scenes]AudioClipSnapshot = undefined;
    var note_lists: [max_scenes][]const undo_mod.Note = undefined;
    var clips: [max_scenes]undo_mod.ClipSlotData = undefined;
    var captured: usize = 0;
    errdefer {
        for (req.track_clips) |snapshot| {
            store.clip_pool.release(snapshot.clip, &store.sample_store);
        }
    }
    errdefer {
        for (0..captured) |i| {
            audio[i].deinit();
            if (note_lists[i].len > 0) store.allocator.free(note_lists[i]);
        }
    }
    for (0..max_scenes) |s| {
        const snap = try snapshotClip(store, req.track_clips[s].clip);
        note_lists[s] = snap.notes;
        audio[s] = snap.audio;
        clips[s] = .{
            .has_clip = req.track_clips[s].has_clip,
            .length_beats = req.track_clips[s].length_beats,
            .name = clipName(store, req.track_clips[s].clip),
        };
        captured += 1;
    }
    const notes_owned = try store.allocator.alloc([]const undo_mod.Note, max_scenes);
    @memcpy(notes_owned, note_lists[0..]);
    store.undo_history.push(.{
        .track_delete = .{
            .track_index = req.track,
            .track_data = .{
                .name = req.track_data.name,
                .volume = req.track_data.volume,
                .pan = req.track_data.pan,
                .mute = req.track_data.mute,
                .solo = req.track_data.solo,
            },
            .clips = clips,
            .notes = notes_owned,
            .audio = audio,
        },
    });
    for (0..max_scenes) |s| store.clip_pool.release(req.track_clips[s].clip, &store.sample_store);
}

fn pushRowDelete(store: *model.Store, req: session_types.UndoRequest) !void {
    var audio: [max_tracks]AudioClipSnapshot = undefined;
    var note_lists: [max_tracks][]const undo_mod.Note = undefined;
    var clips: [max_tracks]undo_mod.ClipSlotData = undefined;
    var captured: usize = 0;
    errdefer {
        for (req.scene_clips) |snapshot| {
            store.clip_pool.release(snapshot.clip, &store.sample_store);
        }
    }
    errdefer {
        for (0..captured) |i| {
            audio[i].deinit();
            if (note_lists[i].len > 0) store.allocator.free(note_lists[i]);
        }
    }
    for (0..max_tracks) |t| {
        const snap = try snapshotClip(store, req.scene_clips[t].clip);
        note_lists[t] = snap.notes;
        audio[t] = snap.audio;
        clips[t] = .{
            .has_clip = req.scene_clips[t].has_clip,
            .length_beats = req.scene_clips[t].length_beats,
            .name = clipName(store, req.scene_clips[t].clip),
        };
        captured += 1;
    }
    const notes_owned = try store.allocator.alloc([]const undo_mod.Note, max_tracks);
    @memcpy(notes_owned, note_lists[0..]);
    store.undo_history.push(.{
        .scene_delete = .{
            .scene_index = req.scene,
            .scene_data = .{ .name = req.scene_data.name },
            .clips = clips,
            .notes = notes_owned,
            .audio = audio,
        },
    });
    for (0..max_tracks) |t| store.clip_pool.release(req.scene_clips[t].clip, &store.sample_store);
}

// ── Command execution ────────────────────────────────────────────────────────

fn executeCommand(store: *model.Store, cmd: *const undo_mod.Command, comptime direction: Direction) void {
    switch (cmd.*) {
        .clip_create => |c| {
            if (direction == .undo) {
                releaseSlotClip(store, c.track, c.scene);
            } else {
                restoreEmptyMidi(store, c.track, c.scene, c.length_beats);
            }
        },
        .clip_delete => |c| {
            if (direction == .undo) {
                restoreSlotFromSnapshot(store, c.track, c.scene, true, c.length_beats, c.name, c.notes, &c.audio);
            } else {
                releaseSlotClip(store, c.track, c.scene);
            }
        },
        .clip_paste => |c| {
            const slot = if (direction == .undo) c.old_clip else c.new_clip;
            const note_slice = if (direction == .undo) c.old_notes else c.new_notes;
            const audio = if (direction == .undo) &c.old_audio else &c.new_audio;
            restoreSlotFromSnapshot(store, c.track, c.scene, slot.has_clip, slot.length_beats, slot.name, note_slice, audio);
        },
        .note_add => |c| {
            const clip = ensureMidi(store, c.track, c.scene) orelse return;
            if (direction == .undo) {
                if (c.note_index < clip.notes.items.len) _ = clip.notes.orderedRemove(c.note_index);
            } else if (c.note_index <= clip.notes.items.len) {
                clip.notes.insert(clip.allocator, c.note_index, c.note) catch {
                    clip.addFullNote(c.note) catch {};
                };
            } else {
                clip.addFullNote(c.note) catch {};
            }
        },
        .note_remove => |c| {
            const clip = ensureMidi(store, c.track, c.scene) orelse return;
            if (direction == .undo) {
                clip.notes.insert(clip.allocator, c.note_index, c.note) catch {
                    clip.addFullNote(c.note) catch {};
                };
            } else if (c.note_index < clip.notes.items.len) {
                _ = clip.notes.orderedRemove(c.note_index);
            }
        },
        .note_move => |c| {
            const clip = ensureMidi(store, c.track, c.scene) orelse return;
            if (c.note_index < clip.notes.items.len) {
                clip.notes.items[c.note_index].start = if (direction == .undo) c.old_start else c.new_start;
                clip.notes.items[c.note_index].pitch = if (direction == .undo) c.old_pitch else c.new_pitch;
            }
        },
        .note_resize => |c| {
            const clip = ensureMidi(store, c.track, c.scene) orelse return;
            if (c.note_index < clip.notes.items.len) {
                clip.notes.items[c.note_index].duration = if (direction == .undo) c.old_duration else c.new_duration;
            }
        },
        .note_batch => |c| {
            const clip = ensureMidi(store, c.track, c.scene) orelse return;
            if (direction == .undo) {
                const remove_count = @min(c.notes.len, clip.notes.items.len);
                clip.notes.shrinkRetainingCapacity(clip.notes.items.len - remove_count);
            } else {
                for (c.notes) |note| clip.addFullNote(note) catch {};
            }
        },
        .notes_replace => |c| {
            const clip = ensureMidi(store, c.track, c.scene) orelse return;
            const note_slice = if (direction == .undo) c.old_notes else c.new_notes;
            midi_history.replaceNotes(clip, note_slice);
            const timing = if (direction == .undo) c.old_timing else c.new_timing;
            midi_history.applyTiming(clip, timing);
        },
        .track_add => |c| {
            if (direction == .undo) {
                if (store.session.track_count > 1) {
                    const idx = store.session.track_count - 1;
                    for (0..max_scenes) |s| releaseSlotClip(store, idx, s);
                    store.session.track_count -= 1;
                    if (store.arrangement.tracks.items.len > 0) {
                        const last = store.arrangement.tracks.items.len - 1;
                        store.arrangement.tracks.items[last].deinit(
                            store.allocator,
                            store.arrangement.clip_pool,
                            store.arrangement.sample_store,
                        );
                        _ = store.arrangement.tracks.orderedRemove(last);
                    }
                }
            } else {
                if (store.session.track_count < max_tracks) {
                    store.session.tracks[store.session.track_count] = .{};
                    store.session.tracks[store.session.track_count].name = c.name;
                    const color = trackColor(store.session.track_count);
                    arr_ops.createTrack(&store.arrangement, store.session.track_count, c.name.get(), color) catch {};
                    store.session.track_count += 1;
                }
            }
        },
        .track_rename => |c| {
            store.session.tracks[c.track_index].name = if (direction == .undo) c.old_name else c.new_name;
        },
        .track_volume => |c| {
            store.session.tracks[c.track_index].volume = if (direction == .undo) c.old_volume else c.new_volume;
        },
        .track_mute => |c| {
            store.session.tracks[c.track_index].mute = if (direction == .undo) c.old_mute else c.new_mute;
        },
        .track_solo => |c| {
            store.session.tracks[c.track_index].solo = if (direction == .undo) c.old_solo else c.new_solo;
        },
        .scene_add => |c| {
            if (direction == .undo) {
                if (store.session.scene_count > 1) store.session.scene_count -= 1;
            } else if (store.session.scene_count < max_scenes) {
                store.session.scenes[store.session.scene_count] = .{};
                store.session.scenes[store.session.scene_count].name = c.name;
                store.session.scene_count += 1;
            }
        },
        .scene_rename => |c| {
            store.session.scenes[c.scene_index].name = if (direction == .undo) c.old_name else c.new_name;
        },
        .clip_rename => |c| {
            const name = if (direction == .undo) c.old_name else c.new_name;
            if (store.slotClip(c.track, c.scene)) |clip| clip.name = name;
        },
        .bpm_change, .quantize_change, .plugin_state => {
            // Owned by chrome / plugin host — not applied from the document layer.
        },
        .clip_move => |c| {
            moveClipPayloads(store, c.moves, direction == .undo);
        },
        .clip_resize => |c| {
            const length = if (direction == .undo) c.old_length else c.new_length;
            if (store.slotClip(c.track, c.scene)) |clip| {
                switch (clip.content) {
                    .midi => |*m| m.length_beats = length,
                    .audio => |*a| a.length_beats = length,
                }
            }
        },
        .arrangement_edit => |*c| {
            arr_undo.execute(&store.arrangement, c, if (direction == .undo) .undo else .redo);
        },
        .arrangement_track_add => |c| {
            arr_undo.executeTrackAdd(&store.arrangement, c, if (direction == .undo) .undo else .redo);
        },
        .arrangement_track_reorder => |c| {
            if (direction == .undo) {
                arr_ops.reorderTrack(&store.arrangement, c.to, c.from);
            } else {
                arr_ops.reorderTrack(&store.arrangement, c.from, c.to);
            }
        },
        .track_delete => |c| {
            if (direction == .undo) {
                insertTrack(store, &c);
            } else {
                deleteTrack(store, c.track_index);
            }
        },
        .scene_delete => |c| {
            if (direction == .undo) {
                insertScene(store, &c);
            } else {
                deleteScene(store, c.scene_index);
            }
        },
    }
}

fn trackColor(track: usize) [4]f32 {
    const colors = [_][4]f32{
        .{ 0.85, 0.35, 0.30, 1 },
        .{ 0.35, 0.55, 0.90, 1 },
        .{ 0.40, 0.75, 0.45, 1 },
        .{ 0.90, 0.70, 0.30, 1 },
        .{ 0.65, 0.45, 0.85, 1 },
        .{ 0.40, 0.80, 0.80, 1 },
        .{ 0.90, 0.50, 0.65, 1 },
        .{ 0.55, 0.55, 0.60, 1 },
    };
    return colors[track % colors.len];
}

fn releaseSlotClip(store: *model.Store, track: usize, scene: usize) void {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return;
    const slot = &store.session.clips[track][scene];
    if (!slot.clip.isNone()) {
        store.clip_pool.release(slot.clip, &store.sample_store);
    }
    slot.* = .{};
    store.session.clip_selected[track][scene] = false;
}

fn restoreEmptyMidi(store: *model.Store, track: usize, scene: usize, length_beats: f32) void {
    releaseSlotClip(store, track, scene);
    if (track >= max_tracks or scene >= max_scenes) return;
    var piano = notes.PianoRollClip.init(store.allocator);
    if (length_beats > 0) piano.length_beats = length_beats;
    const id = store.clip_pool.addMidi(piano) catch {
        piano.deinit();
        return;
    };
    store.clip_pool.retain(id);
    store.session.clips[track][scene] = .{ .state = .stopped, .clip = id };
}

fn ensureMidi(store: *model.Store, track: usize, scene: usize) ?*notes.PianoRollClip {
    if (store.slotMidiClip(track, scene)) |p| return p;
    restoreEmptyMidi(store, track, scene, 0);
    return store.slotMidiClip(track, scene);
}

fn restoreSlotFromSnapshot(
    store: *model.Store,
    track: usize,
    scene: usize,
    has_clip: bool,
    length_beats: f32,
    name: session_types.NameField,
    note_slice: []const notes.Note,
    audio: *const AudioClipSnapshot,
) void {
    releaseSlotClip(store, track, scene);
    if (!has_clip) return;
    if (audio.clip.hasAudio()) {
        var a = audio_clip_types.AudioClip.init(store.allocator);
        if (length_beats > 0) a.length_beats = length_beats;
        const id = store.clip_pool.addAudio(a) catch {
            a.deinit(&store.sample_store);
            return;
        };
        store.clip_pool.retain(id);
        store.session.clips[track][scene] = .{ .state = .stopped, .clip = id };
        if (store.clip_pool.get(id)) |pooled| {
            audio.apply(&pooled.content.audio) catch {};
            if (length_beats > 0) pooled.content.audio.length_beats = length_beats;
            pooled.name = name;
        }
    } else {
        restoreEmptyMidi(store, track, scene, length_beats);
        if (store.slotMidiClip(track, scene)) |p| {
            p.clear();
            for (note_slice) |note| p.addFullNote(note) catch {};
            if (length_beats > 0) p.length_beats = length_beats;
        }
        if (store.slotClip(track, scene)) |c| c.name = name;
    }
}

fn moveClipPayloads(store: *model.Store, moves: []const undo_mod.command.ClipMoveCmd.ClipMove, reverse: bool) void {
    var slots: [max_tracks * max_scenes]session_types.ClipSlot = undefined;
    for (moves, 0..) |move, i| {
        const src_track = if (reverse) move.dst_track else move.src_track;
        const src_scene = if (reverse) move.dst_scene else move.src_scene;
        slots[i] = store.session.clips[src_track][src_scene];
        store.session.clips[src_track][src_scene] = .{};
    }
    for (moves, 0..) |move, i| {
        const dst_track = if (reverse) move.src_track else move.dst_track;
        const dst_scene = if (reverse) move.src_scene else move.dst_scene;
        releaseSlotClip(store, dst_track, dst_scene);
        store.session.clips[dst_track][dst_scene] = slots[i];
    }
}

fn deleteTrack(store: *model.Store, track: usize) void {
    if (store.session.track_count <= 1 or track >= store.session.track_count) return;
    for (0..max_scenes) |s| releaseSlotClip(store, track, s);
    for (track..store.session.track_count - 1) |t| {
        store.session.tracks[t] = store.session.tracks[t + 1];
        for (0..max_scenes) |s| {
            store.session.clips[t][s] = store.session.clips[t + 1][s];
            store.session.clip_selected[t][s] = store.session.clip_selected[t + 1][s];
            store.session.clips[t + 1][s] = .{};
        }
    }
    for (0..max_scenes) |s| {
        store.session.clips[store.session.track_count - 1][s] = .{};
        store.session.clip_selected[store.session.track_count - 1][s] = false;
    }
    store.session.track_count -= 1;
    if (track < store.arrangement.tracks.items.len) {
        store.arrangement.tracks.items[track].deinit(
            store.allocator,
            store.arrangement.clip_pool,
            store.arrangement.sample_store,
        );
        _ = store.arrangement.tracks.orderedRemove(track);
    }
    if (store.session.primary_track >= store.session.track_count) {
        store.session.primary_track = store.session.track_count - 1;
    }
}

fn insertTrack(store: *model.Store, cmd: *const undo_mod.command.TrackDeleteCmd) void {
    if (store.session.track_count >= max_tracks) return;
    var t = store.session.track_count;
    while (t > cmd.track_index) : (t -= 1) {
        store.session.tracks[t] = store.session.tracks[t - 1];
        for (0..max_scenes) |s| {
            store.session.clips[t][s] = store.session.clips[t - 1][s];
            store.session.clip_selected[t][s] = store.session.clip_selected[t - 1][s];
            store.session.clips[t - 1][s] = .{};
        }
    }
    store.session.tracks[cmd.track_index] = .{
        .name = cmd.track_data.name,
        .volume = cmd.track_data.volume,
        .pan = cmd.track_data.pan,
        .mute = cmd.track_data.mute,
        .solo = cmd.track_data.solo,
    };
    for (0..max_scenes) |s| {
        store.session.clip_selected[cmd.track_index][s] = false;
        const note_slice: []const notes.Note = if (s < cmd.notes.len) cmd.notes[s] else &.{};
        restoreSlotFromSnapshot(
            store,
            cmd.track_index,
            s,
            cmd.clips[s].has_clip,
            cmd.clips[s].length_beats,
            cmd.clips[s].name,
            note_slice,
            &cmd.audio[s],
        );
    }
    store.session.track_count += 1;
    const color = trackColor(cmd.track_index);
    arr_ops.createTrack(&store.arrangement, cmd.track_index, cmd.track_data.name.get(), color) catch {};
    // createTrack appends; if we need a specific index, reorder.
    if (store.arrangement.tracks.items.len > 0) {
        const last = store.arrangement.tracks.items.len - 1;
        if (last != cmd.track_index and cmd.track_index <= last) {
            arr_ops.reorderTrack(&store.arrangement, last, cmd.track_index);
        }
    }
}

fn deleteScene(store: *model.Store, scene: usize) void {
    if (store.session.scene_count <= 1 or scene >= store.session.scene_count) return;
    for (0..max_tracks) |t| releaseSlotClip(store, t, scene);
    for (scene..store.session.scene_count - 1) |s| {
        store.session.scenes[s] = store.session.scenes[s + 1];
        for (0..max_tracks) |t| {
            store.session.clips[t][s] = store.session.clips[t][s + 1];
            store.session.clip_selected[t][s] = store.session.clip_selected[t][s + 1];
            store.session.clips[t][s + 1] = .{};
        }
    }
    for (0..max_tracks) |t| {
        store.session.clips[t][store.session.scene_count - 1] = .{};
        store.session.clip_selected[t][store.session.scene_count - 1] = false;
    }
    store.session.scene_count -= 1;
    if (store.session.primary_scene >= store.session.scene_count) {
        store.session.primary_scene = store.session.scene_count - 1;
    }
}

fn insertScene(store: *model.Store, cmd: *const undo_mod.command.SceneDeleteCmd) void {
    if (store.session.scene_count >= max_scenes) return;
    var s = store.session.scene_count;
    while (s > cmd.scene_index) : (s -= 1) {
        store.session.scenes[s] = store.session.scenes[s - 1];
        for (0..max_tracks) |t| {
            store.session.clips[t][s] = store.session.clips[t][s - 1];
            store.session.clip_selected[t][s] = store.session.clip_selected[t][s - 1];
            store.session.clips[t][s - 1] = .{};
        }
    }
    store.session.scenes[cmd.scene_index] = .{ .name = cmd.scene_data.name };
    for (0..max_tracks) |t| {
        store.session.clip_selected[t][cmd.scene_index] = false;
        const note_slice: []const notes.Note = if (t < cmd.notes.len) cmd.notes[t] else &.{};
        restoreSlotFromSnapshot(
            store,
            t,
            cmd.scene_index,
            cmd.clips[t].has_clip,
            cmd.clips[t].length_beats,
            cmd.clips[t].name,
            note_slice,
            &cmd.audio[t],
        );
    }
    store.session.scene_count += 1;
}

fn notesEqual(a: []const notes.Note, b: []const notes.Note) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.pitch != right.pitch or left.start != right.start or
            left.duration != right.duration or left.velocity != right.velocity or
            left.release_velocity != right.release_velocity) return false;
    }
    return true;
}

fn timingsEqual(a: notes.ClipTiming, b: notes.ClipTiming) bool {
    return a.length == b.length and a.play_start == b.play_start and
        a.loop_start == b.loop_start and a.loop_end == b.loop_end;
}

test "session clip create undo redo" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();

    const session_cmd = @import("cmd_session.zig");
    session_cmd.createClip(&store, 0, 0, 4);
    try std.testing.expect(!store.session.clips[0][0].clip.isNone());
    try std.testing.expect(canUndo(&store));

    try std.testing.expect(undo(&store));
    try std.testing.expect(store.session.clips[0][0].clip.isNone());
    try std.testing.expect(canRedo(&store));

    try std.testing.expect(redo(&store));
    try std.testing.expect(!store.session.clips[0][0].clip.isNone());
}

test "mixer mute and volume undo" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();

    const session_cmd = @import("cmd_session.zig");
    const old_vol = store.session.tracks[0].volume;
    session_cmd.setTrackVolume(&store, 0, 0.25);
    session_cmd.toggleTrackMute(&store, 0);
    try std.testing.expect(store.session.tracks[0].mute);
    try std.testing.expect(canUndo(&store));

    try std.testing.expect(undo(&store));
    try std.testing.expect(!store.session.tracks[0].mute);
    try std.testing.expect(undo(&store));
    try std.testing.expectApproxEqAbs(old_vol, store.session.tracks[0].volume, 0.0001);
}
