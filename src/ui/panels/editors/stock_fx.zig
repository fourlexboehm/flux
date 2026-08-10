//! DVUI editor for the stock Flux FX (EQ / compressor / gate / limiter).
//!
//! Stock FX editors: EQ magnitude-response curve
//! with band chips and per-band controls, and a grouped dynamics layout.
//!
//! The response curve is computed from the *parameter* values into a scratch
//! `Equalizer` (never the live DSP instance), so drawing cannot race the audio
//! thread — `Equalizer.responseDb` is pure.

const std = @import("std");
const dvui = @import("dvui");
const clap = @import("clap-bindings");

const theme = @import("../../theme.zig");
const tokens = @import("../../tokens.zig");
const controls = @import("controls.zig");
const flux_builtins = @import("../../../builtins/root.zig");
const eq_dsp = @import("../../../builtins/dsp/equalizer.zig");
const builtin_params = @import("../../../builtins/params.zig");

const Kind = flux_builtins.Kind;
const Ctx = controls.Ctx;

const curve_points: usize = 160;
const db_min: f64 = -24;
const db_max: f64 = 24;
const log_f_min: f64 = @log10(20.0);
const log_f_max: f64 = @log10(20000.0);

const band_colors = [_]dvui.Color{
    theme.colorF(0.95, 0.45, 0.35),
    theme.colorF(0.95, 0.75, 0.30),
    theme.colorF(0.45, 0.90, 0.40),
    theme.colorF(0.35, 0.75, 0.95),
    theme.colorF(0.70, 0.50, 0.95),
    theme.colorF(0.95, 0.50, 0.75),
    theme.colorF(0.55, 0.85, 0.85),
    theme.colorF(0.85, 0.85, 0.50),
};

/// Selected EQ band per rack slot (id_extra), so two EQs keep separate state.
var selected_band: [16]usize = @splat(0);

pub fn cardWidth(kind: Kind) f32 {
    return switch (kind) {
        .equalizer => tokens.device_w_equalizer,
        .compressor, .noise_gate, .limiter => tokens.device_w_dynamics,
    };
}

pub fn draw(plugin: *const clap.Plugin, kind: Kind, target: controls.Target, id_extra: usize) void {
    const ctx = Ctx.init(plugin, target) orelse return;
    switch (kind) {
        .equalizer => drawEq(ctx, id_extra),
        .compressor, .noise_gate, .limiter => drawDynamics(ctx, kind, id_extra),
    }
}

// ── Dynamics ────────────────────────────────────────────────────────────────

fn drawDynamics(ctx: Ctx, kind: Kind, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .id_extra = id_extra,
    });
    defer row.deinit();

    {
        var left = controls.column(@src(), id_extra, true);
        defer left.deinit();

        controls.section("Threshold", id_extra);
        sliderById(ctx, builtin_params.id_threshold, id_extra + 1, "Thresh");

        controls.section(if (kind == .limiter) "Timing" else "Dynamics", id_extra + 2);
        if (kind != .limiter) sliderById(ctx, builtin_params.id_ratio, id_extra + 3, "Ratio");
        sliderById(ctx, builtin_params.id_attack, id_extra + 4, "Attack");
        sliderById(ctx, builtin_params.id_release, id_extra + 5, "Release");
        if (kind == .noise_gate) sliderById(ctx, builtin_params.id_range, id_extra + 6, "Range");
    }

    {
        var right = controls.column(@src(), id_extra + 100, false);
        defer right.deinit();

        controls.section("Gain", id_extra + 7);
        sliderById(ctx, builtin_params.id_input_gain, id_extra + 8, "Input");
        sliderById(ctx, builtin_params.id_output_gain, id_extra + 9, "Output");
        if (kind == .compressor) toggleById(ctx, builtin_params.id_auto_makeup, id_extra + 10, "Makeup");
    }
}

// ── Equalizer ───────────────────────────────────────────────────────────────

fn drawEq(ctx: Ctx, id_extra: usize) void {
    const slot = id_extra % selected_band.len;

    var scratch = eqFromParams(ctx);
    const band_count = @min(scratch.band_count, eq_dsp.max_bands);
    if (selected_band[slot] >= band_count) selected_band[slot] = 0;

    controls.section("Trim", id_extra);
    {
        var trim = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = id_extra,
        });
        defer trim.deinit();
        var in_col = controls.column(@src(), id_extra + 1, true);
        sliderById(ctx, builtin_params.id_eq_input_gain, id_extra + 1, "In");
        in_col.deinit();
        var out_col = controls.column(@src(), id_extra + 2, false);
        sliderById(ctx, builtin_params.id_eq_output_gain, id_extra + 2, "Out");
        out_col.deinit();
    }

    drawCurve(&scratch, id_extra);
    drawBandChips(&scratch, band_count, slot, id_extra);
    drawBandControls(ctx, &scratch, selected_band[slot], id_extra);
}

/// Scratch EQ mirroring the current parameter values (no live DSP access).
fn eqFromParams(ctx: Ctx) eq_dsp.Equalizer {
    var eq = eq_dsp.Equalizer{};
    eq.setSampleRate(48000);
    eq.input_gain_db = paramValue(ctx, builtin_params.id_eq_input_gain) orelse 0;
    eq.output_gain_db = paramValue(ctx, builtin_params.id_eq_output_gain) orelse 0;

    for (0..@min(eq.band_count, eq_dsp.max_bands)) |b| {
        const base = builtin_params.eqBandBase(b);
        if (paramValue(ctx, base + 0)) |t| {
            const max_tag = std.enums.values(eq_dsp.BandType).len - 1;
            const tag: usize = @intFromFloat(std.math.clamp(@round(t), 0, @as(f64, @floatFromInt(max_tag))));
            eq.bands[b].type = @enumFromInt(tag);
        }
        if (paramValue(ctx, base + 1)) |f| eq.bands[b].freq_hz = f;
        if (paramValue(ctx, base + 2)) |g| eq.bands[b].gain_db = g;
        if (paramValue(ctx, base + 3)) |q| eq.bands[b].q = q;
        if (paramValue(ctx, base + 4)) |en| eq.bands[b].enabled = en >= 0.5;
    }
    return eq;
}

fn drawCurve(eq: *const eq_dsp.Equalizer, id_extra: usize) void {
    var xs: [curve_points]f64 = undefined;
    var ys: [curve_points]f64 = undefined;
    for (0..curve_points) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(curve_points - 1));
        const log_f = log_f_min + t * (log_f_max - log_f_min);
        xs[i] = log_f;
        ys[i] = std.math.clamp(eq.responseDb(std.math.pow(f64, 10.0, log_f)), db_min, db_max);
    }

    var x_axis = dvui.PlotWidget.Axis{
        .min = log_f_min,
        .max = log_f_max,
        .ticks = .{ .locations = .{ .custom = &tick_locations }, .side = .left_or_top },
        .gridline_color = theme.grid,
    };
    var y_axis = dvui.PlotWidget.Axis{
        .min = db_min,
        .max = db_max,
        .ticks = .{ .locations = .{ .custom = &db_ticks } },
        .gridline_color = theme.grid,
    };

    dvui.plotXY(@src(), .{
        .plot_opts = .{ .x_axis = &x_axis, .y_axis = &y_axis, .spine_color = theme.grid },
        .thick = 1.5,
        .color = theme.accent,
        .xs = &xs,
        .ys = &ys,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 120 },
        .color_fill = theme.bg,
        .background = true,
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = tokens.gap_tight },
        .id_extra = id_extra,
    });
}

const tick_locations = [_]f64{
    @log10(20.0),    @log10(100.0),  @log10(1000.0),
    @log10(10000.0), @log10(20000.0),
};
const db_ticks = [_]f64{ -24, -12, 0, 12, 24 };

fn drawBandChips(eq: *const eq_dsp.Equalizer, band_count: usize, slot: usize, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .id_extra = id_extra,
    });
    defer row.deinit();

    for (0..band_count) |b| {
        const col = band_colors[b % band_colors.len];
        const is_selected = selected_band[slot] == b;
        const enabled = eq.bands[b].enabled;
        const fill = if (is_selected)
            col
        else if (enabled)
            theme.colorFA(col.r, col.g, col.b, 150)
        else
            theme.cell;

        var label_buf: [8]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "B{d}", .{b + 1}) catch "B";
        if (dvui.button(@src(), label, .{}, .{
            .expand = .horizontal,
            .color_fill = fill,
            .color_text = if (is_selected or enabled) theme.bg else theme.text_dim,
            .min_size_content = .{ .h = tokens.control_h },
            .corners = .round(tokens.radius_sm),
            .margin = .{ .x = if (b == 0) 0 else tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
            .id_extra = id_extra * 16 + b,
        })) {
            selected_band[slot] = b;
        }
    }
}

const band_type_names = [_][]const u8{
    "High Pass", "Low Pass", "Band Pass", "High Shelf", "Low Shelf", "Bell", "Notch",
};

fn drawBandControls(ctx: Ctx, eq: *const eq_dsp.Equalizer, band: usize, id_extra: usize) void {
    if (band >= eq_dsp.max_bands) return;
    const base = builtin_params.eqBandBase(band);

    var title_buf: [16]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Band {d}", .{band + 1}) catch "Band";
    controls.section(title, id_extra + 20);

    toggleById(ctx, base + 4, id_extra + 21, "On");
    choiceById(ctx, base + 0, &band_type_names, id_extra + 22, "Type");
    sliderById(ctx, base + 1, id_extra + 23, "Freq");
    if (eq_dsp.bandHasGain(eq.bands[band].type)) {
        sliderById(ctx, base + 2, id_extra + 24, "Boost");
    } else {
        dvui.label(@src(), "Boost n/a for this band type", .{}, .{
            .color_text = theme.text_soft,
            .id_extra = id_extra + 24,
        });
    }
    sliderById(ctx, base + 3, id_extra + 25, "Q");
}

// ── id-addressed helpers ────────────────────────────────────────────────────

fn paramValue(ctx: Ctx, param_id: u32) ?f64 {
    const index = ctx.indexOfId(param_id) orelse return null;
    var info = ctx.infoAt(index) orelse return null;
    return ctx.value(&info);
}

fn sliderById(ctx: Ctx, param_id: u32, id_extra: usize, label: []const u8) void {
    const index = ctx.indexOfId(param_id) orelse return;
    controls.slider(ctx, index, id_extra, label);
}

fn toggleById(ctx: Ctx, param_id: u32, id_extra: usize, label: []const u8) void {
    const index = ctx.indexOfId(param_id) orelse return;
    controls.toggle(ctx, index, id_extra, label);
}

fn choiceById(ctx: Ctx, param_id: u32, items: []const []const u8, id_extra: usize, label: []const u8) void {
    const index = ctx.indexOfId(param_id) orelse return;
    controls.choice(ctx, index, items, id_extra, label, 0);
}
