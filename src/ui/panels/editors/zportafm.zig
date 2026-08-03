//! DVUI editor for the ZPortaFM (YM2413) built-in — port of its zgui view.
//!
//! Left column: voice selection + performance + patch globals. Right column:
//! the modulator and carrier operators. In preset-instrument mode the patch
//! controls are inert on the DSP side, so they are shown greyed with a hint
//! instead of being editable.

const std = @import("std");
const dvui = @import("dvui");
const clap = @import("clap-bindings");

const theme = @import("../../theme.zig");
const tokens = @import("../../tokens.zig");
const controls = @import("controls.zig");

const Plugin = @import("../../../builtins/instruments/zportafm/plugin.zig").Plugin;
const Params = @import("../../../builtins/instruments/zportafm/ext/params.zig");

const Parameter = Params.Parameter;
const Ctx = controls.Ctx;

pub fn cardWidth() f32 {
    return tokens.device_w_zportafm;
}

fn idx(param: Parameter) u32 {
    return @intFromEnum(param);
}

pub fn draw(plugin: *const clap.Plugin, target: controls.Target, id_extra: usize) void {
    const ctx = Ctx.init(plugin, target) orelse return;
    // In-process built-in: the typed instance supplies the bank's program names.
    const typed = Plugin.fromClapPlugin(plugin);
    const preset_mode = (paramValue(ctx, .VoiceMode) orelse 0) >= 0.5;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .id_extra = id_extra,
    });
    defer row.deinit();

    {
        var left = controls.column(@src(), id_extra, true);
        defer left.deinit();

        controls.section("Voice", id_extra + 1);
        controls.choice(ctx, idx(.VoiceMode), &Params.mode_names, id_extra + 2, "Mode", 0);
        controls.choice(ctx, idx(.Bank), &Params.bank_names, id_extra + 3, "Bank", 0);
        // Instrument is 1-based in the param range.
        controls.choice(ctx, idx(.Instrument), Params.instrumentNames(typed), id_extra + 4, "Instrument", 1);

        controls.section("Performance", id_extra + 5);
        controls.slider(ctx, idx(.PitchWheelRange), id_extra + 6, "Pitch Wheel");
        controls.slider(ctx, idx(.FineTune), id_extra + 7, "Fine Tune");
        controls.slider(ctx, idx(.OutputLevel), id_extra + 8, "Output");

        controls.section("Patch Global", id_extra + 9);
        if (preset_mode) {
            presetHint(id_extra + 10);
        } else {
            controls.slider(ctx, idx(.Feedback), id_extra + 11, "Feedback");
            controls.slider(ctx, idx(.ModLevel), id_extra + 12, "Mod Level");
        }
    }

    {
        var right = controls.column(@src(), id_extra + 100, false);
        defer right.deinit();

        if (preset_mode) {
            controls.section("Operators", id_extra + 13);
            presetHint(id_extra + 14);
            return;
        }

        controls.section("Modulator", id_extra + 15);
        controls.slider(ctx, idx(.ModAttack), id_extra + 16, "Attack");
        controls.slider(ctx, idx(.ModDecay), id_extra + 17, "Decay");
        controls.slider(ctx, idx(.ModSustain), id_extra + 18, "Sustain");
        controls.slider(ctx, idx(.ModRelease), id_extra + 19, "Release");
        controls.slider(ctx, idx(.ModMultiplier), id_extra + 20, "Multiplier");
        controls.toggle(ctx, idx(.ModWave), id_extra + 21, "Half Wave");
        controls.toggle(ctx, idx(.ModTremolo), id_extra + 22, "Tremolo");
        controls.toggle(ctx, idx(.ModVibrato), id_extra + 23, "Vibrato");

        controls.section("Carrier", id_extra + 24);
        controls.slider(ctx, idx(.CarAttack), id_extra + 25, "Attack");
        controls.slider(ctx, idx(.CarDecay), id_extra + 26, "Decay");
        controls.slider(ctx, idx(.CarSustain), id_extra + 27, "Sustain");
        controls.slider(ctx, idx(.CarRelease), id_extra + 28, "Release");
        controls.slider(ctx, idx(.CarMultiplier), id_extra + 29, "Multiplier");
        controls.toggle(ctx, idx(.CarWave), id_extra + 30, "Half Wave");
        controls.toggle(ctx, idx(.CarTremolo), id_extra + 31, "Tremolo");
        controls.toggle(ctx, idx(.CarVibrato), id_extra + 32, "Vibrato");
    }
}

fn presetHint(id_extra: usize) void {
    dvui.label(@src(), "Preset instrument — switch Mode to Custom Patch to edit.", .{}, .{
        .color_text = theme.text_soft,
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        .id_extra = id_extra,
    });
}

fn paramValue(ctx: Ctx, param: Parameter) ?f64 {
    var info = ctx.infoAt(idx(param)) orelse return null;
    return ctx.value(&info);
}
