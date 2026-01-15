const zgui = @import("zgui");
const ui = @import("ui.zig");
const State = @import("ui.zig").State;
const std = @import("std");

const PianoRollClip = ui.PianoRollClip;

pub fn drawSequencer(state: *State, ui_scale: f32) void {
    const clip = &state.piano_clips[state.selected_track][state.selected_scene];
    const clip_label = state.clips[state.selected_track][state.selected_scene].label;

    // Layout constants
    const key_width = 48.0 * ui_scale;
    const ruler_height = 24.0 * ui_scale;
    const min_note_duration: f32 = 0.0625; // 1/16 note minimum
    const resize_handle_width = 8.0 * ui_scale;
    const clip_end_handle_width = 10.0 * ui_scale;
    const quantize_beats = quantizeIndexToBeats(state.quantize_index);

    // Zoom - pixels per beat
    const pixels_per_beat = 60.0 / state.beats_per_pixel;
    const row_height = 20.0 * ui_scale; // Taller rows for better visibility

    const mouse = zgui.getMousePos();
    const mouse_down = zgui.isMouseDown(.left);

    // Header with clip name, length, and zoom slider
    zgui.pushStyleColor4f(.{ .idx = .text, .c = ui.Colors.text_bright });
    zgui.text("{s}", .{clip_label});
    zgui.popStyleColor(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = 20.0 * ui_scale });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = ui.Colors.text_dim });
    zgui.text("{d:.0} bars", .{clip.length_beats / ui.beats_per_bar});
    zgui.popStyleColor(.{ .count = 1 });

    // Scroll/Zoom bar - drag left/right to scroll, drag up/down to zoom
    zgui.sameLine(.{ .spacing = 30.0 * ui_scale });

    const scrollbar_width = 200.0 * ui_scale;
    const scrollbar_height = 16.0 * ui_scale;

    // Get position for drawing
    const bar_pos = zgui.getCursorScreenPos();

    // Create invisible button for interaction
    _ = zgui.invisibleButton("##scroll_zoom_bar", .{ .w = scrollbar_width, .h = scrollbar_height });
    const bar_hovered = zgui.isItemHovered(.{});
    const bar_active = zgui.isItemActive();

    // Handle drag
    if (bar_active) {
        const delta = zgui.getMouseDragDelta(.left, .{});
        if (delta[0] != 0 or delta[1] != 0) {
            // Horizontal drag = scroll (scaled by zoom level)
            const scroll_sensitivity = 2.0;
            state.scroll_x += delta[0] * scroll_sensitivity;

            // Vertical drag = zoom (up = zoom in, down = zoom out)
            const zoom_sensitivity = 0.003;
            state.beats_per_pixel = std.math.clamp(
                state.beats_per_pixel + delta[1] * zoom_sensitivity,
                0.005, // Max zoom in
                1.0, // Max zoom out - can see entire clip
            );

            zgui.resetMouseDragDelta(.left);
        }
        zgui.setMouseCursor(.resize_all);
    } else if (bar_hovered) {
        zgui.setMouseCursor(.resize_all);
    }

    // Draw the scrollbar background
    const draw_list = zgui.getWindowDrawList();
    const bar_color = if (bar_active)
        zgui.colorConvertFloat4ToU32(.{ 0.4, 0.4, 0.5, 1.0 })
    else if (bar_hovered)
        zgui.colorConvertFloat4ToU32(.{ 0.35, 0.35, 0.4, 1.0 })
    else
        zgui.colorConvertFloat4ToU32(.{ 0.25, 0.25, 0.3, 1.0 });

    draw_list.addRectFilled(.{
        .pmin = .{ bar_pos[0], bar_pos[1] },
        .pmax = .{ bar_pos[0] + scrollbar_width, bar_pos[1] + scrollbar_height },
        .col = bar_color,
        .rounding = 4.0,
    });

    // Draw a thumb indicator showing current scroll position
    // Calculate thumb size and position based on visible area vs total content
    const max_beats_preview = @max(clip.length_beats + 16, 64);
    const content_width_preview = max_beats_preview * pixels_per_beat;
    const avail_preview = zgui.getContentRegionAvail();
    const grid_view_width_preview = avail_preview[0] - key_width;

    const thumb_ratio = @min(1.0, grid_view_width_preview / content_width_preview);
    const thumb_width = @max(20.0 * ui_scale, scrollbar_width * thumb_ratio);
    const max_thumb_x = scrollbar_width - thumb_width;
    const scroll_ratio = if (content_width_preview > grid_view_width_preview)
        state.scroll_x / (content_width_preview - grid_view_width_preview)
    else
        0.0;
    const thumb_x = bar_pos[0] + scroll_ratio * max_thumb_x;

    draw_list.addRectFilled(.{
        .pmin = .{ thumb_x, bar_pos[1] + 2 },
        .pmax = .{ thumb_x + thumb_width, bar_pos[1] + scrollbar_height - 2 },
        .col = zgui.colorConvertFloat4ToU32(ui.Colors.accent),
        .rounding = 3.0,
    });

    // Show zoom level indicator (higher % = more zoomed in)
    zgui.sameLine(.{ .spacing = 10.0 * ui_scale });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = ui.Colors.text_dim });
    const zoom_pct = (1.0 - state.beats_per_pixel) / (1.0 - 0.005) * 100;
    zgui.text("{d:.0}%", .{zoom_pct});
    zgui.popStyleColor(.{ .count = 1 });

    zgui.spacing();

    // Calculate content size (full piano roll dimensions)
    const content_height = 128.0 * row_height;
    const max_beats = @max(clip.length_beats + 16, 64); // Extra space beyond clip end
    const content_width = max_beats * pixels_per_beat;

    // Get available space for the entire piano roll area
    const avail = zgui.getContentRegionAvail();
    const total_width = avail[0];
    const total_height = avail[1];

    const base_pos = zgui.getCursorScreenPos();

    // Define regions
    const keys_area_x = base_pos[0];
    const ruler_area_y = base_pos[1];
    const grid_area_x = base_pos[0] + key_width;
    const grid_area_y = base_pos[1] + ruler_height;
    const grid_view_width = total_width - key_width;
    const grid_view_height = total_height - ruler_height;

    // Clamp scroll values to valid range
    const max_scroll_x = @max(0.0, content_width - grid_view_width);
    const max_scroll_y = @max(0.0, content_height - grid_view_height);
    state.scroll_x = std.math.clamp(state.scroll_x, 0, max_scroll_x);
    state.scroll_y = std.math.clamp(state.scroll_y, 0, max_scroll_y);
    const scroll_x = state.scroll_x;
    const scroll_y = state.scroll_y;

    // Grid window position is grid_area position
    const grid_window_pos: [2]f32 = .{ grid_area_x, grid_area_y };

    {

        // Calculate visible ranges with proper clamping
        const first_visible_beat = scroll_x / pixels_per_beat;
        const last_visible_beat = (scroll_x + grid_view_width) / pixels_per_beat;

        // Safe row calculation - clamp to valid MIDI range [0, 127]
        const first_row_f = @max(0, @floor(scroll_y / row_height));
        const last_row_f = @min(127, @ceil((scroll_y + grid_view_height) / row_height));
        const first_visible_row: usize = @intFromFloat(first_row_f);
        const last_visible_row: usize = @intFromFloat(@max(first_row_f, last_row_f));

        const is_black_key = [_]bool{ false, true, false, true, false, false, true, false, true, false, true, false };

        // Clip to grid area
        draw_list.pushClipRect(.{
            .pmin = .{ grid_window_pos[0], grid_window_pos[1] },
            .pmax = .{ grid_window_pos[0] + grid_view_width, grid_window_pos[1] + grid_view_height },
        });

        // Draw grid background rows
        var row: usize = first_visible_row;
        while (row <= last_visible_row) : (row += 1) {
            const pitch: u8 = if (row <= 127) @intCast(127 - row) else 0;
            const y = grid_window_pos[1] + @as(f32, @floatFromInt(row)) * row_height - scroll_y;

            if (y < grid_window_pos[1] - row_height or y > grid_window_pos[1] + grid_view_height) continue;

            const note_in_octave = pitch % 12;
            const row_color = if (is_black_key[note_in_octave])
                zgui.colorConvertFloat4ToU32(.{ 0.10, 0.10, 0.10, 1.0 })
            else if (note_in_octave == 0)
                zgui.colorConvertFloat4ToU32(.{ 0.18, 0.18, 0.18, 1.0 }) // Highlight C rows
            else
                zgui.colorConvertFloat4ToU32(.{ 0.14, 0.14, 0.14, 1.0 });

            draw_list.addRectFilled(.{
                .pmin = .{ grid_window_pos[0], y },
                .pmax = .{ grid_window_pos[0] + content_width, y + row_height },
                .col = row_color,
            });

            // Horizontal grid line - brighter for C notes
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

        // Draw vertical grid lines with subdivisions (1/16 note grid)
        var sub_beat: f32 = @floor(first_visible_beat * 4) / 4;
        while (sub_beat <= @min(last_visible_beat + 1, max_beats)) : (sub_beat += 0.25) {
            const x = grid_window_pos[0] + sub_beat * pixels_per_beat - scroll_x;
            const beat_16th = @as(i32, @intFromFloat(sub_beat * 4));
            const is_bar = @mod(beat_16th, 16) == 0; // Every 4 beats = bar
            const is_beat = @mod(beat_16th, 4) == 0; // Every beat
            const is_8th = @mod(beat_16th, 2) == 0; // Every 1/8 note

            const line_color = if (is_bar)
                zgui.colorConvertFloat4ToU32(.{ 0.45, 0.45, 0.45, 1.0 })
            else if (is_beat)
                zgui.colorConvertFloat4ToU32(.{ 0.32, 0.32, 0.32, 1.0 })
            else if (is_8th)
                zgui.colorConvertFloat4ToU32(.{ 0.24, 0.24, 0.24, 1.0 })
            else
                zgui.colorConvertFloat4ToU32(.{ 0.18, 0.18, 0.18, 1.0 });

            const thickness: f32 = if (is_bar) 2.0 else if (is_beat) 1.0 else 0.5;

            draw_list.addLine(.{
                .p1 = .{ x, grid_window_pos[1] },
                .p2 = .{ x, grid_window_pos[1] + content_height },
                .col = line_color,
                .thickness = thickness,
            });
        }

        // Draw clip end boundary (draggable)
        const clip_end_x = grid_window_pos[0] + clip.length_beats * pixels_per_beat - scroll_x;

        // Check if mouse is over clip end handle (direct hit test)
        const clip_end_hovered = mouse[0] >= clip_end_x - clip_end_handle_width and
            mouse[0] <= clip_end_x + clip_end_handle_width and
            mouse[1] >= grid_window_pos[1] and
            mouse[1] <= grid_window_pos[1] + grid_view_height;

        // Handle clip end drag - check this FIRST before note interactions
        if (clip_end_hovered and state.piano_drag.mode == .none) {
            zgui.setMouseCursor(.resize_ew);
            if (zgui.isMouseClicked(.left)) {
                state.piano_drag = .{
                    .mode = .resize_clip,
                    .note_index = 0,
                    .grab_offset_beats = 0,
                    .grab_offset_pitch = 0,
                    .original_start = clip.length_beats,
                    .original_pitch = 0,
                    .select_start_x = 0,
                    .select_start_y = 0,
                };
            }
        } else if (state.piano_drag.mode == .resize_clip) {
            zgui.setMouseCursor(.resize_ew);
        }

        // Now draw the clip end visuals
        if (clip_end_x > grid_window_pos[0] - clip_end_handle_width and clip_end_x < grid_window_pos[0] + grid_view_width + clip_end_handle_width) {
            // Semi-transparent area beyond clip
            if (clip_end_x < grid_window_pos[0] + grid_view_width) {
                draw_list.addRectFilled(.{
                    .pmin = .{ clip_end_x, grid_window_pos[1] },
                    .pmax = .{ grid_window_pos[0] + grid_view_width, grid_window_pos[1] + grid_view_height },
                    .col = zgui.colorConvertFloat4ToU32(.{ 0.0, 0.0, 0.0, 0.4 }),
                });
            }

            // Clip end line - bright when hovered or dragging
            const end_color = if (clip_end_hovered or state.piano_drag.mode == .resize_clip)
                ui.Colors.accent
            else
                ui.Colors.accent_dim;
            draw_list.addLine(.{
                .p1 = .{ clip_end_x, grid_window_pos[1] },
                .p2 = .{ clip_end_x, grid_window_pos[1] + grid_view_height },
                .col = zgui.colorConvertFloat4ToU32(end_color),
                .thickness = 3.0,
            });

            // Drag handle indicator (triangle at top)
            draw_list.addTriangleFilled(.{
                .p1 = .{ clip_end_x - 6, grid_window_pos[1] },
                .p2 = .{ clip_end_x + 6, grid_window_pos[1] },
                .p3 = .{ clip_end_x, grid_window_pos[1] + 10 },
                .col = zgui.colorConvertFloat4ToU32(end_color),
            });
        }

        // Draw playhead
        if (state.playing) {
            const playhead_x = grid_window_pos[0] + state.playhead_beat * pixels_per_beat - scroll_x;
            if (playhead_x >= grid_window_pos[0] and playhead_x <= grid_window_pos[0] + grid_view_width) {
                draw_list.addLine(.{
                    .p1 = .{ playhead_x, grid_window_pos[1] },
                    .p2 = .{ playhead_x, grid_window_pos[1] + grid_view_height },
                    .col = zgui.colorConvertFloat4ToU32(ui.Colors.accent),
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

            // Skip if not visible
            if (note_row < first_visible_row or note_row > last_visible_row) continue;
            if (note_end < first_visible_beat or note.start > last_visible_beat) continue;

            const note_x = grid_window_pos[0] + note.start * pixels_per_beat - scroll_x;
            const note_y = grid_window_pos[1] + @as(f32, @floatFromInt(note_row)) * row_height - scroll_y;
            const note_w = note.duration * pixels_per_beat;

            // Check if note is selected (in multi-selection set)
            const is_selected = state.selected_notes.contains(note_idx);

            // Note body
            const note_color = if (is_selected) ui.Colors.note_selected else ui.Colors.note_color;
            draw_list.addRectFilled(.{
                .pmin = .{ note_x + 1, note_y + 1 },
                .pmax = .{ note_x + note_w - 1, note_y + row_height - 1 },
                .col = zgui.colorConvertFloat4ToU32(note_color),
                .rounding = 2.0,
            });

            // Selection highlight border
            if (is_selected) {
                draw_list.addRect(.{
                    .pmin = .{ note_x, note_y },
                    .pmax = .{ note_x + note_w, note_y + row_height },
                    .col = zgui.colorConvertFloat4ToU32(.{ 1.0, 1.0, 1.0, 0.8 }),
                    .rounding = 3.0,
                    .thickness = 2.0,
                });
            }

            // Resize handle (subtle darker right edge)
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

            if (over_note and state.piano_drag.mode == .none) {
                if (over_handle) {
                    zgui.setMouseCursor(.resize_ew);
                } else {
                    zgui.setMouseCursor(.resize_all);
                }

                const shift_down_note = zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift);

                if (zgui.isMouseClicked(.left)) {
                    const grab_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
                    const already_selected = state.selected_notes.contains(note_idx);

                    // Handle selection
                    if (shift_down_note) {
                        // Shift+click: toggle this note in selection
                        if (already_selected) {
                            _ = state.selected_notes.orderedRemove(note_idx);
                        } else {
                            state.selected_notes.put(state.allocator, note_idx, {}) catch {};
                        }
                    } else if (!already_selected) {
                        // Regular click on unselected note: clear selection and select only this note
                        state.selected_notes.clearRetainingCapacity();
                        state.selected_notes.put(state.allocator, note_idx, {}) catch {};
                    }
                    // If already selected and no shift, keep the multi-selection for dragging
                    state.selected_note_index = note_idx;

                    // Start drag operation
                    state.piano_drag = .{
                        .mode = if (over_handle) .resize_right else .move,
                        .note_index = note_idx,
                        .grab_offset_beats = grab_beat - note.start,
                        .grab_offset_pitch = 0,
                        .original_start = note.start,
                        .original_pitch = note.pitch,
                        .select_start_x = 0,
                        .select_start_y = 0,
                    };
                    left_click_note = true;
                }

                if (zgui.isMouseClicked(.right)) {
                    right_click_note_index = note_idx;
                    state.selected_note_index = note_idx;
                    // Add to selection if not already selected
                    if (!state.selected_notes.contains(note_idx)) {
                        state.selected_notes.clearRetainingCapacity();
                        state.selected_notes.put(state.allocator, note_idx, {}) catch {};
                    }
                }
            }
        }

        draw_list.popClipRect();

        // ========== INTERACTION HANDLING ==========

        // Check if mouse is in grid area
        const in_grid = mouse[0] >= grid_window_pos[0] and mouse[0] < grid_window_pos[0] + grid_view_width and
            mouse[1] >= grid_window_pos[1] and mouse[1] < grid_window_pos[1] + grid_view_height;

        const modifier_down = zgui.isKeyDown(.left_super) or zgui.isKeyDown(.right_super) or
            zgui.isKeyDown(.left_ctrl) or zgui.isKeyDown(.right_ctrl);
        const shift_down = zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift);
        const keyboard_free = !zgui.isAnyItemActive();

        // Copy selected notes (Ctrl/Cmd+C)
        if (keyboard_free and modifier_down and zgui.isKeyPressed(.c, false)) {
            if (state.selected_notes.count() > 0) {
                state.piano_clipboard.clearRetainingCapacity();
                // Find the earliest note start time for relative positioning
                var min_start: f32 = std.math.floatMax(f32);
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        min_start = @min(min_start, clip.notes.items[idx].start);
                    }
                }
                // Copy notes with relative positions
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        var note_copy = clip.notes.items[idx];
                        note_copy.start -= min_start; // Store relative to first note
                        state.piano_clipboard.append(state.allocator, note_copy) catch {};
                    }
                }
            }
        }

        // Cut selected notes (Ctrl/Cmd+X)
        if (keyboard_free and modifier_down and zgui.isKeyPressed(.x, false)) {
            if (state.selected_notes.count() > 0) {
                state.piano_clipboard.clearRetainingCapacity();
                // Find the earliest note start time for relative positioning
                var min_start: f32 = std.math.floatMax(f32);
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        min_start = @min(min_start, clip.notes.items[idx].start);
                    }
                }
                // Copy notes with relative positions
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        var note_copy = clip.notes.items[idx];
                        note_copy.start -= min_start;
                        state.piano_clipboard.append(state.allocator, note_copy) catch {};
                    }
                }
                // Delete selected notes (in reverse order to maintain indices)
                var indices_to_delete: std.ArrayListUnmanaged(usize) = .{};
                defer indices_to_delete.deinit(state.allocator);
                for (state.selected_notes.keys()) |idx| {
                    indices_to_delete.append(state.allocator, idx) catch {};
                }
                std.mem.sort(usize, indices_to_delete.items, {}, std.sort.desc(usize));
                for (indices_to_delete.items) |idx| {
                    if (idx < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(idx);
                    }
                }
                state.selected_notes.clearRetainingCapacity();
                state.selected_note_index = null;
            }
        }

        // Paste notes (Ctrl/Cmd+V)
        if (keyboard_free and modifier_down and zgui.isKeyPressed(.v, false)) {
            if (state.piano_clipboard.items.len > 0 and in_grid) {
                const click_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
                const click_row = (mouse[1] - grid_window_pos[1] + scroll_y) / row_height;
                var click_pitch_i: i32 = 127 - @as(i32, @intFromFloat(click_row));
                click_pitch_i = std.math.clamp(click_pitch_i, 0, 127);
                const snapped_start = snapToStep(click_beat, quantize_beats);

                // Find pitch offset (paste at mouse pitch relative to first note)
                const first_pitch: i32 = @intCast(state.piano_clipboard.items[0].pitch);
                const pitch_offset = click_pitch_i - first_pitch;

                state.selected_notes.clearRetainingCapacity();
                for (state.piano_clipboard.items) |copied| {
                    const new_start = snapped_start + copied.start;
                    if (new_start >= 0 and new_start < clip.length_beats) {
                        const duration = @min(copied.duration, clip.length_beats - new_start);
                        if (duration >= min_note_duration) {
                            var new_pitch_i: i32 = @as(i32, copied.pitch) + pitch_offset;
                            new_pitch_i = std.math.clamp(new_pitch_i, 0, 127);
                            const new_pitch: u8 = @intCast(new_pitch_i);
                            clip.addNote(new_pitch, new_start, duration) catch {};
                            // Select newly pasted notes
                            const new_idx = clip.notes.items.len - 1;
                            state.selected_notes.put(state.allocator, new_idx, {}) catch {};
                            state.selected_note_index = new_idx;
                        }
                    }
                }
            }
        }

        // Delete selected notes (Delete key)
        if (keyboard_free and in_grid and zgui.isKeyPressed(.delete, false)) {
            if (state.selected_notes.count() > 0) {
                // Delete in reverse order to maintain indices
                var indices_to_delete: std.ArrayListUnmanaged(usize) = .{};
                defer indices_to_delete.deinit(state.allocator);
                for (state.selected_notes.keys()) |idx| {
                    indices_to_delete.append(state.allocator, idx) catch {};
                }
                std.mem.sort(usize, indices_to_delete.items, {}, std.sort.desc(usize));
                for (indices_to_delete.items) |idx| {
                    if (idx < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(idx);
                    }
                }
                state.selected_notes.clearRetainingCapacity();
                state.selected_note_index = null;
            }
        }

        // Select all (Ctrl/Cmd+A)
        if (keyboard_free and modifier_down and zgui.isKeyPressed(.a, false)) {
            state.selected_notes.clearRetainingCapacity();
            for (clip.notes.items, 0..) |_, idx| {
                state.selected_notes.put(state.allocator, idx, {}) catch {};
            }
            if (clip.notes.items.len > 0) {
                state.selected_note_index = 0;
            }
        }

        // Arrow key handling for all selected notes
        if (keyboard_free and in_grid and state.piano_drag.mode == .none and state.selected_notes.count() > 0) {
            // Capture keyboard to prevent system bonk sound on macOS
            zgui.setNextFrameWantCaptureKeyboard(true);

            if (shift_down) {
                // Shift+Arrow: adjust duration of all selected notes
                if (zgui.isKeyPressed(.left_arrow, true)) {
                    for (state.selected_notes.keys()) |idx| {
                        if (idx < clip.notes.items.len) {
                            const note = &clip.notes.items[idx];
                            note.duration = @max(min_note_duration, note.duration - quantize_beats);
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
                // Arrow: move all selected notes
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
                            const pitch_i: i32 = @min(127, @as(i32, note.pitch) + 1);
                            note.pitch = @intCast(pitch_i);
                        }
                    }
                }
                if (zgui.isKeyPressed(.down_arrow, true)) {
                    for (state.selected_notes.keys()) |idx| {
                        if (idx < clip.notes.items.len) {
                            const note = &clip.notes.items[idx];
                            const pitch_i: i32 = @max(0, @as(i32, note.pitch) - 1);
                            note.pitch = @intCast(pitch_i);
                        }
                    }
                }
            }
        }

        // Middle mouse button pan
        if (in_grid and zgui.isMouseDragging(.middle, -1.0)) {
            const delta = zgui.getMouseDragDelta(.middle, .{});
            state.scroll_x = std.math.clamp(state.scroll_x - delta[0], 0, max_scroll_x);
            state.scroll_y = std.math.clamp(state.scroll_y - delta[1], 0, max_scroll_y);
            zgui.resetMouseDragDelta(.middle);
        }

        if (in_grid and zgui.isMouseClicked(.right) and state.piano_drag.mode == .none) {
            const click_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
            const click_row = (mouse[1] - grid_window_pos[1] + scroll_y) / row_height;
            var click_pitch_i: i32 = 127 - @as(i32, @intFromFloat(click_row));
            click_pitch_i = std.math.clamp(click_pitch_i, 0, 127);
            const click_pitch: u8 = @intCast(click_pitch_i);
            state.piano_context_note_index = right_click_note_index;
            state.piano_context_start = snapToStep(click_beat, quantize_beats);
            state.piano_context_pitch = click_pitch;
            state.piano_context_in_grid = true;
            zgui.openPopup("piano_roll_ctx", .{});
        }

        // Handle double-click on empty grid to create note
        if (in_grid and zgui.isMouseDoubleClicked(.left) and state.piano_drag.mode == .none and !left_click_note) {
            const click_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
            const click_row = (mouse[1] - grid_window_pos[1] + scroll_y) / row_height;
            const click_pitch_i: i32 = 127 - @as(i32, @intFromFloat(click_row));

            if (click_beat >= 0 and click_beat < clip.length_beats and click_pitch_i >= 0 and click_pitch_i < 128) {
                const click_pitch: u8 = @intCast(click_pitch_i);
                const snapped_start = snapToStep(click_beat, quantize_beats);
                const max_duration = clip.length_beats - snapped_start;
                const note_duration = @min(quantize_beats, max_duration);

                if (note_duration >= min_note_duration) {
                    clip.addNote(click_pitch, snapped_start, note_duration) catch {};
                    const new_idx = clip.notes.items.len - 1;
                    state.selected_notes.clearRetainingCapacity();
                    state.selected_notes.put(state.allocator, new_idx, {}) catch {};
                    state.selected_note_index = new_idx;
                    state.piano_drag = .{
                        .mode = .create,
                        .note_index = new_idx,
                        .grab_offset_beats = 0,
                        .grab_offset_pitch = 0,
                        .original_start = snapped_start,
                        .original_pitch = click_pitch,
                        .select_start_x = 0,
                        .select_start_y = 0,
                    };
                }
            }
        }

        // Handle single click on empty grid to start selection rectangle
        if (in_grid and zgui.isMouseClicked(.left) and state.piano_drag.mode == .none and !left_click_note) {
            // Clear selection unless shift is held
            if (!shift_down) {
                state.selected_notes.clearRetainingCapacity();
                state.selected_note_index = null;
            }
            // Start selection rectangle drag
            state.piano_drag = .{
                .mode = .select_rect,
                .note_index = 0,
                .grab_offset_beats = 0,
                .grab_offset_pitch = 0,
                .original_start = 0,
                .original_pitch = 0,
                .select_start_x = mouse[0],
                .select_start_y = mouse[1],
            };
        }

        // Handle ongoing drag
        if (state.piano_drag.mode != .none) {
            if (!mouse_down) {
                // On mouse release for select_rect, finalize selection
                if (state.piano_drag.mode == .select_rect) {
                    const sel_x1 = @min(state.piano_drag.select_start_x, mouse[0]);
                    const sel_y1 = @min(state.piano_drag.select_start_y, mouse[1]);
                    const sel_x2 = @max(state.piano_drag.select_start_x, mouse[0]);
                    const sel_y2 = @max(state.piano_drag.select_start_y, mouse[1]);

                    // Select all notes that intersect with the selection rectangle
                    for (clip.notes.items, 0..) |note, note_idx| {
                        const note_row = 127 - @as(usize, note.pitch);
                        const note_x = grid_window_pos[0] + note.start * pixels_per_beat - scroll_x;
                        const note_y = grid_window_pos[1] + @as(f32, @floatFromInt(note_row)) * row_height - scroll_y;
                        const note_w = note.duration * pixels_per_beat;

                        // Check if note rectangle intersects selection rectangle
                        const note_x2 = note_x + note_w;
                        const note_y2 = note_y + row_height;

                        if (note_x < sel_x2 and note_x2 > sel_x1 and note_y < sel_y2 and note_y2 > sel_y1) {
                            state.selected_notes.put(state.allocator, note_idx, {}) catch {};
                            state.selected_note_index = note_idx;
                        }
                    }
                }
                state.piano_drag.mode = .none;
            } else {
                switch (state.piano_drag.mode) {
                    .resize_clip => {
                        const current_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
                        var new_length = @floor(current_beat * 4) / 4; // Snap to 1/4 note
                        new_length = @max(ui.beats_per_bar, new_length); // Minimum 1 bar
                        new_length = @min(256, new_length); // Maximum 64 bars
                        clip.length_beats = new_length;
                    },
                    .move => {
                        if (state.piano_drag.note_index < clip.notes.items.len) {
                            const current_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
                            const current_row = (mouse[1] - grid_window_pos[1] + scroll_y) / row_height;

                            var new_start = current_beat - state.piano_drag.grab_offset_beats;
                            new_start = @floor(new_start * 4) / 4; // Snap to 1/4 note

                            var new_pitch_i: i32 = 127 - @as(i32, @intFromFloat(current_row));
                            new_pitch_i = std.math.clamp(new_pitch_i, 0, 127);

                            // Calculate delta from last frame position
                            const delta_start = new_start - state.piano_drag.original_start;
                            const delta_pitch = new_pitch_i - @as(i32, state.piano_drag.original_pitch);

                            // Move all selected notes by the same delta
                            for (state.selected_notes.keys()) |idx| {
                                if (idx < clip.notes.items.len) {
                                    const note = &clip.notes.items[idx];
                                    const note_new_start = note.start + delta_start;
                                    note.start = @max(0, @min(note_new_start, clip.length_beats - note.duration));
                                    const note_pitch_i = @as(i32, note.pitch) + delta_pitch;
                                    note.pitch = @intCast(std.math.clamp(note_pitch_i, 0, 127));
                                }
                            }

                            // Update reference position for next frame delta calculation
                            state.piano_drag.original_start = new_start;
                            state.piano_drag.original_pitch = @intCast(new_pitch_i);
                        }
                    },
                    .resize_right, .create => {
                        if (state.piano_drag.note_index < clip.notes.items.len) {
                            const note = &clip.notes.items[state.piano_drag.note_index];
                            const current_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;

                            var new_end = current_beat;
                            new_end = @max(note.start + min_note_duration, new_end);
                            new_end = @min(new_end, clip.length_beats);
                            new_end = @ceil(new_end * 16) / 16; // Snap to 1/16 note for resize
                            note.duration = new_end - note.start;
                        }
                    },
                    .select_rect => {
                        // Draw selection rectangle (handled below after clip rect)
                    },
                    .none => {},
                }
            }
        }

        // Draw selection rectangle while dragging
        if (state.piano_drag.mode == .select_rect) {
            const sel_x1 = @min(state.piano_drag.select_start_x, mouse[0]);
            const sel_y1 = @min(state.piano_drag.select_start_y, mouse[1]);
            const sel_x2 = @max(state.piano_drag.select_start_x, mouse[0]);
            const sel_y2 = @max(state.piano_drag.select_start_y, mouse[1]);

            // Clip to grid area
            const clipped_x1 = @max(sel_x1, grid_window_pos[0]);
            const clipped_y1 = @max(sel_y1, grid_window_pos[1]);
            const clipped_x2 = @min(sel_x2, grid_window_pos[0] + grid_view_width);
            const clipped_y2 = @min(sel_y2, grid_window_pos[1] + grid_view_height);

            if (clipped_x2 > clipped_x1 and clipped_y2 > clipped_y1) {
                draw_list.addRectFilled(.{
                    .pmin = .{ clipped_x1, clipped_y1 },
                    .pmax = .{ clipped_x2, clipped_y2 },
                    .col = zgui.colorConvertFloat4ToU32(ui.Colors.selection_rect),
                });
                draw_list.addRect(.{
                    .pmin = .{ clipped_x1, clipped_y1 },
                    .pmax = .{ clipped_x2, clipped_y2 },
                    .col = zgui.colorConvertFloat4ToU32(ui.Colors.selection_rect_border),
                    .thickness = 1.0,
                });
            }
        }

        if (zgui.beginPopup("piano_roll_ctx", .{})) {
            const has_selection = state.selected_notes.count() > 0;
            const can_paste = state.piano_clipboard.items.len > 0 and state.piano_context_in_grid;

            if (zgui.menuItem("Copy", .{ .shortcut = "Cmd/Ctrl+C", .enabled = has_selection })) {
                state.piano_clipboard.clearRetainingCapacity();
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
                        state.piano_clipboard.append(state.allocator, note_copy) catch {};
                    }
                }
            }

            if (zgui.menuItem("Cut", .{ .shortcut = "Cmd/Ctrl+X", .enabled = has_selection })) {
                state.piano_clipboard.clearRetainingCapacity();
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
                        state.piano_clipboard.append(state.allocator, note_copy) catch {};
                    }
                }
                // Delete in reverse order
                var indices_to_delete: std.ArrayListUnmanaged(usize) = .{};
                defer indices_to_delete.deinit(state.allocator);
                for (state.selected_notes.keys()) |idx| {
                    indices_to_delete.append(state.allocator, idx) catch {};
                }
                std.mem.sort(usize, indices_to_delete.items, {}, std.sort.desc(usize));
                for (indices_to_delete.items) |idx| {
                    if (idx < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(idx);
                    }
                }
                state.selected_notes.clearRetainingCapacity();
                state.selected_note_index = null;
            }

            if (zgui.menuItem("Paste", .{ .shortcut = "Cmd/Ctrl+V", .enabled = can_paste })) {
                const snapped_start = state.piano_context_start;
                const first_pitch: i32 = @intCast(state.piano_clipboard.items[0].pitch);
                const pitch_offset = @as(i32, state.piano_context_pitch) - first_pitch;

                state.selected_notes.clearRetainingCapacity();
                for (state.piano_clipboard.items) |copied| {
                    const new_start = snapped_start + copied.start;
                    if (new_start >= 0 and new_start < clip.length_beats) {
                        const duration = @min(copied.duration, clip.length_beats - new_start);
                        if (duration >= min_note_duration) {
                            var new_pitch_i: i32 = @as(i32, copied.pitch) + pitch_offset;
                            new_pitch_i = std.math.clamp(new_pitch_i, 0, 127);
                            const new_pitch: u8 = @intCast(new_pitch_i);
                            clip.addNote(new_pitch, new_start, duration) catch {};
                            const new_idx = clip.notes.items.len - 1;
                            state.selected_notes.put(state.allocator, new_idx, {}) catch {};
                            state.selected_note_index = new_idx;
                        }
                    }
                }
            }

            if (zgui.menuItem("Delete", .{ .shortcut = "Del", .enabled = has_selection })) {
                var indices_to_delete: std.ArrayListUnmanaged(usize) = .{};
                defer indices_to_delete.deinit(state.allocator);
                for (state.selected_notes.keys()) |idx| {
                    indices_to_delete.append(state.allocator, idx) catch {};
                }
                std.mem.sort(usize, indices_to_delete.items, {}, std.sort.desc(usize));
                for (indices_to_delete.items) |idx| {
                    if (idx < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(idx);
                    }
                }
                state.selected_notes.clearRetainingCapacity();
                state.selected_note_index = null;
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

    // ========== RULER ==========

    // Ruler background
    draw_list.addRectFilled(.{
        .pmin = .{ grid_area_x, ruler_area_y },
        .pmax = .{ grid_area_x + grid_view_width, ruler_area_y + ruler_height },
        .col = zgui.colorConvertFloat4ToU32(ui.Colors.bg_header),
    });

    // Ruler clip rect
    draw_list.pushClipRect(.{
        .pmin = .{ grid_area_x, ruler_area_y },
        .pmax = .{ grid_area_x + grid_view_width, ruler_area_y + ruler_height },
    });

    // Draw bar/beat markers on ruler
    const ruler_last_beat = (scroll_x + grid_view_width) / pixels_per_beat;
    var ruler_beat: f32 = @floor(scroll_x / pixels_per_beat);
    while (ruler_beat <= @min(ruler_last_beat + 1, max_beats)) : (ruler_beat += 1) {
        const x = grid_area_x + ruler_beat * pixels_per_beat - scroll_x;
        const beat_int = @as(i32, @intFromFloat(ruler_beat));
        const is_bar = @mod(beat_int, ui.beats_per_bar) == 0;

        if (is_bar) {
            const bar_num = @divFloor(beat_int, ui.beats_per_bar) + 1;
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrintZ(&buf, "{d}", .{bar_num}) catch "";
            draw_list.addText(.{ x + 4, ruler_area_y + 4 }, zgui.colorConvertFloat4ToU32(ui.Colors.text_bright), "{s}", .{label});
        }

        // Tick marks
        const tick_height: f32 = if (is_bar) ruler_height * 0.6 else ruler_height * 0.3;
        draw_list.addLine(.{
            .p1 = .{ x, ruler_area_y + ruler_height - tick_height },
            .p2 = .{ x, ruler_area_y + ruler_height },
            .col = zgui.colorConvertFloat4ToU32(if (is_bar) ui.Colors.text_dim else .{ 0.3, 0.3, 0.3, 1.0 }),
            .thickness = if (is_bar) 1.5 else 1.0,
        });
    }

    draw_list.popClipRect();

    // ========== PIANO KEYS ==========
    // Safe row calculation for piano keys
    const keys_first_row_f = @max(0, @floor(scroll_y / row_height));
    const keys_last_row_f = @min(127, @ceil((scroll_y + grid_view_height) / row_height));
    const keys_first_row: usize = @intFromFloat(keys_first_row_f);
    const keys_last_row: usize = @intFromFloat(@max(keys_first_row_f, keys_last_row_f));
    const is_black_key_keys = [_]bool{ false, true, false, true, false, false, true, false, true, false, true, false };

    // Keys background
    draw_list.addRectFilled(.{
        .pmin = .{ keys_area_x, grid_area_y },
        .pmax = .{ keys_area_x + key_width, grid_area_y + grid_view_height },
        .col = zgui.colorConvertFloat4ToU32(ui.Colors.bg_dark),
    });

    draw_list.pushClipRect(.{
        .pmin = .{ keys_area_x, grid_area_y },
        .pmax = .{ keys_area_x + key_width, grid_area_y + grid_view_height },
    });

    var key_row: usize = keys_first_row;
    while (key_row <= keys_last_row) : (key_row += 1) {
        const pitch: u8 = if (key_row <= 127) @intCast(127 - key_row) else 0;
        const y = grid_area_y + @as(f32, @floatFromInt(key_row)) * row_height - scroll_y;

        if (y < grid_area_y - row_height or y > grid_area_y + grid_view_height) continue;

        const note_in_octave = pitch % 12;
        const oct = @as(i32, @intCast(pitch / 12)) - 1;

        // Key background
        const is_black = is_black_key_keys[note_in_octave];
        const key_color = if (is_black)
            zgui.colorConvertFloat4ToU32(.{ 0.08, 0.08, 0.08, 1.0 })
        else
            zgui.colorConvertFloat4ToU32(.{ 0.20, 0.20, 0.20, 1.0 });

        draw_list.addRectFilled(.{
            .pmin = .{ keys_area_x, y },
            .pmax = .{ keys_area_x + key_width - 1, y + row_height - 1 },
            .col = key_color,
        });

        // Only label C notes (octave markers)
        if (note_in_octave == 0) {
            var label_buf: [8]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "C{d}", .{oct}) catch "";
            draw_list.addText(.{ keys_area_x + 4, y + 2 }, zgui.colorConvertFloat4ToU32(ui.Colors.text_bright), "{s}", .{label});
        }
    }

    draw_list.popClipRect();

    // Top-left corner (empty space)
    draw_list.addRectFilled(.{
        .pmin = .{ keys_area_x, ruler_area_y },
        .pmax = .{ keys_area_x + key_width, ruler_area_y + ruler_height },
        .col = zgui.colorConvertFloat4ToU32(ui.Colors.bg_dark),
    });

    // Reserve space for the piano roll area
    zgui.dummy(.{ .w = total_width, .h = total_height });
}

fn pitchToNoteName(pitch: u8, buf: []u8) []const u8 {
    const note_names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const note = pitch % 12;
    const octave = @as(i32, @intCast(pitch / 12)) - 1;
    return std.fmt.bufPrint(buf, "{s}{d}", .{ note_names[note], octave }) catch "?";
}


fn quantizeIndexToBeats(index: i32) f32 {
    return switch (index) {
        0 => 0.25,
        1 => 0.5,
        2 => 1.0,
        3 => 2.0,
        4 => 4.0,
        else => 1.0,
    };
}

fn snapToStep(value: f32, step: f32) f32 {
    if (step <= 0) return value;
    return @floor(value / step) * step;
}

fn removeNoteWithSelection(clip: *PianoRollClip, selected_note_index: *?usize, index: usize) void {
    clip.removeNoteAt(index);
    if (selected_note_index.*) |selected| {
        if (selected == index) {
            selected_note_index.* = null;
        } else if (selected > index) {
            selected_note_index.* = selected - 1;
        }
    }
}
