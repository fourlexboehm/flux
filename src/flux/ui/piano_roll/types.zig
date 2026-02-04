const std = @import("std");
const selection = @import("../selection.zig");
const session_view_constants = @import("../session_view/constants.zig");

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
    points: std.ArrayListUnmanaged(AutomationPoint) = .{},
};

const AutomationAddTarget = enum {
    track_volume,
    track_pan,
    instrument_param,
    fx_param,
};

pub const ClipAutomation = struct {
    lanes: std.ArrayListUnmanaged(AutomationLane) = .{},

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
    notes: std.ArrayListUnmanaged(Note),
    automation: ClipAutomation,

    pub fn init(allocator: std.mem.Allocator) PianoRollClip {
        return .{
            .allocator = allocator,
            .length_beats = default_clip_bars * beats_per_bar,
            .notes = .{},
            .automation = .{},
        };
    }

    pub fn deinit(self: *PianoRollClip) void {
        self.notes.deinit(self.allocator);
        self.automation.deinit(self.allocator);
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

    pub fn removeNoteAt(self: *PianoRollClip, index: usize) void {
        _ = self.notes.orderedRemove(index);
    }

    pub fn clear(self: *PianoRollClip) void {
        self.notes.clearRetainingCapacity();
        self.automation.clear(self.allocator);
        self.length_beats = default_clip_bars * beats_per_bar;
    }

    pub fn copyFrom(self: *PianoRollClip, src: *const PianoRollClip) void {
        self.clear();
        self.length_beats = src.length_beats;
        if (src.notes.items.len > 0) {
            self.notes.appendSlice(self.allocator, src.notes.items) catch {};
        }
        for (src.automation.lanes.items) |lane| {
            var lane_copy = AutomationLane{
                .target_kind = lane.target_kind,
                .target_id = "",
                .param_id = null,
                .unit = null,
                .points = .{},
            };
            if (lane.target_id.len > 0) {
                lane_copy.target_id = self.allocator.dupe(u8, lane.target_id) catch "";
            }
            if (lane.param_id) |param_id| {
                lane_copy.param_id = self.allocator.dupe(u8, param_id) catch null;
            }
            if (lane.unit) |unit| {
                lane_copy.unit = self.allocator.dupe(u8, unit) catch null;
            }
            if (lane.points.items.len > 0) {
                lane_copy.points.appendSlice(self.allocator, lane.points.items) catch {};
            }
            self.automation.lanes.append(self.allocator, lane_copy) catch {};
        }
    }
};

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
    clipboard: std.ArrayListUnmanaged(Note) = .{},

    // Drag state
    drag: PianoRollDrag = .{},
    drag_select: selection.DragSelectState = .{},
    velocity_drag_notes: std.ArrayListUnmanaged(VelocityDragNote) = .{},

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
    key_pan_active: bool = false,

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

    // Undo requests (processed by ui/undo_requests.zig)
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
        }
    }

    pub fn handleNoteClick(self: *PianoRollState, index: usize, shift_held: bool) void {
        self.note_selection.handleClick(index, shift_held);
    }
};

pub fn quantizeIndexToBeats(index: i32) f32 {
    return switch (index) {
        0 => 0.25,
        1 => 0.5,
        2 => 1.0,
        3 => 2.0,
        4 => 4.0,
        else => 1.0,
    };
}
