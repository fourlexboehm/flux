const std = @import("std");
const selection = @import("selection.zig");
const session_view_constants = @import("constants.zig");

pub const total_pitches = 128;
pub const beats_per_bar = session_view_constants.beats_per_bar;
pub const default_clip_bars = session_view_constants.default_clip_bars;

/// Undo request kinds for piano roll operations
pub const UndoRequestKind = enum {
    note_add,
    note_remove,
    note_move,
    note_resize,
    clip_resize,
    /// Full clip note list replace (bulk tools, mute, duplicate, overlap).
    notes_replace,
};

/// Undo request for piano roll operations
pub const UndoRequest = struct {
    kind: UndoRequestKind,
    track: usize = 0,
    scene: usize = 0,
    note_index: usize = 0,
    note: Note = .{ .pitch = 0, .start = 0, .duration = 0 },
    old_start: f32 = 0,
    old_pitch: u8 = 0,
    new_start: f32 = 0,
    new_pitch: u8 = 0,
    old_duration: f32 = 0,
    new_duration: f32 = 0,
    /// Owned by the request until transferred into undo history (notes_replace only).
    old_notes: []const Note = &.{},
    new_notes: []const Note = &.{},
    old_timing: ClipTiming = .{},
    new_timing: ClipTiming = .{},
};

pub const ClipTiming = struct {
    length: f32 = 0,
    play_start: f32 = 0,
    loop_start: f32 = 0,
    loop_end: f32 = 0,
};

pub const Note = struct {
    pitch: u8, // MIDI pitch 0-127
    start: f32, // Start time in beats
    duration: f32, // Duration in beats
    velocity: f32 = 0.8, // 0.0-1.0
    release_velocity: f32 = 0.8, // 0.0-1.0
};

pub const AutomationTargetKind = enum {
    track,
    device,
    parameter,
};

pub const AutomationPoint = struct {
    time: f32, // in beats
    value: f32,
};

pub const AutomationLane = struct {
    target_kind: AutomationTargetKind = .parameter,
    target_id: []const u8 = "",
    param_id: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    points: std.ArrayListUnmanaged(AutomationPoint) = .empty,
};

const AutomationAddTarget = enum {
    track_volume,
    track_pan,
    instrument_param,
    fx_param,
};

pub const ClipAutomation = struct {
    lanes: std.ArrayListUnmanaged(AutomationLane) = .empty,

    pub fn clear(self: *ClipAutomation, allocator: std.mem.Allocator) void {
        for (self.lanes.items) |*lane| {
            if (lane.target_id.len > 0) {
                allocator.free(lane.target_id);
            }
            if (lane.param_id) |param_id| {
                allocator.free(param_id);
            }
            if (lane.unit) |unit| {
                allocator.free(unit);
            }
            lane.points.deinit(allocator);
        }
        self.lanes.clearRetainingCapacity();
    }

    pub fn deinit(self: *ClipAutomation, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.lanes.deinit(allocator);
    }
};

pub const PianoRollClip = struct {
    allocator: std.mem.Allocator,
    length_beats: f32,
    /// DAWproject playStart — content position where playback begins on launch.
    play_start_beats: f32 = 0,
    /// DAWproject loopStart — loop region start in content time.
    loop_start_beats: f32 = 0,
    /// DAWproject loopEnd — 0 means "use length_beats".
    loop_end_beats: f32 = 0,
    notes: std.ArrayListUnmanaged(Note),
    automation: ClipAutomation,

    pub fn init(allocator: std.mem.Allocator) PianoRollClip {
        return .{
            .allocator = allocator,
            .length_beats = default_clip_bars * beats_per_bar,
            .notes = .empty,
            .automation = .{},
        };
    }

    pub fn deinit(self: *PianoRollClip) void {
        self.notes.deinit(self.allocator);
        self.automation.deinit(self.allocator);
    }

    pub fn loopEnd(self: *const PianoRollClip) f32 {
        if (self.loop_end_beats > 0) return self.loop_end_beats;
        return self.length_beats;
    }

    /// Resize the visible clip while retaining a genuine sub-loop. An implicit
    /// loop end (or an explicit end at the old clip boundary) continues to
    /// follow the clip boundary instead of becoming a second end marker.
    pub fn resizeKeepingLoop(self: *PianoRollClip, length_beats: f32) bool {
        if (length_beats == self.length_beats) return false;
        const loop_was_at_boundary = self.loop_end_beats <= 0 or
            @abs(self.loop_end_beats - self.length_beats) <= 0.001;
        self.length_beats = length_beats;
        self.loop_end_beats = if (loop_was_at_boundary)
            0
        else
            @min(self.loop_end_beats, length_beats);
        return true;
    }

    pub fn addNote(self: *PianoRollClip, pitch: u8, start: f32, duration: f32) !void {
        return self.addNoteWithVelocity(pitch, start, duration, 0.8, 0.8);
    }

    pub fn addNoteWithVelocity(
        self: *PianoRollClip,
        pitch: u8,
        start: f32,
        duration: f32,
        velocity: f32,
        release_velocity: f32,
    ) !void {
        // Trim any existing notes at the same pitch that overlap with the new note's start
        // This handles the case where a new note-on comes while a note is already playing
        var i: usize = 0;
        while (i < self.notes.items.len) {
            var existing = &self.notes.items[i];
            if (existing.pitch == pitch) {
                const existing_end = existing.start + existing.duration;
                // If existing note spans the new note's start point, trim it
                if (existing.start <= start and existing_end > start) {
                    const new_duration = start - existing.start;
                    if (new_duration <= 0) {
                        _ = self.notes.orderedRemove(i);
                        continue;
                    }
                    existing.duration = new_duration;
                }
            }
            i += 1;
        }
        try self.notes.append(self.allocator, .{
            .pitch = pitch,
            .start = start,
            .duration = duration,
            .velocity = velocity,
            .release_velocity = release_velocity,
        });
    }

    pub fn addFullNote(self: *PianoRollClip, note: Note) !void {
        try self.notes.append(self.allocator, note);
    }

    pub fn removeNoteAt(self: *PianoRollClip, index: usize) void {
        _ = self.notes.orderedRemove(index);
    }

    pub fn clear(self: *PianoRollClip) void {
        self.notes.clearRetainingCapacity();
        self.automation.clear(self.allocator);
        self.length_beats = default_clip_bars * beats_per_bar;
        self.play_start_beats = 0;
        self.loop_start_beats = 0;
        self.loop_end_beats = 0;
    }

    pub fn copyFrom(self: *PianoRollClip, src: *const PianoRollClip) void {
        self.copyFromFallible(src) catch self.clear();
    }

    pub fn copyFromFallible(self: *PianoRollClip, src: *const PianoRollClip) !void {
        self.clear();
        errdefer self.clear();
        self.length_beats = src.length_beats;
        self.play_start_beats = src.play_start_beats;
        self.loop_start_beats = src.loop_start_beats;
        self.loop_end_beats = src.loop_end_beats;
        if (src.notes.items.len > 0) {
            try self.notes.appendSlice(self.allocator, src.notes.items);
        }
        for (src.automation.lanes.items) |lane| {
            var lane_copy = try cloneAutomationLane(self.allocator, lane);
            self.automation.lanes.append(self.allocator, lane_copy) catch |err| {
                deinitAutomationLane(self.allocator, &lane_copy);
                return err;
            };
        }
    }
};

test "clip resize keeps an implicit loop end at the clip boundary" {
    var clip = PianoRollClip.init(std.testing.allocator);
    defer clip.deinit();

    try std.testing.expectEqual(@as(f32, 16), clip.loopEnd());
    try std.testing.expect(clip.resizeKeepingLoop(8));
    try std.testing.expectEqual(@as(f32, 8), clip.loopEnd());
    try std.testing.expect(clip.resizeKeepingLoop(24));
    try std.testing.expectEqual(@as(f32, 24), clip.loopEnd());

    clip.loop_start_beats = 4;
    clip.loop_end_beats = 12;
    try std.testing.expect(clip.resizeKeepingLoop(20));
    try std.testing.expectEqual(@as(f32, 12), clip.loopEnd());
    try std.testing.expect(clip.resizeKeepingLoop(10));
    try std.testing.expectEqual(@as(f32, 10), clip.loopEnd());
}

fn cloneAutomationLane(allocator: std.mem.Allocator, src: AutomationLane) !AutomationLane {
    var dst = AutomationLane{ .target_kind = src.target_kind };
    errdefer deinitAutomationLane(allocator, &dst);
    if (src.target_id.len > 0) dst.target_id = try allocator.dupe(u8, src.target_id);
    if (src.param_id) |value| dst.param_id = try allocator.dupe(u8, value);
    if (src.unit) |value| dst.unit = try allocator.dupe(u8, value);
    try dst.points.appendSlice(allocator, src.points.items);
    return dst;
}

fn deinitAutomationLane(allocator: std.mem.Allocator, lane: *AutomationLane) void {
    if (lane.target_id.len > 0) allocator.free(lane.target_id);
    if (lane.param_id) |value| allocator.free(value);
    if (lane.unit) |value| allocator.free(value);
    lane.points.deinit(allocator);
}

pub const DragMode = enum {
    none,
    create,
    resize_right,
    move,
    velocity,
    resize_clip,
    select_rect,
};

pub const PianoRollDrag = struct {
    mode: DragMode = .none,
    note_index: usize = 0,
    grab_offset_beats: f32 = 0,
    grab_offset_pitch: i32 = 0,
    original_start: f32 = 0,
    original_pitch: u8 = 0,
    drag_start_mouse_y: f32 = 0,
    // For undo tracking
    drag_start_start: f32 = 0, // Start position when drag began
    drag_start_pitch: u8 = 0, // Pitch when drag began
    drag_start_duration: f32 = 0, // Duration when drag began
};

const VelocityDragNote = struct {
    index: usize,
    velocity: f32,
};

pub const PianoRollState = struct {
    allocator: std.mem.Allocator,

    // Note selection
    note_selection: selection.SelectionState(usize),

    // Clipboard
    clipboard: std.ArrayListUnmanaged(Note) = .empty,

    // Drag state
    drag: PianoRollDrag = .{},
    drag_select: selection.DragSelectState = .{},
    velocity_drag_notes: std.ArrayListUnmanaged(VelocityDragNote) = .empty,
    drag_old_notes: []Note = &.{},

    // Context menu state
    context_note_index: ?usize = null,
    context_start: f32 = 0,
    context_pitch: u8 = 60,
    context_in_grid: bool = false,

    // Note preview (audition) state
    preview_pitch: ?u8 = null,
    preview_track: ?usize = null,

    // View state
    scroll_x: f32 = 0,
    scroll_y: f32 = 50 * 20.0, // Start around C4
    beats_per_pixel: f32 = 0.5,
    /// Multiplier on base row height (vertical zoom). 1.0 = default.
    row_height_scale: f32 = 1.0,
    key_pan_active: bool = false,
    /// Pitch under cursor for key label hover (null = none).
    hover_pitch: ?u8 = null,
    /// Velocity humanize amount for clip tools (-127..127 mapped to ±1.0).
    velocity_range: f32 = 0,

    // Automation UI state
    automation_edit: bool = false,
    automation_lane_index: ?usize = null,
    automation_selected_point: ?usize = null,
    automation_drag_active: bool = false,
    automation_drag_lane: usize = 0,
    automation_drag_point: usize = 0,
    automation_add_target: AutomationAddTarget = .instrument_param,
    automation_add_fx_index: usize = 0,
    automation_add_param_id: ?u32 = null,

    // Undo requests (processed by document/cmd_undo.zig)
    undo_requests: [16]UndoRequest = undefined,
    undo_request_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) PianoRollState {
        return .{
            .allocator = allocator,
            .note_selection = selection.SelectionState(usize).init(allocator),
        };
    }

    pub fn deinit(self: *PianoRollState) void {
        self.note_selection.deinit();
        self.clipboard.deinit(self.allocator);
        self.velocity_drag_notes.deinit(self.allocator);
        if (self.drag_old_notes.len > 0) self.allocator.free(self.drag_old_notes);
    }

    pub fn clearSelection(self: *PianoRollState) void {
        self.note_selection.clear();
    }

    pub fn selectNote(self: *PianoRollState, index: usize) void {
        self.note_selection.add(index);
    }

    pub fn deselectNote(self: *PianoRollState, index: usize) void {
        self.note_selection.remove(index);
    }

    pub fn isNoteSelected(self: *const PianoRollState, index: usize) bool {
        return self.note_selection.contains(index);
    }

    pub fn hasSelection(self: *const PianoRollState) bool {
        return !self.note_selection.isEmpty();
    }

    pub fn selectOnly(self: *PianoRollState, index: usize) void {
        self.note_selection.selectOnly(index);
    }

    pub fn emitUndoRequest(self: *PianoRollState, request: UndoRequest) void {
        if (self.undo_request_count < self.undo_requests.len) {
            self.undo_requests[self.undo_request_count] = request;
            self.undo_request_count += 1;
        } else if (request.kind == .notes_replace) {
            if (request.old_notes.len > 0) self.allocator.free(request.old_notes);
            if (request.new_notes.len > 0) self.allocator.free(request.new_notes);
        }
    }

    pub fn captureDragNotes(self: *PianoRollState, clip: *const PianoRollClip) void {
        if (self.drag_old_notes.len > 0) self.allocator.free(self.drag_old_notes);
        self.drag_old_notes = self.allocator.dupe(Note, clip.notes.items) catch &.{};
    }

    pub fn takeDragNotes(self: *PianoRollState) []Note {
        const notes = self.drag_old_notes;
        self.drag_old_notes = &.{};
        return notes;
    }

    pub fn handleNoteClick(self: *PianoRollState, index: usize, shift_held: bool) void {
        self.note_selection.handleClick(index, shift_held);
    }
};

/// Grid / quantize step labels (1 beat = quarter note).
pub const quantize_count: i32 = 9;
pub const quantize_labels = [_][]const u8{ "1/32", "1/16", "1/8", "1/4", "1/2", "1 Bar", "2 Bar", "4 Bar", "8 Bar" };

/// Zero-separated combo string for ImGui (must match quantizeIndexToBeats).
pub const quantize_items_z: [:0]const u8 = "1/32\x001/16\x001/8\x001/4\x001/2\x001 Bar\x002 Bar\x004 Bar\x008 Bar\x00";

/// Default = quarter note (1 beat).
pub const default_quantize_index: i32 = 3;

pub fn quantizeIndexToBeats(index: i32) f32 {
    return switch (index) {
        0 => 0.125, // 1/32
        1 => 0.25, // 1/16
        2 => 0.5, // 1/8
        3 => 1.0, // 1/4
        4 => 2.0, // 1/2
        5 => 4.0, // 1 bar @ 4/4
        6 => 8.0, // 2 bars
        7 => 16.0, // 4 bars
        8 => 32.0, // 8 bars
        else => 1.0,
    };
}

pub fn pitchToName(buf: []u8, pitch: u8) []const u8 {
    const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const octave: i32 = @as(i32, @intCast(pitch / 12)) - 1;
    return std.fmt.bufPrint(buf, "{s}{d}", .{ names[pitch % 12], octave }) catch "?";
}
