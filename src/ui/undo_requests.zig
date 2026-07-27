const undo = @import("../undo/root.zig");
const session_constants = @import("../session/constants.zig");
const session_types = @import("../session/types.zig");
const audio_clip_types = @import("../session/audio_clip.zig");
const clip_pool_mod = @import("../session/clip_pool.zig");
const State = @import("state.zig").State;

const NameField = session_types.NameField;

const AudioClip = audio_clip_types.AudioClip;
const AudioClipSnapshot = audio_clip_types.AudioClipSnapshot;
const ClipId = clip_pool_mod.ClipId;

const max_tracks = session_constants.max_tracks;
const max_scenes = session_constants.max_scenes;

/// Notes + audio snapshot captured from a pooled clip for undo. A MIDI clip
/// yields notes with an empty audio snapshot; an audio clip yields the reverse.
/// The audio snapshot's `hasAudio()` decides the kind on rebuild.
const ClipContentSnapshot = struct {
    notes: []const undo.Note,
    audio: AudioClipSnapshot,
};

/// Capture the content of the clip a handle references (empty snapshot when the
/// handle is stale). The returned `notes` slice is owned by the caller / undo
/// command. Returns error only if the audio snapshot allocation fails.
fn snapshotClip(state: *State, id: ClipId) !ClipContentSnapshot {
    if (state.clip_pool.get(id)) |c| {
        switch (c.content) {
            .audio => |*a| {
                const audio = try AudioClipSnapshot.capture(a, &state.sample_store);
                return .{ .notes = &.{}, .audio = audio };
            },
            .midi => |*m| {
                const notes = state.allocator.dupe(undo.Note, m.notes.items) catch &.{};
                return .{ .notes = notes, .audio = try emptyAudioSnapshot(state) };
            },
        }
    }
    return .{ .notes = &.{}, .audio = try emptyAudioSnapshot(state) };
}

fn emptyAudioSnapshot(state: *State) !AudioClipSnapshot {
    var empty = AudioClip.init(state.allocator);
    defer empty.deinit(&state.sample_store);
    return try AudioClipSnapshot.capture(&empty, &state.sample_store);
}

pub fn processUndoRequests(state: *State) void {
    for (state.session.undo_requests[0..state.session.undo_request_count]) |req| {
        switch (req.kind) {
            .clip_create => {
                state.undo_history.push(.{
                    .clip_create = .{
                        .track = req.track,
                        .scene = req.scene,
                        .length_beats = req.length_beats,
                    },
                });
            },
            .clip_delete => {
                // The deleted slot was cleared by session ops but its pooled
                // clip is still alive via `req.old_clip.clip`; snapshot its
                // content for undo, then release the reference.
                const snap = snapshotClip(state, req.old_clip.clip) catch {
                    state.clip_pool.release(req.old_clip.clip, &state.sample_store);
                    continue;
                };
                state.undo_history.push(.{
                    .clip_delete = .{
                        .track = req.track,
                        .scene = req.scene,
                        .length_beats = req.length_beats,
                        .name = clipName(state, req.old_clip.clip),
                        .notes = snap.notes,
                        .audio = snap.audio,
                    },
                });
                state.clip_pool.release(req.old_clip.clip, &state.sample_store);
            },
            .clip_paste => {
                // New content = the freshly-pasted clip now in the slot; old
                // content = the clip the paste displaced (`req.old_clip.clip`,
                // still alive, released after capture).
                const new_id = state.session.clips[req.track][req.scene].clip;
                const old_len = clipLength(state, req.old_clip.clip);
                var old_snap = snapshotClip(state, req.old_clip.clip) catch {
                    state.clip_pool.release(req.old_clip.clip, &state.sample_store);
                    continue;
                };
                const new_snap = snapshotClip(state, new_id) catch {
                    old_snap.audio.deinit();
                    if (old_snap.notes.len > 0) state.allocator.free(old_snap.notes);
                    state.clip_pool.release(req.old_clip.clip, &state.sample_store);
                    continue;
                };
                state.undo_history.push(.{
                    .clip_paste = .{
                        .track = req.track,
                        .scene = req.scene,
                        .old_clip = .{
                            .has_clip = req.old_clip.state != .empty,
                            .length_beats = old_len,
                            .name = clipName(state, req.old_clip.clip),
                        },
                        .new_clip = .{
                            .has_clip = true,
                            .length_beats = req.length_beats,
                            .name = clipName(state, new_id),
                        },
                        .old_notes = old_snap.notes,
                        .new_notes = new_snap.notes,
                        .old_audio = old_snap.audio,
                        .new_audio = new_snap.audio,
                    },
                });
                state.clip_pool.release(req.old_clip.clip, &state.sample_store);
            },
            .track_add => {
                const track = &state.session.tracks[req.track];
                state.undo_history.push(.{
                    .track_add = .{
                        .track_index = req.track,
                        .name = track.name,
                    },
                });
            },
            .track_delete => {
                pushColumnDelete(state, req) catch {};
            },
            .scene_add => {
                const scene = &state.session.scenes[req.scene];
                state.undo_history.push(.{
                    .scene_add = .{
                        .scene_index = req.scene,
                        .name = scene.name,
                    },
                });
            },
            .scene_delete => {
                pushRowDelete(state, req) catch {};
            },
            .track_volume => {
                state.undo_history.push(.{
                    .track_volume = .{
                        .track_index = req.track,
                        .old_volume = req.old_volume,
                        .new_volume = req.new_volume,
                    },
                });
            },
            .scene_rename => {
                state.undo_history.push(.{
                    .scene_rename = .{
                        .scene_index = req.scene,
                        .old_name = req.old_name,
                        .new_name = req.new_name,
                    },
                });
            },
            .clip_rename => {
                // The live clip's name was already updated by session ops.
                state.undo_history.push(.{
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
    state.session.undo_request_count = 0; // Clear processed requests

    // Clip moves: the slots (and their ClipIds) were already moved by session
    // ops; content travels with the handle, so only the undo record remains.
    if (state.session.clip_move_count > 0) {
        if (state.allocator.alloc(undo.command.ClipMoveCmd.ClipMove, state.session.clip_move_count)) |moves| {
            for (state.session.clip_move_requests[0..state.session.clip_move_count], 0..) |req, i| {
                moves[i] = .{
                    .src_track = req.src_track,
                    .src_scene = req.src_scene,
                    .dst_track = req.dst_track,
                    .dst_scene = req.dst_scene,
                };
            }
            state.undo_history.push(.{ .clip_move = .{ .moves = moves } });
        } else |_| {}
        state.session.clip_move_count = 0;
    }
    state.session.pending_piano_moves = false;
    state.session.pending_piano_copies = false;
    state.session.piano_copy_count = 0;
}

fn clipName(state: *State, id: ClipId) NameField {
    if (state.clip_pool.get(id)) |c| return c.name;
    return .{};
}

fn clipLength(state: *State, id: ClipId) f32 {
    if (state.clip_pool.get(id)) |c| return c.lengthBeats();
    return 0;
}

/// Build a `track_delete` undo command from the ClipIds captured at delete time
/// (`req.track_clips[s].clip`) and release those pooled clips.
fn pushColumnDelete(state: *State, req: anytype) !void {
    var audio: [max_scenes]AudioClipSnapshot = undefined;
    var notes: [max_scenes][]const undo.Note = undefined;
    var clips: [max_scenes]undo.ClipSlotData = undefined;
    var captured: usize = 0;
    errdefer {
        for (0..captured) |i| {
            audio[i].deinit();
            if (notes[i].len > 0) state.allocator.free(notes[i]);
        }
    }
    for (0..max_scenes) |s| {
        const snap = try snapshotClip(state, req.track_clips[s].clip);
        notes[s] = snap.notes;
        audio[s] = snap.audio;
        clips[s] = .{ .has_clip = req.track_clips[s].has_clip, .length_beats = req.track_clips[s].length_beats };
        captured += 1;
    }
    const notes_owned = try state.allocator.alloc([]const undo.Note, max_scenes);
    @memcpy(notes_owned, notes[0..]);
    state.undo_history.push(.{
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
    for (0..max_scenes) |s| state.clip_pool.release(req.track_clips[s].clip, &state.sample_store);
}

fn pushRowDelete(state: *State, req: anytype) !void {
    var audio: [max_tracks]AudioClipSnapshot = undefined;
    var notes: [max_tracks][]const undo.Note = undefined;
    var clips: [max_tracks]undo.ClipSlotData = undefined;
    var captured: usize = 0;
    errdefer {
        for (0..captured) |i| {
            audio[i].deinit();
            if (notes[i].len > 0) state.allocator.free(notes[i]);
        }
    }
    for (0..max_tracks) |t| {
        const snap = try snapshotClip(state, req.scene_clips[t].clip);
        notes[t] = snap.notes;
        audio[t] = snap.audio;
        clips[t] = .{ .has_clip = req.scene_clips[t].has_clip, .length_beats = req.scene_clips[t].length_beats };
        captured += 1;
    }
    const notes_owned = try state.allocator.alloc([]const undo.Note, max_tracks);
    @memcpy(notes_owned, notes[0..]);
    state.undo_history.push(.{
        .scene_delete = .{
            .scene_index = req.scene,
            .scene_data = .{ .name = req.scene_data.name },
            .clips = clips,
            .notes = notes_owned,
            .audio = audio,
        },
    });
    for (0..max_tracks) |t| state.clip_pool.release(req.scene_clips[t].clip, &state.sample_store);
}

pub fn processPianoRollUndoRequests(state: *State) void {
    for (state.piano_state.undo_requests[0..state.piano_state.undo_request_count]) |req| {
        switch (req.kind) {
            .note_add => {
                state.undo_history.push(.{
                    .note_add = .{
                        .track = req.track,
                        .scene = req.scene,
                        .note = req.note,
                        .note_index = req.note_index,
                    },
                });
            },
            .note_remove => {
                state.undo_history.push(.{
                    .note_remove = .{
                        .track = req.track,
                        .scene = req.scene,
                        .note = req.note,
                        .note_index = req.note_index,
                    },
                });
            },
            .note_move => {
                state.undo_history.push(.{
                    .note_move = .{
                        .track = req.track,
                        .scene = req.scene,
                        .note_index = req.note_index,
                        .old_start = req.old_start,
                        .old_pitch = req.old_pitch,
                        .new_start = req.new_start,
                        .new_pitch = req.new_pitch,
                    },
                });
            },
            .note_resize => {
                state.undo_history.push(.{
                    .note_resize = .{
                        .track = req.track,
                        .scene = req.scene,
                        .note_index = req.note_index,
                        .old_duration = req.old_duration,
                        .new_duration = req.new_duration,
                    },
                });
            },
            .clip_resize => {
                // The live pooled clip length was already updated by the piano
                // roll (it edits the clip directly); only record the command.
                state.undo_history.push(.{
                    .clip_resize = .{
                        .track = req.track,
                        .scene = req.scene,
                        .old_length = req.old_duration,
                        .new_length = req.new_duration,
                    },
                });
            },
            .notes_replace => {
                state.undo_history.push(.{
                    .notes_replace = .{
                        .track = req.track,
                        .scene = req.scene,
                        .old_notes = req.old_notes,
                        .new_notes = req.new_notes,
                        .old_timing = req.old_timing,
                        .new_timing = req.new_timing,
                    },
                });
            },
        }
    }
    state.piano_state.undo_request_count = 0; // Clear processed requests
}
