//! Embedded zgui UI for stock builtins — dynamics faders + EQ response graph.

const std = @import("std");
const zgui = @import("zgui");
const clap = @import("clap-bindings");
const Plugin = @import("plugin.zig").Plugin;
const params_mod = @import("params.zig");
const undo = @import("undo.zig");
const eq_dsp = @import("dsp/equalizer.zig");

const eq_plot_points: usize = 160;
const eq_db_min: f32 = -24;
const eq_db_max: f32 = 24;
const log_f_min: f64 = @log10(20.0);
const log_f_max: f64 = @log10(20000.0);
/// Cap EQ width so it can breathe (~1000) without filling a 3k-wide pane.
const eq_max_body_w: f32 = 1000;
const thr_col_w: f32 = 96;
const param_label_w: f32 = 72;

const band_colors = [_][4]f32{
    .{ 0.95, 0.45, 0.35, 1 },
    .{ 0.95, 0.75, 0.30, 1 },
    .{ 0.45, 0.90, 0.40, 1 },
    .{ 0.35, 0.75, 0.95, 1 },
    .{ 0.70, 0.50, 0.95, 1 },
    .{ 0.95, 0.50, 0.75, 1 },
    .{ 0.55, 0.85, 0.85, 1 },
    .{ 0.85, 0.85, 0.50, 1 },
};

var eq_selected_band: usize = 0;
var eq_dragging: bool = false;

pub fn drawEmbedded(plugin: *Plugin) void {
    zgui.textUnformatted(plugin.kind.name());
    zgui.separator();

    switch (plugin.kind) {
        .equalizer => drawEq(plugin),
        .compressor, .noise_gate, .limiter => drawDynamics(plugin),
    }
}

/// Continuous control: capture pre-state on activate, commit on edit end.
fn trackSliderUndo(plugin: *Plugin, name: [*:0]const u8) void {
    if (zgui.isItemActivated()) undo.beginChange(plugin);
    if (zgui.isItemDeactivatedAfterEdit()) {
        undo.changeMade(plugin, name);
    } else if (zgui.isItemDeactivated()) {
        undo.cancelChange(plugin);
    }
}

fn paramIndex(plugin: *Plugin, id: u32) ?u32 {
    return plugin.params.indexOf(id);
}

/// Friendly short labels for the side panel (schema names stay on params for DAWproject).
fn displayName(id: u32) [:0]const u8 {
    return switch (id) {
        params_mod.id_threshold => "Thresh",
        params_mod.id_ratio => "Ratio",
        params_mod.id_attack => "Attack",
        params_mod.id_release => "Release",
        params_mod.id_input_gain => "Input",
        params_mod.id_output_gain => "Output",
        params_mod.id_auto_makeup => "Makeup",
        params_mod.id_range => "Range",
        params_mod.id_eq_input_gain => "In",
        params_mod.id_eq_output_gain => "Out",
        else => "Param",
    };
}

/// Labeled row: fixed left caption + slider so the name is never clipped.
fn drawParamRow(plugin: *Plugin, id: u32, row_w: f32) void {
    const ii = paramIndex(plugin, id) orelse return;
    const def = plugin.params.defs[ii];
    const name = displayName(id);

    var id_buf: [32]u8 = undefined;
    const sid = std.fmt.bufPrintSentinel(&id_buf, "##p{d}", .{def.id}, 0) catch "##p";

    if (def.is_bool) {
        var en = plugin.params.values[ii] >= 0.5;
        // Checkbox carries its own label
        var lab_buf: [40]u8 = undefined;
        const lab = std.fmt.bufPrintSentinel(&lab_buf, "{s}##p{d}", .{ name, def.id }, 0) catch name;
        if (zgui.checkbox(lab, .{ .v = &en })) {
            undo.beginChange(plugin);
            plugin.params.setByIndex(ii, if (en) 1 else 0);
            plugin.applyParamsToDsp();
            undo.changeMade(plugin, lab);
        }
        return;
    }

    zgui.alignTextToFramePadding();
    zgui.textUnformatted(name);
    zgui.sameLine(.{ .spacing = 8 });

    var val: f32 = @floatCast(plugin.params.values[ii]);
    const min: f32 = @floatCast(def.min);
    const max: f32 = @floatCast(def.max);
    const flags = if (def.unit == .seconds or def.unit == .hertz)
        zgui.SliderFlags{ .logarithmic = true }
    else
        zgui.SliderFlags{};

    const slider_w = @max(row_w - param_label_w - 8, 60.0);
    zgui.setNextItemWidth(slider_w);

    const cfmt: [:0]const u8 = switch (def.unit) {
        .decibel => "%.1f dB",
        .seconds => "%.3f s",
        .hertz => "%.0f Hz",
        .linear => "%.2f",
    };

    if (zgui.sliderFloat(sid, .{ .v = &val, .min = min, .max = max, .cfmt = cfmt, .flags = flags })) {
        plugin.params.setByIndex(ii, val);
        plugin.applyParamsToDsp();
    }
    trackSliderUndo(plugin, name.ptr);
}

fn drawVerticalThreshold(plugin: *Plugin, height: f32) void {
    const ii = paramIndex(plugin, params_mod.id_threshold) orelse return;
    const def = plugin.params.defs[ii];
    var val: f32 = @floatCast(plugin.params.values[ii]);
    const min: f32 = @floatCast(def.min);
    const max: f32 = @floatCast(def.max);

    const col_w = zgui.getContentRegionAvail()[0];
    {
        const tw = zgui.calcTextSize("Threshold", .{})[0];
        if (col_w > tw) zgui.setCursorPosX(zgui.getCursorPosX() + (col_w - tw) * 0.5);
        zgui.textUnformatted("Threshold");
    }
    zgui.dummy(.{ .w = 1, .h = 4 });

    // Wider fader; value lives under it (no overset number on the grip).
    const slider_w: f32 = 36;
    if (col_w > slider_w) zgui.setCursorPosX(zgui.getCursorPosX() + (col_w - slider_w) * 0.5);

    if (zgui.vsliderFloat("##threshold", .{
        .w = slider_w,
        .h = height,
        .v = &val,
        .min = min,
        .max = max,
        .cfmt = "",
    })) {
        plugin.params.setByIndex(ii, val);
        plugin.applyParamsToDsp();
    }
    trackSliderUndo(plugin, "Threshold");

    zgui.dummy(.{ .w = 1, .h = 6 });
    var db_buf: [24]u8 = undefined;
    const db_txt = std.fmt.bufPrintSentinel(&db_buf, "{d:.1} dB", .{val}, 0) catch "dB";
    const tw = zgui.calcTextSize(db_txt, .{})[0];
    if (col_w > tw) zgui.setCursorPosX(zgui.getCursorPosX() + (col_w - tw) * 0.5);
    zgui.textUnformatted(db_txt);
}

/// Shared compressor / gate / limiter layout: vertical threshold + side params.
fn drawDynamics(plugin: *Plugin) void {
    const avail = zgui.getContentRegionAvail();
    const fader_h = @max(@min(avail[1] - 48, 300.0), 120.0);
    const right_w = @max(avail[0] - thr_col_w - 12, 160.0);

    if (zgui.beginChild("##dyn_thr", .{ .w = thr_col_w, .h = fader_h + 56, .child_flags = .{ .border = false } })) {
        drawVerticalThreshold(plugin, fader_h);
    }
    zgui.endChild();

    zgui.sameLine(.{ .spacing = 12 });

    if (zgui.beginChild("##dyn_side", .{ .w = right_w, .h = fader_h + 56, .child_flags = .{ .border = false } })) {
        const w = @max(zgui.getContentRegionAvail()[0] - 4, 120.0);
        switch (plugin.kind) {
            .compressor => {
                zgui.separatorText("Dynamics");
                drawParamRow(plugin, params_mod.id_ratio, w);
                drawParamRow(plugin, params_mod.id_attack, w);
                drawParamRow(plugin, params_mod.id_release, w);
                zgui.separatorText("Gain");
                drawParamRow(plugin, params_mod.id_input_gain, w);
                drawParamRow(plugin, params_mod.id_output_gain, w);
                drawParamRow(plugin, params_mod.id_auto_makeup, w);
            },
            .limiter => {
                zgui.separatorText("Timing");
                drawParamRow(plugin, params_mod.id_attack, w);
                drawParamRow(plugin, params_mod.id_release, w);
                zgui.separatorText("Gain");
                drawParamRow(plugin, params_mod.id_input_gain, w);
                drawParamRow(plugin, params_mod.id_output_gain, w);
            },
            .noise_gate => {
                zgui.separatorText("Dynamics");
                drawParamRow(plugin, params_mod.id_ratio, w);
                drawParamRow(plugin, params_mod.id_attack, w);
                drawParamRow(plugin, params_mod.id_release, w);
                drawParamRow(plugin, params_mod.id_range, w);
            },
            .equalizer => {},
        }
    }
    zgui.endChild();
}

fn beginClampedBody(max_w: f32) f32 {
    const avail = zgui.getContentRegionAvail()[0];
    const body_w = @min(avail, max_w);
    _ = zgui.beginChild("##fx_body", .{ .w = body_w, .h = 0, .child_flags = .{ .border = false } });
    return body_w;
}

fn endClampedBody() void {
    zgui.endChild();
}

fn drawEq(plugin: *Plugin) void {
    // Keep DSP bands in sync for response curve (UI thread only).
    plugin.applyParamsToDsp();

    const body_w = beginClampedBody(eq_max_body_w);
    defer endClampedBody();

    // Global trim only — band Boost is separate (per-band boost/cut on the curve).
    zgui.separatorText("Trim");
    // Full-width rows (not a short child) so labels/values never clip vertically.
    drawParamRow(plugin, params_mod.id_eq_input_gain, body_w);
    drawParamRow(plugin, params_mod.id_eq_output_gain, body_w);

    drawEqGraph(plugin, body_w);

    // Band selector chips
    const n = plugin.eq.band_count;
    if (eq_selected_band >= n) eq_selected_band = 0;
    const chip_w: f32 = 48;
    for (0..n) |b| {
        if (b > 0) zgui.sameLine(.{ .spacing = 6 });
        var lab_buf: [16]u8 = undefined;
        const lab = std.fmt.bufPrintSentinel(&lab_buf, "B{d}##sel{d}", .{ b + 1, b }, 0) catch "B";
        const col = band_colors[b % band_colors.len];
        const enabled = plugin.eq.bands[b].enabled;
        if (eq_selected_band == b) {
            zgui.pushStyleColor4f(.{ .idx = .button, .c = col });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = col });
            zgui.pushStyleColor4f(.{ .idx = .button_active, .c = col });
        } else if (!enabled) {
            zgui.pushStyleColor4f(.{ .idx = .button, .c = .{ col[0] * 0.35, col[1] * 0.35, col[2] * 0.35, 0.7 } });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ col[0] * 0.5, col[1] * 0.5, col[2] * 0.5, 0.9 } });
            zgui.pushStyleColor4f(.{ .idx = .button_active, .c = col });
        } else {
            zgui.pushStyleColor4f(.{ .idx = .button, .c = .{ col[0] * 0.55, col[1] * 0.55, col[2] * 0.55, 0.85 } });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ col[0] * 0.75, col[1] * 0.75, col[2] * 0.75, 1 } });
            zgui.pushStyleColor4f(.{ .idx = .button_active, .c = col });
        }
        if (zgui.button(lab, .{ .w = chip_w, .h = 0 })) eq_selected_band = b;
        zgui.popStyleColor(.{ .count = 3 });
    }

    drawEqBandControls(plugin, eq_selected_band, body_w);
}

fn drawEqGraph(plugin: *Plugin, body_w: f32) void {
    var xv: [eq_plot_points]f64 = undefined;
    var yv: [eq_plot_points]f64 = undefined;
    for (0..eq_plot_points) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(eq_plot_points - 1));
        const log_f = log_f_min + t * (log_f_max - log_f_min);
        const freq = std.math.pow(f64, 10.0, log_f);
        xv[i] = log_f;
        yv[i] = plugin.eq.responseDb(freq);
    }

    // Cap height by width so wide panes don't get a tall empty graph.
    const plot_h = std.math.clamp(body_w * 0.42, 150.0, 300.0);

    if (zgui.plot.beginPlot("##eq_curve", .{
        .w = -1,
        .h = plot_h,
        .flags = .{
            .no_title = true,
            .no_legend = true,
            .no_menus = true,
            .no_box_select = true,
            .no_mouse_text = true,
        },
    })) {
        zgui.plot.setupAxis(.x1, .{ .label = "Hz", .flags = .{ .no_label = true } });
        zgui.plot.setupAxis(.y1, .{ .label = "dB", .flags = .{ .no_label = true } });
        zgui.plot.setupAxisLimits(.x1, .{ .min = log_f_min, .max = log_f_max, .cond = .always });
        zgui.plot.setupAxisLimits(.y1, .{ .min = eq_db_min, .max = eq_db_max, .cond = .always });

        const tick_vals = [_]f64{
            @log10(20.0),    @log10(50.0),   @log10(100.0),  @log10(200.0),
            @log10(500.0),   @log10(1000.0), @log10(2000.0), @log10(5000.0),
            @log10(10000.0), @log10(20000.0),
        };
        const tick_labels = [_][*:0]const u8{
            "20", "50", "100", "200", "500", "1k", "2k", "5k", "10k", "20k",
        };
        zgui.plot.setupAxisTicks(.x1, .{ .values = &tick_vals, .labels = @constCast(&tick_labels) });

        const y_ticks = [_]f64{ -24, -12, 0, 12, 24 };
        zgui.plot.setupAxisTicks(.y1, .{ .values = &y_ticks, .labels = null });

        zgui.plot.setupFinish();

        zgui.plot.setNextFillStyle(.{ .col = .{ 0.35, 0.65, 0.95, 0.18 } });
        zgui.plot.plotShaded("fill", f64, .{ .xv = &xv, .yv = &yv, .yref = 0 });

        zgui.plot.setNextLineStyle(.{ .col = .{ 0.55, 0.85, 1.0, 1 }, .weight = 2.0 });
        zgui.plot.plotLine("resp", f64, .{ .xv = &xv, .yv = &yv });

        const zero_x = [_]f64{ log_f_min, log_f_max };
        const zero_y = [_]f64{ 0, 0 };
        zgui.plot.setNextLineStyle(.{ .col = .{ 1, 1, 1, 0.25 }, .weight = 1.0 });
        zgui.plot.plotLine("0dB", f64, .{ .xv = &zero_x, .yv = &zero_y });

        var any_drag = false;
        for (0..plugin.eq.band_count) |b| {
            if (!plugin.eq.bands[b].enabled) continue;
            const base = params_mod.eqBandBase(b);
            var fx = @log10(std.math.clamp(plugin.eq.bands[b].freq_hz, 20.0, 20000.0));
            var gy: f64 = if (eq_dsp.bandHasGain(plugin.eq.bands[b].type))
                plugin.eq.bands[b].gain_db
            else
                plugin.eq.responseDb(plugin.eq.bands[b].freq_hz);

            const col = band_colors[b % band_colors.len];
            const size: f32 = if (eq_selected_band == b) 8 else 5.5;
            if (zgui.plot.dragPoint(@intCast(b + 1), .{
                .x = &fx,
                .y = &gy,
                .col = col,
                .size = size,
            })) {
                any_drag = true;
                eq_selected_band = b;
                if (!eq_dragging) {
                    undo.beginChange(plugin);
                    eq_dragging = true;
                }
                const freq = std.math.clamp(std.math.pow(f64, 10.0, fx), 20.0, 20000.0);
                plugin.params.set(base + 1, freq);
                if (eq_dsp.bandHasGain(plugin.eq.bands[b].type)) {
                    plugin.params.set(base + 2, std.math.clamp(gy, eq_db_min, eq_db_max));
                }
                plugin.applyParamsToDsp();
            }
        }

        if (eq_dragging and !any_drag and !zgui.isMouseDown(.left)) {
            undo.changeMade(plugin, "EQ Graph");
            eq_dragging = false;
        }

        zgui.plot.endPlot();
    }
}

fn drawEqBandControls(plugin: *Plugin, band: usize, body_w: f32) void {
    if (band >= plugin.eq.band_count) return;
    const base = params_mod.eqBandBase(band);
    const type_names = "highPass\x00lowPass\x00bandPass\x00highShelf\x00lowShelf\x00bell\x00notch\x00";

    zgui.separator();
    var title_buf: [32]u8 = undefined;
    const title = std.fmt.bufPrintSentinel(&title_buf, "Band {d}", .{band + 1}, 0) catch "Band";
    zgui.separatorText(title);

    // Enabled + type on one row
    if (plugin.params.indexOf(base + 4)) |ii| {
        var en = plugin.params.values[ii] >= 0.5;
        var id_buf: [24]u8 = undefined;
        const id = std.fmt.bufPrintSentinel(&id_buf, "On##b{d}", .{band}, 0) catch "On";
        if (zgui.checkbox(id, .{ .v = &en })) {
            undo.beginChange(plugin);
            plugin.params.setByIndex(ii, if (en) 1 else 0);
            plugin.applyParamsToDsp();
            undo.changeMade(plugin, id);
        }
    }
    zgui.sameLine(.{ .spacing = 16 });
    if (plugin.params.indexOf(base + 0)) |ii| {
        var cur: i32 = @intFromFloat(plugin.params.values[ii]);
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrintSentinel(&id_buf, "Type##b{d}", .{band}, 0) catch "Type";
        zgui.setNextItemWidth(140);
        if (zgui.combo(id, .{ .current_item = &cur, .items_separated_by_zeros = type_names })) {
            undo.beginChange(plugin);
            plugin.params.setByIndex(ii, @floatFromInt(cur));
            plugin.applyParamsToDsp();
            undo.changeMade(plugin, id);
        }
    }

    const w = @max(body_w - 4, 100.0);

    // Freq
    if (plugin.params.indexOf(base + 1)) |ii| {
        zgui.alignTextToFramePadding();
        zgui.textUnformatted("Freq");
        zgui.sameLine(.{ .spacing = 8 });
        var v: f32 = @floatCast(plugin.params.values[ii]);
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrintSentinel(&id_buf, "##freq{d}", .{band}, 0) catch "##f";
        zgui.setNextItemWidth(@max(w - param_label_w - 8, 80.0));
        if (zgui.sliderFloat(id, .{ .v = &v, .min = 20, .max = 20000, .cfmt = "%.0f Hz", .flags = .{ .logarithmic = true } })) {
            plugin.params.setByIndex(ii, v);
            plugin.applyParamsToDsp();
        }
        trackSliderUndo(plugin, "Freq");
    }

    // Band boost/cut (not the global In/Out trim)
    if (plugin.params.indexOf(base + 2)) |ii| {
        zgui.alignTextToFramePadding();
        zgui.textUnformatted("Boost");
        zgui.sameLine(.{ .spacing = 8 });
        var v: f32 = @floatCast(plugin.params.values[ii]);
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrintSentinel(&id_buf, "##gain{d}", .{band}, 0) catch "##g";
        const has_gain = eq_dsp.bandHasGain(plugin.eq.bands[band].type);
        if (!has_gain) zgui.beginDisabled(.{});
        zgui.setNextItemWidth(@max(w - param_label_w - 8, 80.0));
        if (zgui.sliderFloat(id, .{ .v = &v, .min = -24, .max = 24, .cfmt = "%.1f dB" })) {
            plugin.params.setByIndex(ii, v);
            plugin.applyParamsToDsp();
        }
        trackSliderUndo(plugin, "Boost");
        if (!has_gain) zgui.endDisabled();
    }

    // Q
    if (plugin.params.indexOf(base + 3)) |ii| {
        zgui.alignTextToFramePadding();
        zgui.textUnformatted("Q");
        zgui.sameLine(.{ .spacing = 8 });
        var v: f32 = @floatCast(plugin.params.values[ii]);
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrintSentinel(&id_buf, "##q{d}", .{band}, 0) catch "##q";
        zgui.setNextItemWidth(@max(w - param_label_w - 8, 80.0));
        if (zgui.sliderFloat(id, .{ .v = &v, .min = 0.1, .max = 10, .cfmt = "%.2f", .flags = .{ .logarithmic = true } })) {
            plugin.params.setByIndex(ii, v);
            plugin.applyParamsToDsp();
        }
        trackSliderUndo(plugin, "Q");
    }
}

pub fn drawFromClap(clap_plugin: *const clap.Plugin) void {
    drawEmbedded(Plugin.fromClapPlugin(clap_plugin));
}
