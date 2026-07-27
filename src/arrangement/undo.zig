const std = @import("std");
const arr_clip = @import("clip.zig");
const arr_track = @import("track.zig");
const arr_types = @import("types.zig");
const command = @import("../undo/command.zig");
const audio_clip = @import("../session/audio_clip.zig");

const AudioClipSnapshot = audio_clip.AudioClipSnapshot;

pub const Direction = enum { undo, redo };

/// Capture a placement's position plus a content snapshot of its pooled clip.
/// MIDI clips yield notes with a null audio snapshot; audio clips yield the
/// reverse. The snapshot owns its own note slice / retained sample.
pub fn captureClip(
    view: *arr_types.ArrangementView,
    track: usize,
    index: usize,
    clip: *const arr_clip.ArrangementClip,
) !command.ArrangementClipAt {
    var notes: []const command.Note = &.{};
    var audio: ?AudioClipSnapshot = null;
    var length_beats: f32 = 0;
    var color: u32 = 0;
    var name: @import("../session/types.zig").NameField = .{};

    if (view.placementClip(@constCast(clip))) |pooled| {
        length_beats = pooled.lengthBeats();
        color = pooled.color;
        name = pooled.name;
        switch (pooled.content) {
            .midi => |*m| {
                notes = try view.allocator.dupe(command.Note, m.notes.items);
            },
            .audio => |*a| {
                if (view.sample_store) |store| {
                    audio = try AudioClipSnapshot.capture(a, store);
                }
            },
        }
    }
    errdefer if (notes.len > 0) view.allocator.free(notes);

    return .{
        .track = track,
        .index = index,
        .clip = .{
            .start_tick = clip.start_tick,
            .duration_ticks = clip.duration_ticks,
            .source_offset_ticks = clip.source_offset_ticks,
            .color = color,
            .name = name,
            .enabled = clip.enabled,
            .length_beats = length_beats,
            .midi_notes = notes,
            .audio = audio,
        },
    };
}

pub fn deinitCaptured(allocator: std.mem.Allocator, item: command.ArrangementClipAt) void {
    if (item.clip.midi_notes.len > 0) allocator.free(item.clip.midi_notes);
    if (item.clip.audio) |audio| {
        var a = audio;
        a.deinit();
    }
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
                    view.releasePlacement(&view.tracks.items[track_index].clips.items[clip_index]);
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

/// Rebuild a placement (and a fresh pooled clip) from a captured snapshot.
fn insertClip(view: *arr_types.ArrangementView, item: command.ArrangementClipAt) !void {
    if (item.track >= view.tracks.items.len) return error.InvalidTrack;
    const data = item.clip;
    const is_audio = if (data.audio) |a| a.clip.hasAudio() else false;
    const kind: arr_clip.ClipKind = if (is_audio) .audio else .midi;
    const id = view.addPooledClip(kind, data.length_beats);
    if (id.isNone()) return error.OutOfMemory;

    if (view.clip_pool.?.get(id)) |pooled| {
        pooled.name = data.name;
        pooled.color = data.color;
        switch (pooled.content) {
            .midi => |*m| {
                try m.notes.appendSlice(m.allocator, data.midi_notes);
                if (data.length_beats > 0) m.length_beats = data.length_beats;
            },
            .audio => |*a| {
                if (data.audio) |snap| snap.apply(a) catch {};
                if (data.length_beats > 0) a.length_beats = data.length_beats;
            },
        }
    }

    const clip: arr_clip.ArrangementClip = .{
        .clip = id,
        .start_tick = data.start_tick,
        .duration_ticks = data.duration_ticks,
        .source_offset_ticks = data.source_offset_ticks,
        .enabled = data.enabled,
    };
    const dst_index = @min(item.index, view.tracks.items[item.track].clips.items.len);
    view.tracks.items[item.track].clips.insert(view.allocator, dst_index, clip) catch |err| {
        view.releasePlacement(&clip);
        return err;
    };
}

pub fn executeTrackAdd(view: *arr_types.ArrangementView, cmd: command.ArrangementTrackAddCmd, direction: Direction) void {
    if (direction == .undo) {
        if (cmd.index >= view.tracks.items.len) return;
        view.tracks.items[cmd.index].deinit(view.allocator, view.clip_pool, view.sample_store);
        _ = view.tracks.orderedRemove(cmd.index);
        return;
    }
    const track = arr_track.ArrangementTrack.init(cmd.name.get(), cmd.session_track_index, cmd.color);
    view.tracks.insert(view.allocator, @min(cmd.index, view.tracks.items.len), track) catch {};
}

test "arrangement edit moves a clip across tracks and reverses cleanly" {
    const allocator = std.testing.allocator;
    const clip_pool_mod = @import("../session/clip_pool.zig");
    var pool = clip_pool_mod.ClipPool.init(allocator);
    defer pool.deinit(null);
    var view = arr_types.ArrangementView.init(allocator);
    view.clip_pool = &pool;
    defer view.deinit();
    view.clearTracks();
    try view.tracks.append(allocator, arr_track.ArrangementTrack.init("A", 0, .{ 1, 0, 0, 1 }));
    try view.tracks.append(allocator, arr_track.ArrangementTrack.init("B", 1, .{ 0, 1, 0, 1 }));

    const arr_ops = @import("ops.zig");
    const clip_index = try arr_ops.createClip(&view, 0, .midi, 120, 960, "Lead");
    const midi = view.placementMidi(&view.tracks.items[0].clips.items[clip_index]).?;
    try midi.notes.append(allocator, .{ .pitch = 64, .start = 0.25, .duration = 0.5 });

    const before = try captureClip(&view, 0, 0, &view.tracks.items[0].clips.items[0]);
    var after = try captureClip(&view, 1, 0, &view.tracks.items[0].clips.items[0]);
    after.clip.start_tick = 1920;
    const changes = try allocator.alloc(command.ArrangementClipChange, 1);
    changes[0] = .{ .before = before, .after = after };
    var cmd: command.Command = .{ .arrangement_edit = .{ .changes = changes } };
    defer cmd.deinit(allocator);

    execute(&view, &cmd.arrangement_edit, .redo);
    try std.testing.expectEqual(@as(usize, 0), view.tracks.items[0].clips.items.len);
    try std.testing.expectEqual(@as(i64, 1920), view.tracks.items[1].clips.items[0].start_tick);
    try std.testing.expectEqual(@as(u8, 64), view.placementMidi(&view.tracks.items[1].clips.items[0]).?.notes.items[0].pitch);

    execute(&view, &cmd.arrangement_edit, .undo);
    try std.testing.expectEqual(@as(usize, 0), view.tracks.items[1].clips.items.len);
    try std.testing.expectEqual(@as(i64, 120), view.tracks.items[0].clips.items[0].start_tick);
    try std.testing.expectEqualStrings("Lead", view.placementClip(&view.tracks.items[0].clips.items[0]).?.name.get());
}
