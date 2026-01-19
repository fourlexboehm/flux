const zgui = @import("zgui");
const colors = @import("colors.zig");
const selection = @import("selection.zig");
const session_view = @import("session_view.zig");
const std = @import("std");

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
};

pub const PianoRollClip = struct {
    allocator: std.mem.Allocator,
    length_beats: f32,
    notes: std.ArrayListUnmanaged(Note),

    pub fn init(allocator: std.mem.Allocator) PianoRollClip {
        return .{
            .allocator = allocator,
            .length_beats = default_clip_bars * beats_per_bar,
            .notes = .{},
        };
    }

    pub fn deinit(self: *PianoRollClip) void {
        self.notes.deinit(self.allocator);
    }

    pub fn addNote(self: *PianoRollClip, pitch: u8, start: f32, duration: f32) !void {
        try self.notes.append(self.allocator, .{ .pitch = pitch, .start = start, .duration = duration });
    }

    pub fn removeNoteAt(self: *PianoRollClip, index: usize) void {
        _ = self.notes.orderedRemove(index);
    }

    pub fn clear(self: *PianoRollClip) void {
        self.notes.clearRetainingCapacity();
        self.length_beats = default_clip_bars * beats_per_bar;
    }
};

pub const DragMode = enum {
    none,
    create,
    resize_right,
    move,
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
    // For undo tracking
    drag_start_start: f32 = 0, // Start position when drag began
    drag_start_pitch: u8 = 0, // Pitch when drag began
    drag_start_duration: f32 = 0, // Duration when drag began
};

pub const PianoRollState = struct {
    allocator: std.mem.Allocator,

    // Note selection
    selected_notes: std.AutoArrayHashMapUnmanaged(usize, void) = .{},
    selected_note_index: ?usize = null,

    // Clipboard
    clipboard: std.ArrayListUnmanaged(Note) = .{},

    // Drag state
    drag: PianoRollDrag = .{},
    drag_select: selection.DragSelectState = .{},

    // Context menu state
    context_note_index: ?usize = null,
    context_start: f32 = 0,
    context_pitch: u8 = 60,
    context_in_grid: bool = false,

    // View state
    scroll_x: f32 = 0,
    scroll_y: f32 = 50 * 20.0, // Start around C4
    beats_per_pixel: f32 = 0.5,

    // Undo requests (processed by ui.zig)
    undo_requests: [16]UndoRequest = undefined,
    undo_request_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) PianoRollState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PianoRollState) void {
        self.selected_notes.deinit(self.allocator);
        self.clipboard.deinit(self.allocator);
    }

    pub fn clearSelection(self: *PianoRollState) void {
        self.selected_notes.clearRetainingCapacity();
        self.selected_note_index = null;
    }

    pub fn selectNote(self: *PianoRollState, index: usize) void {
        self.selected_notes.put(self.allocator, index, {}) catch {};
        self.selected_note_index = index;
    }

    pub fn deselectNote(self: *PianoRollState, index: usize) void {
        _ = self.selected_notes.orderedRemove(index);
        if (self.selected_note_index == index) {
            self.selected_note_index = if (self.selected_notes.count() > 0) self.selected_notes.keys()[0] else null;
        }
    }

    pub fn isNoteSelected(self: *const PianoRollState, index: usize) bool {
        return self.selected_notes.contains(index);
    }

    pub fn hasSelection(self: *const PianoRollState) bool {
        return self.selected_notes.count() > 0;
    }

    pub fn selectOnly(self: *PianoRollState, index: usize) void {
        self.selected_notes.clearRetainingCapacity();
        self.selectNote(index);
    }

    pub fn emitUndoRequest(self: *PianoRollState, request: UndoRequest) void {
        if (self.undo_request_count < self.undo_requests.len) {
            self.undo_requests[self.undo_request_count] = request;
            self.undo_request_count += 1;
        }
    }

    pub fn handleNoteClick(self: *PianoRollState, index: usize, shift_held: bool) void {
        if (shift_held) {
            if (self.isNoteSelected(index)) {
                self.deselectNote(index);
            } else {
                self.selectNote(index);
            }
        } else if (!self.isNoteSelected(index)) {
            self.selectOnly(index);
        } else {
            self.selected_note_index = index;
        }
    }
};

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
) void {
    const key_width = 56.0 * ui_scale;
    const ruler_height = 24.0 * ui_scale;
    const min_note_duration: f32 = 0.0625;
    const resize_handle_width = 8.0 * ui_scale;
    const clip_end_handle_width = 10.0 * ui_scale;
    const quantize_beats = quantizeIndexToBeats(quantize_index);

    const pixels_per_beat = 60.0 / state.beats_per_pixel;
    const row_height = 20.0 * ui_scale;

    const mouse = zgui.getMousePos();
    const mouse_down = zgui.isMouseDown(.left);

    // Header
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.text_bright });
    zgui.text("{s}", .{clip_label});
    zgui.popStyleColor(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = 20.0 * ui_scale });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.text_dim });
    zgui.text("{d:.0} bars", .{clip.length_beats / beats_per_bar});
    zgui.popStyleColor(.{ .count = 1 });

    // Scroll/zoom bar
    zgui.sameLine(.{ .spacing = 30.0 * ui_scale });
    drawScrollZoomBar(state, pixels_per_beat, key_width, ui_scale);

    zgui.spacing();

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
            zgui.colorConvertFloat4ToU32(.{ 0.10, 0.10, 0.10, 1.0 })
        else if (note_in_octave == 0)
            zgui.colorConvertFloat4ToU32(.{ 0.18, 0.18, 0.18, 1.0 })
        else
            zgui.colorConvertFloat4ToU32(.{ 0.14, 0.14, 0.14, 1.0 });

        draw_list.addRectFilled(.{
            .pmin = .{ grid_window_pos[0], y },
            .pmax = .{ grid_window_pos[0] + content_width, y + row_height },
            .col = row_color,
        });

        const line_col = if (note_in_octave == 0)
            zgui.colorConvertFloat4ToU32(.{ 0.30, 0.30, 0.30, 1.0 })
        else
            zgui.colorConvertFloat4ToU32(.{ 0.20, 0.20, 0.20, 1.0 });
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
            zgui.colorConvertFloat4ToU32(.{ 0.45, 0.45, 0.45, 1.0 })
        else if (is_beat)
            zgui.colorConvertFloat4ToU32(.{ 0.32, 0.32, 0.32, 1.0 })
        else if (is_8th)
            zgui.colorConvertFloat4ToU32(.{ 0.24, 0.24, 0.24, 1.0 })
        else
            zgui.colorConvertFloat4ToU32(.{ 0.18, 0.18, 0.18, 1.0 });

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
                .col = zgui.colorConvertFloat4ToU32(.{ 0.0, 0.0, 0.0, 0.4 }),
            });
        }

        const end_color = if (clip_end_hovered or state.drag.mode == .resize_clip)
            colors.Colors.accent
        else
            colors.Colors.accent_dim;
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
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.accent),
                .thickness = 2.0,
            });
        }
    }

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

        const note_color = if (is_selected) colors.Colors.note_selected else colors.Colors.note_color;
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
                .col = zgui.colorConvertFloat4ToU32(.{ 1.0, 1.0, 1.0, 0.8 }),
                .rounding = 3.0,
                .thickness = 2.0,
            });
        }

        // Resize handle
        const handle_x = note_x + note_w - resize_handle_width;
        const handle_color = if (is_selected) [4]f32{ 0.45, 0.75, 0.55, 1.0 } else [4]f32{ 0.28, 0.58, 0.38, 1.0 };
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

        if (over_note and state.drag.mode == .none) {
            zgui.setMouseCursor(if (over_handle) .resize_ew else .resize_all);

            if (zgui.isMouseClicked(.left)) {
                const grab_beat = (mouse[0] - grid_window_pos[0] + state.scroll_x) / pixels_per_beat;
                state.handleNoteClick(note_idx, selection.isShiftDown());

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
                left_click_note = true;
            }

            if (zgui.isMouseClicked(.right)) {
                right_click_note_index = note_idx;
                state.selected_note_index = note_idx;
                if (!state.isNoteSelected(note_idx)) {
                    state.selectOnly(note_idx);
                }
            }
        }
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
    if (is_focused and keyboard_free) {
        if (modifier_down and zgui.isKeyPressed(.c, false)) {
            copyNotes(state, clip);
        }

        if (modifier_down and zgui.isKeyPressed(.x, false)) {
            copyNotes(state, clip);
            deleteSelectedNotes(state, clip, track_index, scene_index);
        }

        if (modifier_down and zgui.isKeyPressed(.v, false)) {
            if (state.clipboard.items.len > 0 and in_grid) {
                pasteNotes(state, clip, mouse, grid_window_pos, pixels_per_beat, row_height, quantize_beats, min_note_duration);
            }
        }

        if (zgui.isKeyPressed(.delete, false) or zgui.isKeyPressed(.back_space, false)) {
            deleteSelectedNotes(state, clip, track_index, scene_index);
        }

        if (modifier_down and zgui.isKeyPressed(.a, false)) {
            state.selected_notes.clearRetainingCapacity();
            for (clip.notes.items, 0..) |_, idx| {
                state.selected_notes.put(state.allocator, idx, {}) catch {};
            }
            if (clip.notes.items.len > 0) {
                state.selected_note_index = 0;
            }
        }

        // Arrow key handling
        if (state.drag.mode == .none and state.hasSelection()) {
            handleArrowKeys(state, clip, shift_down, quantize_beats, min_note_duration);
        }
    }

    // Middle mouse pan
    if (in_grid and zgui.isMouseDragging(.middle, -1.0)) {
        const delta = zgui.getMouseDragDelta(.middle, .{});
        state.scroll_x = std.math.clamp(state.scroll_x - delta[0], 0, max_scroll_x);
        state.scroll_y = std.math.clamp(state.scroll_y - delta[1], 0, max_scroll_y);
        zgui.resetMouseDragDelta(.middle);
    }

    // Right-click context menu
    if (in_grid and zgui.isMouseClicked(.right) and state.drag.mode == .none) {
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

    // Double-click to create note
    if (in_grid and zgui.isMouseDoubleClicked(.left) and state.drag.mode == .none and !left_click_note) {
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
    if (in_grid and zgui.isMouseClicked(.left) and state.drag.mode == .none and !left_click_note) {
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
        }
    }

    // Draw selection rectangle
    if (state.drag.mode == .select_rect) {
        drawSelectionRect(state, grid_window_pos, grid_view_width, grid_view_height, draw_list);
    }

    // Context menu
    drawContextMenu(state, clip, min_note_duration, track_index, scene_index);

    // Draw ruler
    drawRuler(draw_list, grid_area_x, base_pos[1], grid_view_width, ruler_height, state.scroll_x, pixels_per_beat, max_beats, ui_scale);

    // Draw piano keys
    drawPianoKeys(draw_list, base_pos[0], grid_area_y, key_width, grid_view_height, state.scroll_y, row_height, ui_scale);

    // Top-left corner
    draw_list.addRectFilled(.{
        .pmin = .{ base_pos[0], base_pos[1] },
        .pmax = .{ base_pos[0] + key_width, base_pos[1] + ruler_height },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.bg_dark),
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
        zgui.colorConvertFloat4ToU32(.{ 0.4, 0.4, 0.5, 1.0 })
    else if (bar_hovered)
        zgui.colorConvertFloat4ToU32(.{ 0.35, 0.35, 0.4, 1.0 })
    else
        zgui.colorConvertFloat4ToU32(.{ 0.25, 0.25, 0.3, 1.0 });

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
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.accent),
        .rounding = 3.0,
    });

    zgui.sameLine(.{ .spacing = 10.0 * ui_scale });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.text_dim });
    const zoom_pct = (1.0 - state.beats_per_pixel) / (1.0 - 0.005) * 100;
    zgui.text("{d:.0}%", .{zoom_pct});
    zgui.popStyleColor(.{ .count = 1 });
}

fn copyNotes(state: *PianoRollState, clip: *const PianoRollClip) void {
    if (!state.hasSelection()) return;

    state.clipboard.clearRetainingCapacity();
    var min_start: f32 = std.math.floatMax(f32);
    for (state.selected_notes.keys()) |idx| {
        if (idx < clip.notes.items.len) {
            min_start = @min(min_start, clip.notes.items[idx].start);
        }
    }
    for (state.selected_notes.keys()) |idx| {
        if (idx < clip.notes.items.len) {
            var note_copy = clip.notes.items[idx];
            note_copy.start -= min_start;
            state.clipboard.append(state.allocator, note_copy) catch {};
        }
    }
}

fn deleteSelectedNotes(state: *PianoRollState, clip: *PianoRollClip, track_index: usize, scene_index: usize) void {
    if (!state.hasSelection()) return;

    var indices: std.ArrayListUnmanaged(usize) = .{};
    defer indices.deinit(state.allocator);
    for (state.selected_notes.keys()) |idx| {
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
                state.selectNote(clip.notes.items.len - 1);
            }
        }
    }
}

fn handleArrowKeys(state: *PianoRollState, clip: *PianoRollClip, shift_down: bool, quantize_beats: f32, min_duration: f32) void {
    if (shift_down) {
        if (zgui.isKeyPressed(.left_arrow, true)) {
            for (state.selected_notes.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    note.duration = @max(min_duration, note.duration - quantize_beats);
                }
            }
        }
        if (zgui.isKeyPressed(.right_arrow, true)) {
            for (state.selected_notes.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    note.duration = @min(clip.length_beats - note.start, note.duration + quantize_beats);
                }
            }
        }
    } else {
        if (zgui.isKeyPressed(.left_arrow, true)) {
            for (state.selected_notes.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    note.start = @max(0, note.start - quantize_beats);
                }
            }
        }
        if (zgui.isKeyPressed(.right_arrow, true)) {
            for (state.selected_notes.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    note.start = @min(clip.length_beats - note.duration, note.start + quantize_beats);
                }
            }
        }
        if (zgui.isKeyPressed(.up_arrow, true)) {
            for (state.selected_notes.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    note.pitch = @intCast(@min(127, @as(i32, note.pitch) + 1));
                }
            }
        }
        if (zgui.isKeyPressed(.down_arrow, true)) {
            for (state.selected_notes.keys()) |idx| {
                if (idx < clip.notes.items.len) {
                    const note = &clip.notes.items[idx];
                    note.pitch = @intCast(@max(0, @as(i32, note.pitch) - 1));
                }
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

                for (state.selected_notes.keys()) |idx| {
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

fn drawSelectionRect(
    state: *const PianoRollState,
    grid_pos: [2]f32,
    grid_width: f32,
    grid_height: f32,
    draw_list: zgui.DrawList,
) void {
    const rect = state.drag_select.getRect();
    const sel_x1 = rect.min[0];
    const sel_y1 = rect.min[1];
    const sel_x2 = rect.max[0];
    const sel_y2 = rect.max[1];

    const clipped_x1 = @max(sel_x1, grid_pos[0]);
    const clipped_y1 = @max(sel_y1, grid_pos[1]);
    const clipped_x2 = @min(sel_x2, grid_pos[0] + grid_width);
    const clipped_y2 = @min(sel_y2, grid_pos[1] + grid_height);

    if (clipped_x2 > clipped_x1 and clipped_y2 > clipped_y1) {
        draw_list.addRectFilled(.{
            .pmin = .{ clipped_x1, clipped_y1 },
            .pmax = .{ clipped_x2, clipped_y2 },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.selection_rect),
        });
        draw_list.addRect(.{
            .pmin = .{ clipped_x1, clipped_y1 },
            .pmax = .{ clipped_x2, clipped_y2 },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.selection_rect_border),
            .thickness = 1.0,
        });
    }
}

fn drawContextMenu(state: *PianoRollState, clip: *PianoRollClip, min_duration: f32, track_index: usize, scene_index: usize) void {
    if (zgui.beginPopup("piano_roll_ctx", .{})) {
        const has_selection = state.hasSelection();
        const can_paste = state.clipboard.items.len > 0 and state.context_in_grid;

        if (zgui.menuItem("Copy", .{ .shortcut = "Cmd/Ctrl+C", .enabled = has_selection })) {
            copyNotes(state, clip);
        }

        if (zgui.menuItem("Cut", .{ .shortcut = "Cmd/Ctrl+X", .enabled = has_selection })) {
            copyNotes(state, clip);
            deleteSelectedNotes(state, clip, track_index, scene_index);
        }

        if (zgui.menuItem("Paste", .{ .shortcut = "Cmd/Ctrl+V", .enabled = can_paste })) {
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
                        state.selectNote(clip.notes.items.len - 1);
                    }
                }
            }
        }

        if (zgui.menuItem("Delete", .{ .shortcut = "Del", .enabled = has_selection })) {
            deleteSelectedNotes(state, clip, track_index, scene_index);
        }

        zgui.separator();

        if (zgui.menuItem("Select All", .{ .shortcut = "Cmd/Ctrl+A" })) {
            state.selected_notes.clearRetainingCapacity();
            for (clip.notes.items, 0..) |_, idx| {
                state.selected_notes.put(state.allocator, idx, {}) catch {};
            }
            if (clip.notes.items.len > 0) {
                state.selected_note_index = 0;
            }
        }

        zgui.endPopup();
    }
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
    _ = ui_scale;

    draw_list.addRectFilled(.{
        .pmin = .{ x, y },
        .pmax = .{ x + width, y + height },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.bg_header),
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

        if (is_bar) {
            const bar_num = @divFloor(beat_int, beats_per_bar) + 1;
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrintZ(&buf, "{d}", .{bar_num}) catch "";
            draw_list.addText(.{ bx + 4, y + 4 }, zgui.colorConvertFloat4ToU32(colors.Colors.text_bright), "{s}", .{label});
        }

        const tick_height: f32 = if (is_bar) height * 0.6 else height * 0.3;
        draw_list.addLine(.{
            .p1 = .{ bx, y + height - tick_height },
            .p2 = .{ bx, y + height },
            .col = zgui.colorConvertFloat4ToU32(if (is_bar) colors.Colors.text_dim else .{ 0.3, 0.3, 0.3, 1.0 }),
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
) void {
    _ = ui_scale;

    const is_black_key = [_]bool{ false, true, false, true, false, false, true, false, true, false, true, false };

    draw_list.addRectFilled(.{
        .pmin = .{ x, y },
        .pmax = .{ x + width, y + height },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.bg_dark),
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
            zgui.colorConvertFloat4ToU32(.{ 0.08, 0.08, 0.08, 1.0 })
        else
            zgui.colorConvertFloat4ToU32(.{ 0.20, 0.20, 0.20, 1.0 });

        draw_list.addRectFilled(.{
            .pmin = .{ x, ky },
            .pmax = .{ x + width - 1, ky + row_height - 1 },
            .col = key_color,
        });

        if (note_in_octave == 0) {
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrintZ(&buf, "C{d}", .{oct}) catch "";
            // Center text vertically in row (font is ~13px, center it)
            const text_y = ky + (row_height - 10.0) / 2.0;
            draw_list.addText(.{ x + 6, text_y }, zgui.colorConvertFloat4ToU32(colors.Colors.text_bright), "{s}", .{label});
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
