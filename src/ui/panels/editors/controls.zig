//! Shared DVUI controls for the built-in plugin editors.
//!
//! Values are read through `clap.ext.params` and written through
//! `param_chrome.commitParam` (main-thread flush + RT controller write), so the
//! editors never poke plugin DSP state from the UI thread — even though the
//! built-ins are linked in-process.

const std = @import("std");
const dvui = @import("dvui");
const clap = @import("clap-bindings");

const theme = @import("../../theme.zig");
const tokens = @import("../../tokens.zig");
const param_chrome = @import("../param_chrome.zig");

pub const Target = param_chrome.Target;

/// Bound plugin + params extension for one editor draw pass.
pub const Ctx = struct {
    plugin: *const clap.Plugin,
    params: *const clap.ext.params.Plugin,
    target: Target,

    pub fn init(plugin: *const clap.Plugin, target: Target) ?Ctx {
        const raw = plugin.getExtension(plugin, clap.ext.params.id) orelse return null;
        return .{
            .plugin = plugin,
            .params = @ptrCast(@alignCast(raw)),
            .target = target,
        };
    }

    pub fn count(self: Ctx) u32 {
        return self.params.count(self.plugin);
    }

    pub fn infoAt(self: Ctx, index: u32) ?clap.ext.params.Info {
        var info: clap.ext.params.Info = undefined;
        if (!self.params.getInfo(self.plugin, index, &info)) return null;
        return info;
    }

    /// Built-in params expose `id == index`; scan anyway so id lookups stay
    /// correct if a plugin ever renumbers.
    pub fn indexOfId(self: Ctx, param_id: u32) ?u32 {
        const total = self.count();
        var i: u32 = 0;
        while (i < total) : (i += 1) {
            const info = self.infoAt(i) orelse continue;
            if (@intFromEnum(info.id) == param_id) return i;
        }
        return null;
    }

    pub fn value(self: Ctx, info: *const clap.ext.params.Info) f64 {
        var v: f64 = info.default_value;
        _ = self.params.getValue(self.plugin, info.id, &v);
        return v;
    }

    pub fn set(self: Ctx, info: *const clap.ext.params.Info, v: f64) void {
        const clamped = std.math.clamp(v, info.min_value, info.max_value);
        param_chrome.commitParam(self.plugin, self.target, @intFromEnum(info.id), clamped);
    }

    pub fn valueText(self: Ctx, info: *const clap.ext.params.Info, v: f64, buf: []u8) []const u8 {
        if (self.params.valueToText(self.plugin, info.id, v, buf.ptr, @intCast(buf.len))) {
            return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf.ptr)), 0);
        }
        return "";
    }
};

pub fn paramName(info: *const clap.ext.params.Info) []const u8 {
    return std.mem.sliceTo(&info.name, 0);
}

/// Section caption with a hairline underneath.
pub fn section(title: []const u8, id_extra: usize) void {
    dvui.label(@src(), "{s}", .{title}, .{
        .color_text = theme.text_soft,
        .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = 0 },
        .id_extra = id_extra,
    });
    _ = dvui.separator(@src(), .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 1 },
        .color_fill = theme.grid,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_tight },
        .id_extra = id_extra,
    });
}

/// Slider row: caption + formatted value above a full-width slider.
/// `label_override` replaces the CLAP param name when the schema name is long.
pub fn slider(ctx: Ctx, index: u32, id_extra: usize, label_override: ?[]const u8) void {
    var info = ctx.infoAt(index) orelse return;
    const v = ctx.value(&info);

    var block = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .id_extra = id_extra,
    });
    defer block.deinit();

    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = id_extra,
        });
        defer header.deinit();

        dvui.label(@src(), "{s}", .{label_override orelse paramName(&info)}, .{
            .color_text = theme.text_dim,
            .gravity_y = 0.5,
            .id_extra = id_extra,
        });

        var buf: [64]u8 = undefined;
        const text = ctx.valueText(&info, v, &buf);
        if (text.len > 0) {
            dvui.label(@src(), "{s}", .{text}, .{
                .color_text = theme.text_soft,
                .gravity_x = 1.0,
                .gravity_y = 0.5,
                .id_extra = id_extra,
            });
        }
    }

    if (info.flags.is_read_only) return;

    var val: f32 = @floatCast(v);
    const min: f32 = @floatCast(info.min_value);
    const max: f32 = @floatCast(info.max_value);
    const span = @max(max - min, 1e-9);
    // No inline number: the CLAP-formatted value already sits in the header.
    if (dvui.sliderEntry(@src(), null, .{
        .value = &val,
        .min = min,
        .max = max,
        .interval = span / 100.0,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = tokens.control_h },
        .id_extra = id_extra,
    })) {
        ctx.set(&info, @floatCast(val));
    }
}

/// On/off row for a stepped 0..1 param.
pub fn toggle(ctx: Ctx, index: u32, id_extra: usize, label_override: ?[]const u8) void {
    var info = ctx.infoAt(index) orelse return;
    var on = ctx.value(&info) >= 0.5;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .id_extra = id_extra,
    });
    defer row.deinit();

    if (dvui.checkbox(@src(), &on, label_override orelse paramName(&info), .{
        .color_text = theme.text_dim,
        .gravity_y = 0.5,
        .id_extra = id_extra,
    })) {
        ctx.set(&info, if (on) info.max_value else info.min_value);
    }
}

/// Dropdown over a stepped param whose steps map 1:1 onto `items`.
/// `offset` is added to the stored value (ZPortaFM instruments are 1-based).
pub fn choice(
    ctx: Ctx,
    index: u32,
    items: []const []const u8,
    id_extra: usize,
    label_override: ?[]const u8,
    offset: i32,
) void {
    var info = ctx.infoAt(index) orelse return;
    if (items.len == 0) return;

    const stored: i32 = @intFromFloat(@round(ctx.value(&info)));
    const max_i: i32 = @intCast(items.len - 1);
    var current: usize = @intCast(std.math.clamp(stored - offset, 0, max_i));

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .id_extra = id_extra,
    });
    defer row.deinit();

    dvui.label(@src(), "{s}", .{label_override orelse paramName(&info)}, .{
        .color_text = theme.text_dim,
        .gravity_y = 0.5,
        .id_extra = id_extra,
    });

    if (dvui.dropdown(@src(), items, .{ .choice = &current }, .{}, .{
        .expand = .horizontal,
        .gravity_x = 1.0,
        .min_size_content = .{ .h = tokens.control_h },
        .id_extra = id_extra,
    })) {
        ctx.set(&info, @floatFromInt(@as(i32, @intCast(current)) + offset));
    }
}

/// Radio strip: one button per step, laid out horizontally.
pub fn steps(
    ctx: Ctx,
    index: u32,
    items: []const []const u8,
    id_extra: usize,
    label_override: ?[]const u8,
) void {
    var info = ctx.infoAt(index) orelse return;
    if (items.len == 0) return;
    const current: i32 = @intFromFloat(@round(ctx.value(&info)));

    var block = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .id_extra = id_extra,
    });
    defer block.deinit();

    dvui.label(@src(), "{s}", .{label_override orelse paramName(&info)}, .{
        .color_text = theme.text_dim,
        .id_extra = id_extra,
    });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .id_extra = id_extra,
    });
    defer row.deinit();

    for (items, 0..) |item, i| {
        const active = current == @as(i32, @intCast(i));
        if (dvui.button(@src(), item, .{}, .{
            .expand = .horizontal,
            .color_fill = if (active) theme.accent_dim else theme.cell,
            .color_text = if (active) theme.text_on_fill else theme.text_dim,
            .min_size_content = .{ .h = tokens.control_h },
            .corners = .round(tokens.radius_sm),
            .margin = .{ .x = if (i == 0) 0 else tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
            .id_extra = id_extra * 16 + i,
        })) {
            ctx.set(&info, @floatFromInt(i));
        }
    }
}

/// Vertical column inside an editor card body.
pub fn column(src: std.builtin.SourceLocation, id_extra: usize, first: bool) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .both,
        .margin = .{ .x = if (first) 0 else tokens.gap_group, .y = 0, .w = 0, .h = 0 },
        .id_extra = id_extra,
    });
}
