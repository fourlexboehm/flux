//! DVUI editor for the ZMinimoog (WDF ladder) built-in — port of its zgui view.
//!
//! Left column: the three oscillators + noise. Right column: filter,
//! modulation routing, envelope and the performance controllers.

const std = @import("std");
const dvui = @import("dvui");
const clap = @import("clap-bindings");

const tokens = @import("../../tokens.zig");
const controls = @import("controls.zig");

const Params = @import("../../../builtins/instruments/zminimoog/ext/params.zig");

const Parameter = Params.Parameter;
const Ctx = controls.Ctx;

const waveform_names = [_][]const u8{
    "Triangle", "Shark", "Sawtooth", "Square", "Wide Pulse", "Narrow Pulse",
};
const range_names = [_][]const u8{ "LO", "32'", "16'", "8'", "4'", "2'" };
const noise_names = [_][]const u8{ "White", "Pink" };
const key_tracking_names = [_][]const u8{ "Off", "Half", "Full" };

pub fn cardWidth() f32 {
    return tokens.device_w_zminimoog;
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
        controls.slider(ctx, idx(.Osc1Level), id_extra + 2, "Level");
        controls.choice(ctx, idx(.Osc1Waveform), &waveform_names, id_extra + 3, "Wave", 0);
        controls.choice(ctx, idx(.Osc1Range), &range_names, id_extra + 4, "Range", 0);

        controls.section("Oscillator 2", id_extra + 5);
        controls.slider(ctx, idx(.Osc2Level), id_extra + 6, "Level");
        controls.choice(ctx, idx(.Osc2Waveform), &waveform_names, id_extra + 7, "Wave", 0);
        controls.choice(ctx, idx(.Osc2Range), &range_names, id_extra + 8, "Range", 0);
        controls.slider(ctx, idx(.Osc2Detune), id_extra + 9, "Detune");

        controls.section("Oscillator 3", id_extra + 10);
        controls.slider(ctx, idx(.Osc3Level), id_extra + 11, "Level");
        controls.choice(ctx, idx(.Osc3Waveform), &waveform_names, id_extra + 12, "Wave", 0);
        controls.choice(ctx, idx(.Osc3Range), &range_names, id_extra + 13, "Range", 0);
        controls.slider(ctx, idx(.Osc3Detune), id_extra + 14, "Detune");
        controls.toggle(ctx, idx(.Osc3KeyboardCtrl), id_extra + 15, "Keyboard Ctrl");

        controls.section("Noise", id_extra + 16);
        controls.slider(ctx, idx(.NoiseLevel), id_extra + 17, "Level");
        controls.choice(ctx, idx(.NoiseType), &noise_names, id_extra + 18, "Type", 0);
    }

    {
        var right = controls.column(@src(), id_extra + 100, false);
        defer right.deinit();

        controls.section("Filter", id_extra + 19);
        controls.slider(ctx, idx(.FilterCutoff), id_extra + 20, "Cutoff");
        controls.slider(ctx, idx(.FilterEmphasis), id_extra + 21, "Emphasis");
        controls.slider(ctx, idx(.FilterContour), id_extra + 22, "Contour");
        controls.choice(ctx, idx(.FilterKeyTracking), &key_tracking_names, id_extra + 23, "Key Track", 0);

        controls.section("Modulation", id_extra + 24);
        controls.toggle(ctx, idx(.Osc3ToFilter), id_extra + 25, "Osc3 > Filter");
        controls.toggle(ctx, idx(.Osc3ToOsc), id_extra + 26, "Osc3 > Osc");

        controls.section("Envelope", id_extra + 27);
        controls.slider(ctx, idx(.Attack), id_extra + 28, "Attack");
        controls.slider(ctx, idx(.Decay), id_extra + 29, "Decay");
        controls.slider(ctx, idx(.Sustain), id_extra + 30, "Sustain");
        controls.slider(ctx, idx(.Release), id_extra + 31, "Release");

        controls.section("Controllers", id_extra + 32);
        controls.slider(ctx, idx(.Glide), id_extra + 33, "Glide");
        controls.slider(ctx, idx(.PitchBendRange), id_extra + 34, "Bend Range");
        controls.slider(ctx, idx(.MasterVolume), id_extra + 35, "Volume");
    }
}
