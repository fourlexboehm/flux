const zgui = @import("zgui");
const colors = @import("../../theme/colors.zig");
const arr_timeline = @import("../../../arrangement/timeline.zig");
const arr_clip_mod = @import("../../../arrangement/clip.zig");
const sample_store_mod = @import("../../../audio/sample_store.zig");
const draw_waveform = @import("../audio_clip/draw_waveform.zig");

pub const ClipMouseResult = struct {
    action: ClipAction = .none,
    clip_index: usize = 0,
};

pub const ClipAction = enum {
    none,
    clicked,
    double_clicked,
    right_clicked,
    start_drag,
    start_resize_left,
    start_resize_right,
};

const resize_zone: f32 = 6.0;

fn clipBodyColor(clip: *const arr_clip_mod.ArrangementClip, is_selected: bool) [4]f32 {
    const base = if (clip.kind == .midi)
        colors.Colors.current.clip_stopped
    else
        colors.Colors.current.clip_audio_stopped;
    if (is_selected) return base;
    return .{
        @max(0, base[0] - 0.15),
        @max(0, base[1] - 0.15),
        @max(0, base[2] - 0.15),
        base[3],
    };
}

/// Draw a single arrangement clip. Returns hit-test result when `allow_mouse`.
pub fn drawClip(
    clip: *const arr_clip_mod.ArrangementClip,
    asset: ?*const sample_store_mod.SampleAsset,
    clip_index: usize,
    lane_left: f32,
    lane_top: f32,
    lane_height: f32,
    view_start_tick: i64,
    pixels_per_beat: f32,
    zoom: f32,
    lane_width: f32,
    track_color: [4]f32,
    is_selected: bool,
    mouse_x: f32,
    mouse_y: f32,
    allow_mouse: bool,
) ClipMouseResult {
    const draw_list = zgui.getWindowDrawList();

    const x0 = lane_left + arr_timeline.tickToPixel(clip.start_tick - view_start_tick, zoom, pixels_per_beat);
    const x1 = lane_left + arr_timeline.tickToPixel(clip.endTick() - view_start_tick, zoom, pixels_per_beat);
    const clip_h = lane_height - 4.0;
    const clip_top = lane_top + 2.0;

    if (x1 < lane_left - 1 or x0 > lane_left + lane_width + 1) return .{};

    const body_col = clipBodyColor(clip, is_selected);
    const col_u32 = zgui.colorConvertFloat4ToU32(body_col);

    draw_list.addRectFilled(.{
        .pmin = .{ x0, clip_top },
        .pmax = .{ x1, clip_top + clip_h },
        .col = col_u32,
        .rounding = 3.0,
    });

    if (is_selected) {
        draw_list.addRect(.{
            .pmin = .{ x0, clip_top },
            .pmax = .{ x1, clip_top + clip_h },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.selected),
            .rounding = 3.0,
            .thickness = 1.5,
        });
    }

    // Left color strip (track color)
    const strip_w = 4.0;
    draw_list.addRectFilled(.{
        .pmin = .{ x0, clip_top },
        .pmax = .{ x0 + strip_w, clip_top + clip_h },
        .col = zgui.colorConvertFloat4ToU32(track_color),
        .rounding = 3.0,
    });

    // Clip name
    if (x1 - x0 > 20) {
        const name = clip.name.get();
        if (name.len > 0) {
            const text_x = @max(x0 + strip_w + 4, x0 + 4);
            const clip_w = x1 - x0;
            const max_chars: usize = @intFromFloat(@max(1.0, (clip_w - 8) / 7.0));
            const display = if (name.len > max_chars) name[0..@min(name.len, max_chars)] else name;
            const text_col = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_on_fill);
            draw_list.addText(.{ text_x, clip_top + 2 }, text_col, "{s}", .{display});
        }
    }

    // Peak bins are resampled to the current pixel width every frame, so zoom
    // and tempo-driven clip geometry never require cached waveform rebuilds.
    if (clip.kind == .audio and asset != null and x1 - x0 > 20) {
        draw_waveform.drawPeaks(draw_list, .{
            .pmin = .{ @max(x0 + strip_w + 3, lane_left), clip_top + 14 },
            .pmax = .{ @min(x1 - 3, lane_left + lane_width), clip_top + clip_h - 3 },
            .peaks = asset.?.peaks[0..],
            .col = zgui.colorConvertFloat4ToU32(.{ 1, 1, 1, 0.45 }),
            .amp_frac = 0.82,
        });
    }

    if (!allow_mouse) return .{};

    const in_clip = mouse_x >= x0 and mouse_x <= x1 and mouse_y >= clip_top and mouse_y <= clip_top + clip_h;
    if (!in_clip) return .{};

    // Resize zones (edge hover)
    if (mouse_x - x0 <= resize_zone and x1 - x0 > resize_zone * 3) {
        zgui.setMouseCursor(.resize_ew);
        if (zgui.isMouseClicked(.left)) return .{ .action = .start_resize_left, .clip_index = clip_index };
        return .{};
    }
    if (x1 - mouse_x <= resize_zone and x1 - x0 > resize_zone * 3) {
        zgui.setMouseCursor(.resize_ew);
        if (zgui.isMouseClicked(.left)) return .{ .action = .start_resize_right, .clip_index = clip_index };
        return .{};
    }

    // Body
    zgui.setMouseCursor(.hand);
    if (zgui.isMouseDoubleClicked(.left)) return .{ .action = .double_clicked, .clip_index = clip_index };
    if (zgui.isMouseClicked(.right)) return .{ .action = .right_clicked, .clip_index = clip_index };
    if (zgui.isMouseClicked(.left)) return .{ .action = .clicked, .clip_index = clip_index };

    if (zgui.isMouseDragging(.left, 3.0)) {
        return .{ .action = .start_drag, .clip_index = clip_index };
    }

    return .{};
}
