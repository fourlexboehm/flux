//! Undo/Redo system for Flux DAW
//!
//! This module provides a command-based undo/redo system with:
//! - Memory-efficient command storage
//! - Command coalescing for rapid changes (e.g., slider drags)
//! - XML serialization for DAWproject persistence
//!
//! Usage:
//! 1. When performing an action, create the appropriate Command and call push()
//! 2. To undo: call popForUndo(), execute the undo logic, then confirmUndo()
//! 3. To redo: call popForRedo(), execute the redo logic, then confirmRedo()

pub const command = @import("command.zig");
pub const history = @import("history.zig");
pub const serialization = @import("serialization.zig");

// Re-export commonly used types
pub const Command = command.Command;
pub const CommandKind = command.CommandKind;
pub const UndoHistory = history.UndoHistory;
pub const HistoryEntry = history.HistoryEntry;
pub const Config = history.Config;
pub const Note = command.Note;

// Command types
pub const ClipCreateCmd = command.ClipCreateCmd;
pub const ClipDeleteCmd = command.ClipDeleteCmd;
pub const ClipMoveCmd = command.ClipMoveCmd;
pub const NoteAddCmd = command.NoteAddCmd;
pub const NoteRemoveCmd = command.NoteRemoveCmd;
pub const NoteMoveCmd = command.NoteMoveCmd;
pub const NoteResizeCmd = command.NoteResizeCmd;
pub const NoteBatchCmd = command.NoteBatchCmd;
pub const TrackAddCmd = command.TrackAddCmd;
pub const TrackDeleteCmd = command.TrackDeleteCmd;
pub const TrackRenameCmd = command.TrackRenameCmd;
pub const TrackVolumeCmd = command.TrackVolumeCmd;
pub const TrackMuteCmd = command.TrackMuteCmd;
pub const TrackSoloCmd = command.TrackSoloCmd;
pub const SceneAddCmd = command.SceneAddCmd;
pub const SceneDeleteCmd = command.SceneDeleteCmd;
pub const SceneRenameCmd = command.SceneRenameCmd;
pub const BpmChangeCmd = command.BpmChangeCmd;

// Data types
pub const TrackData = command.TrackData;
pub const SceneData = command.SceneData;
pub const ClipSlotData = command.ClipSlotData;

// Re-export serialization functions
pub const serializeToXml = serialization.serializeToXml;
pub const MetadataWriter = serialization.MetadataWriter;
