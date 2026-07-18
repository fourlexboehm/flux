const std = @import("std");
const zgui = @import("zgui");
const colors = @import("../theme/colors.zig");
const session_selection = @import("../../session/selection.zig");

pub const SelectionState = session_selection.SelectionState;
pub const DragSelectState = session_selection.DragSelectState;

/// Draw selection rectangle overlay
pub fn drawDragSelect(self: *const DragSelectState, draw_list: zgui.DrawList) void {
    if (!self.active) return;

    const rect = self.getRect();
    const fill_color = zgui.colorConvertFloat4ToU32(.{
        colors.Colors.current.selected[0],
        colors.Colors.current.selected[1],
        colors.Colors.current.selected[2],
        0.2,
    });
    const border_color = zgui.colorConvertFloat4ToU32(colors.Colors.current.selected);

    draw_list.addRectFilled(.{ .pmin = rect.min, .pmax = rect.max, .col = fill_color });
    draw_list.addRect(.{ .pmin = rect.min, .pmax = rect.max, .col = border_color, .thickness = 1.0 });
}

/// Draw selection rectangle clipped to a region, with custom colors
pub fn drawDragSelectClipped(
    self: *const DragSelectState,
    draw_list: zgui.DrawList,
    clip_min: [2]f32,
    clip_max: [2]f32,
    fill: [4]f32,
    border: [4]f32,
) void {
    if (!self.active) return;

    const rect = self.getRect();
    const clipped_min = .{
        @max(rect.min[0], clip_min[0]),
        @max(rect.min[1], clip_min[1]),
    };
    const clipped_max = .{
        @min(rect.max[0], clip_max[0]),
        @min(rect.max[1], clip_max[1]),
    };

    if (clipped_max[0] > clipped_min[0] and clipped_max[1] > clipped_min[1]) {
        draw_list.addRectFilled(.{
            .pmin = clipped_min,
            .pmax = clipped_max,
            .col = zgui.colorConvertFloat4ToU32(fill),
        });
        draw_list.addRect(.{
            .pmin = clipped_min,
            .pmax = clipped_max,
            .col = zgui.colorConvertFloat4ToU32(border),
            .thickness = 1.0,
        });
    }
}

/// Helper to check if modifier key (Cmd/Ctrl) is pressed
pub fn isModifierDown() bool {
    return zgui.isKeyDown(.mod_super) or zgui.isKeyDown(.mod_ctrl) or
        zgui.isKeyDown(.left_super) or zgui.isKeyDown(.right_super) or
        zgui.isKeyDown(.left_ctrl) or zgui.isKeyDown(.right_ctrl);
}

/// Helper to check if shift is pressed
pub fn isShiftDown() bool {
    return zgui.isKeyDown(.mod_shift) or
        zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift);
}

/// Snap a value to a grid step
pub fn snapToStep(value: f32, step: f32) f32 {
    if (step <= 0) return value;
    return @floor(value / step) * step;
}

/// Sort indices in descending order for safe deletion
pub fn sortDescending(indices: []usize) void {
    std.mem.sort(usize, indices, {}, std.sort.desc(usize));
}

pub fn sliceToNull(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}
