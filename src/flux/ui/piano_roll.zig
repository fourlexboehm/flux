const zgui = @import("zgui");
const colors = @import("colors.zig");
const selection = @import("selection.zig");
const session_view = @import("session_view.zig");
const edit_actions = @import("edit_actions.zig");
const std = @import("std");
const clap = @import("clap-bindings");

pub const total_pitches = 128;
pub const beats_per_bar = session_view.beats_per_bar;
pub const default_clip_bars = session_view.default_clip_bars;

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

    // Undo requests (processed by ui.zig)
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

fn lerpColor(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
        a[3] + (b[3] - a[3]) * clamped,
    };
}

fn applyVelocityColor(base: [4]f32, velocity: f32) [4]f32 {
    const v = std.math.clamp(velocity, 0.0, 1.0);
    const white: [4]f32 = .{ 1.0, 1.0, 1.0, base[3] };
    const black: [4]f32 = .{ 0.0, 0.0, 0.0, base[3] };
    var color = base;
    // Lower velocity -> lighter, higher velocity -> darker.
    color = lerpColor(color, white, (1.0 - v) * 0.35);
    color = lerpColor(color, black, v * 0.35);
    return color;
}

pub fn drawSequencer(
    state: *PianoRollState,
    clip: *PianoRollClip,
    clip_label: []const u8,
    playhead_beat: f32,
    playing: bool,
    quantize_index: i32,
    ui_scale: f32,
    is_focused: bool,
    track_index: usize,
    scene_index: usize,
    live_key_states: *const [128]bool,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
) void {
    const key_width = 56.0 * ui_scale;
    const ruler_height = 24.0 * ui_scale;
    const min_note_duration: f32 = 0.0625;
    const resize_handle_width = 8.0 * ui_scale;
    const clip_end_handle_width = 10.0 * ui_scale;
    state.preview_pitch = null;
    state.preview_track = null;
    const quantize_beats = quantizeIndexToBeats(quantize_index);

    const pixels_per_beat = 60.0 / state.beats_per_pixel;
    const row_height = 20.0 * ui_scale;

    const mouse = zgui.getMousePos();
    const mouse_down = zgui.isMouseDown(.left);

    // Header
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_bright });
    zgui.text("{s}", .{clip_label});
    zgui.popStyleColor(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = 20.0 * ui_scale });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
    zgui.text("{d:.0} bars", .{clip.length_beats / beats_per_bar});
    zgui.popStyleColor(.{ .count = 1 });

    if (state.note_selection.primary) |note_idx| {
        if (note_idx < clip.notes.items.len) {
            const vel_pct = std.math.clamp(clip.notes.items[note_idx].velocity, 0.0, 1.0) * 127.0;
            zgui.sameLine(.{ .spacing = 20.0 * ui_scale });
            zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
            zgui.text("Vel {d:.0}", .{vel_pct});
            zgui.popStyleColor(.{ .count = 1 });
        }
    }

    // Scroll/zoom bar
    zgui.sameLine(.{ .spacing = 30.0 * ui_scale });
    drawScrollZoomBar(state, pixels_per_beat, key_width, ui_scale);

    zgui.spacing();

    drawAutomationHeader(state, clip, ui_scale, instrument_plugin, fx_plugins);
    const automation_mode = state.automation_edit and state.automation_lane_index != null;

    // Calculate layout
    const content_height = 128.0 * row_height;
    const max_beats = @max(clip.length_beats + 16, 64);
    const content_width = max_beats * pixels_per_beat;

    const avail = zgui.getContentRegionAvail();
    const total_width = avail[0];
    const total_height = avail[1];

    const base_pos = zgui.getCursorScreenPos();
    const grid_area_x = base_pos[0] + key_width;
    const grid_area_y = base_pos[1] + ruler_height;
    const grid_view_width = total_width - key_width;
    const grid_view_height = total_height - ruler_height;

    // Clamp scroll
    const max_scroll_x = @max(0.0, content_width - grid_view_width);
    const max_scroll_y = @max(0.0, content_height - grid_view_height);
    state.scroll_x = std.math.clamp(state.scroll_x, 0, max_scroll_x);
    state.scroll_y = std.math.clamp(state.scroll_y, 0, max_scroll_y);

    const grid_window_pos: [2]f32 = .{ grid_area_x, grid_area_y };
    const draw_list = zgui.getWindowDrawList();

    // Calculate visible ranges
    const first_visible_beat = state.scroll_x / pixels_per_beat;
    const last_visible_beat = (state.scroll_x + grid_view_width) / pixels_per_beat;
    const first_row_f = @max(0, @floor(state.scroll_y / row_height));
    const last_row_f = @min(127, @ceil((state.scroll_y + grid_view_height) / row_height));
    const first_visible_row: usize = @intFromFloat(first_row_f);
    const last_visible_row: usize = @intFromFloat(@max(first_row_f, last_row_f));

    const is_black_key = [_]bool{ false, true, false, true, false, false, true, false, true, false, true, false };

    // Clip to grid area
    draw_list.pushClipRect(.{
        .pmin = grid_window_pos,
        .pmax = .{ grid_window_pos[0] + grid_view_width, grid_window_pos[1] + grid_view_height },
    });

    // Draw grid background rows
    var row: usize = first_visible_row;
    while (row <= last_visible_row) : (row += 1) {
        const pitch: u8 = if (row <= 127) @intCast(127 - row) else 0;
        const y = grid_window_pos[1] + @as(f32, @floatFromInt(row)) * row_height - state.scroll_y;

        if (y < grid_window_pos[1] - row_height or y > grid_window_pos[1] + grid_view_height) continue;

        const note_in_octave = pitch % 12;
        const row_color = if (is_black_key[note_in_octave])
            zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_row_black)
        else if (note_in_octave == 0)
            zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_row_root)
        else if (@mod(row, 2) == 0)
            zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_row_light)
        else
            zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_row_dark);

        draw_list.addRectFilled(.{
            .pmin = .{ grid_window_pos[0], y },
            .pmax = .{ grid_window_pos[0] + content_width, y + row_height },
            .col = row_color,
        });

        const line_col = if (note_in_octave == 0)
            zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_line_beat)
        else
            zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_line_16th);
        draw_list.addLine(.{
            .p1 = .{ grid_window_pos[0], y + row_height },
            .p2 = .{ grid_window_pos[0] + content_width, y + row_height },
            .col = line_col,
            .thickness = if (note_in_octave == 0) 1.0 else 0.5,
        });
    }

    // Draw vertical grid lines
    var sub_beat: f32 = @floor(first_visible_beat * 4) / 4;
    while (sub_beat <= @min(last_visible_beat + 1, max_beats)) : (sub_beat += 0.25) {
        const x = grid_window_pos[0] + sub_beat * pixels_per_beat - state.scroll_x;
        const beat_16th = @as(i32, @intFromFloat(sub_beat * 4));
        const is_bar = @mod(beat_16th, 16) == 0;
        const is_beat = @mod(beat_16th, 4) == 0;
        const is_8th = @mod(beat_16th, 2) == 0;

        const line_color = if (is_bar)
            zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_line_bar)
        else if (is_beat)
            zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_line_beat)
        else if (is_8th)
            zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_line_8th)
        else
            zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_line_16th);

        draw_list.addLine(.{
            .p1 = .{ x, grid_window_pos[1] },
            .p2 = .{ x, grid_window_pos[1] + content_height },
            .col = line_color,
            .thickness = if (is_bar) 2.0 else if (is_beat) 1.0 else 0.5,
        });
    }

    // Draw clip end boundary
    const clip_end_x = grid_window_pos[0] + clip.length_beats * pixels_per_beat - state.scroll_x;
    const clip_end_hovered = mouse[0] >= clip_end_x - clip_end_handle_width and
        mouse[0] <= clip_end_x + clip_end_handle_width and
        mouse[1] >= grid_window_pos[1] and
        mouse[1] <= grid_window_pos[1] + grid_view_height;

    if (clip_end_hovered and state.drag.mode == .none) {
        zgui.setMouseCursor(.resize_ew);
        if (zgui.isMouseClicked(.left)) {
            state.drag = .{
                .mode = .resize_clip,
                .original_start = clip.length_beats,
                .drag_start_duration = clip.length_beats,
            };
        }
    } else if (state.drag.mode == .resize_clip) {
        zgui.setMouseCursor(.resize_ew);
    }

    if (clip_end_x > grid_window_pos[0] - clip_end_handle_width and clip_end_x < grid_window_pos[0] + grid_view_width + clip_end_handle_width) {
        if (clip_end_x < grid_window_pos[0] + grid_view_width) {
            draw_list.addRectFilled(.{
                .pmin = .{ clip_end_x, grid_window_pos[1] },
                .pmax = .{ grid_window_pos[0] + grid_view_width, grid_window_pos[1] + grid_view_height },
                .col = zgui.colorConvertFloat4ToU32(.{ colors.Colors.current.border[0], colors.Colors.current.border[1], colors.Colors.current.border[2], 0.35 }),
            });
        }

        const end_color = if (clip_end_hovered or state.drag.mode == .resize_clip)
            colors.Colors.current.accent
        else
            colors.Colors.current.accent_dim;
        draw_list.addLine(.{
            .p1 = .{ clip_end_x, grid_window_pos[1] },
            .p2 = .{ clip_end_x, grid_window_pos[1] + grid_view_height },
            .col = zgui.colorConvertFloat4ToU32(end_color),
            .thickness = 3.0,
        });

        draw_list.addTriangleFilled(.{
            .p1 = .{ clip_end_x - 6, grid_window_pos[1] },
            .p2 = .{ clip_end_x + 6, grid_window_pos[1] },
            .p3 = .{ clip_end_x, grid_window_pos[1] + 10 },
            .col = zgui.colorConvertFloat4ToU32(end_color),
        });
    }

    // Draw playhead
    if (playing) {
        const playhead_x = grid_window_pos[0] + playhead_beat * pixels_per_beat - state.scroll_x;
        if (playhead_x >= grid_window_pos[0] and playhead_x <= grid_window_pos[0] + grid_view_width) {
            draw_list.addLine(.{
                .p1 = .{ playhead_x, grid_window_pos[1] },
                .p2 = .{ playhead_x, grid_window_pos[1] + grid_view_height },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.accent),
                .thickness = 2.0,
            });
        }
    }

    const popup_open = zgui.isPopupOpen("piano_roll_ctx", .{});

    // Draw notes
    var right_click_note_index: ?usize = null;
    var left_click_note = false;

    for (clip.notes.items, 0..) |note, note_idx| {
        const note_row = 127 - @as(usize, note.pitch);
        const note_end = note.start + note.duration;

        if (note_row < first_visible_row or note_row > last_visible_row) continue;
        if (note_end < first_visible_beat or note.start > last_visible_beat) continue;

        const note_x = grid_window_pos[0] + note.start * pixels_per_beat - state.scroll_x;
        const note_y = grid_window_pos[1] + @as(f32, @floatFromInt(note_row)) * row_height - state.scroll_y;
        const note_w = note.duration * pixels_per_beat;

        const is_selected = state.isNoteSelected(note_idx);

        const base_note_color = if (is_selected) colors.Colors.current.note_selected else colors.Colors.current.note_color;
        const note_color = applyVelocityColor(base_note_color, note.velocity);
        draw_list.addRectFilled(.{
            .pmin = .{ note_x + 1, note_y + 1 },
            .pmax = .{ note_x + note_w - 1, note_y + row_height - 1 },
            .col = zgui.colorConvertFloat4ToU32(note_color),
            .rounding = 2.0,
        });

        if (is_selected) {
            draw_list.addRect(.{
                .pmin = .{ note_x, note_y },
                .pmax = .{ note_x + note_w, note_y + row_height },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.note_border),
                .rounding = 3.0,
                .thickness = 2.0,
            });
        }

        // Resize handle
        const handle_x = note_x + note_w - resize_handle_width;
        const handle_color = if (is_selected) colors.Colors.current.note_handle_selected else colors.Colors.current.note_handle;
        draw_list.addRectFilled(.{
            .pmin = .{ @max(note_x + 1, handle_x), note_y + 1 },
            .pmax = .{ note_x + note_w - 1, note_y + row_height - 1 },
            .col = zgui.colorConvertFloat4ToU32(handle_color),
            .rounding = 2.0,
            .flags = zgui.DrawFlags.round_corners_right,
        });

        // Interaction
        const over_note = mouse[0] >= note_x and mouse[0] < note_x + note_w and
            mouse[1] >= note_y and mouse[1] < note_y + row_height;
        const over_handle = mouse[0] >= handle_x;

        if (!automation_mode and over_note and state.drag.mode == .none) {
            const modifier_down = selection.isModifierDown();
            if (over_handle) {
                zgui.setMouseCursor(.resize_ew);
            } else if (modifier_down) {
                zgui.setMouseCursor(.resize_ns);
            } else {
                zgui.setMouseCursor(.resize_all);
            }

            if (!popup_open and zgui.isMouseClicked(.left)) {
                const grab_beat = (mouse[0] - grid_window_pos[0] + state.scroll_x) / pixels_per_beat;
                state.handleNoteClick(note_idx, selection.isShiftDown());

                if (modifier_down and !over_handle) {
                    state.velocity_drag_notes.clearRetainingCapacity();
                    for (state.note_selection.keys()) |sel_idx| {
                        if (sel_idx < clip.notes.items.len) {
                            state.velocity_drag_notes.append(state.allocator, .{
                                .index = sel_idx,
                                .velocity = clip.notes.items[sel_idx].velocity,
                            }) catch {};
                        }
                    }
                    state.drag = .{
                        .mode = .velocity,
                        .note_index = note_idx,
                        .drag_start_mouse_y = mouse[1],
                    };
                } else {
                    state.drag = .{
                        .mode = if (over_handle) .resize_right else .move,
                        .note_index = note_idx,
                        .grab_offset_beats = grab_beat - note.start,
                        .original_start = note.start,
                        .original_pitch = note.pitch,
                        // Save original values for undo
                        .drag_start_start = note.start,
                        .drag_start_pitch = note.pitch,
                        .drag_start_duration = note.duration,
                    };
                }
                left_click_note = true;
            }

            if (!popup_open and zgui.isMouseClicked(.right)) {
                right_click_note_index = note_idx;
                state.note_selection.primary = note_idx;
                if (!state.isNoteSelected(note_idx)) {
                    state.selectOnly(note_idx);
                }
            }
        }
    }

    if (state.automation_lane_index) |lane_index| {
        drawAutomationOverlay(
            state,
            clip,
            lane_index,
            mouse,
            mouse_down,
            grid_window_pos,
            grid_view_width,
            grid_view_height,
            pixels_per_beat,
            quantize_beats,
            automation_mode,
            instrument_plugin,
            fx_plugins,
            draw_list,
        );
    }

    draw_list.popClipRect();

    // Interaction handling
    const in_grid = mouse[0] >= grid_window_pos[0] and mouse[0] < grid_window_pos[0] + grid_view_width and
        mouse[1] >= grid_window_pos[1] and mouse[1] < grid_window_pos[1] + grid_view_height;

    const modifier_down = selection.isModifierDown();
    const shift_down = selection.isShiftDown();
    const keyboard_free = !zgui.isAnyItemActive();

    if (is_focused and keyboard_free and in_grid) {
        zgui.setNextFrameWantCaptureKeyboard(true);
    }

    // Keyboard shortcuts (only when this pane is focused)
    if (is_focused and keyboard_free and !automation_mode) {
        var edit_ctx = EditCtx{
            .state = state,
            .clip = clip,
            .track_index = track_index,
            .scene_index = scene_index,
            .mouse = mouse,
            .grid_pos = grid_window_pos,
            .pixels_per_beat = pixels_per_beat,
            .row_height = row_height,
            .quantize_beats = quantize_beats,
            .min_note_duration = min_note_duration,
            .in_grid = in_grid,
        };
        edit_actions.handleShortcuts(&edit_ctx, modifier_down, .{
            .has_selection = state.hasSelection(),
            .can_paste = state.clipboard.items.len > 0 and in_grid,
        }, .{
            .copy = editCopy,
            .cut = editCut,
            .paste = editPaste,
            .delete = editDelete,
            .select_all = editSelectAll,
        });

        // Arrow key handling
        if (state.drag.mode == .none and state.hasSelection()) {
            handleArrowKeys(state, clip, shift_down, quantize_beats, min_note_duration, track_index, scene_index);
        }
    }

    const cursor_local_before = zgui.getCursorPos();
    const window_pos = zgui.getWindowPos();
    const key_local_pos: [2]f32 = .{ base_pos[0] - window_pos[0], grid_area_y - window_pos[1] };
    zgui.setCursorPos(key_local_pos);
    _ = zgui.invisibleButton("##piano_keys_drag", .{ .w = key_width, .h = grid_view_height });
    const keys_hovered = zgui.isItemHovered(.{});
    zgui.setCursorPos(cursor_local_before);

    if (keys_hovered and zgui.isMouseClicked(.right)) {
        state.key_pan_active = true;
    }

    if (state.key_pan_active) {
        if (zgui.isMouseDown(.right)) {
            const delta = zgui.getMouseDragDelta(.right, .{});
            if (delta[1] != 0) {
                state.scroll_y = std.math.clamp(state.scroll_y - delta[1], 0, max_scroll_y);
                zgui.resetMouseDragDelta(.right);
            }
            zgui.setMouseCursor(.resize_ns);
        } else {
            state.key_pan_active = false;
        }
    } else if (keys_hovered) {
        zgui.setMouseCursor(.resize_ns);
    }

    const wheel_y = zgui.io.getMouseWheel();
    const ui_hovered = zgui.isAnyItemHovered() or zgui.isAnyItemActive();
    if ((keys_hovered or in_grid) and wheel_y != 0 and !ui_hovered) {
        const scroll_step = row_height * 3.0;
        state.scroll_y = std.math.clamp(state.scroll_y - wheel_y * scroll_step, 0, max_scroll_y);
    }

    // Middle mouse pan
    if (in_grid and zgui.isMouseDragging(.middle, -1.0)) {
        const delta = zgui.getMouseDragDelta(.middle, .{});
        state.scroll_x = std.math.clamp(state.scroll_x - delta[0], 0, max_scroll_x);
        state.scroll_y = std.math.clamp(state.scroll_y - delta[1], 0, max_scroll_y);
        zgui.resetMouseDragDelta(.middle);
    }

    // Right-click context menu
    if (!automation_mode and in_grid and zgui.isMouseClicked(.right) and state.drag.mode == .none) {
        const click_beat = (mouse[0] - grid_window_pos[0] + state.scroll_x) / pixels_per_beat;
        const click_row = (mouse[1] - grid_window_pos[1] + state.scroll_y) / row_height;
        var click_pitch_i: i32 = 127 - @as(i32, @intFromFloat(click_row));
        click_pitch_i = std.math.clamp(click_pitch_i, 0, 127);

        state.context_note_index = right_click_note_index;
        state.context_start = selection.snapToStep(click_beat, quantize_beats);
        state.context_pitch = @intCast(click_pitch_i);
        state.context_in_grid = true;
        zgui.openPopup("piano_roll_ctx", .{});
    }

    const menu_action = drawContextMenu(state, clip, min_note_duration, track_index, scene_index);
    const popup_active = popup_open or zgui.isPopupOpen("piano_roll_ctx", .{});

    // Double-click to create note
    if (!popup_active and !menu_action and !automation_mode and in_grid and zgui.isMouseDoubleClicked(.left) and state.drag.mode == .none and !left_click_note) {
        const click_beat = (mouse[0] - grid_window_pos[0] + state.scroll_x) / pixels_per_beat;
        const click_row = (mouse[1] - grid_window_pos[1] + state.scroll_y) / row_height;
        const click_pitch_i: i32 = 127 - @as(i32, @intFromFloat(click_row));

        if (click_beat >= 0 and click_beat < clip.length_beats and click_pitch_i >= 0 and click_pitch_i < 128) {
            const click_pitch: u8 = @intCast(click_pitch_i);
            const snapped_start = selection.snapToStep(click_beat, quantize_beats);
            const max_duration = clip.length_beats - snapped_start;
            const note_duration = @min(quantize_beats, max_duration);

            if (note_duration >= min_note_duration) {
                clip.addNote(click_pitch, snapped_start, note_duration) catch {};
                const new_idx = clip.notes.items.len - 1;
                state.selectOnly(new_idx);
                state.preview_pitch = click_pitch;
                state.preview_track = track_index;
                state.drag = .{
                    .mode = .create,
                    .note_index = new_idx,
                    .original_start = snapped_start,
                    .original_pitch = click_pitch,
                };
            }
        }
    }

    // Single click to start selection rectangle
    if (!popup_active and !menu_action and !automation_mode and in_grid and zgui.isMouseClicked(.left) and state.drag.mode == .none and !left_click_note) {
        if (!shift_down) {
            state.clearSelection();
        }
        state.drag_select.begin(mouse, shift_down);
        state.drag_select.active = true;
        state.drag_select.pending = false;
        state.drag = .{
            .mode = .select_rect,
        };
    }

    // Handle ongoing drag
    if (state.drag.mode != .none) {
        if (!mouse_down) {
            // Emit undo request when drag ends
            switch (state.drag.mode) {
                .create => {
                    // Note was created - emit add request
                    if (state.drag.note_index < clip.notes.items.len) {
                        const note = clip.notes.items[state.drag.note_index];
                        state.emitUndoRequest(.{
                            .kind = .note_add,
                            .track = track_index,
                            .scene = scene_index,
                            .note_index = state.drag.note_index,
                            .note = note,
                        });
                    }
                },
                .move => {
                    // Note was moved - emit move request if position changed
                    if (state.drag.note_index < clip.notes.items.len) {
                        const note = clip.notes.items[state.drag.note_index];
                        if (note.start != state.drag.drag_start_start or note.pitch != state.drag.drag_start_pitch) {
                            state.emitUndoRequest(.{
                                .kind = .note_move,
                                .track = track_index,
                                .scene = scene_index,
                                .note_index = state.drag.note_index,
                                .old_start = state.drag.drag_start_start,
                                .old_pitch = state.drag.drag_start_pitch,
                                .new_start = note.start,
                                .new_pitch = note.pitch,
                            });
                        }
                    }
                },
                .resize_right => {
                    // Note was resized - emit resize request if duration changed
                    if (state.drag.note_index < clip.notes.items.len) {
                        const note = clip.notes.items[state.drag.note_index];
                        if (note.duration != state.drag.drag_start_duration) {
                            state.emitUndoRequest(.{
                                .kind = .note_resize,
                                .track = track_index,
                                .scene = scene_index,
                                .note_index = state.drag.note_index,
                                .old_duration = state.drag.drag_start_duration,
                                .new_duration = note.duration,
                            });
                        }
                    }
                },
                .select_rect => {
                    finalizeRectSelection(state, clip, grid_window_pos, pixels_per_beat, row_height, state.scroll_x, state.scroll_y);
                    state.drag_select.reset();
                },
                .velocity => {
                    state.velocity_drag_notes.clearRetainingCapacity();
                },
                .resize_clip => {
                    // Clip was resized - emit resize request if length changed
                    if (clip.length_beats != state.drag.drag_start_duration) {
                        state.emitUndoRequest(.{
                            .kind = .clip_resize,
                            .track = track_index,
                            .scene = scene_index,
                            .old_duration = state.drag.drag_start_duration,
                            .new_duration = clip.length_beats,
                        });
                    }
                },
                .none => {},
            }
            state.drag.mode = .none;
        } else {
            handleDrag(state, clip, mouse, grid_window_pos, pixels_per_beat, row_height, min_note_duration);
            if ((state.drag.mode == .move or state.drag.mode == .create) and state.drag.note_index < clip.notes.items.len) {
                state.preview_pitch = clip.notes.items[state.drag.note_index].pitch;
                state.preview_track = track_index;
            }
        }
    }

    // Draw selection rectangle
    if (state.drag.mode == .select_rect) {
        state.drag_select.drawClipped(
            draw_list,
            grid_window_pos,
            .{ grid_window_pos[0] + grid_view_width, grid_window_pos[1] + grid_view_height },
            colors.Colors.current.selection_rect,
            colors.Colors.current.selection_rect_border,
        );
    }

    // Draw ruler
    drawRuler(draw_list, grid_area_x, base_pos[1], grid_view_width, ruler_height, state.scroll_x, pixels_per_beat, max_beats, ui_scale);

    // Draw piano keys
    drawPianoKeys(
        draw_list,
        base_pos[0],
        grid_area_y,
        key_width,
        grid_view_height,
        state.scroll_y,
        row_height,
        ui_scale,
        live_key_states,
    );

    // Top-left corner
    draw_list.addRectFilled(.{
        .pmin = .{ base_pos[0], base_pos[1] },
        .pmax = .{ base_pos[0] + key_width, base_pos[1] + ruler_height },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.bg_header),
    });

    zgui.dummy(.{ .w = total_width, .h = total_height });
}

fn drawScrollZoomBar(state: *PianoRollState, pixels_per_beat: f32, key_width: f32, ui_scale: f32) void {
    const scrollbar_width = 200.0 * ui_scale;
    const scrollbar_height = 16.0 * ui_scale;
    const bar_pos = zgui.getCursorScreenPos();

    _ = zgui.invisibleButton("##scroll_zoom_bar", .{ .w = scrollbar_width, .h = scrollbar_height });
    const bar_hovered = zgui.isItemHovered(.{});
    const bar_active = zgui.isItemActive();

    if (bar_active) {
        const delta = zgui.getMouseDragDelta(.left, .{});
        if (delta[0] != 0 or delta[1] != 0) {
            state.scroll_x += delta[0] * 2.0;
            state.beats_per_pixel = std.math.clamp(state.beats_per_pixel + delta[1] * 0.003, 0.005, 1.0);
            zgui.resetMouseDragDelta(.left);
        }
        zgui.setMouseCursor(.resize_all);
    } else if (bar_hovered) {
        zgui.setMouseCursor(.resize_all);
    }

    const draw_list = zgui.getWindowDrawList();
    const bar_color = if (bar_active)
        zgui.colorConvertFloat4ToU32(colors.Colors.current.bg_cell_active)
    else if (bar_hovered)
        zgui.colorConvertFloat4ToU32(colors.Colors.current.bg_cell_hover)
    else
        zgui.colorConvertFloat4ToU32(colors.Colors.current.bg_cell);

    draw_list.addRectFilled(.{
        .pmin = bar_pos,
        .pmax = .{ bar_pos[0] + scrollbar_width, bar_pos[1] + scrollbar_height },
        .col = bar_color,
        .rounding = 4.0,
    });

    // Thumb
    const avail = zgui.getContentRegionAvail();
    const grid_view_width = avail[0] - key_width;
    const max_beats: f32 = 64;
    const content_width = max_beats * pixels_per_beat;

    const thumb_ratio = @min(1.0, grid_view_width / content_width);
    const thumb_width = @max(20.0 * ui_scale, scrollbar_width * thumb_ratio);
    const max_thumb_x = scrollbar_width - thumb_width;
    const scroll_ratio = if (content_width > grid_view_width)
        state.scroll_x / (content_width - grid_view_width)
    else
        0.0;
    const thumb_x = bar_pos[0] + scroll_ratio * max_thumb_x;

    draw_list.addRectFilled(.{
        .pmin = .{ thumb_x, bar_pos[1] + 2 },
        .pmax = .{ thumb_x + thumb_width, bar_pos[1] + scrollbar_height - 2 },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.accent),
        .rounding = 3.0,
    });

    zgui.sameLine(.{ .spacing = 10.0 * ui_scale });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
    const zoom_pct = (1.0 - state.beats_per_pixel) / (1.0 - 0.005) * 100;
    zgui.text("{d:.0}%", .{zoom_pct});
    zgui.popStyleColor(.{ .count = 1 });
}

fn drawAutomationHeader(
    state: *PianoRollState,
    clip: *PianoRollClip,
    ui_scale: f32,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
) void {
    const lane_count = clip.automation.lanes.items.len;
    if (lane_count == 0) {
        state.automation_lane_index = null;
    } else if (state.automation_lane_index == null or state.automation_lane_index.? >= lane_count) {
        state.automation_lane_index = 0;
    }

    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
    zgui.textUnformatted("Automation:");
    zgui.popStyleColor(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
    zgui.setNextItemWidth(260.0 * ui_scale);

    var preview_buf: [256]u8 = undefined;
    const preview = if (state.automation_lane_index) |idx|
        automationLaneLabel(&preview_buf, &clip.automation.lanes.items[idx], instrument_plugin, fx_plugins)
    else
        (std.fmt.bufPrintZ(&preview_buf, "None", .{}) catch "None");

    if (zgui.beginCombo("##automation_lane", .{ .preview_value = preview })) {
        for (clip.automation.lanes.items, 0..) |*lane, idx| {
            var lane_buf: [256]u8 = undefined;
            const label = automationLaneLabel(&lane_buf, lane, instrument_plugin, fx_plugins);
            const selected = state.automation_lane_index != null and state.automation_lane_index.? == idx;
            if (zgui.selectable(label, .{ .selected = selected })) {
                state.automation_lane_index = idx;
                state.automation_selected_point = null;
            }
        }
        zgui.endCombo();
    }

    zgui.sameLine(.{ .spacing = 10.0 * ui_scale });
    if (zgui.button("Add Lane##automation_add", .{ .w = 0, .h = 0 })) {
        state.automation_add_param_id = null;
        zgui.openPopup("automation_add", .{});
    }

    if (state.automation_lane_index) |idx| {
        zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
        if (zgui.button("Remove##automation_remove", .{ .w = 0, .h = 0 })) {
            if (idx < clip.automation.lanes.items.len) {
                var lane = &clip.automation.lanes.items[idx];
                if (lane.target_id.len > 0) {
                    clip.allocator.free(lane.target_id);
                }
                if (lane.param_id) |param_id| {
                    clip.allocator.free(param_id);
                }
                if (lane.unit) |unit| {
                    clip.allocator.free(unit);
                }
                lane.points.deinit(clip.allocator);
                _ = clip.automation.lanes.orderedRemove(idx);
                state.automation_lane_index = if (clip.automation.lanes.items.len > 0) @min(idx, clip.automation.lanes.items.len - 1) else null;
                state.automation_selected_point = null;
            }
        }
    }

    zgui.sameLine(.{ .spacing = 10.0 * ui_scale });
    _ = zgui.checkbox("Edit##automation_edit", .{ .v = &state.automation_edit });

    if (zgui.beginPopup("automation_add", .{})) {
        const targets = "Track Volume\x00Track Pan\x00Instrument Param\x00FX Param\x00\x00";
        var target_index: i32 = @intFromEnum(state.automation_add_target);
        if (zgui.combo("Target", .{
            .current_item = &target_index,
            .items_separated_by_zeros = targets,
        })) {
            state.automation_add_target = @enumFromInt(target_index);
            state.automation_add_param_id = null;
        }

        if (state.automation_add_target == .fx_param) {
            if (fx_plugins.len == 0) {
                zgui.textUnformatted("No FX slots on this track.");
            } else {
                var fx_label_buf: [64]u8 = undefined;
                const current_fx = @min(state.automation_add_fx_index, fx_plugins.len - 1);
                state.automation_add_fx_index = current_fx;
                const fx_preview = std.fmt.bufPrintZ(&fx_label_buf, "FX {d}", .{current_fx + 1}) catch "FX";
                if (zgui.beginCombo("FX Slot", .{ .preview_value = fx_preview })) {
                    for (0..fx_plugins.len) |fx_index| {
                        var slot_buf: [32]u8 = undefined;
                        const slot_label = std.fmt.bufPrintZ(&slot_buf, "FX {d}", .{fx_index + 1}) catch "FX";
                        const selected = fx_index == state.automation_add_fx_index;
                        if (zgui.selectable(slot_label, .{ .selected = selected })) {
                            state.automation_add_fx_index = fx_index;
                            state.automation_add_param_id = null;
                        }
                    }
                    zgui.endCombo();
                }
            }
        }

        const target_plugin = switch (state.automation_add_target) {
            .instrument_param => instrument_plugin,
            .fx_param => if (fx_plugins.len > 0) fx_plugins[@min(state.automation_add_fx_index, fx_plugins.len - 1)] else null,
            else => null,
        };

        var has_param_selection = true;
        if (state.automation_add_target == .instrument_param or state.automation_add_target == .fx_param) {
            has_param_selection = drawParamCombo("Parameter", target_plugin, &state.automation_add_param_id);
        }

        const allow_add = switch (state.automation_add_target) {
            .track_volume, .track_pan => true,
            else => has_param_selection and state.automation_add_param_id != null,
        };

        zgui.beginDisabled(.{ .disabled = !allow_add });
        if (zgui.button("Create Lane", .{ .w = 0, .h = 0 })) {
            addAutomationLane(state, clip, instrument_plugin, fx_plugins);
            zgui.closeCurrentPopup();
        }
        zgui.endDisabled();

        zgui.endPopup();
    }
}

fn addAutomationLane(
    state: *PianoRollState,
    clip: *PianoRollClip,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
) void {
    var target_kind: AutomationTargetKind = .parameter;
    var target_id_buf: [32]u8 = undefined;
    var target_id: []const u8 = "";
    var param_id_buf: [32]u8 = undefined;
    var param_id: []const u8 = "";

    switch (state.automation_add_target) {
        .track_volume => {
            target_kind = .track;
            target_id = "track";
            param_id = "volume";
        },
        .track_pan => {
            target_kind = .track;
            target_id = "track";
            param_id = "pan";
        },
        .instrument_param => {
            target_kind = .parameter;
            target_id = "instrument";
            if (state.automation_add_param_id) |pid| {
                param_id = std.fmt.bufPrint(&param_id_buf, "{d}", .{pid}) catch "";
            }
        },
        .fx_param => {
            target_kind = .parameter;
            target_id = std.fmt.bufPrint(&target_id_buf, "fx{d}", .{state.automation_add_fx_index}) catch "fx0";
            if (state.automation_add_param_id) |pid| {
                param_id = std.fmt.bufPrint(&param_id_buf, "{d}", .{pid}) catch "";
            }
        },
    }

    if (param_id.len == 0 and (state.automation_add_target == .instrument_param or state.automation_add_target == .fx_param)) {
        return;
    }

    if (findAutomationLaneIndex(clip, target_kind, target_id, param_id)) |existing| {
        state.automation_lane_index = existing;
        state.automation_selected_point = null;
        return;
    }

    const target_id_copy = if (target_id.len > 0) clip.allocator.dupe(u8, target_id) catch "" else "";
    const param_id_copy = if (param_id.len > 0) (clip.allocator.dupe(u8, param_id) catch null) else null;

    _ = instrument_plugin;
    _ = fx_plugins;

    clip.automation.lanes.append(clip.allocator, .{
        .target_kind = target_kind,
        .target_id = target_id_copy,
        .param_id = param_id_copy,
        .unit = null,
        .points = .{},
    }) catch return;

    state.automation_lane_index = clip.automation.lanes.items.len - 1;
    state.automation_selected_point = null;
}

fn findAutomationLaneIndex(
    clip: *PianoRollClip,
    target_kind: AutomationTargetKind,
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

fn drawParamCombo(
    label: []const u8,
    plugin: ?*const clap.Plugin,
    selected_param: *?u32,
) bool {
    if (plugin == null) {
        zgui.textUnformatted("No plugin loaded.");
        return false;
    }
    const ext_raw = plugin.?.getExtension(plugin.?, clap.ext.params.id) orelse {
        zgui.textUnformatted("No parameters exposed.");
        return false;
    };
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const count = params.count(plugin.?);
    if (count == 0) {
        zgui.textUnformatted("No parameters exposed.");
        return false;
    }

    var preview_buf: [256]u8 = undefined;
    const preview_label = if (selected_param.*) |pid|
        getParamLabelById(&preview_buf, plugin.?, params, pid)
    else
        (std.fmt.bufPrintZ(&preview_buf, "Select parameter", .{}) catch "Select parameter");

    var label_buf: [64]u8 = undefined;
    const label_z: [:0]const u8 = std.fmt.bufPrintZ(&label_buf, "{s}", .{label}) catch "Parameter";
    if (zgui.beginCombo(label_z, .{ .preview_value = preview_label })) {
        for (0..count) |i| {
            var info: clap.ext.params.Info = undefined;
            if (!params.getInfo(plugin.?, @intCast(i), &info)) continue;
            var name_buf: [256]u8 = undefined;
            const name = formatParamLabelZ(&name_buf, &info);
            const selected = selected_param.* != null and selected_param.*.? == @intFromEnum(info.id);
            if (zgui.selectable(name, .{ .selected = selected })) {
                selected_param.* = @intFromEnum(info.id);
            }
        }
        zgui.endCombo();
    }
    return true;
}

fn drawAutomationOverlay(
    state: *PianoRollState,
    clip: *PianoRollClip,
    lane_index: usize,
    mouse: [2]f32,
    mouse_down: bool,
    grid_window_pos: [2]f32,
    grid_view_width: f32,
    grid_view_height: f32,
    pixels_per_beat: f32,
    quantize_beats: f32,
    automation_mode: bool,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
    draw_list: zgui.DrawList,
) void {
    if (lane_index >= clip.automation.lanes.items.len) return;
    var lane = &clip.automation.lanes.items[lane_index];
    if (lane.points.items.len == 0 and !automation_mode) return;

    const range = getAutomationRange(lane, instrument_plugin, fx_plugins);
    const min_value = range.min_value;
    const max_value = range.max_value;

    const in_grid = mouse[0] >= grid_window_pos[0] and mouse[0] < grid_window_pos[0] + grid_view_width and
        mouse[1] >= grid_window_pos[1] and mouse[1] < grid_window_pos[1] + grid_view_height;

    const point_radius = 4.0;
    var hovered_point: ?usize = null;

    for (lane.points.items, 0..) |point, idx| {
        const x = grid_window_pos[0] + point.time * pixels_per_beat - state.scroll_x;
        const y = valueToY(point.value, min_value, max_value, grid_window_pos[1], grid_view_height);
        if (@abs(mouse[0] - x) <= point_radius and @abs(mouse[1] - y) <= point_radius) {
            hovered_point = idx;
            break;
        }
    }

    if (automation_mode) {
        if (state.automation_drag_active) {
            if (mouse_down) {
                if (state.automation_drag_lane == lane_index and state.automation_drag_point < lane.points.items.len) {
                    const drag_time = selection.snapToStep(
                        std.math.clamp((mouse[0] - grid_window_pos[0] + state.scroll_x) / pixels_per_beat, 0, clip.length_beats),
                        quantize_beats,
                    );
                    const drag_value = valueFromY(mouse[1], min_value, max_value, grid_window_pos[1], grid_view_height);
                    lane.points.items[state.automation_drag_point] = .{ .time = drag_time, .value = drag_value };
                    sortAutomationPoints(&lane.points);
                    state.automation_drag_point = findPointIndex(&lane.points, drag_time, drag_value);
                    state.automation_selected_point = state.automation_drag_point;
                }
            } else {
                state.automation_drag_active = false;
            }
        } else if (hovered_point) |idx| {
            if (zgui.isMouseClicked(.left)) {
                state.automation_drag_active = true;
                state.automation_drag_lane = lane_index;
                state.automation_drag_point = idx;
                state.automation_selected_point = idx;
            } else if (zgui.isMouseClicked(.right)) {
                _ = lane.points.orderedRemove(idx);
                if (state.automation_selected_point) |sel| {
                    if (sel == idx or sel >= lane.points.items.len) {
                        state.automation_selected_point = null;
                    }
                }
            }
        } else if (in_grid and zgui.isMouseClicked(.left)) {
            if (lane.points.items.len < 64) {
                const new_time = selection.snapToStep(
                    std.math.clamp((mouse[0] - grid_window_pos[0] + state.scroll_x) / pixels_per_beat, 0, clip.length_beats),
                    quantize_beats,
                );
                const new_value = valueFromY(mouse[1], min_value, max_value, grid_window_pos[1], grid_view_height);
                lane.points.append(clip.allocator, .{ .time = new_time, .value = new_value }) catch {};
                sortAutomationPoints(&lane.points);
                state.automation_selected_point = findPointIndex(&lane.points, new_time, new_value);
            }
        }
    }

    sortAutomationPoints(&lane.points);

    if (lane.points.items.len > 1) {
        const line_color = zgui.colorConvertFloat4ToU32(colors.Colors.current.accent);
        for (lane.points.items, 0..) |point, idx| {
            if (idx == 0) continue;
            const prev = lane.points.items[idx - 1];
            const x1 = grid_window_pos[0] + prev.time * pixels_per_beat - state.scroll_x;
            const y1 = valueToY(prev.value, min_value, max_value, grid_window_pos[1], grid_view_height);
            const x2 = grid_window_pos[0] + point.time * pixels_per_beat - state.scroll_x;
            const y2 = valueToY(point.value, min_value, max_value, grid_window_pos[1], grid_view_height);
        draw_list.addLine(.{ .p1 = .{ x1, y1 }, .p2 = .{ x2, y2 }, .col = line_color, .thickness = 2.0 });
        }
    }

    for (lane.points.items, 0..) |point, idx| {
        const x = grid_window_pos[0] + point.time * pixels_per_beat - state.scroll_x;
        const y = valueToY(point.value, min_value, max_value, grid_window_pos[1], grid_view_height);
        const is_selected = state.automation_selected_point != null and state.automation_selected_point.? == idx;
        const point_color = if (is_selected) colors.Colors.current.note_handle_selected else colors.Colors.current.note_handle;
        draw_list.addCircleFilled(.{ .p = .{ x, y }, .r = point_radius, .col = zgui.colorConvertFloat4ToU32(point_color) });
    }
}

const AutomationRange = struct {
    min_value: f32,
    max_value: f32,
};

fn getAutomationRange(
    lane: *const AutomationLane,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
) AutomationRange {
    if (lane.target_kind == .track) {
        if (lane.param_id) |param_id| {
            if (std.mem.eql(u8, param_id, "volume")) {
                return .{ .min_value = 0.0, .max_value = 2.0 };
            }
            if (std.mem.eql(u8, param_id, "pan")) {
                return .{ .min_value = 0.0, .max_value = 1.0 };
            }
        }
    }

    const plugin = getLanePlugin(lane, instrument_plugin, fx_plugins) orelse return .{ .min_value = 0.0, .max_value = 1.0 };
    const param_id = lane.param_id orelse return .{ .min_value = 0.0, .max_value = 1.0 };
    const pid = std.fmt.parseInt(u32, param_id, 10) catch return .{ .min_value = 0.0, .max_value = 1.0 };

    var info: clap.ext.params.Info = undefined;
    if (findParamInfo(plugin, pid, &info)) {
        const min_value: f32 = @floatCast(info.min_value);
        const max_value: f32 = @floatCast(info.max_value);
        if (max_value > min_value) {
            return .{ .min_value = min_value, .max_value = max_value };
        }
    }
    return .{ .min_value = 0.0, .max_value = 1.0 };
}

fn getLanePlugin(
    lane: *const AutomationLane,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
) ?*const clap.Plugin {
    if (lane.target_kind != .parameter) return null;
    if (lane.target_id.len == 0 or std.mem.eql(u8, lane.target_id, "instrument")) {
        return instrument_plugin;
    }
    if (parseFxIndex(lane.target_id)) |fx_index| {
        if (fx_index < fx_plugins.len) {
            return fx_plugins[fx_index];
        }
    }
    return null;
}

fn valueToY(value: f32, min_value: f32, max_value: f32, top: f32, height: f32) f32 {
    const clamped = std.math.clamp(value, min_value, max_value);
    const t = if (max_value > min_value) (clamped - min_value) / (max_value - min_value) else 0.0;
    return top + (1.0 - t) * height;
}

fn valueFromY(y: f32, min_value: f32, max_value: f32, top: f32, height: f32) f32 {
    const t = 1.0 - std.math.clamp((y - top) / height, 0.0, 1.0);
    return min_value + t * (max_value - min_value);
}

fn sortAutomationPoints(points: *std.ArrayListUnmanaged(AutomationPoint)) void {
    std.mem.sort(AutomationPoint, points.items, {}, struct {
        fn lessThan(_: void, a: AutomationPoint, b: AutomationPoint) bool {
            return a.time < b.time;
        }
    }.lessThan);
}

fn findPointIndex(points: *const std.ArrayListUnmanaged(AutomationPoint), time: f32, value: f32) usize {
    for (points.items, 0..) |point, idx| {
        if (std.math.approxEqAbs(f32, point.time, time, 0.0001) and std.math.approxEqAbs(f32, point.value, value, 0.0001)) {
            return idx;
        }
    }
    return 0;
}

fn parseFxIndex(target_id: []const u8) ?usize {
    if (!std.mem.startsWith(u8, target_id, "fx")) return null;
    var idx_str = target_id["fx".len..];
    if (std.mem.startsWith(u8, idx_str, ":")) {
        idx_str = idx_str[1..];
    }
    return std.fmt.parseInt(usize, idx_str, 10) catch null;
}

fn automationLaneLabel(
    buf: []u8,
    lane: *const AutomationLane,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
) [:0]const u8 {
    if (lane.target_kind == .track) {
        if (lane.param_id) |param_id| {
            if (std.mem.eql(u8, param_id, "volume")) {
                return std.fmt.bufPrintZ(buf, "Track Volume", .{}) catch "Track Volume";
            }
            if (std.mem.eql(u8, param_id, "pan")) {
                return std.fmt.bufPrintZ(buf, "Track Pan", .{}) catch "Track Pan";
            }
        }
        return std.fmt.bufPrintZ(buf, "Track Automation", .{}) catch "Track Automation";
    }

    var target_buf: [64]u8 = undefined;
    const target_label = if (lane.target_id.len == 0 or std.mem.eql(u8, lane.target_id, "instrument")) blk: {
        break :blk "Instrument";
    } else if (parseFxIndex(lane.target_id)) |fx_index| blk: {
        break :blk std.fmt.bufPrint(&target_buf, "FX {d}", .{fx_index + 1}) catch "FX";
    } else blk: {
        break :blk "Device";
    };

    const param_label = if (lane.param_id) |param_id| blk: {
        const pid = std.fmt.parseInt(u32, param_id, 10) catch break :blk param_id;
        const plugin = getLanePlugin(lane, instrument_plugin, fx_plugins) orelse break :blk param_id;
        const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse break :blk param_id;
        const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
        var label_buf: [256]u8 = undefined;
        break :blk getParamLabelById(&label_buf, plugin, params, pid);
    } else "Param";

    return std.fmt.bufPrintZ(buf, "{s}: {s}", .{ target_label, param_label }) catch "Automation";
}

fn findParamInfo(plugin: *const clap.Plugin, param_id: u32, out: *clap.ext.params.Info) bool {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse return false;
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const count = params.count(plugin);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (!params.getInfo(plugin, @intCast(i), out)) continue;
        if (@intFromEnum(out.id) == param_id) return true;
    }
    return false;
}

fn getParamLabelById(
    buf: []u8,
    plugin: *const clap.Plugin,
    params: *const clap.ext.params.Plugin,
    param_id: u32,
) [:0]const u8 {
    const count = params.count(plugin);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var info: clap.ext.params.Info = undefined;
        if (!params.getInfo(plugin, @intCast(i), &info)) continue;
        if (@intFromEnum(info.id) != param_id) continue;
        return formatParamLabelZ(buf, &info);
    }
    return std.fmt.bufPrintZ(buf, "Param {d}", .{param_id}) catch "Param";
}

fn formatParamLabelZ(buf: []u8, info: *const clap.ext.params.Info) [:0]const u8 {
    const name = sliceToNull(info.name[0..]);
    const module = sliceToNull(info.module[0..]);
    if (module.len > 0) {
        return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ module, name }) catch "Param";
    }
    return std.fmt.bufPrintZ(buf, "{s}", .{name}) catch "Param";
}

fn sliceToNull(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

const EditCtx = struct {
    state: *PianoRollState,
    clip: *PianoRollClip,
    track_index: usize,
    scene_index: usize,
    mouse: [2]f32,
    grid_pos: [2]f32,
    pixels_per_beat: f32,
    row_height: f32,
    quantize_beats: f32,
    min_note_duration: f32,
    in_grid: bool,
};

const MenuCtx = struct {
    state: *PianoRollState,
    clip: *PianoRollClip,
    track_index: usize,
    scene_index: usize,
    min_note_duration: f32,
};

fn editCopy(ctx: *EditCtx) void {
    copyNotes(ctx.state, ctx.clip);
}

fn editCut(ctx: *EditCtx) void {
    copyNotes(ctx.state, ctx.clip);
    deleteSelectedNotes(ctx.state, ctx.clip, ctx.track_index, ctx.scene_index);
}

fn editPaste(ctx: *EditCtx) void {
    if (ctx.state.clipboard.items.len == 0 or !ctx.in_grid) return;
    pasteNotes(
        ctx.state,
        ctx.clip,
        ctx.track_index,
        ctx.scene_index,
        ctx.mouse,
        ctx.grid_pos,
        ctx.pixels_per_beat,
        ctx.row_height,
        ctx.quantize_beats,
        ctx.min_note_duration,
    );
}

fn editDelete(ctx: *EditCtx) void {
    deleteSelectedNotes(ctx.state, ctx.clip, ctx.track_index, ctx.scene_index);
}

fn editSelectAll(ctx: *EditCtx) void {
    ctx.state.note_selection.clear();
    for (ctx.clip.notes.items, 0..) |_, idx| {
        ctx.state.note_selection.add(idx);
    }
    if (ctx.clip.notes.items.len > 0) {
        ctx.state.note_selection.primary = 0;
    }
}

fn menuCopy(ctx: *MenuCtx) void {
    copyNotes(ctx.state, ctx.clip);
}

fn menuCut(ctx: *MenuCtx) void {
    copyNotes(ctx.state, ctx.clip);
    deleteSelectedNotes(ctx.state, ctx.clip, ctx.track_index, ctx.scene_index);
}

fn menuPaste(ctx: *MenuCtx) void {
    if (ctx.state.clipboard.items.len == 0 or !ctx.state.context_in_grid) return;
    pasteNotesFromContextMenu(ctx.state, ctx.clip, ctx.track_index, ctx.scene_index, ctx.min_note_duration);
}

fn menuDelete(ctx: *MenuCtx) void {
    deleteSelectedNotes(ctx.state, ctx.clip, ctx.track_index, ctx.scene_index);
}

fn menuSelectAll(ctx: *MenuCtx) void {
    ctx.state.note_selection.clear();
    for (ctx.clip.notes.items, 0..) |_, idx| {
        ctx.state.note_selection.add(idx);
    }
    if (ctx.clip.notes.items.len > 0) {
        ctx.state.note_selection.primary = 0;
    }
}

fn copyNotes(state: *PianoRollState, clip: *const PianoRollClip) void {
    if (!state.hasSelection()) return;

    state.clipboard.clearRetainingCapacity();
    var min_start: f32 = std.math.floatMax(f32);
    for (state.note_selection.keys()) |idx| {
        if (idx < clip.notes.items.len) {
            min_start = @min(min_start, clip.notes.items[idx].start);
        }
    }
    for (state.note_selection.keys()) |idx| {
        if (idx < clip.notes.items.len) {
            var note_copy = clip.notes.items[idx];
            note_copy.start -= min_start;
            state.clipboard.append(state.allocator, note_copy) catch {};
        }
    }
}

fn pasteNotesFromContextMenu(
    state: *PianoRollState,
    clip: *PianoRollClip,
    track_index: usize,
    scene_index: usize,
    min_duration: f32,
) void {
    const snapped_start = state.context_start;
    const first_pitch: i32 = @intCast(state.clipboard.items[0].pitch);
    const pitch_offset = @as(i32, state.context_pitch) - first_pitch;

    state.clearSelection();
    for (state.clipboard.items) |copied| {
        const new_start = snapped_start + copied.start;
        if (new_start >= 0 and new_start < clip.length_beats) {
            const duration = @min(copied.duration, clip.length_beats - new_start);
            if (duration >= min_duration) {
                var new_pitch_i: i32 = @as(i32, copied.pitch) + pitch_offset;
                new_pitch_i = std.math.clamp(new_pitch_i, 0, 127);
                clip.addNote(@intCast(new_pitch_i), new_start, duration) catch {};
                if (clip.notes.items.len > 0) {
                    const note_index = clip.notes.items.len - 1;
                    const note = clip.notes.items[note_index];
                    state.emitUndoRequest(.{
                        .kind = .note_add,
                        .track = track_index,
                        .scene = scene_index,
                        .note_index = note_index,
                        .note = note,
                    });
                    state.selectNote(note_index);
                }
            }
        }
    }
}

fn deleteSelectedNotes(state: *PianoRollState, clip: *PianoRollClip, track_index: usize, scene_index: usize) void {
    if (!state.hasSelection()) return;

    var indices: std.ArrayListUnmanaged(usize) = .{};
    defer indices.deinit(state.allocator);
    for (state.note_selection.keys()) |idx| {
        indices.append(state.allocator, idx) catch {};
    }
    selection.sortDescending(indices.items);
    for (indices.items) |idx| {
        if (idx < clip.notes.items.len) {
            const note = clip.notes.items[idx];
            // Emit undo request before removing
            state.emitUndoRequest(.{
                .kind = .note_remove,
                .track = track_index,
                .scene = scene_index,
                .note_index = idx,
                .note = note,
            });
            _ = clip.notes.orderedRemove(idx);
        }
    }
    state.clearSelection();
}

fn pasteNotes(
    state: *PianoRollState,
    clip: *PianoRollClip,
    track_index: usize,
    scene_index: usize,
    mouse: [2]f32,
    grid_pos: [2]f32,
    pixels_per_beat: f32,
    row_height: f32,
    quantize_beats: f32,
    min_duration: f32,
) void {
    const click_beat = (mouse[0] - grid_pos[0] + state.scroll_x) / pixels_per_beat;
    const click_row = (mouse[1] - grid_pos[1] + state.scroll_y) / row_height;
    var click_pitch_i: i32 = 127 - @as(i32, @intFromFloat(click_row));
    click_pitch_i = std.math.clamp(click_pitch_i, 0, 127);
    const snapped_start = selection.snapToStep(click_beat, quantize_beats);

    const first_pitch: i32 = @intCast(state.clipboard.items[0].pitch);
    const pitch_offset = click_pitch_i - first_pitch;

    state.clearSelection();
    for (state.clipboard.items) |copied| {
        const new_start = snapped_start + copied.start;
        if (new_start >= 0 and new_start < clip.length_beats) {
            const duration = @min(copied.duration, clip.length_beats - new_start);
            if (duration >= min_duration) {
                var new_pitch_i: i32 = @as(i32, copied.pitch) + pitch_offset;
                new_pitch_i = std.math.clamp(new_pitch_i, 0, 127);
                clip.addNote(@intCast(new_pitch_i), new_start, duration) catch {};
                if (clip.notes.items.len > 0) {
                    const note_index = clip.notes.items.len - 1;
                    const note = clip.notes.items[note_index];
                    state.emitUndoRequest(.{
                        .kind = .note_add,
                        .track = track_index,
                        .scene = scene_index,
                        .note_index = note_index,
                        .note = note,
                    });
                    state.selectNote(note_index);
                }
            }
        }
    }
}

fn handleArrowKeys(
    state: *PianoRollState,
    clip: *PianoRollClip,
    shift_down: bool,
    quantize_beats: f32,
    min_duration: f32,
    track_index: usize,
    scene_index: usize,
) void {
    if (shift_down) {
        if (zgui.isKeyPressed(.left_arrow, true)) {
            for (state.note_selection.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    note.duration = @max(min_duration, note.duration - quantize_beats);
                }
            }
        }
        if (zgui.isKeyPressed(.right_arrow, true)) {
            for (state.note_selection.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    note.duration = @min(clip.length_beats - note.start, note.duration + quantize_beats);
                }
            }
        }
        if (zgui.isKeyPressed(.up_arrow, true)) {
            var preview_pitch: ?u8 = null;
            var moved = false;
            for (state.note_selection.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    const old_pitch = note.pitch;
                    const new_pitch_i = @min(127, @as(i32, old_pitch) + 12);
                    if (new_pitch_i != old_pitch) {
                        note.pitch = @intCast(new_pitch_i);
                        if (preview_pitch == null) {
                            preview_pitch = note.pitch;
                        }
                        moved = true;
                        state.emitUndoRequest(.{
                            .kind = .note_move,
                            .track = track_index,
                            .scene = scene_index,
                            .note_index = idx,
                            .old_start = note.start,
                            .old_pitch = old_pitch,
                            .new_start = note.start,
                            .new_pitch = note.pitch,
                        });
                    }
                }
            }
            if (moved and preview_pitch != null) {
                state.preview_pitch = preview_pitch;
                state.preview_track = track_index;
            }
        }
        if (zgui.isKeyPressed(.down_arrow, true)) {
            var preview_pitch: ?u8 = null;
            var moved = false;
            for (state.note_selection.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    const old_pitch = note.pitch;
                    const new_pitch_i = @max(0, @as(i32, old_pitch) - 12);
                    if (new_pitch_i != old_pitch) {
                        note.pitch = @intCast(new_pitch_i);
                        if (preview_pitch == null) {
                            preview_pitch = note.pitch;
                        }
                        moved = true;
                        state.emitUndoRequest(.{
                            .kind = .note_move,
                            .track = track_index,
                            .scene = scene_index,
                            .note_index = idx,
                            .old_start = note.start,
                            .old_pitch = old_pitch,
                            .new_start = note.start,
                            .new_pitch = note.pitch,
                        });
                    }
                }
            }
            if (moved and preview_pitch != null) {
                state.preview_pitch = preview_pitch;
                state.preview_track = track_index;
            }
        }
    } else {
        if (zgui.isKeyPressed(.left_arrow, true)) {
            var preview_pitch: ?u8 = null;
            var moved = false;
            for (state.note_selection.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    const old_start = note.start;
                    note.start = @max(0, note.start - quantize_beats);
                    if (note.start != old_start) {
                        if (preview_pitch == null) {
                            preview_pitch = note.pitch;
                        }
                        moved = true;
                    }
                }
            }
            if (moved and preview_pitch != null) {
                state.preview_pitch = preview_pitch;
                state.preview_track = track_index;
            }
        }
        if (zgui.isKeyPressed(.right_arrow, true)) {
            var preview_pitch: ?u8 = null;
            var moved = false;
            for (state.note_selection.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    const old_start = note.start;
                    note.start = @min(clip.length_beats - note.duration, note.start + quantize_beats);
                    if (note.start != old_start) {
                        if (preview_pitch == null) {
                            preview_pitch = note.pitch;
                        }
                        moved = true;
                    }
                }
            }
            if (moved and preview_pitch != null) {
                state.preview_pitch = preview_pitch;
                state.preview_track = track_index;
            }
        }
        if (zgui.isKeyPressed(.up_arrow, true)) {
            var preview_pitch: ?u8 = null;
            var moved = false;
            for (state.note_selection.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    const old_pitch = note.pitch;
                    const new_pitch: u8 = @intCast(@min(127, @as(i32, note.pitch) + 1));
                    if (new_pitch != old_pitch) {
                        note.pitch = new_pitch;
                        if (preview_pitch == null) {
                            preview_pitch = note.pitch;
                        }
                        moved = true;
                        state.emitUndoRequest(.{
                            .kind = .note_move,
                            .track = track_index,
                            .scene = scene_index,
                            .note_index = idx,
                            .old_start = note.start,
                            .old_pitch = old_pitch,
                            .new_start = note.start,
                            .new_pitch = note.pitch,
                        });
                    }
                }
            }
            if (moved and preview_pitch != null) {
                state.preview_pitch = preview_pitch;
                state.preview_track = track_index;
            }
        }
        if (zgui.isKeyPressed(.down_arrow, true)) {
            var preview_pitch: ?u8 = null;
            var moved = false;
            for (state.note_selection.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    const old_pitch = note.pitch;
                    const new_pitch: u8 = @intCast(@max(0, @as(i32, note.pitch) - 1));
                    if (new_pitch != old_pitch) {
                        note.pitch = new_pitch;
                        if (preview_pitch == null) {
                            preview_pitch = note.pitch;
                        }
                        moved = true;
                        state.emitUndoRequest(.{
                            .kind = .note_move,
                            .track = track_index,
                            .scene = scene_index,
                            .note_index = idx,
                            .old_start = note.start,
                            .old_pitch = old_pitch,
                            .new_start = note.start,
                            .new_pitch = note.pitch,
                        });
                    }
                }
            }
            if (moved and preview_pitch != null) {
                state.preview_pitch = preview_pitch;
                state.preview_track = track_index;
            }
        }
    }
}

fn handleDrag(
    state: *PianoRollState,
    clip: *PianoRollClip,
    mouse: [2]f32,
    grid_pos: [2]f32,
    pixels_per_beat: f32,
    row_height: f32,
    min_duration: f32,
) void {
    switch (state.drag.mode) {
        .resize_clip => {
            const current_beat = (mouse[0] - grid_pos[0] + state.scroll_x) / pixels_per_beat;
            var new_length = @floor(current_beat * 4) / 4;
            new_length = @max(beats_per_bar, new_length);
            new_length = @min(256, new_length);
            clip.length_beats = new_length;
        },
        .move => {
            if (state.drag.note_index < clip.notes.items.len) {
                const current_beat = (mouse[0] - grid_pos[0] + state.scroll_x) / pixels_per_beat;
                const current_row = (mouse[1] - grid_pos[1] + state.scroll_y) / row_height;

                var new_start = current_beat - state.drag.grab_offset_beats;
                new_start = @floor(new_start * 4) / 4;

                var new_pitch_i: i32 = 127 - @as(i32, @intFromFloat(current_row));
                new_pitch_i = std.math.clamp(new_pitch_i, 0, 127);

                const delta_start = new_start - state.drag.original_start;
                const delta_pitch = new_pitch_i - @as(i32, state.drag.original_pitch);

                for (state.note_selection.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        const note = &clip.notes.items[idx];
                        note.start = @max(0, @min(note.start + delta_start, clip.length_beats - note.duration));
                        note.pitch = @intCast(std.math.clamp(@as(i32, note.pitch) + delta_pitch, 0, 127));
                    }
                }

                state.drag.original_start = new_start;
                state.drag.original_pitch = @intCast(new_pitch_i);
            }
        },
        .velocity => {
            const velocity_per_pixel: f32 = 0.005;
            const delta = (state.drag.drag_start_mouse_y - mouse[1]) * velocity_per_pixel;
            for (state.velocity_drag_notes.items) |entry| {
                if (entry.index < clip.notes.items.len) {
                    const new_velocity = std.math.clamp(entry.velocity + delta, 0.0, 1.0);
                    clip.notes.items[entry.index].velocity = new_velocity;
                }
            }
        },
        .resize_right, .create => {
            if (state.drag.note_index < clip.notes.items.len) {
                const note = &clip.notes.items[state.drag.note_index];
                const current_beat = (mouse[0] - grid_pos[0] + state.scroll_x) / pixels_per_beat;

                var new_end = current_beat;
                new_end = @max(note.start + min_duration, new_end);
                new_end = @min(new_end, clip.length_beats);
                new_end = @ceil(new_end * 16) / 16;
                note.duration = new_end - note.start;
            }
        },
        .select_rect => {
            state.drag_select.update(mouse);
        },
        .none => {},
    }
}

fn finalizeRectSelection(
    state: *PianoRollState,
    clip: *const PianoRollClip,
    grid_pos: [2]f32,
    pixels_per_beat: f32,
    row_height: f32,
    scroll_x: f32,
    scroll_y: f32,
) void {
    const rect = state.drag_select.getRect();
    const sel_x1 = rect.min[0];
    const sel_y1 = rect.min[1];
    const sel_x2 = rect.max[0];
    const sel_y2 = rect.max[1];

    for (clip.notes.items, 0..) |note, idx| {
        const note_row = 127 - @as(usize, note.pitch);
        const note_x = grid_pos[0] + note.start * pixels_per_beat - scroll_x;
        const note_y = grid_pos[1] + @as(f32, @floatFromInt(note_row)) * row_height - scroll_y;
        const note_w = note.duration * pixels_per_beat;

        if (note_x < sel_x2 and note_x + note_w > sel_x1 and note_y < sel_y2 and note_y + row_height > sel_y1) {
            state.selectNote(idx);
        }
    }
}

fn drawContextMenu(state: *PianoRollState, clip: *PianoRollClip, min_duration: f32, track_index: usize, scene_index: usize) bool {
    if (zgui.beginPopup("piano_roll_ctx", .{})) {
        var menu_ctx = MenuCtx{
            .state = state,
            .clip = clip,
            .track_index = track_index,
            .scene_index = scene_index,
            .min_note_duration = min_duration,
        };
        const action_triggered = edit_actions.drawMenu(&menu_ctx, .{
            .has_selection = state.hasSelection(),
            .can_paste = state.clipboard.items.len > 0 and state.context_in_grid,
        }, .{
            .copy = menuCopy,
            .cut = menuCut,
            .paste = menuPaste,
            .delete = menuDelete,
            .select_all = menuSelectAll,
        });

        zgui.endPopup();
        return action_triggered;
    }
    return false;
}

fn drawRuler(
    draw_list: zgui.DrawList,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    scroll_x: f32,
    pixels_per_beat: f32,
    max_beats: f32,
    ui_scale: f32,
) void {
    const font_size = zgui.getFontSize();
    const max_label_size = height - 4.0 * ui_scale;
    const label_font_size = @min(font_size, @max(0.0, max_label_size));
    const label_y = y + (height - label_font_size) / 2.0;

    draw_list.addRectFilled(.{
        .pmin = .{ x, y },
        .pmax = .{ x + width, y + height },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.bg_header),
    });

    draw_list.pushClipRect(.{
        .pmin = .{ x, y },
        .pmax = .{ x + width, y + height },
    });

    const last_beat = (scroll_x + width) / pixels_per_beat;
    var beat: f32 = @floor(scroll_x / pixels_per_beat);
    while (beat <= @min(last_beat + 1, max_beats)) : (beat += 1) {
        const bx = x + beat * pixels_per_beat - scroll_x;
        const beat_int = @as(i32, @intFromFloat(beat));
        const is_bar = @mod(beat_int, beats_per_bar) == 0;

        if (is_bar and label_font_size >= 6.0) {
            const bar_num = @divFloor(beat_int, beats_per_bar) + 1;
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrintZ(&buf, "{d}", .{bar_num}) catch "";
            draw_list.addTextExtended(
                .{ bx + 4, label_y },
                zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright),
                "{s}",
                .{label},
                .{ .font = null, .font_size = label_font_size },
            );
        }

        const tick_height: f32 = if (is_bar) height * 0.6 else height * 0.3;
        draw_list.addLine(.{
            .p1 = .{ bx, y + height - tick_height },
            .p2 = .{ bx, y + height },
            .col = zgui.colorConvertFloat4ToU32(if (is_bar) colors.Colors.current.ruler_tick else colors.Colors.current.text_soft),
            .thickness = if (is_bar) 1.5 else 1.0,
        });
    }

    draw_list.popClipRect();
}

fn drawPianoKeys(
    draw_list: zgui.DrawList,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    scroll_y: f32,
    row_height: f32,
    ui_scale: f32,
    live_key_states: *const [128]bool,
) void {
    const font_size = zgui.getFontSize();
    const max_label_size = row_height - 2.0 * ui_scale;
    const label_font_size = @min(font_size, @max(0.0, max_label_size));

    const is_black_key = [_]bool{ false, true, false, true, false, false, true, false, true, false, true, false };

    draw_list.addRectFilled(.{
        .pmin = .{ x, y },
        .pmax = .{ x + width, y + height },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.bg_panel),
    });

    draw_list.pushClipRect(.{
        .pmin = .{ x, y },
        .pmax = .{ x + width, y + height },
    });

    const first_row: usize = @intFromFloat(@max(0, @floor(scroll_y / row_height)));
    const last_row: usize = @intFromFloat(@min(127, @ceil((scroll_y + height) / row_height)));

    var row: usize = first_row;
    while (row <= last_row) : (row += 1) {
        const pitch: u8 = if (row <= 127) @intCast(127 - row) else 0;
        const ky = y + @as(f32, @floatFromInt(row)) * row_height - scroll_y;

        if (ky < y - row_height or ky > y + height) continue;

        const note_in_octave = pitch % 12;
        const oct = @as(i32, @intCast(pitch / 12)) - 1;

        const is_black = is_black_key[note_in_octave];
        const key_color = if (is_black)
            zgui.colorConvertFloat4ToU32(colors.Colors.current.piano_key_black)
        else
            zgui.colorConvertFloat4ToU32(colors.Colors.current.piano_key_white);

        draw_list.addRectFilled(.{
            .pmin = .{ x, ky },
            .pmax = .{ x + width - 1, ky + row_height - 1 },
            .col = key_color,
        });

        if (live_key_states[pitch]) {
            const accent = colors.Colors.current.accent;
            const highlight = zgui.colorConvertFloat4ToU32(.{
                accent[0],
                accent[1],
                accent[2],
                if (is_black) 0.55 else 0.4,
            });
            draw_list.addRectFilled(.{
                .pmin = .{ x, ky },
                .pmax = .{ x + width - 1, ky + row_height - 1 },
                .col = highlight,
            });
            draw_list.addRect(.{
                .pmin = .{ x, ky },
                .pmax = .{ x + width - 1, ky + row_height - 1 },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.accent_dim),
                .thickness = 1.0,
            });
        }

        if (note_in_octave == 0 and label_font_size >= 6.0) {
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrintZ(&buf, "C{d}", .{oct}) catch "";
            const text_y = ky + (row_height - label_font_size) / 2.0;
            draw_list.addTextExtended(
                .{ x + 6, text_y },
                zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright),
                "{s}",
                .{label},
                .{ .font = null, .font_size = label_font_size },
            );
        }
    }

    draw_list.popClipRect();
}

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
