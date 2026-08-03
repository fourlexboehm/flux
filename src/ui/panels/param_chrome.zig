//! Embedded CLAP parameter chrome for plugins without a floating GUI.
//!
//! Multi-column layout inside a device rack card (zgui device body parity).
//! Writes go through `audio_runtime` controller events and a main-thread
//! flush for immediate `getValue` feedback — no direct engine/DSP imports.

const std = @import("std");
const dvui = @import("dvui");
const clap = @import("clap-bindings");

const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const audio_runtime = @import("../audio_runtime.zig");
const param_flush = @import("../../plugin/param_flush.zig");
const gui_float = @import("../../plugin/gui_float.zig");

const max_drawn_params: u32 = 64;
/// Target column width for multi-column param grids (natural px).
pub const col_w: f32 = 150;
pub const col_gap: f32 = 8;

pub const Target = struct {
    track: usize,
    /// -1 = instrument, else FX index.
    fx_index: i8,
};

/// Natural width that fits the multi-column param chrome for this plugin
/// (card chrome + body padding included). Used by the device rack so cards
/// hug their controls instead of reserved legacy widths.
pub fn preferredCardWidth(plugin: *const clap.Plugin) f32 {
    if (gui_float.hasFloatingGui(plugin)) return tokens.device_w_external;
    const cols = columnCount(plugin);
    const body_pad = tokens.gap_group * 2;
    const card_pad = tokens.gap_group * 2;
    const border: f32 = 4;
    const gaps = if (cols > 1) @as(f32, @floatFromInt(cols - 1)) * col_gap else 0;
    const content = @as(f32, @floatFromInt(cols)) * col_w + gaps;
    return @max(tokens.device_w_empty, content + body_pad + card_pad + border);
}

fn columnCount(plugin: *const clap.Plugin) u32 {
    const n_vis = countVisibleParams(plugin);
    if (n_vis == 0) return 1;
    return if (n_vis <= 4) 1 else if (n_vis <= 10) 2 else if (n_vis <= 18) 3 else 4;
}

fn countVisibleParams(plugin: *const clap.Plugin) u32 {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse return 0;
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const total = params.count(plugin);
    var n_vis: u32 = 0;
    var i: u32 = 0;
    while (i < total and n_vis < max_drawn_params) : (i += 1) {
        var info: clap.ext.params.Info = undefined;
        if (!params.getInfo(plugin, i, &info)) continue;
        if (info.flags.is_hidden) continue;
        n_vis += 1;
    }
    return n_vis;
}

/// Draw inside a device rack card body.
/// Floating-GUI plugins: compact summary only. Others: multi-column params.
pub fn draw(plugin: *const clap.Plugin, target: Target, id_extra: usize) void {
    const has_float = gui_float.hasFloatingGui(plugin);
    if (has_float) {
        drawExternalSummary(plugin, id_extra);
        return;
    }
    drawParamGrid(plugin, target, id_extra);
}

fn drawExternalSummary(plugin: *const clap.Plugin, id_extra: usize) void {
    dvui.label(@src(), "External CLAP", .{}, .{
        .color_text = theme.text_soft,
        .id_extra = id_extra,
    });
    if (plugin.descriptor.vendor) |vendor_z| {
        const vendor = std.mem.sliceTo(vendor_z, 0);
        if (vendor.len > 0) {
            dvui.label(@src(), "{s}", .{vendor}, .{
                .color_text = theme.text_soft,
                .id_extra = id_extra + 1,
            });
        }
    }
    if (plugin.getExtension(plugin, clap.ext.params.id)) |ext_raw| {
        const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
        dvui.label(@src(), "{d} parameters", .{params.count(plugin)}, .{
            .color_text = theme.text_soft,
            .id_extra = id_extra + 2,
        });
    }
}

fn drawParamGrid(plugin: *const clap.Plugin, target: Target, id_extra: usize) void {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse {
        dvui.label(@src(), "No parameters extension", .{}, .{
            .color_text = theme.text_soft,
            .id_extra = id_extra,
        });
        return;
    };
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const total = params.count(plugin);
    if (total == 0) {
        dvui.label(@src(), "No automatable parameters.", .{}, .{
            .color_text = theme.text_soft,
            .id_extra = id_extra,
        });
        return;
    }

    // Collect visible param indices for column packing.
    var visible: [max_drawn_params]u32 = undefined;
    var n_vis: u32 = 0;
    var i: u32 = 0;
    while (i < total and n_vis < max_drawn_params) : (i += 1) {
        var info: clap.ext.params.Info = undefined;
        if (!params.getInfo(plugin, i, &info)) continue;
        if (info.flags.is_hidden) continue;
        visible[n_vis] = i;
        n_vis += 1;
    }
    if (n_vis == 0) return;

    // Prefer 2–4 columns depending on visible count (same as preferredCardWidth).
    const cols = columnCount(plugin);
    const rows: u32 = (n_vis + cols - 1) / cols;

    var scroll = dvui.scrollArea(@src(), .{
        .horizontal_bar = .auto,
        .vertical_bar = .auto,
    }, .{
        .expand = .both,
        .id_extra = id_extra,
    });
    defer scroll.deinit();

    var grid = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .id_extra = id_extra,
    });
    defer grid.deinit();

    var c: u32 = 0;
    while (c < cols) : (c += 1) {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = col_w },
            .expand = .vertical,
            .margin = .{ .x = if (c == 0) 0 else col_gap, .y = 0, .w = 0, .h = 0 },
            .id_extra = id_extra * 10 + c,
        });
        defer col.deinit();

        var r: u32 = 0;
        while (r < rows) : (r += 1) {
            const idx = c * rows + r;
            if (idx >= n_vis) break;
            var info: clap.ext.params.Info = undefined;
            if (!params.getInfo(plugin, visible[idx], &info)) continue;
            drawOneParam(plugin, params, &info, target, id_extra * 1000 + idx + 1);
        }
    }

    if (total > max_drawn_params) {
        dvui.label(@src(), "… +{d} more", .{total - max_drawn_params}, .{
            .color_text = theme.text_dim,
            .id_extra = id_extra + 900,
        });
    }
}

fn drawOneParam(
    plugin: *const clap.Plugin,
    params: *const clap.ext.params.Plugin,
    info: *const clap.ext.params.Info,
    target: Target,
    id_extra: usize,
) void {
    const name = param_flush.paramName(info);
    const param_id: u32 = @intFromEnum(info.id);
    const read_only = info.flags.is_read_only;

    var value: f64 = info.default_value;
    _ = params.getValue(plugin, info.id, &value);

    if (info.flags.is_stepped and (info.max_value - info.min_value) <= 1.0 + 1e-9) {
        const on = value >= 0.5;
        const label = if (on) "On" else "Off";
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
            .id_extra = id_extra,
        });
        defer row.deinit();
        dvui.label(@src(), "{s}", .{name}, .{
            .color_text = theme.text_dim,
            .gravity_y = 0.5,
            .expand = .horizontal,
            .id_extra = id_extra,
        });
        if (dvui.button(@src(), label, .{}, .{
            .color_fill = if (on) theme.accent_dim else theme.cell,
            .color_text = theme.text,
            .min_size_content = .{ .h = tokens.control_h },
            .corners = .round(tokens.radius_sm),
            .gravity_y = 0.5,
            .id_extra = id_extra,
        }) and !read_only) {
            commitParam(plugin, target, param_id, if (on) info.min_value else info.max_value);
        }
        return;
    }

    var val_f: f32 = @floatCast(value);
    const min_f: f32 = @floatCast(info.min_value);
    const max_f: f32 = @floatCast(info.max_value);
    const span = @max(max_f - min_f, 1e-9);
    const interval = span / 100.0;

    var block = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
        .id_extra = id_extra,
    });
    defer block.deinit();

    var text_buf: [64]u8 = undefined;
    const value_label: []const u8 = blk: {
        if (params.valueToText(plugin, info.id, value, &text_buf, text_buf.len)) {
            break :blk std.mem.sliceTo(&text_buf, 0);
        }
        break :blk "";
    };

    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = id_extra,
        });
        defer header.deinit();
        dvui.label(@src(), "{s}", .{name}, .{
            .color_text = theme.text_dim,
            .gravity_y = 0.5,
            .id_extra = id_extra,
        });
        if (value_label.len > 0) {
            dvui.label(@src(), "{s}", .{value_label}, .{
                .color_text = theme.text_soft,
                .gravity_x = 1.0,
                .gravity_y = 0.5,
                .id_extra = id_extra + 1,
            });
        }
    }

    if (read_only) {
        dvui.label(@src(), "{d:.3}", .{val_f}, .{
            .color_text = theme.text_soft,
            .id_extra = id_extra,
        });
        return;
    }

    if (dvui.sliderEntry(@src(), "{d:.3}", .{
        .value = &val_f,
        .min = min_f,
        .max = max_f,
        .interval = interval,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = tokens.control_h },
        .id_extra = id_extra,
    })) {
        commitParam(plugin, target, param_id, @floatCast(val_f));
    }
}

/// Write a param on the main thread and queue it for the RT graph.
/// Shared with the bespoke built-in editors under `editors/`.
pub fn commitParam(plugin: *const clap.Plugin, target: Target, param_id: u32, value: f64) void {
    _ = param_flush.flushParamValue(plugin, param_id, value);
    if (audio_runtime.ready()) {
        audio_runtime.g.pushControllerParamWrite(.{
            .track_index = @intCast(@min(target.track, 255)),
            .target_fx_index = target.fx_index,
            .param_id = param_id,
            .value = value,
        });
    }
}
