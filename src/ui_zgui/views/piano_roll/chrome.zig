//! Piano-roll chrome: region markers, scroll/zoom bar, tools, ruler, keys (legacy zgui).
const zgui = @import("zgui");
const colors = @import("../../theme/colors.zig");
const widgets = @import("../../theme/widgets.zig");
const selection = @import("../../input/selection.zig");
const edit_actions = @import("../../input/edit_actions.zig");
const std = @import("std");
const clap = @import("clap-bindings");

const types = @import("../../../session/notes.zig");
const ops = @import("ops.zig");
const edit = @import("edit.zig");
const PianoRollState = types.PianoRollState;
const PianoRollClip = types.PianoRollClip;
const AutomationPoint = types.AutomationPoint;
const AutomationLane = types.AutomationLane;
const AutomationTargetKind = types.AutomationTargetKind;
const quantizeIndexToBeats = types.quantizeIndexToBeats;

const is_black_key = [_]bool{ false, true, false, true, false, false, true, false, true, false, true, false };

pub fn mouseToBeat(mouse_x: f32, grid_x: f32, scroll_x: f32, pixels_per_beat: f32) f32 {
    return (mouse_x - grid_x + scroll_x) / pixels_per_beat;
}

pub fn mouseToRow(mouse_y: f32, grid_y: f32, scroll_y: f32, row_height: f32) f32 {
    return (mouse_y - grid_y + scroll_y) / row_height;
}

pub fn beatToScreenX(beat: f32, grid_x: f32, scroll_x: f32, pixels_per_beat: f32) f32 {
    return grid_x + beat * pixels_per_beat - scroll_x;
}

/// Gold loop brace + green playStart punch-in (same visual language as the audio viewer).
pub fn drawClipRegionMarkers(
    draw_list: zgui.DrawList,
    clip: *const PianoRollClip,
    grid_pos: [2]f32,
    view_w: f32,
    view_h: f32,
    scroll_x: f32,
    pixels_per_beat: f32,
    ui_scale: f32,
) void {
    const length = clip.length_beats;
    if (length <= 0.001) return;

    const x_min = grid_pos[0];
    const x_max = grid_pos[0] + view_w;
    const y0 = grid_pos[1];
    const y1 = grid_pos[1] + view_h;
    const loop_col = zgui.colorConvertFloat4ToU32(.{ 0.95, 0.78, 0.28, 0.75 });
    const play_col = zgui.colorConvertFloat4ToU32(colors.Colors.current.transport_play);
    const dim_col = zgui.colorConvertFloat4ToU32(.{ 0.0, 0.0, 0.0, 0.22 });
    const tri = 6.0 * ui_scale;
    const line_th = 1.5 * ui_scale;

    const loop_start = clip.loop_start_beats;
    const loop_end = clip.loopEnd();
    const play_start = clip.play_start_beats;
    const has_sub_loop = (loop_start > 0.001) or (loop_end < length - 0.001);

    // Dim content outside the loop brace (within clip bounds).
    if (has_sub_loop) {
        if (loop_start > 0.001) {
            const x0 = beatToScreenX(0, x_min, scroll_x, pixels_per_beat);
            const x1 = beatToScreenX(loop_start, x_min, scroll_x, pixels_per_beat);
            const left = @max(x0, x_min);
            const right = @min(x1, x_max);
            if (right > left) {
                draw_list.addRectFilled(.{ .pmin = .{ left, y0 }, .pmax = .{ right, y1 }, .col = dim_col });
            }
        }
        if (loop_end < length - 0.001) {
            const x0 = beatToScreenX(loop_end, x_min, scroll_x, pixels_per_beat);
            const x1 = beatToScreenX(length, x_min, scroll_x, pixels_per_beat);
            const left = @max(x0, x_min);
            const right = @min(x1, x_max);
            if (right > left) {
                draw_list.addRectFilled(.{ .pmin = .{ left, y0 }, .pmax = .{ right, y1 }, .col = dim_col });
            }
        }
    }

    const drawMarkerLine = struct {
        fn go(dl: zgui.DrawList, x: f32, ymin: f32, ymax: f32, xmin: f32, xmax: f32, col: u32, thickness: f32) void {
            if (x < xmin - 1 or x > xmax + 1) return;
            dl.addLine(.{ .p1 = .{ x, ymin }, .p2 = .{ x, ymax }, .col = col, .thickness = thickness });
        }
    }.go;

    const drawTopFlag = struct {
        fn go(dl: zgui.DrawList, x: f32, ymin: f32, xmin: f32, xmax: f32, col: u32, half: f32) void {
            if (x < xmin - 1 or x > xmax + 1) return;
            dl.addTriangleFilled(.{
                .p1 = .{ x - half, ymin },
                .p2 = .{ x + half, ymin },
                .p3 = .{ x, ymin + half * 1.4 },
                .col = col,
            });
        }
    }.go;

    if (has_sub_loop) {
        if (loop_start > 0.001) {
            const lx = beatToScreenX(loop_start, x_min, scroll_x, pixels_per_beat);
            drawMarkerLine(draw_list, lx, y0, y1, x_min, x_max, loop_col, line_th);
            // Left brace tick at top
            if (lx >= x_min and lx <= x_max) {
                draw_list.addLine(.{
                    .p1 = .{ lx, y0 },
                    .p2 = .{ lx + tri, y0 },
                    .col = loop_col,
                    .thickness = line_th,
                });
            }
        }
        if (loop_end > 0.001 and loop_end < length - 0.001) {
            const lx = beatToScreenX(loop_end, x_min, scroll_x, pixels_per_beat);
            drawMarkerLine(draw_list, lx, y0, y1, x_min, x_max, loop_col, line_th);
            if (lx >= x_min and lx <= x_max) {
                draw_list.addLine(.{
                    .p1 = .{ lx - tri, y0 },
                    .p2 = .{ lx, y0 },
                    .col = loop_col,
                    .thickness = line_th,
                });
            }
        }
    }

    // Punch-in (playStart): only when offset from clip start.
    if (play_start > 0.001 and play_start < length - 0.001) {
        const px = beatToScreenX(play_start, x_min, scroll_x, pixels_per_beat);
        drawMarkerLine(draw_list, px, y0, y1, x_min, x_max, play_col, line_th);
        drawTopFlag(draw_list, px, y0, x_min, x_max, play_col, tri);
    }
}

pub fn drawScrollZoomBar(state: *PianoRollState, pixels_per_beat: f32, key_width: f32, ui_scale: f32) void {
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

pub fn drawContextMenu(
    state: *PianoRollState,
    clip: *PianoRollClip,
    min_duration: f32,
    track_index: usize,
    scene_index: usize,
    quantize_beats: f32,
    quantize_index: *i32,
) bool {
    if (zgui.beginPopup("piano_roll_ctx", .{})) {
        var menu_ctx = edit.MenuCtx{
            .state = state,
            .clip = clip,
            .track_index = track_index,
            .scene_index = scene_index,
            .min_note_duration = min_duration,
        };
        var action_triggered = edit_actions.drawMenu(&menu_ctx, .{
            .has_selection = state.hasSelection(),
            .can_paste = state.clipboard.items.len > 0 and state.context_in_grid,
        }, .{
            .copy = edit.menuCopy,
            .cut = edit.menuCut,
            .paste = edit.menuPaste,
            .delete = edit.menuDelete,
            .select_all = edit.menuSelectAll,
        });

        zgui.separator();
        if (zgui.menuItem("Duplicate", .{ .shortcut = "Cmd/Ctrl+D", .enabled = state.hasSelection() })) {
            ops.duplicateSelected(state, clip, track_index, scene_index, true);
            action_triggered = true;
        }
        zgui.separator();
        if (zgui.menuItem("Quantize", .{ .enabled = state.hasSelection() })) {
            edit.quantizeSelectedNotes(state, clip, quantize_beats, track_index, scene_index);
            action_triggered = true;
        }
        if (zgui.beginMenu("Grid", true)) {
            for (types.quantize_labels, 0..) |label, i| {
                const idx: i32 = @intCast(i);
                var label_z: [16]u8 = undefined;
                const z = std.fmt.bufPrintSentinel(&label_z, "{s}", .{label}, 0) catch continue;
                if (zgui.menuItem(z, .{ .selected = quantize_index.* == idx })) {
                    quantize_index.* = idx;
                    action_triggered = true;
                }
            }
            zgui.endMenu();
        }

        zgui.endPopup();
        return action_triggered;
    }
    return false;
}

pub fn drawClipTools(
    state: *PianoRollState,
    clip: *PianoRollClip,
    track_index: usize,
    scene_index: usize,
    min_duration: f32,
    ui_scale: f32,
) void {
    // Match adjacent sliders and the active theme instead of guessing a pixel height.
    const btn_h = zgui.getFrameHeight();
    const spacing = 4.0 * ui_scale;

    if (zgui.button("÷2", .{ .w = clipToolButtonWidth("÷2", ui_scale), .h = btn_h })) {
        ops.scaleClipTime(state, clip, track_index, scene_index, 0.5);
    }
    widgets.itemTooltip("Halve note times and clip length");
    zgui.sameLine(.{ .spacing = spacing });
    if (zgui.button("×2", .{ .w = clipToolButtonWidth("×2", ui_scale), .h = btn_h })) {
        ops.scaleClipTime(state, clip, track_index, scene_index, 2.0);
    }
    widgets.itemTooltip("Double note times and clip length");
    zgui.sameLine(.{ .spacing = spacing });
    if (zgui.button("Reverse", .{ .w = clipToolButtonWidth("Reverse", ui_scale), .h = btn_h })) {
        ops.reverseNotes(state, clip, track_index, scene_index);
    }
    zgui.sameLine(.{ .spacing = spacing });
    if (zgui.button("Invert", .{ .w = clipToolButtonWidth("Invert", ui_scale), .h = btn_h })) {
        ops.invertPitches(state, clip, track_index, scene_index);
    }
    widgets.itemTooltip("Mirror pitches around selection range");
    zgui.sameLine(.{ .spacing = spacing });
    if (zgui.button("Legato", .{ .w = clipToolButtonWidth("Legato", ui_scale), .h = btn_h })) {
        ops.legatoNotes(state, clip, track_index, scene_index, min_duration);
    }
    widgets.itemTooltip("Extend each note to the next note start");
    zgui.sameLine(.{ .spacing = spacing });
    if (zgui.button("Duplicate", .{ .w = clipToolButtonWidth("Duplicate", ui_scale), .h = btn_h })) {
        ops.duplicateSelected(state, clip, track_index, scene_index, true);
    }
    zgui.sameLine(.{ .spacing = spacing * 2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
    zgui.alignTextToFramePadding();
    zgui.textUnformatted("Vel ±");
    zgui.popStyleColor(.{ .count = 1 });
    zgui.sameLine(.{ .spacing = spacing });
    zgui.setNextItemWidth(70 * ui_scale);
    _ = zgui.sliderFloat("##vel_range", .{
        .v = &state.velocity_range,
        .min = -1.0,
        .max = 1.0,
        .cfmt = "%.2f",
    });
    zgui.sameLine(.{ .spacing = spacing });
    if (zgui.button("Humanize", .{ .w = clipToolButtonWidth("Humanize", ui_scale), .h = btn_h })) {
        ops.humanizeVelocity(state, clip, track_index, scene_index, state.velocity_range);
    }
    widgets.itemTooltip("Randomize velocity by Vel ± amount (selected or all)");
}

fn clipToolButtonWidth(label: []const u8, ui_scale: f32) f32 {
    const padding = zgui.getStyle().frame_padding[0] * 2.0;
    return zgui.calcTextSize(label, .{})[0] + padding + 8.0 * ui_scale;
}

pub fn drawRuler(
    draw_list: zgui.DrawList,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    scroll_x: f32,
    pixels_per_beat: f32,
    max_beats: f32,
    ui_scale: f32,
    beats_per_bar_in: f32,
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
        const bar_index = @round(beat / beats_per_bar_in);
        const is_bar = @abs(beat - bar_index * beats_per_bar_in) < 0.001;

        if (is_bar and label_font_size >= 6.0) {
            const bar_num: i32 = @intFromFloat(bar_index + 1);
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrintSentinel(&buf, "{d}", .{bar_num}, 0) catch "";
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

pub fn drawPianoKeys(
    draw_list: zgui.DrawList,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    scroll_y: f32,
    row_height: f32,
    ui_scale: f32,
    live_key_states: *const [128]bool,
    hover_pitch: ?u8,
) void {
    const font_size = zgui.getFontSize();
    const max_label_size = row_height - 2.0 * ui_scale;
    const label_font_size = @min(font_size, @max(0.0, max_label_size));

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

        const show_label = (note_in_octave == 0 or (hover_pitch != null and hover_pitch.? == pitch)) and label_font_size >= 6.0;
        if (show_label) {
            var buf: [12]u8 = undefined;
            const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
            const label = std.fmt.bufPrintSentinel(&buf, "{s}{d}", .{ names[pitch % 12], oct }, 0) catch "";
            const text_y = ky + (row_height - label_font_size) / 2.0;
            draw_list.addTextExtended(
                .{ x + 6, text_y },
                zgui.colorConvertFloat4ToU32(if (is_black) colors.Colors.current.text_bright else colors.Colors.current.text_dim),
                "{s}",
                .{label},
                .{ .font = null, .font_size = label_font_size },
            );
        }
    }

    draw_list.popClipRect();
}
