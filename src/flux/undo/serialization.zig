//! XML serialization for undo history stored in DAWproject archives.
//! Keeps undo data separate from the main project.xml payload.

const std = @import("std");
const command = @import("command.zig");
const history = @import("history.zig");
const Command = command.Command;
const CommandKind = command.CommandKind;
const UndoHistory = history.UndoHistory;
const HistoryEntry = history.HistoryEntry;
const Note = command.Note;

/// XML writer for metadata
pub const MetadataWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8),
    indent_level: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn toOwnedSlice(self: *Self) ![]u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    fn writeIndent(self: *Self) !void {
        for (0..self.indent_level) |_| {
            try self.buffer.appendSlice(self.allocator, "  ");
        }
    }

    fn writeEscaped(self: *Self, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '<' => try self.buffer.appendSlice(self.allocator, "&lt;"),
                '>' => try self.buffer.appendSlice(self.allocator, "&gt;"),
                '&' => try self.buffer.appendSlice(self.allocator, "&amp;"),
                '"' => try self.buffer.appendSlice(self.allocator, "&quot;"),
                '\'' => try self.buffer.appendSlice(self.allocator, "&apos;"),
                else => try self.buffer.append(self.allocator, c),
            }
        }
    }

    fn writeAttr(self: *Self, name: []const u8, value: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, " ");
        try self.buffer.appendSlice(self.allocator, name);
        try self.buffer.appendSlice(self.allocator, "=\"");
        try self.writeEscaped(value);
        try self.buffer.appendSlice(self.allocator, "\"");
    }

    fn writeAttrFloat(self: *Self, name: []const u8, value: f64) !void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.6}", .{value}) catch return;
        try self.writeAttr(name, s);
    }

    fn writeAttrInt(self: *Self, name: []const u8, value: anytype) !void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        try self.writeAttr(name, s);
    }

    fn writeAttrBool(self: *Self, name: []const u8, value: bool) !void {
        try self.writeAttr(name, if (value) "true" else "false");
    }

    /// Write complete metadata.xml content
    pub fn writeMetadata(self: *Self, undo_history: *const UndoHistory) !void {
        try self.buffer.appendSlice(self.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        try self.buffer.appendSlice(self.allocator, "<Metadata xmlns:flux=\"http://flux.daw/1.0\">\n");
        self.indent_level += 1;

        try self.writeUndoHistory(undo_history);

        self.indent_level -= 1;
        try self.buffer.appendSlice(self.allocator, "</Metadata>\n");
    }

    fn writeUndoHistory(self: *Self, undo_history: *const UndoHistory) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<flux:UndoHistory");
        try self.writeAttr("version", "1");
        try self.writeAttrInt("savePoint", undo_history.getSavePoint());
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        // Write undo stack
        for (undo_history.getUndoCommands()) |entry| {
            try self.writeCommand(&entry);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</flux:UndoHistory>\n");
    }

    fn writeCommand(self: *Self, entry: *const HistoryEntry) !void {
        const cmd = &entry.cmd;
        const kind: CommandKind = cmd.*;

        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<flux:Command");
        try self.writeAttr("type", @tagName(kind));
        try self.writeAttrInt("ts", entry.timestamp);

        switch (cmd.*) {
            .clip_create => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrFloat("length", c.length_beats);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .clip_delete => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrFloat("length", c.length_beats);
                if (c.notes.len == 0) {
                    try self.buffer.appendSlice(self.allocator, "/>\n");
                } else {
                    try self.buffer.appendSlice(self.allocator, ">\n");
                    self.indent_level += 1;
                    for (c.notes) |note| {
                        try self.writeNote(&note);
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.buffer.appendSlice(self.allocator, "</flux:Command>\n");
                }
            },
            .clip_paste => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrInt("oldHasClip", @intFromBool(c.old_clip.has_clip));
                try self.writeAttrFloat("oldLength", c.old_clip.length_beats);
                try self.writeAttrInt("newHasClip", @intFromBool(c.new_clip.has_clip));
                try self.writeAttrFloat("newLength", c.new_clip.length_beats);
                if (c.old_notes.len == 0 and c.new_notes.len == 0) {
                    try self.buffer.appendSlice(self.allocator, "/>\n");
                } else {
                    try self.buffer.appendSlice(self.allocator, ">\n");
                    self.indent_level += 1;
                    if (c.old_notes.len > 0) {
                        try self.writeIndent();
                        try self.buffer.appendSlice(self.allocator, "<flux:OldNotes>\n");
                        self.indent_level += 1;
                        for (c.old_notes) |note| {
                            try self.writeNote(&note);
                        }
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.buffer.appendSlice(self.allocator, "</flux:OldNotes>\n");
                    }
                    if (c.new_notes.len > 0) {
                        try self.writeIndent();
                        try self.buffer.appendSlice(self.allocator, "<flux:NewNotes>\n");
                        self.indent_level += 1;
                        for (c.new_notes) |note| {
                            try self.writeNote(&note);
                        }
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.buffer.appendSlice(self.allocator, "</flux:NewNotes>\n");
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.buffer.appendSlice(self.allocator, "</flux:Command>\n");
                }
            },
            inline .note_add, .note_remove => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrInt("noteIndex", c.note_index);
                try self.buffer.appendSlice(self.allocator, ">\n");
                self.indent_level += 1;
                try self.writeNote(&c.note);
                self.indent_level -= 1;
                try self.writeIndent();
                try self.buffer.appendSlice(self.allocator, "</flux:Command>\n");
            },
            .note_move => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrInt("noteIndex", c.note_index);
                try self.writeAttrFloat("oldStart", c.old_start);
                try self.writeAttrInt("oldPitch", c.old_pitch);
                try self.writeAttrFloat("newStart", c.new_start);
                try self.writeAttrInt("newPitch", c.new_pitch);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .note_resize => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrInt("noteIndex", c.note_index);
                try self.writeAttrFloat("oldDuration", c.old_duration);
                try self.writeAttrFloat("newDuration", c.new_duration);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .note_batch => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                if (c.notes.len == 0) {
                    try self.buffer.appendSlice(self.allocator, "/>\n");
                } else {
                    try self.buffer.appendSlice(self.allocator, ">\n");
                    self.indent_level += 1;
                    for (c.notes) |note| {
                        try self.writeNote(&note);
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.buffer.appendSlice(self.allocator, "</flux:Command>\n");
                }
            },
            .track_add => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                try self.writeAttr("name", c.name.get());
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .track_delete => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .track_rename => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                try self.writeAttr("oldName", c.old_name.get());
                try self.writeAttr("newName", c.new_name.get());
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .track_volume => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                try self.writeAttrFloat("oldVolume", c.old_volume);
                try self.writeAttrFloat("newVolume", c.new_volume);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .track_mute => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                try self.writeAttrBool("oldMute", c.old_mute);
                try self.writeAttrBool("newMute", c.new_mute);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .track_solo => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                try self.writeAttrBool("oldSolo", c.old_solo);
                try self.writeAttrBool("newSolo", c.new_solo);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .scene_add => |c| {
                try self.writeAttrInt("sceneIndex", c.scene_index);
                try self.writeAttr("name", c.name.get());
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .scene_delete => |c| {
                try self.writeAttrInt("sceneIndex", c.scene_index);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .scene_rename => |c| {
                try self.writeAttrInt("sceneIndex", c.scene_index);
                try self.writeAttr("oldName", c.old_name.get());
                try self.writeAttr("newName", c.new_name.get());
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .bpm_change => |c| {
                try self.writeAttrFloat("oldBpm", c.old_bpm);
                try self.writeAttrFloat("newBpm", c.new_bpm);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .clip_move => |c| {
                if (c.moves.len == 0) {
                    try self.buffer.appendSlice(self.allocator, "/>\n");
                } else {
                    try self.buffer.appendSlice(self.allocator, ">\n");
                    self.indent_level += 1;
                    for (c.moves) |move| {
                        try self.writeIndent();
                        try self.buffer.appendSlice(self.allocator, "<flux:Move");
                        try self.writeAttrInt("srcTrack", move.src_track);
                        try self.writeAttrInt("srcScene", move.src_scene);
                        try self.writeAttrInt("dstTrack", move.dst_track);
                        try self.writeAttrInt("dstScene", move.dst_scene);
                        try self.buffer.appendSlice(self.allocator, "/>\n");
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.buffer.appendSlice(self.allocator, "</flux:Command>\n");
                }
            },
            .clip_resize => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrFloat("oldLength", c.old_length);
                try self.writeAttrFloat("newLength", c.new_length);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .quantize_change => |c| {
                try self.writeAttrInt("oldIndex", c.old_index);
                try self.writeAttrInt("newIndex", c.new_index);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
            .plugin_state => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                // Plugin state is binary - store lengths only, actual data not serialized to XML
                try self.writeAttrInt("oldStateLen", c.old_state.len);
                try self.writeAttrInt("newStateLen", c.new_state.len);
                try self.buffer.appendSlice(self.allocator, "/>\n");
            },
        }
    }

    fn writeNote(self: *Self, note: *const Note) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<flux:Note");
        try self.writeAttrInt("pitch", note.pitch);
        try self.writeAttrFloat("start", note.start);
        try self.writeAttrFloat("duration", note.duration);
        try self.buffer.appendSlice(self.allocator, "/>\n");
    }
};

/// Serialize undo history to XML string
pub fn serializeToXml(allocator: std.mem.Allocator, undo_history: *const UndoHistory) ![]u8 {
    var writer = MetadataWriter.init(allocator);
    defer writer.deinit();
    try writer.writeMetadata(undo_history);
    return writer.toOwnedSlice();
}
