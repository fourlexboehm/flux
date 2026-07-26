const std = @import("std");
const zgui = @import("zgui");
const colors = @import("../../theme/colors.zig");
const arr_timeline = @import("../../../arrangement/timeline.zig");

pub fn drawRuler(
    scroll_x: f32,
    ruler_height: f32,
    ruler_width: f32,
    pixels_per_beat: f32,
    zoom: f32,
    _: f32,
    beats_per_bar: u8,
    _: f32,
    _: i64,
) void {
    const draw_list = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    draw_list.pushClipRect(.{
        .pmin = pos,
        .pmax = .{ pos[0] + ruler_width, pos[1] + ruler_height },
    });
    defer draw_list.popClipRect();

    draw_list.addRectFilled(.{
        .pmin = pos,
        .pmax = .{ pos[0] + ruler_width, pos[1] + ruler_height },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.bg_header),
    });

    const ticks_per_bar: i64 = arr_timeline.ppq * @as(i64, @intCast(beats_per_bar));
    const view_start = arr_timeline.pixelToTick(scroll_x, zoom, pixels_per_beat);
    const view_end = arr_timeline.pixelToTick(scroll_x + ruler_width, zoom, pixels_per_beat);

    const label_every_n_bars: i64 = if (zoom < 0.25) 8 else if (zoom < 0.5) 4 else if (zoom < 1.0) 2 else 1;

    var bar: i64 = @divFloor(view_start, ticks_per_bar);
    while (bar * ticks_per_bar <= view_end) : (bar += label_every_n_bars) {
        const tick: i64 = bar * ticks_per_bar;
        const x = pos[0] + arr_timeline.tickToPixel(tick - view_start, zoom, pixels_per_beat);
        if (x > pos[0] + ruler_width) break;

        const mt = arr_timeline.ticksToMusicalTime(tick, beats_per_bar);
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ mt.bars + 1, mt.beat + 1, @divTrunc(mt.ticks, 40) }) catch "";

        draw_list.addText(.{ x + 3, pos[1] + 2 }, zgui.colorConvertFloat4ToU32(colors.Colors.current.ruler_tick), "{s}", .{label});
        draw_list.addLine(.{
            .p1 = .{ x, pos[1] + ruler_height * 0.6 },
            .p2 = .{ x, pos[1] + ruler_height },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.border),
            .thickness = 1.0,
        });
    }

    if (zoom >= 0.5) {
        var tick: i64 = @divFloor(view_start, arr_timeline.ppq);
        while (tick <= view_end) : (tick += arr_timeline.ppq) {
            if (@mod(tick, ticks_per_bar) == 0) continue;
            const x = pos[0] + arr_timeline.tickToPixel(tick - view_start, zoom, pixels_per_beat);
            draw_list.addLine(.{
                .p1 = .{ x, pos[1] + ruler_height * 0.75 },
                .p2 = .{ x, pos[1] + ruler_height },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.grid_line_beat),
                .thickness = 0.5,
            });
        }
    }

    draw_list.addLine(.{
        .p1 = .{ pos[0], pos[1] + ruler_height - 1 },
        .p2 = .{ pos[0] + ruler_width, pos[1] + ruler_height - 1 },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.border),
        .thickness = 1.0,
    });

    zgui.dummy(.{ .w = ruler_width, .h = ruler_height });
}
