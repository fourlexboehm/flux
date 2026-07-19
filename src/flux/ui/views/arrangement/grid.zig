const zgui = @import("zgui");
const colors = @import("../../theme/colors.zig");
const arr_timeline = @import("../../../arrangement/timeline.zig");
const arr_types = @import("../../../arrangement/types.zig");

fn gridTickFrequency(zoom: f32) struct { major: i64, minor: i64 } {
    const base_tick = arr_timeline.ppq;
    // zoom 1.0 = 1 bar (~240px) — show bar & beat
    // zoom 0.5 = 2 bars    — bar & beat
    // zoom 2.0 = half bar  — beat & 16th
    if (zoom < 0.35) return .{ .major = base_tick * 4, .minor = base_tick * 4 };
    if (zoom < 0.7) return .{ .major = base_tick * 4, .minor = base_tick };
    if (zoom < 1.3) return .{ .major = base_tick * 4, .minor = base_tick / 2 };
    return .{ .major = base_tick, .minor = base_tick / 4 };
}

pub fn drawGridLines(
    draw_list: zgui.DrawList,
    lane_top: f32,
    lane_bottom: f32,
    lane_left: f32,
    view_start_tick: i64,
    view_end_tick: i64,
    pixels_per_beat: f32,
    zoom: f32,
    beats_per_bar: u8,
) void {
    const freq = gridTickFrequency(zoom);
    const bar_ticks = arr_timeline.ppq * @as(i64, @intCast(beats_per_bar));

    var tick: i64 = @divFloor(view_start_tick, freq.major) * freq.major;
    while (tick <= view_end_tick) : (tick += freq.major) {
        const x = lane_left + arr_timeline.tickToPixel(tick - view_start_tick, zoom, pixels_per_beat);
        const c = if (tick > 0 and @mod(tick, bar_ticks) == 0) colors.Colors.current.grid_line_bar else colors.Colors.current.grid_line_beat;
        draw_list.addLine(.{
            .p1 = .{ x, lane_top },
            .p2 = .{ x, lane_bottom },
            .col = zgui.colorConvertFloat4ToU32(c),
            .thickness = 0.5,
        });
    }

    tick = @divFloor(view_start_tick, freq.minor) * freq.minor;
    while (tick <= view_end_tick) : (tick += freq.minor) {
        if (@mod(tick, freq.major) == 0) continue;
        const x = lane_left + arr_timeline.tickToPixel(tick - view_start_tick, zoom, pixels_per_beat);
        draw_list.addLine(.{
            .p1 = .{ x, lane_top },
            .p2 = .{ x, lane_bottom },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_line_16th),
            .thickness = 0.5,
        });
    }
}
