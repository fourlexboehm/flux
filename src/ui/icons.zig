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
    search,
    sort_up,
    sort_down,
    close,
    remove,
    instrument,
    effect,
    appearance,
    save,
    open_editor,
    bypass,
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
        .search => entypo.magnifying_glass,
        .sort_up => entypo.chevron_small_up,
        .sort_down => entypo.chevron_small_down,
        .close, .remove => entypo.cross,
        .instrument => entypo.note,
        .effect => entypo.sound_mix,
        .appearance => entypo.light_up,
        .save => entypo.save,
        .open_editor => entypo.popup,
        .bypass => entypo.circle,
    };
}

pub fn name(kind: IconKind) []const u8 {
    return switch (kind) {
        .play => "Play (Space)",
        .stop => "Stop (Space)",
        .browser => "Show or hide browser (B)",
        .metronome => "Toggle metronome",
        .sort_up => "Sort descending",
        .sort_down => "Sort ascending",
        .close => "Close or clear",
        .remove => "Remove device",
        .open_editor => "Open plugin editor",
        .bypass => "Toggle device",
        else => @tagName(kind),
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
        pad: f32 = 5,
        margin: dvui.Rect = .{},
        gravity_y: f32 = 0.5,
        border: bool = false,
    },
) bool {
    const fill = opts.fill orelse theme.cell;
    const col = opts.color orelse theme.text;
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{}, .{
        .label = .{ .text = name(kind) },
        .min_size_content = .{ .w = opts.size, .h = opts.size },
        .color_fill = fill,
        .color_text = col,
        .corners = .round(tokens.radius_sm),
        .padding = dvui.Rect.all(opts.pad),
        .margin = opts.margin,
        .gravity_y = opts.gravity_y,
        .border = if (opts.border) dvui.Rect.all(1) else .{},
        .color_border = theme.border_light,
        .id_extra = opts.id_extra,
    });
    bw.processEvents();
    bw.drawBackground();
    dvui.icon(@src(), name(kind), tvg(kind), .{}, bw.style().override(.{
        .min_size_content = .{ .w = opts.size, .h = opts.size },
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .role = .none,
    }));
    const clicked = bw.clicked();
    const rect = bw.data().rectScale().r;
    bw.drawFocus();
    bw.deinit();
    dvui.tooltip(@src(), .{ .active_rect = rect }, "{s}", .{name(kind)}, .{ .id_extra = opts.id_extra });
    return clicked;
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

/// Left-aligned navigation, with a vector icon and a single hit target.
pub fn navigation(src: std.builtin.SourceLocation, kind: IconKind, label: []const u8, opts: dvui.Options) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{}, opts.override(.{ .label = .{ .text = label } }));
    bw.processEvents();
    bw.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        draw(@src(), kind, .{ .color = opts.color_text, .size = tokens.icon_sm, .gravity_x = 0 });
        dvui.label(@src(), "{s}", .{label}, .{
            .color_text = opts.color_text,
            .gravity_y = 0.5,
            .margin = .{ .x = 8 },
            .padding = .{},
        });
    }
    const clicked = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    return clicked;
}
