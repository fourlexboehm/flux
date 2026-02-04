const undo = @import("../undo/root.zig");
const session_constants = @import("session_view/constants.zig");
const piano_roll_types = @import("piano_roll/types.zig");
const State = @import("state.zig").State;

const max_tracks = session_constants.max_tracks;
const max_scenes = session_constants.max_scenes;

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
                // Capture notes before they're lost (they may already be cleared)
                const notes = state.allocator.dupe(
                    undo.Note,
                    state.piano_clips[req.track][req.scene].notes.items,
                ) catch &.{};
                state.undo_history.push(.{
                    .clip_delete = .{
                        .track = req.track,
                        .scene = req.scene,
                        .length_beats = req.length_beats,
                        .notes = notes,
                    },
                });
                // Clear the piano clip notes
                state.piano_clips[req.track][req.scene].clear();
            },
            .clip_paste => {
                const old_notes = state.allocator.dupe(
                    undo.Note,
                    state.piano_clips[req.track][req.scene].notes.items,
                ) catch &.{};
                const new_notes = state.allocator.dupe(
                    undo.Note,
                    state.piano_clips[req.src_track][req.src_scene].notes.items,
                ) catch &.{};
                state.undo_history.push(.{
                    .clip_paste = .{
                        .track = req.track,
                        .scene = req.scene,
                        .old_clip = .{
                            .has_clip = req.old_clip.state != .empty,
                            .length_beats = req.old_clip.length_beats,
                        },
                        .new_clip = .{
                            .has_clip = req.length_beats > 0,
                            .length_beats = req.length_beats,
                        },
                        .old_notes = old_notes,
                        .new_notes = new_notes,
                    },
                });
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
                var clips: [max_scenes]undo.ClipSlotData = undefined;
                for (0..max_scenes) |s| {
                    clips[s] = .{
                        .has_clip = req.track_clips[s].has_clip,
                        .length_beats = req.track_clips[s].length_beats,
                    };
                }

                if (state.allocator.alloc([]const undo.Note, max_scenes)) |notes| {
                    for (0..max_scenes) |s| {
                        if (req.track_clips[s].has_clip) {
                            const note_items = state.piano_clips[req.track][s].notes.items;
                            notes[s] = state.allocator.dupe(undo.Note, note_items) catch &.{};
                        } else {
                            notes[s] = &.{};
                        }
                    }
                    state.undo_history.push(.{
                        .track_delete = .{
                            .track_index = req.track,
                            .track_data = .{
                                .name = req.track_data.name,
                                .volume = req.track_data.volume,
                                .mute = req.track_data.mute,
                                .solo = req.track_data.solo,
                            },
                            .clips = clips,
                            .notes = notes,
                        },
                    });
                } else |_| {}

                const old_track_count = @min(state.session.track_count + 1, max_tracks);
                state.deleteTrackPianoClips(req.track, old_track_count);
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
                var clips: [max_tracks]undo.ClipSlotData = undefined;
                for (0..max_tracks) |t| {
                    clips[t] = .{
                        .has_clip = req.scene_clips[t].has_clip,
                        .length_beats = req.scene_clips[t].length_beats,
                    };
                }

                if (state.allocator.alloc([]const undo.Note, max_tracks)) |notes| {
                    for (0..max_tracks) |t| {
                        if (req.scene_clips[t].has_clip) {
                            const note_items = state.piano_clips[t][req.scene].notes.items;
                            notes[t] = state.allocator.dupe(undo.Note, note_items) catch &.{};
                        } else {
                            notes[t] = &.{};
                        }
                    }
                    state.undo_history.push(.{
                        .scene_delete = .{
                            .scene_index = req.scene,
                            .scene_data = .{
                                .name = req.scene_data.name,
                            },
                            .clips = clips,
                            .notes = notes,
                        },
                    });
                } else |_| {}

                const old_scene_count = @min(state.session.scene_count + 1, max_scenes);
                state.deleteScenePianoClips(req.scene, old_scene_count);
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
        }
    }
    state.session.undo_request_count = 0; // Clear processed requests

    // Process clip move requests (separate since it involves multiple clips)
    if (state.session.clip_move_count > 0) {
        // First, move the piano clips (session_view already moved the clip slots)
        if (state.session.pending_piano_moves) {
            for (state.session.clip_move_requests[0..state.session.clip_move_count]) |req| {
                // Swap piano clips from src to dst
                const temp = state.piano_clips[req.src_track][req.src_scene];
                state.piano_clips[req.dst_track][req.dst_scene] = temp;
                state.piano_clips[req.src_track][req.src_scene] = piano_roll_types.PianoRollClip.init(state.allocator);
            }
            state.session.pending_piano_moves = false;
        }

        // Allocate and copy the moves for undo
        if (state.allocator.alloc(undo.command.ClipMoveCmd.ClipMove, state.session.clip_move_count)) |moves| {
            for (state.session.clip_move_requests[0..state.session.clip_move_count], 0..) |req, i| {
                moves[i] = .{
                    .src_track = req.src_track,
                    .src_scene = req.src_scene,
                    .dst_track = req.dst_track,
                    .dst_scene = req.dst_scene,
                };
            }
            state.undo_history.push(.{
                .clip_move = .{
                    .moves = moves,
                },
            });
        } else |_| {}
        state.session.clip_move_count = 0;
    }

    // Process piano clip copy requests (from session view paste)
    if (state.session.pending_piano_copies and state.session.piano_copy_count > 0) {
        var temp_clips: [max_tracks * max_scenes]piano_roll_types.PianoRollClip = undefined;
        var temp_valid: [max_tracks * max_scenes]bool = undefined;
        for (state.session.piano_copy_requests[0..state.session.piano_copy_count], 0..) |req, i| {
            if (req.src_track == req.dst_track and req.src_scene == req.dst_scene) {
                temp_valid[i] = false;
                continue;
            }
            temp_valid[i] = true;
            temp_clips[i] = piano_roll_types.PianoRollClip.init(state.allocator);
            temp_clips[i].copyFrom(&state.piano_clips[req.src_track][req.src_scene]);
            temp_clips[i].length_beats = state.session.clips[req.dst_track][req.dst_scene].length_beats;
        }

        for (state.session.piano_copy_requests[0..state.session.piano_copy_count], 0..) |req, i| {
            if (!temp_valid[i]) continue;
            state.piano_clips[req.dst_track][req.dst_scene].deinit();
            state.piano_clips[req.dst_track][req.dst_scene] = temp_clips[i];
        }

        state.session.pending_piano_copies = false;
        state.session.piano_copy_count = 0;
    }
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
                // Also sync the session clip length
                state.session.clips[req.track][req.scene].length_beats = req.new_duration;
                state.undo_history.push(.{
                    .clip_resize = .{
                        .track = req.track,
                        .scene = req.scene,
                        .old_length = req.old_duration,
                        .new_length = req.new_duration,
                    },
                });
            },
        }
    }
    state.piano_state.undo_request_count = 0; // Clear processed requests
}
