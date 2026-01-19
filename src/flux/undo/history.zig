//! Undo history manager - maintains stacks of commands for undo/redo.
//!
//! Note: Actual command execution is handled by the caller (ui.zig)
//! to avoid circular dependencies.

const std = @import("std");
const command = @import("command.zig");
const Command = command.Command;

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
    undo_stack: std.ArrayListUnmanaged(HistoryEntry),
    redo_stack: std.ArrayListUnmanaged(HistoryEntry),
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
            .undo_stack = .empty,
            .redo_stack = .empty,
            .save_point = 0,
            .max_commands = config.max_commands,
            .coalesce_time_ms = config.coalesce_time_ms,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.undo_stack.items) |*entry| {
            var cmd_copy = entry.cmd;
            cmd_copy.deinit(self.allocator);
        }
        self.undo_stack.deinit(self.allocator);

        for (self.redo_stack.items) |*entry| {
            var cmd_copy = entry.cmd;
            cmd_copy.deinit(self.allocator);
        }
        self.redo_stack.deinit(self.allocator);
    }

    /// Push a new command onto the undo stack.
    /// The command should already have been executed by the caller.
    pub fn push(self: *Self, cmd: Command) void {
        // Use timestamp = 0 to disable coalescing for now
        // Real time-based coalescing can be added later
        self.pushWithTimestamp(cmd, 0);
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
        self.undo_stack.append(self.allocator, .{
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

    /// Pop and return the most recent command for undo.
    /// Returns null if nothing to undo.
    /// Caller must execute the undo operation, then call confirmUndo().
    pub fn popForUndo(self: *Self) ?*const Command {
        if (self.undo_stack.items.len == 0) return null;
        return &self.undo_stack.items[self.undo_stack.items.len - 1].cmd;
    }

    /// Confirm the undo was executed - moves command to redo stack.
    pub fn confirmUndo(self: *Self) void {
        if (self.undo_stack.items.len == 0) return;
        const entry = self.undo_stack.pop() orelse return;
        self.redo_stack.append(self.allocator, entry) catch {
            var cmd_copy = entry.cmd;
            cmd_copy.deinit(self.allocator);
        };
    }

    /// Pop and return the most recent undone command for redo.
    /// Returns null if nothing to redo.
    /// Caller must execute the redo operation, then call confirmRedo().
    pub fn popForRedo(self: *Self) ?*const Command {
        if (self.redo_stack.items.len == 0) return null;
        return &self.redo_stack.items[self.redo_stack.items.len - 1].cmd;
    }

    /// Confirm the redo was executed - moves command back to undo stack.
    pub fn confirmRedo(self: *Self) void {
        if (self.redo_stack.items.len == 0) return;
        const entry = self.redo_stack.pop() orelse return;
        self.undo_stack.append(self.allocator, entry) catch {
            var cmd_copy = entry.cmd;
            cmd_copy.deinit(self.allocator);
        };
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
            var cmd_copy = entry.cmd;
            cmd_copy.deinit(self.allocator);
        }
        self.undo_stack.clearRetainingCapacity();

        for (self.redo_stack.items) |*entry| {
            var cmd_copy = entry.cmd;
            cmd_copy.deinit(self.allocator);
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
