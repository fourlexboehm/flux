//! Command types for undo/redo system.
//! Uses command pattern - each command stores both forward and reverse data.

const std = @import("std");
const session_view = @import("../ui/session_view.zig");
const piano_roll = @import("../ui/piano_roll.zig");

/// Command type enumeration
pub const CommandKind = enum {
    // Clip operations
    clip_create,
    clip_delete,
    clip_move,

    // Note operations
    note_add,
    note_remove,
    note_move,
    note_resize,
    note_batch,

    // Track operations
    track_add,
    track_delete,
    track_rename,
    track_volume,
    track_mute,
    track_solo,

    // Scene operations
    scene_add,
    scene_delete,
    scene_rename,

    // Transport
    bpm_change,
};

/// Create clip command - stores track/scene position
pub const ClipCreateCmd = struct {
    track: usize,
    scene: usize,
    length_beats: f32,
};

/// Delete clip command - stores full clip state for restore
pub const ClipDeleteCmd = struct {
    track: usize,
    scene: usize,
    length_beats: f32,
    notes: []const piano_roll.Note,
};

/// Move clip command - stores source and destination
pub const ClipMoveCmd = struct {
    /// Original positions of all moved clips
    moves: []const ClipMove,

    pub const ClipMove = struct {
        src_track: usize,
        src_scene: usize,
        dst_track: usize,
        dst_scene: usize,
    };
};

/// Add note command
pub const NoteAddCmd = struct {
    track: usize,
    scene: usize,
    note: piano_roll.Note,
    note_index: usize,
};

/// Remove note command - stores note data for restore
pub const NoteRemoveCmd = struct {
    track: usize,
    scene: usize,
    note: piano_roll.Note,
    note_index: usize,
};

/// Move note command
pub const NoteMoveCmd = struct {
    track: usize,
    scene: usize,
    note_index: usize,
    old_start: f32,
    old_pitch: u8,
    new_start: f32,
    new_pitch: u8,
};

/// Resize note command
pub const NoteResizeCmd = struct {
    track: usize,
    scene: usize,
    note_index: usize,
    old_duration: f32,
    new_duration: f32,
};

/// Batch note command - for recording multiple notes at once
pub const NoteBatchCmd = struct {
    track: usize,
    scene: usize,
    notes: []const piano_roll.Note,
};

/// Add track command
pub const TrackAddCmd = struct {
    track_index: usize,
    name: [32]u8,
    name_len: usize,
};

/// Delete track command - stores all track data for restore
pub const TrackDeleteCmd = struct {
    track_index: usize,
    track_data: session_view.Track,
    clips: [session_view.max_scenes]session_view.ClipSlot,
    notes: []const []const piano_roll.Note, // Notes for each scene
};

/// Rename track command
pub const TrackRenameCmd = struct {
    track_index: usize,
    old_name: [32]u8,
    old_len: usize,
    new_name: [32]u8,
    new_len: usize,
};

/// Track volume change command
pub const TrackVolumeCmd = struct {
    track_index: usize,
    old_volume: f32,
    new_volume: f32,
};

/// Track mute toggle command
pub const TrackMuteCmd = struct {
    track_index: usize,
    old_mute: bool,
    new_mute: bool,
};

/// Track solo toggle command
pub const TrackSoloCmd = struct {
    track_index: usize,
    old_solo: bool,
    new_solo: bool,
};

/// Add scene command
pub const SceneAddCmd = struct {
    scene_index: usize,
    name: [32]u8,
    name_len: usize,
};

/// Delete scene command - stores all scene data for restore
pub const SceneDeleteCmd = struct {
    scene_index: usize,
    scene_data: session_view.Scene,
    clips: [session_view.max_tracks]session_view.ClipSlot,
    notes: []const []const piano_roll.Note, // Notes for each track
};

/// Rename scene command
pub const SceneRenameCmd = struct {
    scene_index: usize,
    old_name: [32]u8,
    old_len: usize,
    new_name: [32]u8,
    new_len: usize,
};

/// BPM change command
pub const BpmChangeCmd = struct {
    old_bpm: f32,
    new_bpm: f32,
};

/// Unified command union
pub const Command = union(CommandKind) {
    clip_create: ClipCreateCmd,
    clip_delete: ClipDeleteCmd,
    clip_move: ClipMoveCmd,
    note_add: NoteAddCmd,
    note_remove: NoteRemoveCmd,
    note_move: NoteMoveCmd,
    note_resize: NoteResizeCmd,
    note_batch: NoteBatchCmd,
    track_add: TrackAddCmd,
    track_delete: TrackDeleteCmd,
    track_rename: TrackRenameCmd,
    track_volume: TrackVolumeCmd,
    track_mute: TrackMuteCmd,
    track_solo: TrackSoloCmd,
    scene_add: SceneAddCmd,
    scene_delete: SceneDeleteCmd,
    scene_rename: SceneRenameCmd,
    bpm_change: BpmChangeCmd,

    /// Execute the command (apply forward change)
    pub fn execute(self: *const Command, state: *ui.State) void {
        switch (self.*) {
            .clip_create => |cmd| executeClipCreate(cmd, state),
            .clip_delete => |cmd| executeClipDelete(cmd, state),
            .clip_move => |cmd| executeClipMove(cmd, state),
            .note_add => |cmd| executeNoteAdd(cmd, state),
            .note_remove => |cmd| executeNoteRemove(cmd, state),
            .note_move => |cmd| executeNoteMove(cmd, state),
            .note_resize => |cmd| executeNoteResize(cmd, state),
            .note_batch => |cmd| executeNoteBatch(cmd, state),
            .track_add => |cmd| executeTrackAdd(cmd, state),
            .track_delete => |cmd| executeTrackDelete(cmd, state),
            .track_rename => |cmd| executeTrackRename(cmd, state),
            .track_volume => |cmd| executeTrackVolume(cmd, state),
            .track_mute => |cmd| executeTrackMute(cmd, state),
            .track_solo => |cmd| executeTrackSolo(cmd, state),
            .scene_add => |cmd| executeSceneAdd(cmd, state),
            .scene_delete => |cmd| executeSceneDelete(cmd, state),
            .scene_rename => |cmd| executeSceneRename(cmd, state),
            .bpm_change => |cmd| executeBpmChange(cmd, state),
        }
    }

    /// Undo the command (apply reverse change)
    pub fn undo(self: *const Command, state: *ui.State) void {
        switch (self.*) {
            .clip_create => |cmd| undoClipCreate(cmd, state),
            .clip_delete => |cmd| undoClipDelete(cmd, state),
            .clip_move => |cmd| undoClipMove(cmd, state),
            .note_add => |cmd| undoNoteAdd(cmd, state),
            .note_remove => |cmd| undoNoteRemove(cmd, state),
            .note_move => |cmd| undoNoteMove(cmd, state),
            .note_resize => |cmd| undoNoteResize(cmd, state),
            .note_batch => |cmd| undoNoteBatch(cmd, state),
            .track_add => |cmd| undoTrackAdd(cmd, state),
            .track_delete => |cmd| undoTrackDelete(cmd, state),
            .track_rename => |cmd| undoTrackRename(cmd, state),
            .track_volume => |cmd| undoTrackVolume(cmd, state),
            .track_mute => |cmd| undoTrackMute(cmd, state),
            .track_solo => |cmd| undoTrackSolo(cmd, state),
            .scene_add => |cmd| undoSceneAdd(cmd, state),
            .scene_delete => |cmd| undoSceneDelete(cmd, state),
            .scene_rename => |cmd| undoSceneRename(cmd, state),
            .bpm_change => |cmd| undoBpmChange(cmd, state),
        }
    }

    /// Check if this command can be merged with another (for coalescing)
    pub fn canMerge(self: *const Command, other: *const Command) bool {
        const self_kind: CommandKind = self.*;
        const other_kind: CommandKind = other.*;

        if (self_kind != other_kind) return false;

        return switch (self.*) {
            .track_volume => |cmd| {
                const other_cmd = other.track_volume;
                return cmd.track_index == other_cmd.track_index;
            },
            .note_move => |cmd| {
                const other_cmd = other.note_move;
                return cmd.track == other_cmd.track and
                    cmd.scene == other_cmd.scene and
                    cmd.note_index == other_cmd.note_index;
            },
            .note_resize => |cmd| {
                const other_cmd = other.note_resize;
                return cmd.track == other_cmd.track and
                    cmd.scene == other_cmd.scene and
                    cmd.note_index == other_cmd.note_index;
            },
            .bpm_change => true,
            else => false,
        };
    }

    /// Merge another command into this one (for coalescing)
    pub fn merge(self: *Command, other: *const Command) void {
        switch (self.*) {
            .track_volume => |*cmd| {
                cmd.new_volume = other.track_volume.new_volume;
            },
            .note_move => |*cmd| {
                cmd.new_start = other.note_move.new_start;
                cmd.new_pitch = other.note_move.new_pitch;
            },
            .note_resize => |*cmd| {
                cmd.new_duration = other.note_resize.new_duration;
            },
            .bpm_change => |*cmd| {
                cmd.new_bpm = other.bpm_change.new_bpm;
            },
            else => {},
        }
    }

    /// Get a human-readable description of this command
    pub fn getDescription(self: *const Command) []const u8 {
        return switch (self.*) {
            .clip_create => "Create Clip",
            .clip_delete => "Delete Clip",
            .clip_move => "Move Clip",
            .note_add => "Add Note",
            .note_remove => "Remove Note",
            .note_move => "Move Note",
            .note_resize => "Resize Note",
            .note_batch => "Record Notes",
            .track_add => "Add Track",
            .track_delete => "Delete Track",
            .track_rename => "Rename Track",
            .track_volume => "Change Volume",
            .track_mute => "Toggle Mute",
            .track_solo => "Toggle Solo",
            .scene_add => "Add Scene",
            .scene_delete => "Delete Scene",
            .scene_rename => "Rename Scene",
            .bpm_change => "Change BPM",
        };
    }

    /// Free any heap-allocated data in this command
    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .clip_delete => |*cmd| {
                if (cmd.notes.len > 0) {
                    allocator.free(cmd.notes);
                }
            },
            .clip_move => |*cmd| {
                if (cmd.moves.len > 0) {
                    allocator.free(cmd.moves);
                }
            },
            .note_batch => |*cmd| {
                if (cmd.notes.len > 0) {
                    allocator.free(cmd.notes);
                }
            },
            .track_delete => |*cmd| {
                if (cmd.notes.len > 0) {
                    for (cmd.notes) |scene_notes| {
                        if (scene_notes.len > 0) {
                            allocator.free(scene_notes);
                        }
                    }
                    allocator.free(cmd.notes);
                }
            },
            .scene_delete => |*cmd| {
                if (cmd.notes.len > 0) {
                    for (cmd.notes) |track_notes| {
                        if (track_notes.len > 0) {
                            allocator.free(track_notes);
                        }
                    }
                    allocator.free(cmd.notes);
                }
            },
            else => {},
        }
    }
};

// ============================================================================
// Command execution functions
// ============================================================================

fn executeClipCreate(cmd: ClipCreateCmd, state: *ui.State) void {
    state.session.clips[cmd.track][cmd.scene] = .{
        .state = .stopped,
        .length_beats = cmd.length_beats,
    };
}

fn undoClipCreate(cmd: ClipCreateCmd, state: *ui.State) void {
    state.session.clips[cmd.track][cmd.scene] = .{};
    state.piano_clips[cmd.track][cmd.scene].clear();
}

fn executeClipDelete(cmd: ClipDeleteCmd, state: *ui.State) void {
    state.session.clips[cmd.track][cmd.scene] = .{};
    state.piano_clips[cmd.track][cmd.scene].clear();
}

fn undoClipDelete(cmd: ClipDeleteCmd, state: *ui.State) void {
    state.session.clips[cmd.track][cmd.scene] = .{
        .state = .stopped,
        .length_beats = cmd.length_beats,
    };
    // Restore notes
    state.piano_clips[cmd.track][cmd.scene].notes.clearRetainingCapacity();
    for (cmd.notes) |note| {
        state.piano_clips[cmd.track][cmd.scene].addNote(note.pitch, note.start, note.duration) catch {};
    }
}

fn executeClipMove(cmd: ClipMoveCmd, state: *ui.State) void {
    for (cmd.moves) |move| {
        // Store source data
        const clip = state.session.clips[move.src_track][move.src_scene];
        const notes = state.piano_clips[move.src_track][move.src_scene].notes.items;

        // Clear source
        state.session.clips[move.src_track][move.src_scene] = .{};
        state.piano_clips[move.src_track][move.src_scene].clear();

        // Set destination
        state.session.clips[move.dst_track][move.dst_scene] = clip;
        for (notes) |note| {
            state.piano_clips[move.dst_track][move.dst_scene].addNote(note.pitch, note.start, note.duration) catch {};
        }
    }
}

fn undoClipMove(cmd: ClipMoveCmd, state: *ui.State) void {
    // Reverse the moves
    var i = cmd.moves.len;
    while (i > 0) {
        i -= 1;
        const move = cmd.moves[i];

        const clip = state.session.clips[move.dst_track][move.dst_scene];
        const notes = state.piano_clips[move.dst_track][move.dst_scene].notes.items;

        state.session.clips[move.dst_track][move.dst_scene] = .{};
        state.piano_clips[move.dst_track][move.dst_scene].clear();

        state.session.clips[move.src_track][move.src_scene] = clip;
        for (notes) |note| {
            state.piano_clips[move.src_track][move.src_scene].addNote(note.pitch, note.start, note.duration) catch {};
        }
    }
}

fn executeNoteAdd(cmd: NoteAddCmd, state: *ui.State) void {
    const clip = &state.piano_clips[cmd.track][cmd.scene];
    clip.addNote(cmd.note.pitch, cmd.note.start, cmd.note.duration) catch {};
}

fn undoNoteAdd(cmd: NoteAddCmd, state: *ui.State) void {
    const clip = &state.piano_clips[cmd.track][cmd.scene];
    if (cmd.note_index < clip.notes.items.len) {
        _ = clip.notes.orderedRemove(cmd.note_index);
    }
}

fn executeNoteRemove(cmd: NoteRemoveCmd, state: *ui.State) void {
    const clip = &state.piano_clips[cmd.track][cmd.scene];
    if (cmd.note_index < clip.notes.items.len) {
        _ = clip.notes.orderedRemove(cmd.note_index);
    }
}

fn undoNoteRemove(cmd: NoteRemoveCmd, state: *ui.State) void {
    const clip = &state.piano_clips[cmd.track][cmd.scene];
    clip.notes.insert(clip.allocator, cmd.note_index, cmd.note) catch {
        // If insert at index fails, append
        clip.addNote(cmd.note.pitch, cmd.note.start, cmd.note.duration) catch {};
    };
}

fn executeNoteMove(cmd: NoteMoveCmd, state: *ui.State) void {
    const clip = &state.piano_clips[cmd.track][cmd.scene];
    if (cmd.note_index < clip.notes.items.len) {
        clip.notes.items[cmd.note_index].start = cmd.new_start;
        clip.notes.items[cmd.note_index].pitch = cmd.new_pitch;
    }
}

fn undoNoteMove(cmd: NoteMoveCmd, state: *ui.State) void {
    const clip = &state.piano_clips[cmd.track][cmd.scene];
    if (cmd.note_index < clip.notes.items.len) {
        clip.notes.items[cmd.note_index].start = cmd.old_start;
        clip.notes.items[cmd.note_index].pitch = cmd.old_pitch;
    }
}

fn executeNoteResize(cmd: NoteResizeCmd, state: *ui.State) void {
    const clip = &state.piano_clips[cmd.track][cmd.scene];
    if (cmd.note_index < clip.notes.items.len) {
        clip.notes.items[cmd.note_index].duration = cmd.new_duration;
    }
}

fn undoNoteResize(cmd: NoteResizeCmd, state: *ui.State) void {
    const clip = &state.piano_clips[cmd.track][cmd.scene];
    if (cmd.note_index < clip.notes.items.len) {
        clip.notes.items[cmd.note_index].duration = cmd.old_duration;
    }
}

fn executeNoteBatch(cmd: NoteBatchCmd, state: *ui.State) void {
    const clip = &state.piano_clips[cmd.track][cmd.scene];
    for (cmd.notes) |note| {
        clip.addNote(note.pitch, note.start, note.duration) catch {};
    }
}

fn undoNoteBatch(cmd: NoteBatchCmd, state: *ui.State) void {
    const clip = &state.piano_clips[cmd.track][cmd.scene];
    // Remove the last N notes (where N = cmd.notes.len)
    const remove_count = @min(cmd.notes.len, clip.notes.items.len);
    clip.notes.shrinkRetainingCapacity(clip.notes.items.len - remove_count);
}

fn executeTrackAdd(cmd: TrackAddCmd, state: *ui.State) void {
    if (state.session.track_count >= session_view.max_tracks) return;
    state.session.tracks[state.session.track_count] = .{};
    state.session.tracks[state.session.track_count].name = cmd.name;
    state.session.tracks[state.session.track_count].name_len = cmd.name_len;
    state.session.track_count += 1;
}

fn undoTrackAdd(cmd: TrackAddCmd, state: *ui.State) void {
    _ = cmd;
    if (state.session.track_count > 1) {
        state.session.track_count -= 1;
    }
}

fn executeTrackDelete(cmd: TrackDeleteCmd, state: *ui.State) void {
    _ = state.session.deleteTrack(cmd.track_index);
}

fn undoTrackDelete(cmd: TrackDeleteCmd, state: *ui.State) void {
    // Re-insert the track
    if (state.session.track_count >= session_view.max_tracks) return;

    // Shift tracks right
    var t = state.session.track_count;
    while (t > cmd.track_index) : (t -= 1) {
        state.session.tracks[t] = state.session.tracks[t - 1];
        for (0..session_view.max_scenes) |s| {
            state.session.clips[t][s] = state.session.clips[t - 1][s];
        }
    }

    // Restore track
    state.session.tracks[cmd.track_index] = cmd.track_data;
    for (0..session_view.max_scenes) |s| {
        state.session.clips[cmd.track_index][s] = cmd.clips[s];
    }
    state.session.track_count += 1;

    // Restore notes
    if (cmd.notes.len > 0) {
        for (cmd.notes, 0..) |scene_notes, s| {
            for (scene_notes) |note| {
                state.piano_clips[cmd.track_index][s].addNote(note.pitch, note.start, note.duration) catch {};
            }
        }
    }
}

fn executeTrackRename(cmd: TrackRenameCmd, state: *ui.State) void {
    state.session.tracks[cmd.track_index].name = cmd.new_name;
    state.session.tracks[cmd.track_index].name_len = cmd.new_len;
}

fn undoTrackRename(cmd: TrackRenameCmd, state: *ui.State) void {
    state.session.tracks[cmd.track_index].name = cmd.old_name;
    state.session.tracks[cmd.track_index].name_len = cmd.old_len;
}

fn executeTrackVolume(cmd: TrackVolumeCmd, state: *ui.State) void {
    state.session.tracks[cmd.track_index].volume = cmd.new_volume;
}

fn undoTrackVolume(cmd: TrackVolumeCmd, state: *ui.State) void {
    state.session.tracks[cmd.track_index].volume = cmd.old_volume;
}

fn executeTrackMute(cmd: TrackMuteCmd, state: *ui.State) void {
    state.session.tracks[cmd.track_index].mute = cmd.new_mute;
}

fn undoTrackMute(cmd: TrackMuteCmd, state: *ui.State) void {
    state.session.tracks[cmd.track_index].mute = cmd.old_mute;
}

fn executeTrackSolo(cmd: TrackSoloCmd, state: *ui.State) void {
    state.session.tracks[cmd.track_index].solo = cmd.new_solo;
}

fn undoTrackSolo(cmd: TrackSoloCmd, state: *ui.State) void {
    state.session.tracks[cmd.track_index].solo = cmd.old_solo;
}

fn executeSceneAdd(cmd: SceneAddCmd, state: *ui.State) void {
    if (state.session.scene_count >= session_view.max_scenes) return;
    state.session.scenes[state.session.scene_count] = .{};
    state.session.scenes[state.session.scene_count].name = cmd.name;
    state.session.scenes[state.session.scene_count].name_len = cmd.name_len;
    state.session.scene_count += 1;
}

fn undoSceneAdd(cmd: SceneAddCmd, state: *ui.State) void {
    _ = cmd;
    if (state.session.scene_count > 1) {
        state.session.scene_count -= 1;
    }
}

fn executeSceneDelete(cmd: SceneDeleteCmd, state: *ui.State) void {
    _ = state.session.deleteScene(cmd.scene_index);
}

fn undoSceneDelete(cmd: SceneDeleteCmd, state: *ui.State) void {
    // Re-insert the scene
    if (state.session.scene_count >= session_view.max_scenes) return;

    // Shift scenes down
    var s = state.session.scene_count;
    while (s > cmd.scene_index) : (s -= 1) {
        state.session.scenes[s] = state.session.scenes[s - 1];
        for (0..session_view.max_tracks) |t| {
            state.session.clips[t][s] = state.session.clips[t][s - 1];
        }
    }

    // Restore scene
    state.session.scenes[cmd.scene_index] = cmd.scene_data;
    for (0..session_view.max_tracks) |t| {
        state.session.clips[t][cmd.scene_index] = cmd.clips[t];
    }
    state.session.scene_count += 1;

    // Restore notes
    if (cmd.notes.len > 0) {
        for (cmd.notes, 0..) |track_notes, t| {
            for (track_notes) |note| {
                state.piano_clips[t][cmd.scene_index].addNote(note.pitch, note.start, note.duration) catch {};
            }
        }
    }
}

fn executeSceneRename(cmd: SceneRenameCmd, state: *ui.State) void {
    state.session.scenes[cmd.scene_index].name = cmd.new_name;
    state.session.scenes[cmd.scene_index].name_len = cmd.new_len;
}

fn undoSceneRename(cmd: SceneRenameCmd, state: *ui.State) void {
    state.session.scenes[cmd.scene_index].name = cmd.old_name;
    state.session.scenes[cmd.scene_index].name_len = cmd.old_len;
}

fn executeBpmChange(cmd: BpmChangeCmd, state: *ui.State) void {
    state.bpm = cmd.new_bpm;
}

fn undoBpmChange(cmd: BpmChangeCmd, state: *ui.State) void {
    state.bpm = cmd.old_bpm;
}
