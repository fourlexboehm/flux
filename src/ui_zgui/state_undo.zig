//! Undo/redo command application for legacy zgui State.
const std = @import("std");
const undo = @import("../undo/root.zig");
const session_view = @import("../session/types.zig");
const session_constants = @import("../session/constants.zig");
const piano_roll_types = @import("../session/notes.zig");
const audio_clip_types = @import("../session/audio_clip.zig");
const arr_types = @import("../arrangement/types.zig");
const arr_undo = @import("../arrangement/undo.zig");
const arr_ops = @import("../arrangement/ops.zig");
const state_mod = @import("state.zig");

const State = state_mod.State;
const max_tracks = session_constants.max_tracks;
const max_scenes = session_constants.max_scenes;

pub const UndoDirection = enum { undo, redo };

/// Rebuild a session slot's pooled content from an undo snapshot. The
/// snapshot's audio payload determines the kind: a loaded sample restores
/// an audio clip, otherwise a MIDI clip with the captured notes.
pub fn restoreSlotFromSnapshot(
    self: *State,
    track: usize,
    scene: usize,
    has_clip: bool,
    length_beats: f32,
    name: session_view.NameField,
    notes: []const piano_roll_types.Note,
    audio: *const audio_clip_types.AudioClipSnapshot,
) void {
    self.releaseSlotClip(track, scene);
    if (!has_clip) return;
    if (audio.clip.hasAudio()) {
        const a = self.ensureSlotAudio(track, scene) orelse return;
        audio.apply(a) catch {};
        if (length_beats > 0) a.length_beats = length_beats;
    } else {
        const p = self.ensureSlotPiano(track, scene);
        p.clear();
        for (notes) |note| p.addNote(note.pitch, note.start, note.duration) catch {};
        if (length_beats > 0) p.length_beats = length_beats;
    }
    if (self.slotClip(track, scene)) |c| c.name = name;
}

pub fn executeCommand(self: *State, cmd: *const undo.Command, comptime direction: UndoDirection) void {
    switch (cmd.*) {
        .clip_create => |c| {
            if (direction == .undo) {
                self.releaseSlotClip(c.track, c.scene);
            } else {
                self.releaseSlotClip(c.track, c.scene);
                const id = self.makeMidiClip(c.length_beats);
                if (!id.isNone()) {
                    self.session.clips[c.track][c.scene] = .{ .state = .stopped, .clip = id };
                }
            }
        },
        .clip_delete => |c| {
            if (direction == .undo) {
                restoreSlotFromSnapshot(self, c.track, c.scene, true, c.length_beats, c.name, c.notes, &c.audio);
            } else {
                self.releaseSlotClip(c.track, c.scene);
            }
        },
        .clip_paste => |c| {
            const slot = if (direction == .undo) c.old_clip else c.new_clip;
            const notes = if (direction == .undo) c.old_notes else c.new_notes;
            const audio = if (direction == .undo) &c.old_audio else &c.new_audio;
            restoreSlotFromSnapshot(self, c.track, c.scene, slot.has_clip, slot.length_beats, slot.name, notes, audio);
        },
        .note_add => |c| {
            if (direction == .undo) {
                const clip = self.ensureSlotPiano(c.track, c.scene);
                if (c.note_index < clip.notes.items.len) {
                    _ = clip.notes.orderedRemove(c.note_index);
                }
            } else {
                const clip = self.ensureSlotPiano(c.track, c.scene);
                if (c.note_index <= clip.notes.items.len) {
                    clip.notes.insert(clip.allocator, c.note_index, c.note) catch {
                        clip.addFullNote(c.note) catch {};
                    };
                } else {
                    clip.addFullNote(c.note) catch {};
                }
            }
        },
        .note_remove => |c| {
            if (direction == .undo) {
                const clip = self.ensureSlotPiano(c.track, c.scene);
                clip.notes.insert(clip.allocator, c.note_index, c.note) catch {
                    clip.addFullNote(c.note) catch {};
                };
            } else {
                const clip = self.ensureSlotPiano(c.track, c.scene);
                if (c.note_index < clip.notes.items.len) {
                    _ = clip.notes.orderedRemove(c.note_index);
                }
            }
        },
        .note_move => |c| {
            const clip = self.ensureSlotPiano(c.track, c.scene);
            if (c.note_index < clip.notes.items.len) {
                clip.notes.items[c.note_index].start = if (direction == .undo) c.old_start else c.new_start;
                clip.notes.items[c.note_index].pitch = if (direction == .undo) c.old_pitch else c.new_pitch;
            }
        },
        .note_resize => |c| {
            const clip = self.ensureSlotPiano(c.track, c.scene);
            if (c.note_index < clip.notes.items.len) {
                clip.notes.items[c.note_index].duration = if (direction == .undo) c.old_duration else c.new_duration;
            }
        },
        .note_batch => |c| {
            if (direction == .undo) {
                const clip = self.ensureSlotPiano(c.track, c.scene);
                const remove_count = @min(c.notes.len, clip.notes.items.len);
                clip.notes.shrinkRetainingCapacity(clip.notes.items.len - remove_count);
            } else {
                const clip = self.ensureSlotPiano(c.track, c.scene);
                for (c.notes) |note| {
                    clip.addFullNote(note) catch {};
                }
            }
        },
        .notes_replace => |c| {
            const clip = self.ensureSlotPiano(c.track, c.scene);
            const notes = if (direction == .undo) c.old_notes else c.new_notes;
            clip.notes.clearRetainingCapacity();
            for (notes) |note| {
                clip.addFullNote(note) catch {};
            }
            const timing = if (direction == .undo) c.old_timing else c.new_timing;
            clip.length_beats = timing.length;
            clip.play_start_beats = timing.play_start;
            clip.loop_start_beats = timing.loop_start;
            clip.loop_end_beats = timing.loop_end;
        },
        .track_add => |c| {
            if (direction == .undo) {
                if (self.session.track_count > 1) {
                    self.session.track_count -= 1;
                }
            } else {
                if (self.session.track_count < max_tracks) {
                    self.session.tracks[self.session.track_count] = .{};
                    self.session.tracks[self.session.track_count].name = c.name;
                    self.session.track_count += 1;
                }
            }
        },
        .track_rename => |c| {
            self.session.tracks[c.track_index].name = if (direction == .undo) c.old_name else c.new_name;
        },
        .track_volume => |c| {
            self.session.tracks[c.track_index].volume = if (direction == .undo) c.old_volume else c.new_volume;
        },
        .track_mute => |c| {
            self.session.tracks[c.track_index].mute = if (direction == .undo) c.old_mute else c.new_mute;
        },
        .track_solo => |c| {
            self.session.tracks[c.track_index].solo = if (direction == .undo) c.old_solo else c.new_solo;
        },
        .scene_add => |c| {
            if (direction == .undo) {
                if (self.session.scene_count > 1) {
                    self.session.scene_count -= 1;
                }
            } else {
                if (self.session.scene_count < max_scenes) {
                    self.session.scenes[self.session.scene_count] = .{};
                    self.session.scenes[self.session.scene_count].name = c.name;
                    self.session.scene_count += 1;
                }
            }
        },
        .scene_rename => |c| {
            self.session.scenes[c.scene_index].name = if (direction == .undo) c.old_name else c.new_name;
        },
        .clip_rename => |c| {
            const name = if (direction == .undo) c.old_name else c.new_name;
            if (self.slotClip(c.track, c.scene)) |clip| clip.name = name;
        },
        .bpm_change => |c| {
            self.bpm = if (direction == .undo) c.old_bpm else c.new_bpm;
        },
        .quantize_change => |c| {
            self.quantize_index = if (direction == .undo) c.old_index else c.new_index;
            self.quantize_last = if (direction == .undo) c.old_index else c.new_index;
        },
        .clip_move => |c| {
            moveClipPayloads(self, c.moves, direction == .undo);
        },
        .clip_resize => |c| {
            const length = if (direction == .undo) c.old_length else c.new_length;
            if (self.slotClip(c.track, c.scene)) |clip| {
                switch (clip.content) {
                    .midi => |*m| m.length_beats = length,
                    .audio => |*a| a.length_beats = length,
                }
            }
        },
        .plugin_state => |c| {
            self.plugin_state_restore_request = .{
                .track_index = c.track_index,
                .fx_index = c.fx_index,
                .state_data = if (direction == .undo) c.old_state else c.new_state,
            };
        },
        .arrangement_edit => |*c| {
            arr_undo.execute(&self.arrangement, c, if (direction == .undo) .undo else .redo);
        },
        .arrangement_track_add => |c| {
            arr_undo.executeTrackAdd(&self.arrangement, c, if (direction == .undo) .undo else .redo);
        },
        .arrangement_track_reorder => |c| {
            if (direction == .undo) {
                arr_ops.reorderTrack(&self.arrangement, c.to, c.from);
            } else {
                arr_ops.reorderTrack(&self.arrangement, c.from, c.to);
            }
        },
        .track_delete => |c| {
            if (direction == .undo) {
                insertTrackInState(self, &c);
            } else {
                deleteTrackInState(self, c.track_index);
            }
        },
        .scene_delete => |c| {
            if (direction == .undo) {
                insertSceneInState(self, &c);
            } else {
                deleteSceneInState(self, c.scene_index);
            }
        },
    }
}

pub fn moveClipPayloads(self: *State, moves: []const undo.command.ClipMoveCmd.ClipMove, reverse: bool) void {
    // Content travels with each slot's ClipId, so a move is just moving the
    // ClipSlot value. Lift all sources first (in case source and dest sets
    // overlap), then drop them at their destinations.
    var slots: [max_tracks * max_scenes]@TypeOf(self.session.clips[0][0]) = undefined;

    for (moves, 0..) |move, i| {
        const src_track = if (reverse) move.dst_track else move.src_track;
        const src_scene = if (reverse) move.dst_scene else move.src_scene;
        slots[i] = self.session.clips[src_track][src_scene];
        self.session.clips[src_track][src_scene] = .{}; // move out (handle carried in `slots[i]`)
    }

    for (moves, 0..) |move, i| {
        const dst_track = if (reverse) move.src_track else move.dst_track;
        const dst_scene = if (reverse) move.src_scene else move.dst_scene;
        self.releaseSlotClip(dst_track, dst_scene); // free any clip displaced at the destination
        self.session.clips[dst_track][dst_scene] = slots[i];
    }
}

pub fn deleteTrackInState(self: *State, track: usize) void {
    if (self.session.track_count <= 1) return;
    if (track >= self.session.track_count) return;

    for (0..self.session.scene_count) |s| {
        session_ops.deselectClip(&self.session, track, s);
    }
    // Release the deleted track's pooled clips before the shift overwrites
    // them (content lives in the pool, referenced by ClipId in each slot).
    for (0..max_scenes) |s| self.releaseSlotClip(track, s);
    for (track..self.session.track_count - 1) |t| {
        self.session.tracks[t] = self.session.tracks[t + 1];
        for (0..max_scenes) |s| {
            self.session.clips[t][s] = self.session.clips[t + 1][s];
            self.session.clip_selected[t][s] = self.session.clip_selected[t + 1][s];
        }
    }
    for (0..max_scenes) |s| {
        self.session.clips[self.session.track_count - 1][s] = .{}; // moved out by shift
        self.session.clip_selected[self.session.track_count - 1][s] = false;
    }
    self.session.track_count -= 1;
    if (self.session.primary_track >= self.session.track_count) {
        self.session.primary_track = self.session.track_count - 1;
    }
}

pub fn deleteSceneInState(self: *State, scene: usize) void {
    if (self.session.scene_count <= 1) return;
    if (scene >= self.session.scene_count) return;

    for (0..self.session.track_count) |t| {
        session_ops.deselectClip(&self.session, t, scene);
    }
    for (0..max_tracks) |t| self.releaseSlotClip(t, scene);
    for (scene..self.session.scene_count - 1) |s| {
        self.session.scenes[s] = self.session.scenes[s + 1];
        for (0..max_tracks) |t| {
            self.session.clips[t][s] = self.session.clips[t][s + 1];
            self.session.clip_selected[t][s] = self.session.clip_selected[t][s + 1];
        }
    }
    for (0..max_tracks) |t| {
        self.session.clips[t][self.session.scene_count - 1] = .{}; // moved out by shift
        self.session.clip_selected[t][self.session.scene_count - 1] = false;
    }
    self.session.scene_count -= 1;
    if (self.session.primary_scene >= self.session.scene_count) {
        self.session.primary_scene = self.session.scene_count - 1;
    }
}

pub fn insertTrackInState(self: *State, cmd: *const undo.command.TrackDeleteCmd) void {
    if (self.session.track_count >= max_tracks) return;

    var t = self.session.track_count;
    while (t > cmd.track_index) : (t -= 1) {
        self.session.tracks[t] = self.session.tracks[t - 1];
        for (0..max_scenes) |s| {
            // ClipId carries content, so shifting the slot shifts the clip.
            self.session.clips[t][s] = self.session.clips[t - 1][s];
            self.session.clip_selected[t][s] = self.session.clip_selected[t - 1][s];
            self.session.clips[t - 1][s] = .{}; // moved out
        }
    }

    self.session.tracks[cmd.track_index] = .{
        .name = cmd.track_data.name,
        .volume = cmd.track_data.volume,
        .pan = cmd.track_data.pan,
        .mute = cmd.track_data.mute,
        .solo = cmd.track_data.solo,
    };
    for (0..max_scenes) |s| {
        const slot = cmd.clips[s];
        self.session.clip_selected[cmd.track_index][s] = false;
        const notes: []const piano_roll_types.Note = if (s < cmd.notes.len) cmd.notes[s] else &.{};
        restoreSlotFromSnapshot(self, cmd.track_index, s, slot.has_clip, slot.length_beats, slot.name, notes, &cmd.audio[s]);
    }

    self.session.track_count += 1;
    if (self.session.primary_track >= self.session.track_count) {
        self.session.primary_track = self.session.track_count - 1;
    }
}

pub fn insertSceneInState(self: *State, cmd: *const undo.command.SceneDeleteCmd) void {
    if (self.session.scene_count >= max_scenes) return;

    var s = self.session.scene_count;
    while (s > cmd.scene_index) : (s -= 1) {
        self.session.scenes[s] = self.session.scenes[s - 1];
        for (0..max_tracks) |t| {
            self.session.clips[t][s] = self.session.clips[t][s - 1];
            self.session.clip_selected[t][s] = self.session.clip_selected[t][s - 1];
            self.session.clips[t][s - 1] = .{}; // moved out
        }
    }

    self.session.scenes[cmd.scene_index] = .{
        .name = cmd.scene_data.name,
    };
    for (0..max_tracks) |t| {
        const slot = cmd.clips[t];
        self.session.clip_selected[t][cmd.scene_index] = false;
        const notes: []const piano_roll_types.Note = if (t < cmd.notes.len) cmd.notes[t] else &.{};
        restoreSlotFromSnapshot(self, t, cmd.scene_index, slot.has_clip, slot.length_beats, slot.name, notes, &cmd.audio[t]);
    }

    self.session.scene_count += 1;
    if (self.session.primary_scene >= self.session.scene_count) {
        self.session.primary_scene = self.session.scene_count - 1;
    }
}
};
