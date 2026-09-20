//! Shared mixer value editing and metering for session and arrangement.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const tokens = @import("tokens.zig");
const gain = @import("gain.zig");

pub fn volumeEntry(src: std.builtin.SourceLocation, value: *f32, opts: dvui.Options) bool {
    // Round the display only; preserve the audio gain until the user edits it.
    var db = @round(gain.toDb(value.*) * 10) / 10;
    if (numberEntry(src, &db, gain.floor_db, gain.ceiling_db, "dB", "Volume in decibels", opts)) {
        value.* = gain.fromDb(db);
        return true;
    }
    return false;
}

pub fn panEntry(src: std.builtin.SourceLocation, value: *f32, opts: dvui.Options) bool {
    return numberEntry(src, value, -1, 1, "Pan", "Pan: -1 left, 0 centre, 1 right", opts);
}

fn numberEntry(src: std.builtin.SourceLocation, value: *f32, min: f32, max: f32, unit: []const u8, label: []const u8, opts: dvui.Options) bool {
    var row = dvui.box(src, .{ .dir = .horizontal }, opts);
    defer row.deinit();
    var edited = value.*;
    const result = dvui.textEntryNumber(@src(), f32, .{
        .value = &edited,
        .min = min,
        .max = max,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 28, .h = tokens.control_h },
        .padding = .{ .x = 4, .w = 4 },
        .label = .{ .text = label },
        .color_fill = theme.panel,
        .color_border = theme.grid,
    });
    dvui.label(@src(), "{s}", .{unit}, .{
        .gravity_y = 0.5,
        .color_text = theme.text_dim,
        .padding = .{},
        .margin = .{ .x = 4 },
    });
    if (!result.changed or !std.math.isFinite(edited)) return false;
    value.* = edited;
    return true;
}

pub fn fader(src: std.builtin.SourceLocation, value: *f32, levels: [2]f32, id: usize) bool {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .gravity_x = 0.5,
        .margin = .{ .y = 6, .h = 4 },
        .id_extra = id,
    });
    defer row.deinit();
    var fraction = gain.fraction(value.*);
    const changed = dvui.slider(@src(), .{ .fraction = &fraction, .dir = .vertical }, .{
        .min_size_content = .{ .w = 18, .h = 76 },
        .label = .{ .text = "Volume fader" },
        .color_fill = theme.cell,
        .color_border = theme.border_light,
    });
    if (changed) value.* = gain.fromFraction(fraction);
    meter(levels);
    return changed;
}

fn meter(levels: [2]f32) void {
    var box = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 10, .h = 76 },
        .margin = .{ .x = 8 },
        .background = true,
        .color_fill = theme.bg,
    });
    defer box.deinit();
    const rs = box.data().contentRectScale();
    for (levels, 0..) |level, i| {
        const amount = @max(0, @min(1, (gain.toDb(level) + 60) / 60));
        const r: dvui.Rect.Physical = .{
            .x = rs.r.x + @as(f32, @floatFromInt(i)) * 6 * rs.s,
            .y = rs.r.y + rs.r.h * (1 - amount),
            .w = 4 * rs.s,
            .h = rs.r.h * amount,
        };
        r.fill(.all(0), .{ .color = if (level >= 1) theme.danger else if (level > 0.7) theme.clip_queued else theme.play });
    }
}
