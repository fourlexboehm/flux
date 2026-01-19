//! XML serialization for undo history in metadata.xml
//! Stores undo history in DAWproject files for session recovery.

const std = @import("std");
const command = @import("command.zig");
const history = @import("history.zig");
const Command = command.Command;
const CommandKind = command.CommandKind;
const UndoHistory = history.UndoHistory;
const HistoryEntry = history.HistoryEntry;
const ui = @import("../ui.zig");

/// XML writer for metadata
pub const MetadataWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    indent_level: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    pub fn toOwnedSlice(self: *Self) ![]u8 {
        return self.buffer.toOwnedSlice();
    }

    fn writeIndent(self: *Self) !void {
        for (0..self.indent_level) |_| {
            try self.buffer.appendSlice("  ");
        }
    }

    fn writeEscaped(self: *Self, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '<' => try self.buffer.appendSlice("&lt;"),
                '>' => try self.buffer.appendSlice("&gt;"),
                '&' => try self.buffer.appendSlice("&amp;"),
                '"' => try self.buffer.appendSlice("&quot;"),
                '\'' => try self.buffer.appendSlice("&apos;"),
                else => try self.buffer.append(c),
            }
        }
    }

    fn writeAttr(self: *Self, name: []const u8, value: []const u8) !void {
        try self.buffer.appendSlice(" ");
        try self.buffer.appendSlice(name);
        try self.buffer.appendSlice("=\"");
        try self.writeEscaped(value);
        try self.buffer.appendSlice("\"");
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
        try self.buffer.appendSlice("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        try self.buffer.appendSlice("<Metadata xmlns:flux=\"http://flux.daw/1.0\">\n");
        self.indent_level += 1;

        try self.writeUndoHistory(undo_history);

        self.indent_level -= 1;
        try self.buffer.appendSlice("</Metadata>\n");
    }

    fn writeUndoHistory(self: *Self, undo_history: *const UndoHistory) !void {
        try self.writeIndent();
        try self.buffer.appendSlice("<flux:UndoHistory");
        try self.writeAttr("version", "1");
        try self.writeAttrInt("savePoint", undo_history.getSavePoint());
        try self.buffer.appendSlice(">\n");
        self.indent_level += 1;

        // Write undo stack
        for (undo_history.getUndoCommands()) |entry| {
            try self.writeCommand(&entry);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice("</flux:UndoHistory>\n");
    }

    fn writeCommand(self: *Self, entry: *const HistoryEntry) !void {
        const cmd = &entry.cmd;
        const kind: CommandKind = cmd.*;

        try self.writeIndent();
        try self.buffer.appendSlice("<flux:Command");
        try self.writeAttr("type", @tagName(kind));
        try self.writeAttrInt("ts", entry.timestamp);

        switch (cmd.*) {
            .clip_create => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrFloat("length", c.length_beats);
                try self.buffer.appendSlice("/>\n");
            },
            .clip_delete => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrFloat("length", c.length_beats);
                if (c.notes.len == 0) {
                    try self.buffer.appendSlice("/>\n");
                } else {
                    try self.buffer.appendSlice(">\n");
                    self.indent_level += 1;
                    for (c.notes) |note| {
                        try self.writeNote(&note);
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.buffer.appendSlice("</flux:Command>\n");
                }
            },
            .note_add, .note_remove => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrInt("noteIndex", c.note_index);
                try self.buffer.appendSlice(">\n");
                self.indent_level += 1;
                try self.writeNote(&c.note);
                self.indent_level -= 1;
                try self.writeIndent();
                try self.buffer.appendSlice("</flux:Command>\n");
            },
            .note_move => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrInt("noteIndex", c.note_index);
                try self.writeAttrFloat("oldStart", c.old_start);
                try self.writeAttrInt("oldPitch", c.old_pitch);
                try self.writeAttrFloat("newStart", c.new_start);
                try self.writeAttrInt("newPitch", c.new_pitch);
                try self.buffer.appendSlice("/>\n");
            },
            .note_resize => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                try self.writeAttrInt("noteIndex", c.note_index);
                try self.writeAttrFloat("oldDuration", c.old_duration);
                try self.writeAttrFloat("newDuration", c.new_duration);
                try self.buffer.appendSlice("/>\n");
            },
            .note_batch => |c| {
                try self.writeAttrInt("track", c.track);
                try self.writeAttrInt("scene", c.scene);
                if (c.notes.len == 0) {
                    try self.buffer.appendSlice("/>\n");
                } else {
                    try self.buffer.appendSlice(">\n");
                    self.indent_level += 1;
                    for (c.notes) |note| {
                        try self.writeNote(&note);
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.buffer.appendSlice("</flux:Command>\n");
                }
            },
            .track_add => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                try self.writeAttr("name", c.name[0..c.name_len]);
                try self.buffer.appendSlice("/>\n");
            },
            .track_delete => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                // Full track data serialization would go here
                try self.buffer.appendSlice("/>\n");
            },
            .track_rename => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                try self.writeAttr("oldName", c.old_name[0..c.old_len]);
                try self.writeAttr("newName", c.new_name[0..c.new_len]);
                try self.buffer.appendSlice("/>\n");
            },
            .track_volume => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                try self.writeAttrFloat("oldVolume", c.old_volume);
                try self.writeAttrFloat("newVolume", c.new_volume);
                try self.buffer.appendSlice("/>\n");
            },
            .track_mute => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                try self.writeAttrBool("oldMute", c.old_mute);
                try self.writeAttrBool("newMute", c.new_mute);
                try self.buffer.appendSlice("/>\n");
            },
            .track_solo => |c| {
                try self.writeAttrInt("trackIndex", c.track_index);
                try self.writeAttrBool("oldSolo", c.old_solo);
                try self.writeAttrBool("newSolo", c.new_solo);
                try self.buffer.appendSlice("/>\n");
            },
            .scene_add => |c| {
                try self.writeAttrInt("sceneIndex", c.scene_index);
                try self.writeAttr("name", c.name[0..c.name_len]);
                try self.buffer.appendSlice("/>\n");
            },
            .scene_delete => |c| {
                try self.writeAttrInt("sceneIndex", c.scene_index);
                try self.buffer.appendSlice("/>\n");
            },
            .scene_rename => |c| {
                try self.writeAttrInt("sceneIndex", c.scene_index);
                try self.writeAttr("oldName", c.old_name[0..c.old_len]);
                try self.writeAttr("newName", c.new_name[0..c.new_len]);
                try self.buffer.appendSlice("/>\n");
            },
            .bpm_change => |c| {
                try self.writeAttrFloat("oldBpm", c.old_bpm);
                try self.writeAttrFloat("newBpm", c.new_bpm);
                try self.buffer.appendSlice("/>\n");
            },
            .clip_move => |c| {
                if (c.moves.len == 0) {
                    try self.buffer.appendSlice("/>\n");
                } else {
                    try self.buffer.appendSlice(">\n");
                    self.indent_level += 1;
                    for (c.moves) |move| {
                        try self.writeIndent();
                        try self.buffer.appendSlice("<flux:Move");
                        try self.writeAttrInt("srcTrack", move.src_track);
                        try self.writeAttrInt("srcScene", move.src_scene);
                        try self.writeAttrInt("dstTrack", move.dst_track);
                        try self.writeAttrInt("dstScene", move.dst_scene);
                        try self.buffer.appendSlice("/>\n");
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.buffer.appendSlice("</flux:Command>\n");
                }
            },
        }
    }

    fn writeNote(self: *Self, note: *const ui.Note) !void {
        try self.writeIndent();
        try self.buffer.appendSlice("<flux:Note");
        try self.writeAttrInt("pitch", note.pitch);
        try self.writeAttrFloat("start", note.start);
        try self.writeAttrFloat("duration", note.duration);
        try self.buffer.appendSlice("/>\n");
    }
};

/// Serialize undo history to XML string
pub fn serializeToXml(allocator: std.mem.Allocator, undo_history: *const UndoHistory) ![]u8 {
    var writer = MetadataWriter.init(allocator);
    defer writer.deinit();
    try writer.writeMetadata(undo_history);
    return writer.toOwnedSlice();
}

/// Parse metadata.xml and restore undo history
pub fn parseMetadataXml(allocator: std.mem.Allocator, xml_data: []const u8) !UndoHistory {
    var undo_history = UndoHistory.init(allocator);
    errdefer undo_history.deinit();

    const xml = @import("xml");
    var static_reader: xml.Reader.Static = .init(allocator, xml_data, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var save_point: usize = 0;

    while (true) {
        const node = reader.read() catch break;
        switch (node) {
            .eof => break,
            .element_start => {
                const elem_name = reader.elementName();

                if (std.mem.eql(u8, elem_name, "flux:UndoHistory")) {
                    if (getAttrInt(reader, "savePoint")) |sp| {
                        save_point = @intCast(sp);
                    }
                } else if (std.mem.eql(u8, elem_name, "flux:Command")) {
                    if (try parseCommand(allocator, reader)) |cmd_entry| {
                        undo_history.pushWithTimestamp(cmd_entry.cmd, cmd_entry.timestamp);
                    }
                }
            },
            else => {},
        }
    }

    undo_history.setSavePoint(save_point);
    return undo_history;
}

fn parseCommand(allocator: std.mem.Allocator, reader: anytype) !?HistoryEntry {
    const type_str = getAttr(reader, "type") orelse return null;
    const timestamp = getAttrInt(reader, "ts") orelse 0;

    const kind = std.meta.stringToEnum(CommandKind, type_str) orelse return null;

    const cmd: Command = switch (kind) {
        .clip_create => .{
            .clip_create = .{
                .track = @intCast(getAttrInt(reader, "track") orelse 0),
                .scene = @intCast(getAttrInt(reader, "scene") orelse 0),
                .length_beats = @floatCast(getAttrFloat(reader, "length") orelse 16.0),
            },
        },
        .note_move => .{
            .note_move = .{
                .track = @intCast(getAttrInt(reader, "track") orelse 0),
                .scene = @intCast(getAttrInt(reader, "scene") orelse 0),
                .note_index = @intCast(getAttrInt(reader, "noteIndex") orelse 0),
                .old_start = @floatCast(getAttrFloat(reader, "oldStart") orelse 0),
                .old_pitch = @intCast(getAttrInt(reader, "oldPitch") orelse 60),
                .new_start = @floatCast(getAttrFloat(reader, "newStart") orelse 0),
                .new_pitch = @intCast(getAttrInt(reader, "newPitch") orelse 60),
            },
        },
        .note_resize => .{
            .note_resize = .{
                .track = @intCast(getAttrInt(reader, "track") orelse 0),
                .scene = @intCast(getAttrInt(reader, "scene") orelse 0),
                .note_index = @intCast(getAttrInt(reader, "noteIndex") orelse 0),
                .old_duration = @floatCast(getAttrFloat(reader, "oldDuration") orelse 1.0),
                .new_duration = @floatCast(getAttrFloat(reader, "newDuration") orelse 1.0),
            },
        },
        .track_volume => .{
            .track_volume = .{
                .track_index = @intCast(getAttrInt(reader, "trackIndex") orelse 0),
                .old_volume = @floatCast(getAttrFloat(reader, "oldVolume") orelse 0.8),
                .new_volume = @floatCast(getAttrFloat(reader, "newVolume") orelse 0.8),
            },
        },
        .track_mute => .{
            .track_mute = .{
                .track_index = @intCast(getAttrInt(reader, "trackIndex") orelse 0),
                .old_mute = getAttrBool(reader, "oldMute"),
                .new_mute = getAttrBool(reader, "newMute"),
            },
        },
        .track_solo => .{
            .track_solo = .{
                .track_index = @intCast(getAttrInt(reader, "trackIndex") orelse 0),
                .old_solo = getAttrBool(reader, "oldSolo"),
                .new_solo = getAttrBool(reader, "newSolo"),
            },
        },
        .bpm_change => .{
            .bpm_change = .{
                .old_bpm = @floatCast(getAttrFloat(reader, "oldBpm") orelse 120.0),
                .new_bpm = @floatCast(getAttrFloat(reader, "newBpm") orelse 120.0),
            },
        },
        // Commands requiring child element parsing - simplified for now
        else => {
            _ = allocator;
            return null;
        },
    };

    return .{
        .cmd = cmd,
        .timestamp = timestamp,
    };
}

fn getAttr(reader: anytype, name: []const u8) ?[]const u8 {
    if (reader.attributeIndex(name)) |idx| {
        return reader.attributeValue(idx) catch null;
    }
    return null;
}

fn getAttrInt(reader: anytype, name: []const u8) ?i64 {
    const str = getAttr(reader, name) orelse return null;
    return std.fmt.parseInt(i64, str, 10) catch null;
}

fn getAttrFloat(reader: anytype, name: []const u8) ?f64 {
    const str = getAttr(reader, name) orelse return null;
    return std.fmt.parseFloat(f64, str) catch null;
}

fn getAttrBool(reader: anytype, name: []const u8) bool {
    const str = getAttr(reader, name) orelse return false;
    return std.mem.eql(u8, str, "true");
}
