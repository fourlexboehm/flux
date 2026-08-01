//! Vector icons for chrome (Entypo TVG via DVUI — no font glyphs).
//! Play/stop/record match zgui's drawn symbols without unicode tofu.

const std = @import("std");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const theme = @import("theme.zig");
const tokens = @import("tokens.zig");

pub const IconKind = enum {
    play,
    stop,
    pause,
    record,
    plus,
    chevron_right,
    browser,
    metronome,
};

pub fn tvg(kind: IconKind) []const u8 {
    return switch (kind) {
        .play => entypo.controller_play,
        .stop => entypo.controller_stop,
        .pause => entypo.controller_pause,
        .record => entypo.controller_record,
        .plus => entypo.plus,
        .chevron_right => entypo.chevron_small_right,
        .browser => entypo.folder,
        .metronome => entypo.clock,
    };
}

pub fn name(kind: IconKind) []const u8 {
    return switch (kind) {
        .play => "play",
        .stop => "stop",
        .pause => "pause",
        .record => "record",
        .plus => "plus",
        .chevron_right => "chevron",
        .browser => "browser",
        .metronome => "metronome",
    };
}

/// Compact icon-only button. Returns true when clicked.
pub fn button(
    src: std.builtin.SourceLocation,
    kind: IconKind,
    opts: struct {
        id_extra: usize = 0,
        fill: ?dvui.Color = null,
        color: ?dvui.Color = null,
        size: f32 = tokens.icon_md,
        pad: f32 = 2,
        margin: dvui.Rect = .{},
        gravity_y: f32 = 0.5,
        border: bool = false,
    },
) bool {
    const fill = opts.fill orelse theme.cell;
    const col = opts.color orelse theme.text;
    const side = opts.size + opts.pad * 2;
    return dvui.buttonIcon(
        src,
        name(kind),
        tvg(kind),
        .{},
        .{},
        .{
            .min_size_content = .{ .w = side, .h = side },
            .color_fill = fill,
            .color_text = col,
            .corners = .round(tokens.radius_sm),
            .padding = dvui.Rect.all(opts.pad),
            .margin = opts.margin,
            .gravity_y = opts.gravity_y,
            .border = if (opts.border) dvui.Rect.all(1) else .{},
            .color_border = theme.grid,
            .id_extra = opts.id_extra,
        },
    );
}

/// Non-interactive icon (e.g. inside a parent button box).
pub fn draw(
    src: std.builtin.SourceLocation,
    kind: IconKind,
    opts: struct {
        id_extra: usize = 0,
        color: ?dvui.Color = null,
        size: f32 = tokens.icon_sm,
        gravity_x: f32 = 0.5,
        gravity_y: f32 = 0.5,
    },
) void {
    const col = opts.color orelse theme.text;
    dvui.icon(src, name(kind), tvg(kind), .{}, .{
        .min_size_content = .{ .w = opts.size, .h = opts.size },
        .color_text = col,
        .gravity_x = opts.gravity_x,
        .gravity_y = opts.gravity_y,
        .id_extra = opts.id_extra,
    });
}
