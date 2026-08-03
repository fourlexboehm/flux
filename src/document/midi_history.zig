//! Lightweight MIDI clip undo/redo for the document layer.
//!
//! Snapshots full note lists + clip timing (notes_replace style). Gestures
//! capture once at begin and commit one history entry on end when content
//! actually changed. Bulk tools and discrete adds/removes push immediately.

const std = @import("std");
const notes = @import("../session/notes.zig");

pub const max_depth: usize = 64;

pub const Snapshot = struct {
    track: usize,
    scene: usize,
    notes_slice: []notes.Note,
    timing: notes.ClipTiming,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        if (self.notes_slice.len > 0) allocator.free(self.notes_slice);
        self.* = .{
            .track = 0,
            .scene = 0,
            .notes_slice = &.{},
            .timing = .{},
        };
    }
};

pub const Entry = struct {
    track: usize,
    scene: usize,
    old_notes: []notes.Note,
    new_notes: []notes.Note,
    old_timing: notes.ClipTiming,
    new_timing: notes.ClipTiming,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.old_notes.len > 0) allocator.free(self.old_notes);
        if (self.new_notes.len > 0) allocator.free(self.new_notes);
        self.* = .{
            .track = 0,
            .scene = 0,
            .old_notes = &.{},
            .new_notes = &.{},
            .old_timing = .{},
            .new_timing = .{},
        };
    }
};

pub const History = struct {
    allocator: std.mem.Allocator,
    undo_stack: std.ArrayListUnmanaged(Entry) = .empty,
    redo_stack: std.ArrayListUnmanaged(Entry) = .empty,
    /// Open gesture capture (drag / multi-step edit). Null when idle.
    pending: ?Snapshot = null,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        self.clearPending();
        clearStack(self.allocator, &self.undo_stack);
        clearStack(self.allocator, &self.redo_stack);
        self.* = undefined;
    }

    pub fn clear(self: *History) void {
        self.clearPending();
        clearStack(self.allocator, &self.undo_stack);
        clearStack(self.allocator, &self.redo_stack);
    }

    /// Drop an open gesture without recording (no content change).
    pub fn cancelGesture(self: *History) void {
        self.clearPending();
    }

    pub fn canUndo(self: *const History) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const History) bool {
        return self.redo_stack.items.len > 0;
    }

    /// Capture clip state before an in-place gesture. Replaces any open pending.
    pub fn beginGesture(self: *History, track: usize, scene: usize, clip: *const notes.PianoRollClip) void {
        self.clearPending();
        self.pending = captureClip(self.allocator, track, scene, clip) catch null;
    }

    /// If a gesture is open for this clip and content differs, push one entry.
    pub fn endGesture(self: *History, track: usize, scene: usize, clip: *const notes.PianoRollClip) void {
        const pending = self.pending orelse return;
        if (pending.track != track or pending.scene != scene) {
            self.clearPending();
            return;
        }
        self.pending = null;

        const after = captureClip(self.allocator, track, scene, clip) catch {
            var fail = pending;
            fail.deinit(self.allocator);
            return;
        };

        if (snapshotsEqual(pending, after)) {
            var old_snap = pending;
            old_snap.deinit(self.allocator);
            var new_snap = after;
            new_snap.deinit(self.allocator);
            return;
        }

        // Slice ownership moves into the history entry.
        self.pushEntry(.{
            .track = track,
            .scene = scene,
            .old_notes = pending.notes_slice,
            .new_notes = after.notes_slice,
            .old_timing = pending.timing,
            .new_timing = after.timing,
        }) catch {
            self.allocator.free(pending.notes_slice);
            self.allocator.free(after.notes_slice);
        };
    }

    /// Snapshot before/after around an already-applied discrete mutation.
    pub fn recordReplace(
        self: *History,
        track: usize,
        scene: usize,
        old_notes: []const notes.Note,
        new_notes: []const notes.Note,
        old_timing: notes.ClipTiming,
        new_timing: notes.ClipTiming,
    ) void {
        if (notesEqual(old_notes, new_notes) and timingsEqual(old_timing, new_timing)) return;
        const owned_old = self.allocator.dupe(notes.Note, old_notes) catch return;
        errdefer self.allocator.free(owned_old);
        const owned_new = self.allocator.dupe(notes.Note, new_notes) catch {
            self.allocator.free(owned_old);
            return;
        };
        self.pushEntry(.{
            .track = track,
            .scene = scene,
            .old_notes = owned_old,
            .new_notes = owned_new,
            .old_timing = old_timing,
            .new_timing = new_timing,
        }) catch {
            self.allocator.free(owned_old);
            self.allocator.free(owned_new);
        };
    }

    /// Pop undo entry without applying. Caller applies then discards via freeEntry.
    pub fn popUndo(self: *History) ?Entry {
        if (self.undo_stack.items.len == 0) return null;
        return self.undo_stack.pop();
    }

    pub fn popRedo(self: *History) ?Entry {
        if (self.redo_stack.items.len == 0) return null;
        return self.redo_stack.pop();
    }

    /// After a successful undo application, park the entry on the redo stack.
    pub fn confirmUndo(self: *History, entry: Entry) void {
        self.redo_stack.append(self.allocator, entry) catch {
            var e = entry;
            e.deinit(self.allocator);
            return;
        };
        trimStack(self.allocator, &self.redo_stack);
    }

    /// After a successful redo application, park the entry on the undo stack.
    pub fn confirmRedo(self: *History, entry: Entry) void {
        self.undo_stack.append(self.allocator, entry) catch {
            var e = entry;
            e.deinit(self.allocator);
            return;
        };
        trimStack(self.allocator, &self.undo_stack);
    }

    pub fn freeEntry(self: *History, entry: Entry) void {
        var e = entry;
        e.deinit(self.allocator);
    }

    fn pushEntry(self: *History, entry: Entry) !void {
        clearStack(self.allocator, &self.redo_stack);
        try self.undo_stack.append(self.allocator, entry);
        trimStack(self.allocator, &self.undo_stack);
    }

    fn clearPending(self: *History) void {
        if (self.pending) |*p| {
            p.deinit(self.allocator);
            self.pending = null;
        }
    }
};

fn captureClip(allocator: std.mem.Allocator, track: usize, scene: usize, clip: *const notes.PianoRollClip) !Snapshot {
    const owned = try allocator.dupe(notes.Note, clip.notes.items);
    return .{
        .track = track,
        .scene = scene,
        .notes_slice = owned,
        .timing = timingOf(clip),
    };
}

pub fn timingOf(clip: *const notes.PianoRollClip) notes.ClipTiming {
    return .{
        .length = clip.length_beats,
        .play_start = clip.play_start_beats,
        .loop_start = clip.loop_start_beats,
        .loop_end = clip.loop_end_beats,
    };
}

pub fn applyTiming(clip: *notes.PianoRollClip, timing: notes.ClipTiming) void {
    clip.length_beats = timing.length;
    clip.play_start_beats = timing.play_start;
    clip.loop_start_beats = timing.loop_start;
    clip.loop_end_beats = timing.loop_end;
}

pub fn replaceNotes(clip: *notes.PianoRollClip, source: []const notes.Note) void {
    clip.notes.clearRetainingCapacity();
    clip.notes.appendSlice(clip.allocator, source) catch {
        // Best-effort: try one-by-one so a partial restore is still useful.
        for (source) |note| clip.notes.append(clip.allocator, note) catch break;
    };
}

fn clearStack(allocator: std.mem.Allocator, stack: *std.ArrayListUnmanaged(Entry)) void {
    for (stack.items) |*entry| entry.deinit(allocator);
    stack.deinit(allocator);
    stack.* = .empty;
}

fn trimStack(allocator: std.mem.Allocator, stack: *std.ArrayListUnmanaged(Entry)) void {
    while (stack.items.len > max_depth) {
        var oldest = stack.orderedRemove(0);
        oldest.deinit(allocator);
    }
}

fn snapshotsEqual(a: Snapshot, b: Snapshot) bool {
    return notesEqual(a.notes_slice, b.notes_slice) and timingsEqual(a.timing, b.timing);
}

fn notesEqual(a: []const notes.Note, b: []const notes.Note) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.pitch != right.pitch) return false;
        if (left.start != right.start) return false;
        if (left.duration != right.duration) return false;
        if (left.velocity != right.velocity) return false;
        if (left.release_velocity != right.release_velocity) return false;
    }
    return true;
}

fn timingsEqual(a: notes.ClipTiming, b: notes.ClipTiming) bool {
    return a.length == b.length and
        a.play_start == b.play_start and
        a.loop_start == b.loop_start and
        a.loop_end == b.loop_end;
}

test "midi history undo redo round-trip ownership" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    const old = [_]notes.Note{.{ .pitch = 60, .start = 0, .duration = 1 }};
    const new = [_]notes.Note{
        .{ .pitch = 60, .start = 0, .duration = 1 },
        .{ .pitch = 64, .start = 1, .duration = 0.5 },
    };
    history.recordReplace(0, 0, &old, &new, .{ .length = 16 }, .{ .length = 16 });
    try std.testing.expect(history.canUndo());
    try std.testing.expect(!history.canRedo());

    const undone = history.popUndo() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), undone.old_notes.len);
    try std.testing.expectEqual(@as(usize, 2), undone.new_notes.len);
    history.confirmUndo(undone);
    try std.testing.expect(history.canRedo());

    const redone = history.popRedo() orelse return error.TestUnexpectedResult;
    history.confirmRedo(redone);
    try std.testing.expect(history.canUndo());
    try std.testing.expect(!history.canRedo());
}

test "gesture begin/end records one entry when notes change" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    var clip = notes.PianoRollClip.init(std.testing.allocator);
    defer clip.deinit();
    try clip.addFullNote(.{ .pitch = 60, .start = 0, .duration = 1 });

    history.beginGesture(0, 0, &clip);
    clip.notes.items[0].pitch = 62;
    history.endGesture(0, 0, &clip);
    try std.testing.expect(history.canUndo());
    try std.testing.expectEqual(@as(usize, 1), history.undo_stack.items.len);
}
