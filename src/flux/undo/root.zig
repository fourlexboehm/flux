//! Undo/Redo system for Flux DAW
//!
//! This module provides a command-based undo/redo system with:
//! - Memory-efficient command storage
//! - Command coalescing for rapid changes (e.g., slider drags)
//! - XML serialization for DAWproject persistence

pub const command = @import("command.zig");
pub const history = @import("history.zig");
pub const serialization = @import("serialization.zig");

// Re-export commonly used types
pub const Command = command.Command;
pub const CommandKind = command.CommandKind;
pub const UndoHistory = history.UndoHistory;
pub const HistoryEntry = history.HistoryEntry;
pub const Config = history.Config;

// Re-export helper functions
pub const recordClipCreate = history.recordClipCreate;
pub const recordClipDelete = history.recordClipDelete;
pub const recordNoteAdd = history.recordNoteAdd;
pub const recordNoteRemove = history.recordNoteRemove;
pub const recordNoteMove = history.recordNoteMove;
pub const recordNoteResize = history.recordNoteResize;
pub const recordTrackAdd = history.recordTrackAdd;
pub const recordSceneAdd = history.recordSceneAdd;
pub const recordBpmChange = history.recordBpmChange;
pub const recordTrackVolume = history.recordTrackVolume;
pub const recordTrackMute = history.recordTrackMute;
pub const recordTrackSolo = history.recordTrackSolo;

// Re-export serialization functions
pub const serializeToXml = serialization.serializeToXml;
pub const parseMetadataXml = serialization.parseMetadataXml;
pub const MetadataWriter = serialization.MetadataWriter;
