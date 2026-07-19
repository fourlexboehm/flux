//! XML serialization for undo history stored in DAWproject archives.
//! Keeps undo data separate from the main project.xml payload.

const std = @import("std");
const command = @import("command.zig");
const history = @import("history.zig");
const SampleStore = @import("../audio/sample_store.zig").SampleStore;
const session_view = @import("../session/types.zig");
const XmlWriter = @import("../project/format/xml_writer.zig").XmlWriter;
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
        const commands = undo_history.getUndoCommands();
        var suffix_start: usize = 0;
        for (commands, 0..) |entry, i| {
            if (!isLosslesslySerialized(entry.cmd)) suffix_start = i + 1;
        }
        const save_point = undo_history.getSavePoint();
        const suffix_save_point = if (save_point >= suffix_start)
            @min(save_point - suffix_start, commands.len - suffix_start)
        else
            0;

        try self.xml.writeIndent();
        try self.xml.buffer.appendSlice(self.xml.allocator, "<flux:UndoHistory");
        try self.xml.writeAttr("version", "1");
        try self.xml.writeAttrInt("savePoint", suffix_save_point);
        try self.xml.buffer.appendSlice(self.xml.allocator, ">\n");
        self.xml.indent_level += 1;

        // A hole in an undo chain is unsafe: retain only the complete suffix.
        for (commands[suffix_start..]) |entry| {
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
            .clip_rename => |c| {
                try self.xml.writeAttrInt("track", c.track);
                try self.xml.writeAttrInt("scene", c.scene);
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
                if (c.fx_index) |fx| {
                    try self.xml.writeAttrInt("fxIndex", fx);
                }
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

/// Replace `history` contents from a flux_undo.xml payload.
pub fn deserializeFromXml(
    hist: *UndoHistory,
    xml_data: []const u8,
    sample_store: *SampleStore,
) !void {
    _ = sample_store;
    hist.clear();

    const xml = @import("xml");
    var static_reader: xml.Reader.Static = .init(hist.allocator, xml_data, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var save_point: usize = 0;
    var in_history = false;
    var cmd_builder: ?CommandBuilder = null;

    while (true) {
        const node = reader.read() catch break;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (isLocal(name, "UndoHistory")) {
                    in_history = true;
                    if (attrUsize(reader, "savePoint")) |sp| save_point = sp;
                } else if (in_history and isLocal(name, "Command")) {
                    if (cmd_builder) |*b| {
                        finishAndAppend(hist, b);
                        cmd_builder = null;
                    }
                    cmd_builder = beginCommand(hist.allocator, reader);
                } else if (cmd_builder) |*b| {
                    if (isLocal(name, "Note")) {
                        b.addNote(parseNote(reader)) catch {};
                    } else if (isLocal(name, "OldNotes")) {
                        b.note_target = .old_notes;
                    } else if (isLocal(name, "NewNotes")) {
                        b.note_target = .new_notes;
                    } else if (isLocal(name, "Move")) {
                        b.addMove(.{
                            .src_track = attrUsize(reader, "srcTrack") orelse 0,
                            .src_scene = attrUsize(reader, "srcScene") orelse 0,
                            .dst_track = attrUsize(reader, "dstTrack") orelse 0,
                            .dst_scene = attrUsize(reader, "dstScene") orelse 0,
                        }) catch {};
                    }
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (isLocal(name, "Command")) {
                    if (cmd_builder) |*b| {
                        finishAndAppend(hist, b);
                        cmd_builder = null;
                    }
                } else if (isLocal(name, "OldNotes") or isLocal(name, "NewNotes")) {
                    if (cmd_builder) |*b| b.note_target = .default;
                } else if (isLocal(name, "UndoHistory")) {
                    in_history = false;
                }
            },
            else => {},
        }
    }

    if (cmd_builder) |*b| {
        finishAndAppend(hist, b);
    }

    hist.setSavePoint(@min(save_point, hist.undoCount()));
}

fn finishAndAppend(hist: *UndoHistory, b: *CommandBuilder) void {
    if (finishCommand(hist, b)) |entry| {
        hist.appendRestored(entry);
    } else |err| {
        // Commands before an incomplete entry cannot safely follow it in the chain.
        if (err == error.IncompleteSerializedCommand) hist.clear();
        std.log.warn("Skipping incomplete undo command: {s}", .{@tagName(b.kind)});
    }
}

const NoteTarget = enum { default, old_notes, new_notes };

const CommandBuilder = struct {
    kind: CommandKind,
    timestamp: history.Timestamp = 0,
    // Shared attrs
    track: usize = 0,
    scene: usize = 0,
    track_index: usize = 0,
    fx_index: ?usize = null,
    scene_index: usize = 0,
    note_index: usize = 0,
    length_beats: f32 = 0,
    old_length: f32 = 0,
    new_length: f32 = 0,
    old_start: f32 = 0,
    new_start: f32 = 0,
    old_duration: f32 = 0,
    new_duration: f32 = 0,
    old_pitch: u8 = 0,
    new_pitch: u8 = 0,
    old_volume: f32 = 0,
    new_volume: f32 = 0,
    old_bpm: f32 = 120,
    new_bpm: f32 = 120,
    old_mute: bool = false,
    new_mute: bool = false,
    old_solo: bool = false,
    new_solo: bool = false,
    old_index: i32 = 0,
    new_index: i32 = 0,
    old_has_clip: bool = false,
    new_has_clip: bool = false,
    old_clip_length: f32 = 0,
    new_clip_length: f32 = 0,
    name: session_view.NameField = .{}, // track_add / scene_add
    old_name: session_view.NameField = .{},
    new_name: session_view.NameField = .{},
    note: Note = .{ .pitch = 0, .start = 0, .duration = 0 },
    notes: std.ArrayListUnmanaged(Note) = .empty,
    old_notes: std.ArrayListUnmanaged(Note) = .empty,
    new_notes: std.ArrayListUnmanaged(Note) = .empty,
    moves: std.ArrayListUnmanaged(command.ClipMoveCmd.ClipMove) = .empty,
    note_target: NoteTarget = .default,
    allocator: std.mem.Allocator,

    fn deinitLists(self: *CommandBuilder) void {
        self.notes.deinit(self.allocator);
        self.old_notes.deinit(self.allocator);
        self.new_notes.deinit(self.allocator);
        self.moves.deinit(self.allocator);
    }

    fn addNote(self: *CommandBuilder, n: Note) !void {
        switch (self.note_target) {
            .default => try self.notes.append(self.allocator, n),
            .old_notes => try self.old_notes.append(self.allocator, n),
            .new_notes => try self.new_notes.append(self.allocator, n),
        }
    }

    fn addMove(self: *CommandBuilder, m: command.ClipMoveCmd.ClipMove) !void {
        try self.moves.append(self.allocator, m);
    }
};

fn beginCommand(allocator: std.mem.Allocator, reader: anytype) ?CommandBuilder {
    const type_str = attr(reader, "type") orelse return null;
    const kind = std.meta.stringToEnum(CommandKind, type_str) orelse {
        std.log.warn("Unknown undo command type: {s}", .{type_str});
        return null;
    };

    var b: CommandBuilder = .{
        .kind = kind,
        .allocator = allocator,
        .timestamp = attrI64(reader, "ts") orelse 0,
    };

    b.track = attrUsize(reader, "track") orelse 0;
    b.scene = attrUsize(reader, "scene") orelse 0;
    b.track_index = attrUsize(reader, "trackIndex") orelse 0;
    b.fx_index = attrUsize(reader, "fxIndex");
    b.scene_index = attrUsize(reader, "sceneIndex") orelse 0;
    b.note_index = attrUsize(reader, "noteIndex") orelse 0;
    b.length_beats = attrF32(reader, "length") orelse 0;
    b.old_length = attrF32(reader, "oldLength") orelse 0;
    b.new_length = attrF32(reader, "newLength") orelse 0;
    b.old_start = attrF32(reader, "oldStart") orelse 0;
    b.new_start = attrF32(reader, "newStart") orelse 0;
    b.old_duration = attrF32(reader, "oldDuration") orelse 0;
    b.new_duration = attrF32(reader, "newDuration") orelse 0;
    b.old_pitch = @intCast(attrUsize(reader, "oldPitch") orelse 0);
    b.new_pitch = @intCast(attrUsize(reader, "newPitch") orelse 0);
    b.old_volume = attrF32(reader, "oldVolume") orelse 0;
    b.new_volume = attrF32(reader, "newVolume") orelse 0;
    b.old_bpm = attrF32(reader, "oldBpm") orelse 120;
    b.new_bpm = attrF32(reader, "newBpm") orelse 120;
    b.old_mute = attrBool(reader, "oldMute");
    b.new_mute = attrBool(reader, "newMute");
    b.old_solo = attrBool(reader, "oldSolo");
    b.new_solo = attrBool(reader, "newSolo");
    b.old_index = attrI32(reader, "oldIndex") orelse 0;
    b.new_index = attrI32(reader, "newIndex") orelse 0;
    b.old_has_clip = (attrUsize(reader, "oldHasClip") orelse 0) != 0;
    b.new_has_clip = (attrUsize(reader, "newHasClip") orelse 0) != 0;
    b.old_clip_length = attrF32(reader, "oldLength") orelse 0;
    b.new_clip_length = attrF32(reader, "newLength") orelse 0;

    if (attr(reader, "name")) |n| b.name = session_view.NameField.init(n);
    if (attr(reader, "oldName")) |n| b.old_name = session_view.NameField.init(n);
    if (attr(reader, "newName")) |n| b.new_name = session_view.NameField.init(n);

    return b;
}

fn finishCommand(
    hist: *UndoHistory,
    b: *CommandBuilder,
) !HistoryEntry {
    defer b.deinitLists();
    const allocator = hist.allocator;
    const cmd: Command = switch (b.kind) {
        .clip_create => .{ .clip_create = .{
            .track = b.track,
            .scene = b.scene,
            .length_beats = b.length_beats,
        } },
        .clip_delete, .clip_paste => return error.IncompleteSerializedCommand,
        .clip_move => blk: {
            const moves = try allocator.dupe(command.ClipMoveCmd.ClipMove, b.moves.items);
            errdefer allocator.free(moves);
            break :blk .{ .clip_move = .{ .moves = moves } };
        },
        .clip_resize => .{ .clip_resize = .{
            .track = b.track,
            .scene = b.scene,
            .old_length = b.old_length,
            .new_length = b.new_length,
        } },
        .clip_rename => .{ .clip_rename = .{
            .track = b.track,
            .scene = b.scene,
            .old_name = b.old_name,
            .new_name = b.new_name,
        } },
        .note_add, .note_remove, .note_batch => return error.IncompleteSerializedCommand,
        .note_move => .{ .note_move = .{
            .track = b.track,
            .scene = b.scene,
            .note_index = b.note_index,
            .old_start = b.old_start,
            .old_pitch = b.old_pitch,
            .new_start = b.new_start,
            .new_pitch = b.new_pitch,
        } },
        .note_resize => .{ .note_resize = .{
            .track = b.track,
            .scene = b.scene,
            .note_index = b.note_index,
            .old_duration = b.old_duration,
            .new_duration = b.new_duration,
        } },
        .track_add => .{ .track_add = .{
            .track_index = b.track_index,
            .name = b.name,
        } },
        .track_delete => return error.IncompleteSerializedCommand,
        .track_rename => .{ .track_rename = .{
            .track_index = b.track_index,
            .old_name = b.old_name,
            .new_name = b.new_name,
        } },
        .track_volume => .{ .track_volume = .{
            .track_index = b.track_index,
            .old_volume = b.old_volume,
            .new_volume = b.new_volume,
        } },
        .track_mute => .{ .track_mute = .{
            .track_index = b.track_index,
            .old_mute = b.old_mute,
            .new_mute = b.new_mute,
        } },
        .track_solo => .{ .track_solo = .{
            .track_index = b.track_index,
            .old_solo = b.old_solo,
            .new_solo = b.new_solo,
        } },
        .scene_add => .{ .scene_add = .{
            .scene_index = b.scene_index,
            .name = b.name,
        } },
        .scene_delete => return error.IncompleteSerializedCommand,
        .scene_rename => .{ .scene_rename = .{
            .scene_index = b.scene_index,
            .old_name = b.old_name,
            .new_name = b.new_name,
        } },
        .bpm_change => .{ .bpm_change = .{
            .old_bpm = b.old_bpm,
            .new_bpm = b.new_bpm,
        } },
        .quantize_change => .{ .quantize_change = .{
            .old_index = b.old_index,
            .new_index = b.new_index,
        } },
        .plugin_state => return error.IncompleteSerializedCommand,
    };

    return .{
        .cmd = cmd,
        .timestamp = b.timestamp,
    };
}

fn isLosslesslySerialized(cmd: Command) bool {
    return switch (cmd) {
        .clip_delete,
        .clip_paste,
        .note_add,
        .note_remove,
        .note_batch,
        .track_delete,
        .scene_delete,
        .plugin_state,
        => false,
        else => true,
    };
}

fn parseNote(reader: anytype) Note {
    return .{
        .pitch = @intCast(attrUsize(reader, "pitch") orelse 0),
        .start = attrF32(reader, "start") orelse 0,
        .duration = attrF32(reader, "duration") orelse 0,
    };
}

fn isLocal(name: []const u8, local: []const u8) bool {
    if (std.mem.eql(u8, name, local)) return true;
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| {
        return std.mem.eql(u8, name[colon + 1 ..], local);
    }
    return false;
}

fn attr(reader: anytype, name: []const u8) ?[]const u8 {
    if (reader.attributeIndex(name)) |idx| {
        return reader.attributeValue(idx) catch null;
    }
    return null;
}

fn attrUsize(reader: anytype, name: []const u8) ?usize {
    const s = attr(reader, name) orelse return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

fn attrI32(reader: anytype, name: []const u8) ?i32 {
    const s = attr(reader, name) orelse return null;
    return std.fmt.parseInt(i32, s, 10) catch null;
}

fn attrI64(reader: anytype, name: []const u8) ?i64 {
    const s = attr(reader, name) orelse return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn attrF32(reader: anytype, name: []const u8) ?f32 {
    const s = attr(reader, name) orelse return null;
    return std.fmt.parseFloat(f32, s) catch null;
}

fn attrBool(reader: anytype, name: []const u8) bool {
    const s = attr(reader, name) orelse return false;
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1");
}

test "serialization keeps only complete undo suffix" {
    const allocator = std.testing.allocator;
    var hist = UndoHistory.init(allocator);
    defer hist.deinit();
    hist.push(.{ .track_volume = .{ .track_index = 0, .old_volume = 1, .new_volume = 0.5 } });
    hist.push(.{ .plugin_state = .{ .track_index = 0, .old_state = &.{}, .new_state = &.{} } });
    hist.push(.{ .bpm_change = .{ .old_bpm = 120, .new_bpm = 125 } });
    hist.markSavePoint();

    const xml = try serializeToXml(allocator, &hist);
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "bpm_change") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "track_volume") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "plugin_state") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "savePoint=\"1\"") != null);
}
