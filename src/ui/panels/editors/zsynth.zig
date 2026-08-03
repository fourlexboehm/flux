//! DVUI editor for the ZSynth built-in (port of its zgui view).
//!
//! Two columns: oscillators + envelope on the left, filter + a live waveform
//! preview on the right. Parameters are addressed by their `Parameter` enum
//! index (ZSynth exposes `id == index`), so the layout stays compile-time
//! checked against the plugin's own enum.

const std = @import("std");
const dvui = @import("dvui");
const clap = @import("clap-bindings");

const theme = @import("../../theme.zig");
const tokens = @import("../../tokens.zig");
const controls = @import("controls.zig");

const Params = @import("../../../builtins/instruments/zsynth/ext/params.zig");
const polyblep = @import("../../../builtins/instruments/zsynth/audio/polyblep.zig");
const waves = @import("../../../builtins/instruments/zsynth/audio/waves.zig");

const Parameter = Params.Parameter;
const Ctx = controls.Ctx;

const wave_names = [_][]const u8{ "Sine", "Saw", "Tri", "Sqr" };
const filter_names = [_][]const u8{ "LP", "HP", "BP" };

const preview_points: usize = 192;
/// Preview key (A3) — matches the diagnostic voice the zgui view used.
const preview_key: f64 = 57;

pub fn cardWidth() f32 {
    return tokens.device_w_zsynth;
}

fn idx(param: Parameter) u32 {
    return @intFromEnum(param);
}

pub fn draw(plugin: *const clap.Plugin, target: controls.Target, id_extra: usize) void {
    const ctx = Ctx.init(plugin, target) orelse return;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .id_extra = id_extra,
    });
    defer row.deinit();

    {
        var left = controls.column(@src(), id_extra, true);
        defer left.deinit();

        controls.section("Oscillator 1", id_extra + 1);
        controls.steps(ctx, idx(.WaveShape1), &wave_names, id_extra + 2, "Wave");
        controls.slider(ctx, idx(.Octave1), id_extra + 3, "Octave");
        controls.slider(ctx, idx(.Pitch1), id_extra + 4, "Detune");

        controls.section("Oscillator 2", id_extra + 5);
        controls.steps(ctx, idx(.WaveShape2), &wave_names, id_extra + 6, "Wave");
        controls.slider(ctx, idx(.Octave2), id_extra + 7, "Octave");
        controls.slider(ctx, idx(.Pitch2), id_extra + 8, "Detune");
        controls.slider(ctx, idx(.Mix), id_extra + 9, "Osc 1/2 Mix");

        controls.section("Voice Envelope", id_extra + 10);
        controls.slider(ctx, idx(.Attack), id_extra + 11, "Attack");
        controls.slider(ctx, idx(.Decay), id_extra + 12, "Decay");
        controls.slider(ctx, idx(.Sustain), id_extra + 13, "Sustain");
        controls.slider(ctx, idx(.Release), id_extra + 14, "Release");
    }

    {
        var right = controls.column(@src(), id_extra + 100, false);
        defer right.deinit();

        controls.section("Filter", id_extra + 15);
        controls.toggle(ctx, idx(.FilterEnable), id_extra + 16, "Enabled");
        controls.steps(ctx, idx(.FilterType), &filter_names, id_extra + 17, "Type");
        controls.slider(ctx, idx(.FilterFreq), id_extra + 18, "Cutoff");
        controls.slider(ctx, idx(.FilterQ), id_extra + 19, "Resonance");

        controls.section("Options", id_extra + 20);
        controls.toggle(ctx, idx(.ScaleVoices), id_extra + 21, "Scale Voices");

        controls.section("Oscillator Mix", id_extra + 22);
        drawWavePreview(ctx, id_extra + 23);
    }
}

/// Mixed oscillator waveform, generated the same way the voice does so the
/// preview tracks wave shape, octave, detune and mix.
fn drawWavePreview(ctx: Ctx, id_extra: usize) void {
    const sample_rate: f64 = 48000;

    const osc1_wave = waveAt(ctx, .WaveShape1);
    const osc2_wave = waveAt(ctx, .WaveShape2);
    const mix: f64 = std.math.clamp(paramValue(ctx, .Mix) orelse 0, 0, 1);

    const key1 = tunedKey(paramValue(ctx, .Pitch1) orelse 0, paramValue(ctx, .Octave1) orelse 0);
    const key2 = tunedKey(paramValue(ctx, .Pitch2) orelse 0, paramValue(ctx, .Octave2) orelse 0);

    var osc1 = polyblep.PolyBLEP.init(sample_rate, osc1_wave, waves.getFrequency(key1), 0.0);
    var osc2 = polyblep.PolyBLEP.init(sample_rate, osc2_wave, waves.getFrequency(key2), 0.0);

    var xs: [preview_points]f64 = undefined;
    var ys: [preview_points]f64 = undefined;
    for (0..preview_points) |i| {
        const a = osc1.getAndInc();
        const b = osc2.getAndInc();
        xs[i] = @floatFromInt(i);
        ys[i] = std.math.clamp(a * (1 - mix) + b * mix, -1.2, 1.2);
    }

    var x_axis = dvui.PlotWidget.Axis{
        .min = 0,
        .max = @floatFromInt(preview_points - 1),
        .ticks = .{ .locations = .none },
    };
    var y_axis = dvui.PlotWidget.Axis{ .min = -1.2, .max = 1.2, .ticks = .{ .locations = .none } };

    dvui.plotXY(@src(), .{
        .plot_opts = .{ .x_axis = &x_axis, .y_axis = &y_axis, .spine_color = theme.grid },
        .thick = 1.5,
        .color = theme.accent,
        .xs = &xs,
        .ys = &ys,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 90 },
        .background = true,
        .color_fill = theme.bg,
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        .id_extra = id_extra,
    });
}

fn tunedKey(detune_semis: f64, octave: f64) f64 {
    return preview_key + detune_semis + octave * 12.0;
}

fn waveAt(ctx: Ctx, param: Parameter) polyblep.Waveform {
    const raw = paramValue(ctx, param) orelse 0;
    const tag: usize = @intFromFloat(std.math.clamp(@round(raw), 0, 3));
    return switch (@as(waves.Wave, @enumFromInt(tag))) {
        .Sine => .Sine,
        .Saw => .Saw,
        .Triangle => .Triangle,
        .Square => .Square,
    };
}

fn paramValue(ctx: Ctx, param: Parameter) ?f64 {
    var info = ctx.infoAt(idx(param)) orelse return null;
    return ctx.value(&info);
}
