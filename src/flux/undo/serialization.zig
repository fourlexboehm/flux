//! XML serialization for undo history stored in DAWproject archives.
//! Keeps undo data separate from the main project.xml payload.

const std = @import("std");
const command = @import("command.zig");
const history = @import("history.zig");
const XmlWriter = @import("../dawproject/xml_writer.zig").XmlWriter;
const Command = command.Command;
const CommandKind = command.CommandKind;
const UndoHistory = history.UndoHistory;
const HistoryEntry = history.HistoryEntry;
const Note = command.Note;

/// XML writer for metadata - delegates base writing to XmlWriter
pub const MetadataWriter = struct {
    xml: XmlWriter,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .xml = XmlWriter.init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.xml.deinit();
    }

    pub fn toOwnedSlice(self: *Self) ![]u8 {
        return self.xml.toOwnedSlice();
    }

    /// Write complete metadata.xml content
    pub fn writeMetadata(self: *Self, undo_history: *const UndoHistory) !void {
        try self.xml.buffer.appendSlice(self.xml.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        try self.xml.buffer.appendSlice(self.xml.allocator, "<Metadata xmlns:flux=\"http://flux.daw/1.0\">\n");
        self.xml.indent_level += 1;

        try self.writeUndoHistory(undo_history);

        self.xml.indent_level -= 1;
        try self.xml.buffer.appendSlice(self.xml.allocator, "</Metadata>\n");
    }

    fn writeUndoHistory(self: *Self, undo_history: *const UndoHistory) !void {
        try self.xml.writeIndent();
        try self.xml.buffer.appendSlice(self.xml.allocator, "<flux:UndoHistory");
        try self.xml.writeAttr("version", "1");
        try self.xml.writeAttrInt("savePoint", undo_history.getSavePoint());
        try self.xml.buffer.appendSlice(self.xml.allocator, ">\n");
        self.xml.indent_level += 1;

        // Write undo stack
        for (undo_history.getUndoCommands()) |entry| {
            try self.writeCommand(&entry);
        }

        self.xml.indent_level -= 1;
        try self.xml.writeIndent();
        try self.xml.buffer.appendSlice(self.xml.allocator, "</flux:UndoHistory>\n");
    }

    fn writeCommand(self: *Self, entry: *const HistoryEntry) !void {
        const cmd = &entry.cmd;
        const kind: CommandKind = cmd.*;

        try self.xml.writeIndent();
        try self.xml.buffer.appendSlice(self.xml.allocator, "<flux:Command");
        try self.xml.writeAttr("type", @tagName(kind));
        try self.xml.writeAttrInt("ts", entry.timestamp);

        switch (cmd.*) {
            .clip_create => |c| {
                try self.xml.writeAttrInt("track", c.track);
                try self.xml.writeAttrInt("scene", c.scene);
                try self.xml.writeAttrFloat("length", c.length_beats);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .clip_delete => |c| {
                try self.xml.writeAttrInt("track", c.track);
                try self.xml.writeAttrInt("scene", c.scene);
                try self.xml.writeAttrFloat("length", c.length_beats);
                if (c.notes.len == 0) {
                    try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
                } else {
                    try self.xml.buffer.appendSlice(self.xml.allocator, ">\n");
                    self.xml.indent_level += 1;
                    for (c.notes) |note| {
                        try self.writeNote(&note);
                    }
                    self.xml.indent_level -= 1;
                    try self.xml.writeIndent();
                    try self.xml.buffer.appendSlice(self.xml.allocator, "</flux:Command>\n");
                }
            },
            .clip_paste => |c| {
                try self.xml.writeAttrInt("track", c.track);
                try self.xml.writeAttrInt("scene", c.scene);
                try self.xml.writeAttrInt("oldHasClip", @intFromBool(c.old_clip.has_clip));
                try self.xml.writeAttrFloat("oldLength", c.old_clip.length_beats);
                try self.xml.writeAttrInt("newHasClip", @intFromBool(c.new_clip.has_clip));
                try self.xml.writeAttrFloat("newLength", c.new_clip.length_beats);
                if (c.old_notes.len == 0 and c.new_notes.len == 0) {
                    try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
                } else {
                    try self.xml.buffer.appendSlice(self.xml.allocator, ">\n");
                    self.xml.indent_level += 1;
                    if (c.old_notes.len > 0) {
                        try self.xml.writeIndent();
                        try self.xml.buffer.appendSlice(self.xml.allocator, "<flux:OldNotes>\n");
                        self.xml.indent_level += 1;
                        for (c.old_notes) |note| {
                            try self.writeNote(&note);
                        }
                        self.xml.indent_level -= 1;
                        try self.xml.writeIndent();
                        try self.xml.buffer.appendSlice(self.xml.allocator, "</flux:OldNotes>\n");
                    }
                    if (c.new_notes.len > 0) {
                        try self.xml.writeIndent();
                        try self.xml.buffer.appendSlice(self.xml.allocator, "<flux:NewNotes>\n");
                        self.xml.indent_level += 1;
                        for (c.new_notes) |note| {
                            try self.writeNote(&note);
                        }
                        self.xml.indent_level -= 1;
                        try self.xml.writeIndent();
                        try self.xml.buffer.appendSlice(self.xml.allocator, "</flux:NewNotes>\n");
                    }
                    self.xml.indent_level -= 1;
                    try self.xml.writeIndent();
                    try self.xml.buffer.appendSlice(self.xml.allocator, "</flux:Command>\n");
                }
            },
            inline .note_add, .note_remove => |c| {
                try self.xml.writeAttrInt("track", c.track);
                try self.xml.writeAttrInt("scene", c.scene);
                try self.xml.writeAttrInt("noteIndex", c.note_index);
                try self.xml.buffer.appendSlice(self.xml.allocator, ">\n");
                self.xml.indent_level += 1;
                try self.writeNote(&c.note);
                self.xml.indent_level -= 1;
                try self.xml.writeIndent();
                try self.xml.buffer.appendSlice(self.xml.allocator, "</flux:Command>\n");
            },
            .note_move => |c| {
                try self.xml.writeAttrInt("track", c.track);
                try self.xml.writeAttrInt("scene", c.scene);
                try self.xml.writeAttrInt("noteIndex", c.note_index);
                try self.xml.writeAttrFloat("oldStart", c.old_start);
                try self.xml.writeAttrInt("oldPitch", c.old_pitch);
                try self.xml.writeAttrFloat("newStart", c.new_start);
                try self.xml.writeAttrInt("newPitch", c.new_pitch);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .note_resize => |c| {
                try self.xml.writeAttrInt("track", c.track);
                try self.xml.writeAttrInt("scene", c.scene);
                try self.xml.writeAttrInt("noteIndex", c.note_index);
                try self.xml.writeAttrFloat("oldDuration", c.old_duration);
                try self.xml.writeAttrFloat("newDuration", c.new_duration);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .note_batch => |c| {
                try self.xml.writeAttrInt("track", c.track);
                try self.xml.writeAttrInt("scene", c.scene);
                if (c.notes.len == 0) {
                    try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
                } else {
                    try self.xml.buffer.appendSlice(self.xml.allocator, ">\n");
                    self.xml.indent_level += 1;
                    for (c.notes) |note| {
                        try self.writeNote(&note);
                    }
                    self.xml.indent_level -= 1;
                    try self.xml.writeIndent();
                    try self.xml.buffer.appendSlice(self.xml.allocator, "</flux:Command>\n");
                }
            },
            .track_add => |c| {
                try self.xml.writeAttrInt("trackIndex", c.track_index);
                try self.xml.writeAttr("name", c.name.get());
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .track_delete => |c| {
                try self.xml.writeAttrInt("trackIndex", c.track_index);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .track_rename => |c| {
                try self.xml.writeAttrInt("trackIndex", c.track_index);
                try self.xml.writeAttr("oldName", c.old_name.get());
                try self.xml.writeAttr("newName", c.new_name.get());
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .track_volume => |c| {
                try self.xml.writeAttrInt("trackIndex", c.track_index);
                try self.xml.writeAttrFloat("oldVolume", c.old_volume);
                try self.xml.writeAttrFloat("newVolume", c.new_volume);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .track_mute => |c| {
                try self.xml.writeAttrInt("trackIndex", c.track_index);
                try self.xml.writeAttrBool("oldMute", c.old_mute);
                try self.xml.writeAttrBool("newMute", c.new_mute);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .track_solo => |c| {
                try self.xml.writeAttrInt("trackIndex", c.track_index);
                try self.xml.writeAttrBool("oldSolo", c.old_solo);
                try self.xml.writeAttrBool("newSolo", c.new_solo);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .scene_add => |c| {
                try self.xml.writeAttrInt("sceneIndex", c.scene_index);
                try self.xml.writeAttr("name", c.name.get());
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .scene_delete => |c| {
                try self.xml.writeAttrInt("sceneIndex", c.scene_index);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .scene_rename => |c| {
                try self.xml.writeAttrInt("sceneIndex", c.scene_index);
                try self.xml.writeAttr("oldName", c.old_name.get());
                try self.xml.writeAttr("newName", c.new_name.get());
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .bpm_change => |c| {
                try self.xml.writeAttrFloat("oldBpm", c.old_bpm);
                try self.xml.writeAttrFloat("newBpm", c.new_bpm);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .clip_move => |c| {
                if (c.moves.len == 0) {
                    try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
                } else {
                    try self.xml.buffer.appendSlice(self.xml.allocator, ">\n");
                    self.xml.indent_level += 1;
                    for (c.moves) |move| {
                        try self.xml.writeIndent();
                        try self.xml.buffer.appendSlice(self.xml.allocator, "<flux:Move");
                        try self.xml.writeAttrInt("srcTrack", move.src_track);
                        try self.xml.writeAttrInt("srcScene", move.src_scene);
                        try self.xml.writeAttrInt("dstTrack", move.dst_track);
                        try self.xml.writeAttrInt("dstScene", move.dst_scene);
                        try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
                    }
                    self.xml.indent_level -= 1;
                    try self.xml.writeIndent();
                    try self.xml.buffer.appendSlice(self.xml.allocator, "</flux:Command>\n");
                }
            },
            .clip_resize => |c| {
                try self.xml.writeAttrInt("track", c.track);
                try self.xml.writeAttrInt("scene", c.scene);
                try self.xml.writeAttrFloat("oldLength", c.old_length);
                try self.xml.writeAttrFloat("newLength", c.new_length);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .quantize_change => |c| {
                try self.xml.writeAttrInt("oldIndex", c.old_index);
                try self.xml.writeAttrInt("newIndex", c.new_index);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
            .plugin_state => |c| {
                try self.xml.writeAttrInt("trackIndex", c.track_index);
                // Plugin state is binary - store lengths only, actual data not serialized to XML
                try self.xml.writeAttrInt("oldStateLen", c.old_state.len);
                try self.xml.writeAttrInt("newStateLen", c.new_state.len);
                try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
            },
        }
    }

    fn writeNote(self: *Self, note: *const Note) !void {
        try self.xml.writeIndent();
        try self.xml.buffer.appendSlice(self.xml.allocator, "<flux:Note");
        try self.xml.writeAttrInt("pitch", note.pitch);
        try self.xml.writeAttrFloat("start", note.start);
        try self.xml.writeAttrFloat("duration", note.duration);
        try self.xml.buffer.appendSlice(self.xml.allocator, "/>\n");
    }
};

/// Serialize undo history to XML string
pub fn serializeToXml(allocator: std.mem.Allocator, undo_history: *const UndoHistory) ![]u8 {
    var writer = MetadataWriter.init(allocator);
    defer writer.deinit();
    try writer.writeMetadata(undo_history);
    return writer.toOwnedSlice();
}
