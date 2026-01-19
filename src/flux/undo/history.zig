//! Undo history manager - maintains stacks of commands for undo/redo.

const std = @import("std");
const command = @import("command.zig");
const Command = command.Command;
const ui = @import("../ui.zig");

/// Configuration for undo history
pub const Config = struct {
    max_commands: usize = 100,
    coalesce_time_ms: u64 = 500,
};

/// Timestamp for command coalescing
pub const Timestamp = i64;

/// Entry in the undo stack
pub const HistoryEntry = struct {
    cmd: Command,
    timestamp: Timestamp,
};

/// Undo history manager
pub const UndoHistory = struct {
    allocator: std.mem.Allocator,
    undo_stack: std.ArrayList(HistoryEntry),
    redo_stack: std.ArrayList(HistoryEntry),
    save_point: usize,
    max_commands: usize,
    coalesce_time_ms: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return initWithConfig(allocator, .{});
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: Config) Self {
        return .{
            .allocator = allocator,
            .undo_stack = std.ArrayList(HistoryEntry).init(allocator),
            .redo_stack = std.ArrayList(HistoryEntry).init(allocator),
            .save_point = 0,
            .max_commands = config.max_commands,
            .coalesce_time_ms = config.coalesce_time_ms,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.undo_stack.items) |*entry| {
            var cmd = entry.cmd;
            cmd.deinit(self.allocator);
        }
        self.undo_stack.deinit();

        for (self.redo_stack.items) |*entry| {
            var cmd = entry.cmd;
            cmd.deinit(self.allocator);
        }
        self.redo_stack.deinit();
    }

    /// Push a new command onto the undo stack
    /// The command should already have been executed
    pub fn push(self: *Self, cmd: Command) void {
        self.pushWithTimestamp(cmd, std.time.milliTimestamp());
    }

    /// Push a command with a specific timestamp (for testing or serialization)
    pub fn pushWithTimestamp(self: *Self, cmd: Command, timestamp: Timestamp) void {
        // Clear redo stack when new command is pushed
        for (self.redo_stack.items) |*entry| {
            var c = entry.cmd;
            c.deinit(self.allocator);
        }
        self.redo_stack.clearRetainingCapacity();

        // Try to coalesce with previous command
        if (self.undo_stack.items.len > 0) {
            const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
            const time_diff = timestamp - last.timestamp;

            if (time_diff >= 0 and @as(u64, @intCast(time_diff)) < self.coalesce_time_ms) {
                if (last.cmd.canMerge(&cmd)) {
                    var merged = last.cmd;
                    merged.merge(&cmd);
                    last.cmd = merged;
                    last.timestamp = timestamp;
                    // Free the new command since we merged
                    var mutable_cmd = cmd;
                    mutable_cmd.deinit(self.allocator);
                    return;
                }
            }
        }

        // Add new entry
        self.undo_stack.append(.{
            .cmd = cmd,
            .timestamp = timestamp,
        }) catch return;

        // Enforce max commands limit
        while (self.undo_stack.items.len > self.max_commands) {
            var removed = self.undo_stack.orderedRemove(0);
            removed.cmd.deinit(self.allocator);
            // Adjust save point
            if (self.save_point > 0) {
                self.save_point -= 1;
            }
        }
    }

    /// Undo the most recent command
    pub fn undo(self: *Self, state: *ui.State) bool {
        if (self.undo_stack.items.len == 0) return false;

        var entry = self.undo_stack.pop();
        entry.cmd.undo(state);

        self.redo_stack.append(entry) catch {
            // If we can't push to redo, free the command
            entry.cmd.deinit(self.allocator);
        };

        return true;
    }

    /// Redo the most recently undone command
    pub fn redo(self: *Self, state: *ui.State) bool {
        if (self.redo_stack.items.len == 0) return false;

        var entry = self.redo_stack.pop();
        entry.cmd.execute(state);

        self.undo_stack.append(entry) catch {
            entry.cmd.deinit(self.allocator);
        };

        return true;
    }

    /// Check if undo is available
    pub fn canUndo(self: *const Self) bool {
        return self.undo_stack.items.len > 0;
    }

    /// Check if redo is available
    pub fn canRedo(self: *const Self) bool {
        return self.redo_stack.items.len > 0;
    }

    /// Get the description of the next undo action
    pub fn getUndoDescription(self: *const Self) ?[]const u8 {
        if (self.undo_stack.items.len == 0) return null;
        return self.undo_stack.items[self.undo_stack.items.len - 1].cmd.getDescription();
    }

    /// Get the description of the next redo action
    pub fn getRedoDescription(self: *const Self) ?[]const u8 {
        if (self.redo_stack.items.len == 0) return null;
        return self.redo_stack.items[self.redo_stack.items.len - 1].cmd.getDescription();
    }

    /// Mark the current position as a save point
    pub fn markSavePoint(self: *Self) void {
        self.save_point = self.undo_stack.items.len;
    }

    /// Check if there are unsaved changes
    pub fn hasUnsavedChanges(self: *const Self) bool {
        return self.undo_stack.items.len != self.save_point;
    }

    /// Get the number of commands since save point
    pub fn changesSinceSave(self: *const Self) usize {
        if (self.undo_stack.items.len >= self.save_point) {
            return self.undo_stack.items.len - self.save_point;
        } else {
            return self.save_point - self.undo_stack.items.len;
        }
    }

    /// Clear all history
    pub fn clear(self: *Self) void {
        for (self.undo_stack.items) |*entry| {
            var cmd = entry.cmd;
            cmd.deinit(self.allocator);
        }
        self.undo_stack.clearRetainingCapacity();

        for (self.redo_stack.items) |*entry| {
            var cmd = entry.cmd;
            cmd.deinit(self.allocator);
        }
        self.redo_stack.clearRetainingCapacity();

        self.save_point = 0;
    }

    /// Get the number of undo steps available
    pub fn undoCount(self: *const Self) usize {
        return self.undo_stack.items.len;
    }

    /// Get the number of redo steps available
    pub fn redoCount(self: *const Self) usize {
        return self.redo_stack.items.len;
    }

    /// Get all commands in undo stack (for serialization)
    pub fn getUndoCommands(self: *const Self) []const HistoryEntry {
        return self.undo_stack.items;
    }

    /// Get all commands in redo stack (for serialization)
    pub fn getRedoCommands(self: *const Self) []const HistoryEntry {
        return self.redo_stack.items;
    }

    /// Get save point index (for serialization)
    pub fn getSavePoint(self: *const Self) usize {
        return self.save_point;
    }

    /// Set save point index (for deserialization)
    pub fn setSavePoint(self: *Self, point: usize) void {
        self.save_point = point;
    }
};

// ============================================================================
// Helper functions for creating commands
// ============================================================================

/// Create a clip create command and push to history
pub fn recordClipCreate(history: *UndoHistory, track: usize, scene: usize, length_beats: f32) void {
    history.push(.{
        .clip_create = .{
            .track = track,
            .scene = scene,
            .length_beats = length_beats,
        },
    });
}

/// Create a clip delete command (captures current state) and push to history
pub fn recordClipDelete(
    history: *UndoHistory,
    state: *const ui.State,
    track: usize,
    scene: usize,
) void {
    const clip = &state.piano_clips[track][scene];
    const notes = history.allocator.dupe(ui.Note, clip.notes.items) catch &.{};

    history.push(.{
        .clip_delete = .{
            .track = track,
            .scene = scene,
            .length_beats = state.session.clips[track][scene].length_beats,
            .notes = notes,
        },
    });
}

/// Create a note add command and push to history
pub fn recordNoteAdd(
    history: *UndoHistory,
    track: usize,
    scene: usize,
    note: ui.Note,
    note_index: usize,
) void {
    history.push(.{
        .note_add = .{
            .track = track,
            .scene = scene,
            .note = note,
            .note_index = note_index,
        },
    });
}

/// Create a note remove command and push to history
pub fn recordNoteRemove(
    history: *UndoHistory,
    track: usize,
    scene: usize,
    note: ui.Note,
    note_index: usize,
) void {
    history.push(.{
        .note_remove = .{
            .track = track,
            .scene = scene,
            .note = note,
            .note_index = note_index,
        },
    });
}

/// Create a note move command and push to history
pub fn recordNoteMove(
    history: *UndoHistory,
    track: usize,
    scene: usize,
    note_index: usize,
    old_start: f32,
    old_pitch: u8,
    new_start: f32,
    new_pitch: u8,
) void {
    history.push(.{
        .note_move = .{
            .track = track,
            .scene = scene,
            .note_index = note_index,
            .old_start = old_start,
            .old_pitch = old_pitch,
            .new_start = new_start,
            .new_pitch = new_pitch,
        },
    });
}

/// Create a note resize command and push to history
pub fn recordNoteResize(
    history: *UndoHistory,
    track: usize,
    scene: usize,
    note_index: usize,
    old_duration: f32,
    new_duration: f32,
) void {
    history.push(.{
        .note_resize = .{
            .track = track,
            .scene = scene,
            .note_index = note_index,
            .old_duration = old_duration,
            .new_duration = new_duration,
        },
    });
}

/// Create a track add command and push to history
pub fn recordTrackAdd(history: *UndoHistory, track_index: usize, name: []const u8) void {
    var name_buf: [32]u8 = undefined;
    const len = @min(name.len, name_buf.len);
    @memcpy(name_buf[0..len], name[0..len]);

    history.push(.{
        .track_add = .{
            .track_index = track_index,
            .name = name_buf,
            .name_len = len,
        },
    });
}

/// Create a scene add command and push to history
pub fn recordSceneAdd(history: *UndoHistory, scene_index: usize, name: []const u8) void {
    var name_buf: [32]u8 = undefined;
    const len = @min(name.len, name_buf.len);
    @memcpy(name_buf[0..len], name[0..len]);

    history.push(.{
        .scene_add = .{
            .scene_index = scene_index,
            .name = name_buf,
            .name_len = len,
        },
    });
}

/// Create a BPM change command and push to history
pub fn recordBpmChange(history: *UndoHistory, old_bpm: f32, new_bpm: f32) void {
    history.push(.{
        .bpm_change = .{
            .old_bpm = old_bpm,
            .new_bpm = new_bpm,
        },
    });
}

/// Create a track volume change command and push to history
pub fn recordTrackVolume(history: *UndoHistory, track_index: usize, old_volume: f32, new_volume: f32) void {
    history.push(.{
        .track_volume = .{
            .track_index = track_index,
            .old_volume = old_volume,
            .new_volume = new_volume,
        },
    });
}

/// Create a track mute toggle command and push to history
pub fn recordTrackMute(history: *UndoHistory, track_index: usize, old_mute: bool, new_mute: bool) void {
    history.push(.{
        .track_mute = .{
            .track_index = track_index,
            .old_mute = old_mute,
            .new_mute = new_mute,
        },
    });
}

/// Create a track solo toggle command and push to history
pub fn recordTrackSolo(history: *UndoHistory, track_index: usize, old_solo: bool, new_solo: bool) void {
    history.push(.{
        .track_solo = .{
            .track_index = track_index,
            .old_solo = old_solo,
            .new_solo = new_solo,
        },
    });
}
