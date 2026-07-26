const std = @import("std");
const arr_clip = @import("clip.zig");
const arr_track = @import("track.zig");
const arr_types = @import("types.zig");
const command = @import("../undo/command.zig");

pub const Direction = enum { undo, redo };

pub fn captureClip(
    allocator: std.mem.Allocator,
    track: usize,
    index: usize,
    clip: *const arr_clip.ArrangementClip,
) !command.ArrangementClipAt {
    const path = if (clip.audio_path) |value| try allocator.dupe(u8, value) else &.{};
    errdefer if (path.len > 0) allocator.free(path);
    const notes = if (clip.midi) |midi| try allocator.dupe(command.Note, midi.notes.items) else &.{};
    return .{
        .track = track,
        .index = index,
        .clip = .{
            .kind = clip.kind,
            .start_tick = clip.start_tick,
            .duration_ticks = clip.duration_ticks,
            .source_offset_ticks = clip.source_offset_ticks,
            .color = clip.color,
            .name = clip.name,
            .enabled = clip.enabled,
            .audio_path = path,
            .midi_session_track = clip.midi_session_track,
            .midi_session_scene = clip.midi_session_scene,
            .midi_length_beats = if (clip.midi) |midi| midi.length_beats else 0,
            .midi_notes = notes,
        },
    };
}

pub fn deinitCaptured(allocator: std.mem.Allocator, item: command.ArrangementClipAt) void {
    if (item.clip.audio_path.len > 0) allocator.free(item.clip.audio_path);
    if (item.clip.midi_notes.len > 0) allocator.free(item.clip.midi_notes);
}

pub fn deinitChanges(allocator: std.mem.Allocator, changes: []command.ArrangementClipChange) void {
    for (changes) |change| {
        if (change.before) |item| deinitCaptured(allocator, item);
        if (change.after) |item| deinitCaptured(allocator, item);
    }
    if (changes.len > 0) allocator.free(changes);
}

pub fn execute(view: *arr_types.ArrangementView, edit: *const command.ArrangementEditCmd, direction: Direction) void {
    removeSide(view, edit.changes, if (direction == .undo) .after else .before);
    insertSide(view, edit.changes, if (direction == .undo) .before else .after);
}

const Side = enum { before, after };

fn side(change: command.ArrangementClipChange, which: Side) ?command.ArrangementClipAt {
    return if (which == .before) change.before else change.after;
}

fn removeSide(view: *arr_types.ArrangementView, changes: []const command.ArrangementClipChange, which: Side) void {
    var track_index = view.tracks.items.len;
    while (track_index > 0) {
        track_index -= 1;
        var clip_index = view.tracks.items[track_index].clips.items.len;
        while (clip_index > 0) {
            clip_index -= 1;
            for (changes) |change| {
                const item = side(change, which) orelse continue;
                if (item.track == track_index and item.index == clip_index) {
                    var clip = &view.tracks.items[track_index].clips.items[clip_index];
                    clip.deinit(view.allocator);
                    _ = view.tracks.items[track_index].clips.orderedRemove(clip_index);
                    break;
                }
            }
        }
    }
}

fn insertSide(view: *arr_types.ArrangementView, changes: []const command.ArrangementClipChange, which: Side) void {
    // Repeatedly choose the lowest position so original indices remain stable.
    var inserted: usize = 0;
    while (inserted < changes.len) {
        var best: ?command.ArrangementClipAt = null;
        var best_ordinal: usize = 0;
        for (changes, 0..) |change, ordinal| {
            const item = side(change, which) orelse continue;
            var earlier_count: usize = 0;
            for (changes) |other_change| {
                const other = side(other_change, which) orelse continue;
                if (other.track < item.track or (other.track == item.track and other.index < item.index)) earlier_count += 1;
            }
            if (earlier_count != inserted) continue;
            if (best == null or ordinal < best_ordinal) {
                best = item;
                best_ordinal = ordinal;
            }
        }
        const item = best orelse break;
        insertClip(view, item) catch return;
        inserted += 1;
    }
}

fn insertClip(view: *arr_types.ArrangementView, item: command.ArrangementClipAt) !void {
    if (item.track >= view.tracks.items.len) return error.InvalidTrack;
    const data = item.clip;
    var clip = arr_clip.ArrangementClip.init(view.allocator, data.kind, data.start_tick, data.duration_ticks);
    errdefer clip.deinit(view.allocator);
    clip.color = data.color;
    clip.source_offset_ticks = data.source_offset_ticks;
    clip.name = data.name;
    clip.enabled = data.enabled;
    clip.midi_session_track = data.midi_session_track;
    clip.midi_session_scene = data.midi_session_scene;
    if (data.audio_path.len > 0) clip.audio_path = try view.allocator.dupe(u8, data.audio_path);
    if (clip.midi) |*midi| {
        midi.length_beats = data.midi_length_beats;
        try midi.notes.appendSlice(midi.allocator, data.midi_notes);
    }
    const index = @min(item.index, view.tracks.items[item.track].clips.items.len);
    try view.tracks.items[item.track].clips.insert(view.allocator, index, clip);
}

pub fn executeTrackAdd(view: *arr_types.ArrangementView, cmd: command.ArrangementTrackAddCmd, direction: Direction) void {
    if (direction == .undo) {
        if (cmd.index >= view.tracks.items.len) return;
        view.tracks.items[cmd.index].deinit(view.allocator);
        _ = view.tracks.orderedRemove(cmd.index);
        return;
    }
    const track = arr_track.ArrangementTrack.init(cmd.name.get(), cmd.session_track_index, cmd.color);
    view.tracks.insert(view.allocator, @min(cmd.index, view.tracks.items.len), track) catch {};
}

test "arrangement edit moves a clip across tracks and reverses cleanly" {
    const allocator = std.testing.allocator;
    var view = arr_types.ArrangementView.init(allocator);
    defer view.deinit();
    view.clearTracks();
    try view.tracks.append(allocator, arr_track.ArrangementTrack.init("A", 0, .{ 1, 0, 0, 1 }));
    try view.tracks.append(allocator, arr_track.ArrangementTrack.init("B", 1, .{ 0, 1, 0, 1 }));

    var clip = arr_clip.ArrangementClip.init(allocator, .midi, 120, 960);
    clip.name.set("Lead");
    try clip.midi.?.notes.append(allocator, .{ .pitch = 64, .start = 0.25, .duration = 0.5 });
    try view.tracks.items[0].clips.append(allocator, clip);

    const before = try captureClip(allocator, 0, 0, &view.tracks.items[0].clips.items[0]);
    var after = try captureClip(allocator, 1, 0, &view.tracks.items[0].clips.items[0]);
    after.clip.start_tick = 1920;
    const changes = try allocator.alloc(command.ArrangementClipChange, 1);
    changes[0] = .{ .before = before, .after = after };
    var cmd: command.Command = .{ .arrangement_edit = .{ .changes = changes } };
    defer cmd.deinit(allocator);

    execute(&view, &cmd.arrangement_edit, .redo);
    try std.testing.expectEqual(@as(usize, 0), view.tracks.items[0].clips.items.len);
    try std.testing.expectEqual(@as(i64, 1920), view.tracks.items[1].clips.items[0].start_tick);
    try std.testing.expectEqual(@as(u8, 64), view.tracks.items[1].clips.items[0].midi.?.notes.items[0].pitch);

    execute(&view, &cmd.arrangement_edit, .undo);
    try std.testing.expectEqual(@as(usize, 0), view.tracks.items[1].clips.items.len);
    try std.testing.expectEqual(@as(i64, 120), view.tracks.items[0].clips.items[0].start_tick);
    try std.testing.expectEqualStrings("Lead", view.tracks.items[0].clips.items[0].name.get());
}
