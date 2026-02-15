const std = @import("std");
const zgui = @import("zgui");

pub fn applyScaleFromMemory(font: []const u8, scale: f32) void {
    _ = zgui.io.addFontFromMemory(font, std.math.floor(16.0 * scale));
    zgui.getStyle().scaleAllSizes(scale);
}

pub fn applyFontFromMemory(font: []const u8, scale: f32) void {
    _ = zgui.io.addFontFromMemory(font, std.math.floor(16.0 * scale));
}

pub fn applyScaleFromFile(path: [:0]const u8, scale: f32) void {
    _ = zgui.io.addFontFromFile(path, std.math.floor(16.0 * scale));
    if (scale != 1.0) {
        zgui.getStyle().scaleAllSizes(scale);
    }
}
