//! Piano-roll MIDI and automation document commands.
const std = @import("std");
const model = @import("model.zig");
const midi_history = @import("midi_history.zig");
const notes = @import("../session/notes.zig");

pub fn midiClip(store: *model.Store, track: usize, scene: usize) ?*notes.PianoRollClip {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return null;
    const id = store.session.clips[track][scene].clip;
    const clip = store.clip_pool.get(id) orelse return null;
    return if (clip.content == .midi) &clip.content.midi else null;
}

fn recordMidiReplace(store: *model.Store, track: usize, scene: usize, clip: *const notes.PianoRollClip, old_notes: []const notes.Note, old_timing: notes.ClipTiming) void {
    store.midi_history.recordReplace(
        track,
        scene,
        old_notes,
        clip.notes.items,
        old_timing,
        midi_history.timingOf(clip),
    );
}

/// Capture clip notes before an in-place piano-roll gesture (drag / velocity / markers).
pub fn beginMidiGesture(store: *model.Store, track: usize, scene: usize) void {
    const clip = midiClip(store, track, scene) orelse return;
    store.midi_history.beginGesture(track, scene, clip);
}

pub fn addMidiNote(store: *model.Store, track: usize, scene: usize, note: notes.Note) ?usize {
    const clip = midiClip(store, track, scene) orelse return null;
    const old_notes = store.allocator.dupe(notes.Note, clip.notes.items) catch null;
    defer if (old_notes) |slice| store.allocator.free(slice);
    const old_timing = midi_history.timingOf(clip);
    clip.addFullNote(note) catch return null;
    if (old_notes) |before| recordMidiReplace(store, track, scene, clip, before, old_timing);
    store.markChanged();
    return clip.notes.items.len - 1;
}

pub fn addMidiNotes(store: *model.Store, track: usize, scene: usize, new_notes: []const notes.Note) ?usize {
    if (new_notes.len == 0) return null;
    const clip = midiClip(store, track, scene) orelse return null;
    const old_notes = store.allocator.dupe(notes.Note, clip.notes.items) catch null;
    defer if (old_notes) |slice| store.allocator.free(slice);
    const old_timing = midi_history.timingOf(clip);
    const first = clip.notes.items.len;
    clip.notes.ensureUnusedCapacity(clip.allocator, new_notes.len) catch return null;
    for (new_notes) |note| clip.notes.appendAssumeCapacity(note);
    if (old_notes) |before| recordMidiReplace(store, track, scene, clip, before, old_timing);
    store.markChanged();
    return first;
}

pub fn removeMidiNote(store: *model.Store, track: usize, scene: usize, index: usize) bool {
    const clip = midiClip(store, track, scene) orelse return false;
    if (index >= clip.notes.items.len) return false;
    const old_notes = store.allocator.dupe(notes.Note, clip.notes.items) catch null;
    defer if (old_notes) |slice| store.allocator.free(slice);
    const old_timing = midi_history.timingOf(clip);
    clip.removeNoteAt(index);
    if (old_notes) |before| recordMidiReplace(store, track, scene, clip, before, old_timing);
    store.markChanged();
    return true;
}

pub fn removeMidiNotes(store: *model.Store, track: usize, scene: usize, indices: []const usize) bool {
    const clip = midiClip(store, track, scene) orelse return false;
    const old_notes = store.allocator.dupe(notes.Note, clip.notes.items) catch null;
    defer if (old_notes) |slice| store.allocator.free(slice);
    const old_timing = midi_history.timingOf(clip);
    var removed = false;
    var i = clip.notes.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.indexOfScalar(usize, indices, i) != null) {
            clip.removeNoteAt(i);
            removed = true;
        }
    }
    if (!removed) return false;
    if (old_notes) |before| recordMidiReplace(store, track, scene, clip, before, old_timing);
    store.markChanged();
    return true;
}

/// End an in-place gesture: push one history entry when content changed, bump revision.
pub fn commitMidiNoteEdit(store: *model.Store, track: usize, scene: usize) void {
    if (midiClip(store, track, scene) == null) return;
    store.midi_history.endGesture(track, scene, midiClip(store, track, scene).?);
    store.markChanged();
}

pub fn canUndoMidi(store: *const model.Store) bool {
    return store.midi_history.canUndo();
}

pub fn canRedoMidi(store: *const model.Store) bool {
    return store.midi_history.canRedo();
}

pub fn undoMidi(store: *model.Store) bool {
    const entry = store.midi_history.popUndo() orelse return false;
    const clip = midiClip(store, entry.track, entry.scene) orelse {
        store.midi_history.freeEntry(entry);
        return false;
    };
    midi_history.replaceNotes(clip, entry.old_notes);
    midi_history.applyTiming(clip, entry.old_timing);
    store.midi_history.confirmUndo(entry);
    store.markChanged();
    return true;
}

pub fn redoMidi(store: *model.Store) bool {
    const entry = store.midi_history.popRedo() orelse return false;
    const clip = midiClip(store, entry.track, entry.scene) orelse {
        store.midi_history.freeEntry(entry);
        return false;
    };
    midi_history.replaceNotes(clip, entry.new_notes);
    midi_history.applyTiming(clip, entry.new_timing);
    store.midi_history.confirmRedo(entry);
    store.markChanged();
    return true;
}

pub const MidiTransform = enum { quantize, duplicate, reverse, invert, legato, resolve_overlaps, humanize, half_time, double_time };

fn selected(index: usize, indices: []const usize) bool {
    if (indices.len == 0) return true;
    return std.mem.indexOfScalar(usize, indices, index) != null;
}

/// Applies the legacy piano-roll bulk tools. An empty selection means all notes.
pub fn transformMidiNotes(store: *model.Store, track: usize, scene: usize, indices: []const usize, transform: MidiTransform, step: f32) bool {
    const clip = midiClip(store, track, scene) orelse return false;
    if (clip.notes.items.len == 0) return false;
    const old_notes = store.allocator.dupe(notes.Note, clip.notes.items) catch null;
    defer if (old_notes) |slice| store.allocator.free(slice);
    const old_timing = midi_history.timingOf(clip);
    var changed = false;
    switch (transform) {
        .quantize => for (clip.notes.items, 0..) |*note, i| {
            if (!selected(i, indices)) continue;
            const value = @max(0, @round(note.start / step) * step);
            changed = changed or value != note.start;
            note.start = value;
        },
        .duplicate => {
            const original_len = clip.notes.items.len;
            var min_start = std.math.floatMax(f32);
            var max_end: f32 = 0;
            for (clip.notes.items[0..original_len], 0..) |note, i| if (selected(i, indices)) {
                min_start = @min(min_start, note.start);
                max_end = @max(max_end, note.start + note.duration);
            };
            if (min_start == std.math.floatMax(f32)) return false;
            const shift = @max(step, max_end - min_start);
            for (clip.notes.items[0..original_len], 0..) |note, i| if (selected(i, indices)) {
                var copy = note;
                copy.start += shift;
                clip.notes.append(clip.allocator, copy) catch return false;
                changed = true;
            };
        },
        .reverse => for (clip.notes.items, 0..) |*note, i| {
            if (!selected(i, indices)) continue;
            note.start = @max(0, clip.length_beats - (note.start + note.duration));
            changed = true;
        },
        .invert => {
            var low: u8 = 127;
            var high: u8 = 0;
            for (clip.notes.items, 0..) |note, i| if (selected(i, indices)) {
                low = @min(low, note.pitch);
                high = @max(high, note.pitch);
            };
            if (high < low) return false;
            for (clip.notes.items, 0..) |*note, i| if (selected(i, indices)) {
                note.pitch = @intCast(@as(u16, low) + high - note.pitch);
                changed = true;
            };
        },
        .legato => {
            for (clip.notes.items, 0..) |*note, i| {
                if (!selected(i, indices)) continue;
                var next = clip.length_beats;
                for (clip.notes.items, 0..) |other, j| {
                    if (i != j and selected(j, indices) and other.start > note.start) next = @min(next, other.start);
                }
                if (next > note.start) {
                    const duration = @max(0.0625, next - note.start);
                    changed = changed or duration != note.duration;
                    note.duration = duration;
                }
            }
        },
        .resolve_overlaps => {
            for (clip.notes.items, 0..) |*note, i| {
                if (!selected(i, indices)) continue;
                var next = note.start + note.duration;
                for (clip.notes.items, 0..) |other, j| {
                    if (i == j or !selected(j, indices) or other.pitch != note.pitch or other.start <= note.start) continue;
                    next = @min(next, other.start);
                }
                const duration = @max(0.0625, next - note.start);
                changed = changed or duration != note.duration;
                note.duration = duration;
            }
        },
        .humanize => {
            var prng = std.Random.DefaultPrng.init(@as(u64, clip.notes.items.len) *% 0x9e3779b97f4a7c15 +% store.revision);
            const random = prng.random();
            for (clip.notes.items, 0..) |*note, i| {
                if (!selected(i, indices)) continue;
                note.velocity = std.math.clamp(note.velocity + (random.float(f32) * 2 - 1) * 0.08, 0, 1);
                changed = true;
            }
        },
        .half_time, .double_time => {
            const factor: f32 = if (transform == .half_time) 0.5 else 2;
            for (clip.notes.items, 0..) |*note, i| if (selected(i, indices)) {
                note.start *= factor;
                note.duration = @max(0.0625, note.duration * factor);
                changed = true;
            };
            clip.length_beats = @max(step, clip.length_beats * factor);
        },
    }
    if (!changed) return false;
    if (old_notes) |before| recordMidiReplace(store, track, scene, clip, before, old_timing);
    store.markChanged();
    return true;
}

/// Shift the pitch/timing of selected notes by a fixed delta (arrow-key nudge).
/// `selected` marks note indices to move; out-of-range indices are ignored.
pub fn nudgeMidiNotes(store: *model.Store, track: usize, scene: usize, note_selected: []const bool, beat_delta: f32, pitch_delta: i32) bool {
    const clip = midiClip(store, track, scene) orelse return false;
    if (clip.notes.items.len == 0) return false;
    const old_notes = store.allocator.dupe(notes.Note, clip.notes.items) catch null;
    defer if (old_notes) |slice| store.allocator.free(slice);
    const old_timing = midi_history.timingOf(clip);
    var changed = false;
    for (clip.notes.items, 0..) |*note, i| {
        if (i >= note_selected.len or !note_selected[i]) continue;
        const start = @max(0, note.start + beat_delta);
        const pitch = std.math.clamp(@as(i32, note.pitch) + pitch_delta, 0, 127);
        changed = changed or start != note.start or pitch != @as(i32, note.pitch);
        note.start = start;
        note.pitch = @intCast(pitch);
    }
    if (!changed) return false;
    if (old_notes) |before| recordMidiReplace(store, track, scene, clip, before, old_timing);
    store.markChanged();
    return true;
}

pub fn setMidiClipLength(store: *model.Store, track: usize, scene: usize, length: f32) bool {
    const clip = midiClip(store, track, scene) orelse return false;
    const value = @max(0.125, length);
    const old_timing = midi_history.timingOf(clip);
    const old_notes = store.allocator.dupe(notes.Note, clip.notes.items) catch null;
    defer if (old_notes) |slice| store.allocator.free(slice);
    if (!clip.resizeKeepingLoop(value)) return false;
    if (clip.play_start_beats > value) clip.play_start_beats = value;
    if (old_notes) |before| recordMidiReplace(store, track, scene, clip, before, old_timing);
    store.markChanged();
    return true;
}

// ── Clip automation (no undo stack; revision bump only) ─────────────────────

const max_automation_points: usize = 64;

/// Add-lane target kinds used by piano-roll chrome (mirrors zgui).
pub const AutomationAddTarget = enum {
    track_volume,
    track_pan,
    instrument_param,
    fx_param,
};

/// Creates a lane or focuses an existing identical target. Returns lane index.
pub fn addAutomationLane(
    store: *model.Store,
    track: usize,
    scene: usize,
    target: AutomationAddTarget,
    fx_index: usize,
    param_id: ?u32,
) ?usize {
    const clip = midiClip(store, track, scene) orelse return null;

    var target_kind: notes.AutomationTargetKind = .parameter;
    var target_id_buf: [32]u8 = undefined;
    var target_id: []const u8 = "";
    var param_id_buf: [32]u8 = undefined;
    var param_str: []const u8 = "";

    switch (target) {
        .track_volume => {
            target_kind = .track;
            target_id = "track";
            param_str = "volume";
        },
        .track_pan => {
            target_kind = .track;
            target_id = "track";
            param_str = "pan";
        },
        .instrument_param => {
            target_kind = .parameter;
            target_id = "instrument";
            const pid = param_id orelse return null;
            param_str = std.fmt.bufPrint(&param_id_buf, "{d}", .{pid}) catch return null;
        },
        .fx_param => {
            target_kind = .parameter;
            target_id = std.fmt.bufPrint(&target_id_buf, "fx{d}", .{fx_index}) catch "fx0";
            const pid = param_id orelse return null;
            param_str = std.fmt.bufPrint(&param_id_buf, "{d}", .{pid}) catch return null;
        },
    }
    if (param_str.len == 0) return null;

    if (findAutomationLaneIndex(clip, target_kind, target_id, param_str)) |existing| {
        return existing;
    }

    const target_id_copy = if (target_id.len > 0) clip.allocator.dupe(u8, target_id) catch return null else "";
    errdefer if (target_id_copy.len > 0) clip.allocator.free(target_id_copy);
    const param_id_copy = clip.allocator.dupe(u8, param_str) catch return null;
    errdefer clip.allocator.free(param_id_copy);

    clip.automation.lanes.append(clip.allocator, .{
        .target_kind = target_kind,
        .target_id = target_id_copy,
        .param_id = param_id_copy,
        .unit = null,
        .points = .empty,
    }) catch return null;

    store.markChanged();
    return clip.automation.lanes.items.len - 1;
}

pub fn removeAutomationLane(store: *model.Store, track: usize, scene: usize, lane_index: usize) bool {
    const clip = midiClip(store, track, scene) orelse return false;
    if (lane_index >= clip.automation.lanes.items.len) return false;
    var lane = clip.automation.lanes.orderedRemove(lane_index);
    freeAutomationLane(clip.allocator, &lane);
    store.markChanged();
    return true;
}

pub fn addAutomationPoint(
    store: *model.Store,
    track: usize,
    scene: usize,
    lane_index: usize,
    time: f32,
    value: f32,
) ?usize {
    const clip = midiClip(store, track, scene) orelse return null;
    if (lane_index >= clip.automation.lanes.items.len) return null;
    var lane = &clip.automation.lanes.items[lane_index];
    if (lane.points.items.len >= max_automation_points) return null;
    const clamped_time = std.math.clamp(time, 0, clip.length_beats);
    lane.points.append(clip.allocator, .{ .time = clamped_time, .value = value }) catch return null;
    sortAutomationPoints(&lane.points);
    store.markChanged();
    return findPointIndex(&lane.points, clamped_time, value);
}

pub fn removeAutomationPoint(
    store: *model.Store,
    track: usize,
    scene: usize,
    lane_index: usize,
    point_index: usize,
) bool {
    const clip = midiClip(store, track, scene) orelse return false;
    if (lane_index >= clip.automation.lanes.items.len) return false;
    var lane = &clip.automation.lanes.items[lane_index];
    if (point_index >= lane.points.items.len) return false;
    _ = lane.points.orderedRemove(point_index);
    store.markChanged();
    return true;
}

/// Move an existing point in place (used while dragging). Does not bump revision;
/// call `commitAutomationEdit` on gesture release.
pub fn setAutomationPointInPlace(
    store: *model.Store,
    track: usize,
    scene: usize,
    lane_index: usize,
    point_index: usize,
    time: f32,
    value: f32,
) ?usize {
    const clip = midiClip(store, track, scene) orelse return null;
    if (lane_index >= clip.automation.lanes.items.len) return null;
    var lane = &clip.automation.lanes.items[lane_index];
    if (point_index >= lane.points.items.len) return null;
    const clamped_time = std.math.clamp(time, 0, clip.length_beats);
    lane.points.items[point_index] = .{ .time = clamped_time, .value = value };
    sortAutomationPoints(&lane.points);
    return findPointIndex(&lane.points, clamped_time, value);
}

/// Bump document revision after an in-place automation gesture.
pub fn commitAutomationEdit(store: *model.Store, track: usize, scene: usize) void {
    if (midiClip(store, track, scene) == null) return;
    store.markChanged();
}

fn freeAutomationLane(allocator: std.mem.Allocator, lane: *notes.AutomationLane) void {
    if (lane.target_id.len > 0) allocator.free(lane.target_id);
    if (lane.param_id) |param_id| allocator.free(param_id);
    if (lane.unit) |unit| allocator.free(unit);
    lane.points.deinit(allocator);
    lane.* = .{};
}

fn findAutomationLaneIndex(
    clip: *const notes.PianoRollClip,
    target_kind: notes.AutomationTargetKind,
    target_id: []const u8,
    param_id: []const u8,
) ?usize {
    for (clip.automation.lanes.items, 0..) |lane, idx| {
        if (lane.target_kind != target_kind) continue;
        if (!automationTargetIdMatch(lane.target_id, target_id)) continue;
        const lane_param = lane.param_id orelse "";
        if (!std.mem.eql(u8, lane_param, param_id)) continue;
        return idx;
    }
    return null;
}

fn automationTargetIdMatch(existing: []const u8, desired: []const u8) bool {
    if (std.mem.eql(u8, existing, desired)) return true;
    if (existing.len == 0 and std.mem.eql(u8, desired, "instrument")) return true;
    if (desired.len == 0 and std.mem.eql(u8, existing, "instrument")) return true;
    return false;
}

fn sortAutomationPoints(points: *std.ArrayListUnmanaged(notes.AutomationPoint)) void {
    std.mem.sort(notes.AutomationPoint, points.items, {}, struct {
        fn lessThan(_: void, a: notes.AutomationPoint, b: notes.AutomationPoint) bool {
            return a.time < b.time;
        }
    }.lessThan);
}

fn findPointIndex(points: *const std.ArrayListUnmanaged(notes.AutomationPoint), time: f32, value: f32) usize {
    for (points.items, 0..) |point, idx| {
        if (std.math.approxEqAbs(f32, point.time, time, 0.0001) and std.math.approxEqAbs(f32, point.value, value, 0.0001)) {
            return idx;
        }
    }
    return 0;
}

