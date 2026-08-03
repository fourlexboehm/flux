//! Legacy zgui piano-roll sequencer canvas.
//! Split: automation.zig, edit.zig, chrome.zig, ops.zig
const zgui = @import("zgui");
const colors = @import("../../theme/colors.zig");
const widgets = @import("../../theme/widgets.zig");
const selection = @import("../../input/selection.zig");
const edit_actions = @import("../../input/edit_actions.zig");
const std = @import("std");
const clap = @import("clap-bindings");

const types = @import("../../../session/notes.zig");
const ops = @import("ops.zig");
const PianoRollState = types.PianoRollState;
const PianoRollClip = types.PianoRollClip;
const AutomationPoint = types.AutomationPoint;
const AutomationLane = types.AutomationLane;
const AutomationTargetKind = types.AutomationTargetKind;
const quantizeIndexToBeats = types.quantizeIndexToBeats;

const automation = @import("automation.zig");
const edit = @import("edit.zig");
const chrome = @import("chrome.zig");

const is_black_key = [_]bool{ false, true, false, true, false, false, true, false, true, false, true, false };

fn mouseToBeat(mouse_x: f32, grid_x: f32, scroll_x: f32, pixels_per_beat: f32) f32 {
    return (mouse_x - grid_x + scroll_x) / pixels_per_beat;
}

fn mouseToRow(mouse_y: f32, grid_y: f32, scroll_y: f32, row_height: f32) f32 {
    return (mouse_y - grid_y + scroll_y) / row_height;
}

fn beatToScreenX(beat: f32, grid_x: f32, scroll_x: f32, pixels_per_beat: f32) f32 {
    return grid_x + beat * pixels_per_beat - scroll_x;
}

/// Gold loop brace + green playStart punch-in (same visual language as the audio viewer).
fn rowToPitch(row: f32) i32 {
    return std.math.clamp(127 - @as(i32, @intFromFloat(row)), 0, 127);
}

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
    quantize_index: *i32,
    beats_per_bar_in: f32,
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
    const quantize_beats = quantizeIndexToBeats(quantize_index.*);

    const pixels_per_beat = 60.0 / state.beats_per_pixel;
    state.row_height_scale = std.math.clamp(state.row_height_scale, 0.4, 3.0);
    const row_height = 20.0 * ui_scale * state.row_height_scale;
    state.hover_pitch = null;

    const mouse = zgui.getMousePos();
    const mouse_down = zgui.isMouseDown(.left);

    // Header
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_bright });
    zgui.text("{s}", .{clip_label});
    zgui.popStyleColor(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = 20.0 * ui_scale });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
    zgui.text("{d:.2} bars", .{clip.length_beats / beats_per_bar_in});
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
    chrome.drawScrollZoomBar(state, pixels_per_beat, key_width, ui_scale);

    zgui.spacing();
    chrome.drawClipTools(state, clip, track_index, scene_index, min_note_duration, ui_scale);
    zgui.spacing();

    automation.drawAutomationHeader(state, clip, ui_scale, instrument_plugin, fx_plugins);
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
        const bar_16ths: i32 = @intFromFloat(beats_per_bar_in * 4.0);
        const is_bar = @mod(beat_16th, bar_16ths) == 0;
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

    // Punch-in (playStart) + loop brace (loopStart/loopEnd) — match audio viewer markers.
    chrome.drawClipRegionMarkers(
        draw_list,
        clip,
        grid_window_pos,
        grid_view_width,
        grid_view_height,
        state.scroll_x,
        pixels_per_beat,
        ui_scale,
    );

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

        // Note name label when wide/tall enough
        if (row_height >= 12.0 and note_w > 28.0 * ui_scale) {
            var name_buf: [8]u8 = undefined;
            const name = types.pitchToName(&name_buf, note.pitch);
            const text_col = if (note.velocity > 0.4)
                zgui.colorConvertFloat4ToU32(.{ 0, 0, 0, 0.9 })
            else
                zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright);
            const font_sz = @min(zgui.getFontSize(), row_height - 2.0);
            if (font_sz >= 8.0) {
                draw_list.addTextExtended(
                    .{ note_x + 3, note_y + (row_height - font_sz) * 0.5 },
                    text_col,
                    "{s}",
                    .{name},
                    .{ .font = null, .font_size = font_sz },
                );
            }
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

            // Double-click note → delete
            if (!popup_open and zgui.isMouseDoubleClicked(.left)) {
                const del = [_]usize{note_idx};
                ops.deleteNotesAtIndices(state, clip, track_index, scene_index, &del);
                left_click_note = true;
                break;
            }

            if (!popup_open and zgui.isMouseClicked(.left)) {
                const grab_beat = mouseToBeat(mouse[0], grid_window_pos[0], state.scroll_x, pixels_per_beat);
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
                    state.captureDragNotes(clip);
                    state.drag = .{
                        .mode = if (over_handle) .resize_right else .move,
                        .note_index = note_idx,
                        .grab_offset_beats = grab_beat - note.start,
                        .original_start = note.start,
                        .original_pitch = note.pitch,
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
        automation.drawAutomationOverlay(
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
        var edit_ctx = edit.EditCtx{
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
            .copy = edit.editCopy,
            .cut = edit.editCut,
            .paste = edit.editPaste,
            .delete = edit.editDelete,
            .select_all = edit.editSelectAll,
        });

        // Arrow key handling
        if (state.drag.mode == .none and state.hasSelection()) {
            edit.handleArrowKeys(state, clip, shift_down, quantize_beats, min_note_duration, track_index, scene_index);
        }

        // Duplicate (Cmd/Ctrl+D)
        if (state.drag.mode == .none and state.hasSelection() and modifier_down and zgui.isKeyPressed(.d, false)) {
            ops.duplicateSelected(state, clip, track_index, scene_index, true);
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

    const wheel_y = fluxZguiGetMouseWheelY();
    const ui_hovered = zgui.isAnyItemHovered() or zgui.isAnyItemActive();
    if ((keys_hovered or in_grid) and wheel_y != 0 and !ui_hovered) {
        const ctrl = selection.isModifierDown();
        const alt = zgui.isKeyDown(.left_alt) or zgui.isKeyDown(.right_alt);
        if (ctrl and !alt) {
            // Horizontal zoom toward mouse X
            const mouse_beat = mouseToBeat(mouse[0], grid_window_pos[0], state.scroll_x, pixels_per_beat);
            const h_factor: f32 = if (wheel_y > 0) @as(f32, 0.9) else @as(f32, 1.1);
            state.beats_per_pixel = std.math.clamp(state.beats_per_pixel * h_factor, 0.005, 1.0);
            const new_ppb = 60.0 / state.beats_per_pixel;
            const mouse_local_x = mouse[0] - grid_window_pos[0];
            state.scroll_x = mouse_beat * new_ppb - mouse_local_x;
        } else if (alt) {
            // Vertical zoom toward mouse Y
            const mouse_row = mouseToRow(mouse[1], grid_window_pos[1], state.scroll_y, row_height);
            const v_factor: f32 = if (wheel_y > 0) @as(f32, 1.1) else @as(f32, 0.9);
            state.row_height_scale = std.math.clamp(state.row_height_scale * v_factor, 0.4, 3.0);
            const new_rh = 20.0 * ui_scale * state.row_height_scale;
            const mouse_local_y = mouse[1] - grid_window_pos[1];
            state.scroll_y = mouse_row * new_rh - mouse_local_y;
        } else {
            const scroll_step = row_height * 3.0;
            state.scroll_y = std.math.clamp(state.scroll_y - wheel_y * scroll_step, 0, max_scroll_y);
        }
    }

    // Hover pitch for key labels (grid or keys)
    if (in_grid or keys_hovered) {
        const row_f = mouseToRow(mouse[1], grid_window_pos[1], state.scroll_y, row_height);
        const pitch_i = rowToPitch(row_f);
        if (pitch_i >= 0 and pitch_i < 128) state.hover_pitch = @intCast(pitch_i);
    }

    // Middle mouse pan (Shift = 4× boost)
    if (in_grid and zgui.isMouseDragging(.middle, -1.0)) {
        const delta = zgui.getMouseDragDelta(.middle, .{});
        const boost: f32 = if (selection.isShiftDown()) 4.0 else 1.0;
        state.scroll_x = std.math.clamp(state.scroll_x - delta[0] * boost, 0, max_scroll_x);
        state.scroll_y = std.math.clamp(state.scroll_y - delta[1] * boost, 0, max_scroll_y);
        zgui.resetMouseDragDelta(.middle);
    }

    // Right-click context menu
    if (!automation_mode and in_grid and zgui.isMouseClicked(.right) and state.drag.mode == .none) {
        const click_beat = mouseToBeat(mouse[0], grid_window_pos[0], state.scroll_x, pixels_per_beat);
        const click_pitch_i = rowToPitch(mouseToRow(mouse[1], grid_window_pos[1], state.scroll_y, row_height));

        state.context_note_index = right_click_note_index;
        state.context_start = selection.snapToStep(click_beat, quantize_beats);
        state.context_pitch = @intCast(click_pitch_i);
        state.context_in_grid = true;
        zgui.openPopup("piano_roll_ctx", .{});
    }

    const menu_action = chrome.drawContextMenu(state, clip, min_note_duration, track_index, scene_index, quantize_beats, quantize_index);
    const popup_active = popup_open or zgui.isPopupOpen("piano_roll_ctx", .{});

    // Double-click to create note
    if (!popup_active and !menu_action and !automation_mode and in_grid and zgui.isMouseDoubleClicked(.left) and state.drag.mode == .none and !left_click_note) {
        const click_beat = mouseToBeat(mouse[0], grid_window_pos[0], state.scroll_x, pixels_per_beat);
        const click_pitch_i = rowToPitch(mouseToRow(mouse[1], grid_window_pos[1], state.scroll_y, row_height));

        if (click_beat >= 0 and click_beat < clip.length_beats and click_pitch_i >= 0 and click_pitch_i < 128) {
            const click_pitch: u8 = @intCast(click_pitch_i);
            const snapped_start = selection.snapToStep(click_beat, quantize_beats);
            const max_duration = clip.length_beats - snapped_start;
            const note_duration = @min(quantize_beats, max_duration);

            if (note_duration >= min_note_duration) {
                state.captureDragNotes(clip);
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
                    if (state.drag.note_index < clip.notes.items.len) {
                        const one = [_]usize{state.drag.note_index};
                        ops.resolveOverlaps(clip, &one);
                        ops.commitReplace(state, clip, track_index, scene_index, state.takeDragNotes());
                    }
                },
                .move => {
                    if (state.drag.note_index < clip.notes.items.len) {
                        const note = clip.notes.items[state.drag.note_index];
                        if (note.start != state.drag.drag_start_start or note.pitch != state.drag.drag_start_pitch) {
                            var sel_buf: [256]usize = undefined;
                            var sel_n: usize = 0;
                            for (state.note_selection.keys()) |idx| {
                                if (sel_n < sel_buf.len) {
                                    sel_buf[sel_n] = idx;
                                    sel_n += 1;
                                }
                            }
                            if (sel_n > 0) ops.resolveOverlaps(clip, sel_buf[0..sel_n]);
                            ops.commitReplace(state, clip, track_index, scene_index, state.takeDragNotes());
                        } else {
                            const old = state.takeDragNotes();
                            if (old.len > 0) state.allocator.free(old);
                        }
                    }
                },
                .resize_right => {
                    if (state.drag.note_index < clip.notes.items.len) {
                        const note = clip.notes.items[state.drag.note_index];
                        if (note.duration != state.drag.drag_start_duration) {
                            const one = [_]usize{state.drag.note_index};
                            ops.resolveOverlaps(clip, &one);
                            ops.commitReplace(state, clip, track_index, scene_index, state.takeDragNotes());
                        } else {
                            const old = state.takeDragNotes();
                            if (old.len > 0) state.allocator.free(old);
                        }
                    }
                },
                .select_rect => {
                    edit.finalizeRectSelection(state, clip, grid_window_pos, pixels_per_beat, row_height, state.scroll_x, state.scroll_y);
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
            edit.handleDrag(state, clip, mouse, grid_window_pos, pixels_per_beat, row_height, min_note_duration, beats_per_bar_in);
            if ((state.drag.mode == .move or state.drag.mode == .create) and state.drag.note_index < clip.notes.items.len) {
                state.preview_pitch = clip.notes.items[state.drag.note_index].pitch;
                state.preview_track = track_index;
            }
        }
    }

    // Draw selection rectangle
    if (state.drag.mode == .select_rect) {
        selection.drawDragSelectClipped(&state.drag_select, 
            draw_list,
            grid_window_pos,
            .{ grid_window_pos[0] + grid_view_width, grid_window_pos[1] + grid_view_height },
            colors.Colors.current.selection_rect,
            colors.Colors.current.selection_rect_border,
        );
    }

    // Draw ruler
    chrome.drawRuler(draw_list, grid_area_x, base_pos[1], grid_view_width, ruler_height, state.scroll_x, pixels_per_beat, max_beats, ui_scale, beats_per_bar_in);

    // Draw piano keys
    chrome.drawPianoKeys(
        draw_list,
        base_pos[0],
        grid_area_y,
        key_width,
        grid_view_height,
        state.scroll_y,
        row_height,
        ui_scale,
        live_key_states,
        state.hover_pitch,
    );

    // Top-left corner
    draw_list.addRectFilled(.{
        .pmin = .{ base_pos[0], base_pos[1] },
        .pmax = .{ base_pos[0] + key_width, base_pos[1] + ruler_height },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.bg_header),
    });

    zgui.dummy(.{ .w = total_width, .h = total_height });
}

