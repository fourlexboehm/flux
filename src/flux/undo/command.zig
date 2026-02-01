//! Command types for undo/redo system.
//! Uses command pattern - each command stores both forward and reverse data.

const std = @import("std");
const session_view = @import("../ui/session_view.zig");
const piano_roll = @import("../ui/piano_roll.zig");

pub const Note = piano_roll.Note;
pub const max_tracks = session_view.max_tracks;
pub const max_scenes = session_view.max_scenes;

/// Command type enumeration
pub const CommandKind = enum {
    // Clip operations
    clip_create,
    clip_delete,
    clip_move,
    clip_resize,

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
    quantize_change,

    // Plugin state
    plugin_state,
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
    notes: []const Note,
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

/// Resize clip command - changes clip length
pub const ClipResizeCmd = struct {
    track: usize,
    scene: usize,
    old_length: f32,
    new_length: f32,
};

/// Add note command
pub const NoteAddCmd = struct {
    track: usize,
    scene: usize,
    note: Note,
    note_index: usize,
};

/// Remove note command - stores note data for restore
pub const NoteRemoveCmd = struct {
    track: usize,
    scene: usize,
    note: Note,
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
    notes: []const Note,
};

/// Add track command
pub const TrackAddCmd = struct {
    track_index: usize,
    name: session_view.NameField,
};

/// Delete track command - stores all track data for restore
pub const TrackDeleteCmd = struct {
    track_index: usize,
    track_data: TrackData,
    clips: [max_scenes]ClipSlotData,
    notes: []const []const Note, // Notes for each scene
};

/// Track data for serialization (avoids dependency on full Track type)
pub const TrackData = struct {
    name: session_view.NameField,
    volume: f32,
    mute: bool,
    solo: bool,
};

/// Clip slot data for serialization
pub const ClipSlotData = struct {
    has_clip: bool,
    length_beats: f32,
};

/// Rename track command
pub const TrackRenameCmd = struct {
    track_index: usize,
    old_name: session_view.NameField,
    new_name: session_view.NameField,
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
    name: session_view.NameField,
};

/// Delete scene command - stores all scene data for restore
pub const SceneDeleteCmd = struct {
    scene_index: usize,
    scene_data: SceneData,
    clips: [max_tracks]ClipSlotData,
    notes: []const []const Note, // Notes for each track
};

/// Scene data for serialization
pub const SceneData = struct {
    name: session_view.NameField,
};

/// Rename scene command
pub const SceneRenameCmd = struct {
    scene_index: usize,
    old_name: session_view.NameField,
    new_name: session_view.NameField,
};

/// BPM change command
pub const BpmChangeCmd = struct {
    old_bpm: f32,
    new_bpm: f32,
};

/// Quantize setting change command
pub const QuantizeChangeCmd = struct {
    old_index: i32,
    new_index: i32,
};

/// Plugin state change command - stores full state blobs for undo/redo
pub const PluginStateCmd = struct {
    track_index: usize,
    old_state: []const u8, // State before the change
    new_state: []const u8, // State after the change
};

/// Unified command union
pub const Command = union(CommandKind) {
    clip_create: ClipCreateCmd,
    clip_delete: ClipDeleteCmd,
    clip_move: ClipMoveCmd,
    clip_resize: ClipResizeCmd,
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
    quantize_change: QuantizeChangeCmd,
    plugin_state: PluginStateCmd,

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
            .clip_resize => "Resize Clip",
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
            .quantize_change => "Change Quantize",
            .plugin_state => "Change Plugin",
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
            .plugin_state => |*cmd| {
                if (cmd.old_state.len > 0) {
                    allocator.free(cmd.old_state);
                }
                if (cmd.new_state.len > 0) {
                    allocator.free(cmd.new_state);
                }
            },
            else => {},
        }
    }
};
