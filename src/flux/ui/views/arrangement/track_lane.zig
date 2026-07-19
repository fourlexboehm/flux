const zgui = @import("zgui");
const colors = @import("../../theme/colors.zig");
const arr_types = @import("../../../arrangement/types.zig");
const arr_ops = @import("../../../arrangement/ops.zig");
const arr_timeline = @import("../../../arrangement/timeline.zig");
const draw_clip = @import("clip.zig");
const draw_grid = @import("grid.zig");
const sample_store_mod = @import("../../../audio/sample_store.zig");

pub const LaneEvent = struct {
    track: usize,
    clip_index: usize,
    action: draw_clip.ClipAction,
    clip_x0: f32,
    clip_x1: f32,
    clip_top: f32,
    clip_bottom: f32,
};

pub fn drawTrackLane(
    view: *arr_types.ArrangementView,
    sample_store: *const sample_store_mod.SampleStore,
    track_index: usize,
    lane_left: f32,
    lane_top: f32,
    lane_width: f32,
    lane_height: f32,
    pixels_per_beat: f32,
    beats_per_bar: u8,
    scroll_x: f32,
    allow_mouse: bool,
) ?LaneEvent {
    const draw_list = zgui.getWindowDrawList();
    const mouse = zgui.getMousePos();

    const view_start_tick = arr_timeline.pixelToTick(scroll_x, view.zoom, pixels_per_beat);
    const view_end_tick = arr_timeline.pixelToTick(scroll_x + lane_width, view.zoom, pixels_per_beat);

    const track = &view.tracks.items[track_index];
    const track_color = if (track.color[3] > 0) track.color else colors.Colors.trackColor(track_index);

    // Alternating lane background
    draw_list.addRectFilled(.{
        .pmin = .{ lane_left, lane_top },
        .pmax = .{ lane_left + lane_width, lane_top + lane_height },
        .col = zgui.colorConvertFloat4ToU32(if (track_index % 2 == 0)
            colors.Colors.current.bg_cell
        else
            colors.Colors.current.bg_header),
    });

    draw_grid.drawGridLines(
        draw_list,
        lane_top,
        lane_top + lane_height,
        lane_left,
        view_start_tick,
        view_end_tick,
        pixels_per_beat,
        view.zoom,
        beats_per_bar,
    );

    var event: ?LaneEvent = null;

    for (track.clips.items, 0..) |clip, ci| {
        const asset = if (clip.audio_path) |path|
            if (sample_store.path_to_id.get(path)) |sample_id| sample_store.get(sample_id) else null
        else
            null;
        const result = draw_clip.drawClip(
            &clip,
            asset,
            ci,
            lane_left,
            lane_top,
            lane_height,
            view_start_tick,
            pixels_per_beat,
            view.zoom,
            lane_width,
            track_color,
            clip.selected,
            mouse[0],
            mouse[1],
            allow_mouse,
        );

        if (result.action != .none) {
            const x0 = lane_left + arr_timeline.tickToPixel(clip.start_tick - view_start_tick, view.zoom, pixels_per_beat);
            const x1 = lane_left + arr_timeline.tickToPixel(clip.endTick() - view_start_tick, view.zoom, pixels_per_beat);
            event = .{
                .track = track_index,
                .clip_index = ci,
                .action = result.action,
                .clip_x0 = x0,
                .clip_x1 = x1,
                .clip_top = lane_top + 2.0,
                .clip_bottom = lane_top + lane_height - 2.0,
            };
        }
    }

    // Lane bottom border
    draw_list.addLine(.{
        .p1 = .{ lane_left, lane_top + lane_height - 1 },
        .p2 = .{ lane_left + lane_width, lane_top + lane_height - 1 },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.border),
        .thickness = 0.5,
    });

    zgui.dummy(.{ .w = lane_width, .h = lane_height });

    return event;
}
