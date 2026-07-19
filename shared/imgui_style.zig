const std = @import("std");
const zgui = @import("zgui");

// Inter's x-height runs slightly smaller than Roboto's; 17px keeps parity.
const base_font_px: f32 = 17.0;

pub fn applyScaleFromMemory(font: []const u8, scale: f32) void {
    _ = zgui.io.addFontFromMemory(font, std.math.floor(base_font_px * scale));
    zgui.getStyle().scaleAllSizes(scale);
}

pub fn applyFontFromMemory(font: []const u8, scale: f32) void {
    _ = zgui.io.addFontFromMemory(font, std.math.floor(base_font_px * scale));
}

pub fn applyScaleFromFile(path: [:0]const u8, scale: f32) void {
    _ = zgui.io.addFontFromFile(path, std.math.floor(base_font_px * scale));
    if (scale != 1.0) {
        zgui.getStyle().scaleAllSizes(scale);
    }
}
