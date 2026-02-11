const std = @import("std");
const clap = @import("clap-bindings");
const zgui = @import("zgui");

const Params = @import("../params.zig");
const Plugin = @import("../../plugin.zig");

pub const DrawOptions = struct {
    notify_host: bool = true,
    show_title: bool = true,
};

pub fn drawWindow(plugin: *Plugin) void {
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    const display_size = zgui.io.getDisplaySize();
    zgui.setNextWindowSize(.{ .w = display_size[0], .h = display_size[1], .cond = .always });

    if (zgui.begin(
        "ZOB-X",
        .{
            .flags = .{
                .no_collapse = true,
                .no_move = true,
                .no_resize = true,
                .no_title_bar = true,
                .always_auto_resize = true,
            },
        },
    )) {
        drawContent(plugin, .{});
    }
    zgui.end();
}

pub fn drawEmbedded(plugin: *Plugin, options: DrawOptions) void {
    drawContent(plugin, options);
}

fn drawContent(plugin: *Plugin, options: DrawOptions) void {
    if (options.show_title) {
        zgui.text("ZOB-X", .{});
    }

    if (plugin.sample_rate == null) {
        zgui.textUnformatted("Synth engine inactive.");
        return;
    }

    const avail = zgui.getContentRegionAvail();
    const col_width = avail[0] / 3.0 - 8;

    // Left Column: Oscillators, Mixer
    if (zgui.beginChild("LeftColumn", .{ .w = col_width, .h = 0 })) {
        zgui.separatorText("Oscillator 1");
        renderToggle(plugin, .Osc1Saw, "Saw", options);
        renderToggle(plugin, .Osc1Pulse, "Pulse", options);
        renderParam(plugin, .Osc1Pitch, options);
        renderParam(plugin, .Osc1Volume, options);

        zgui.separatorText("Oscillator 2");
        renderToggle(plugin, .Osc2Saw, "Saw", options);
        renderToggle(plugin, .Osc2Pulse, "Pulse", options);
        renderParam(plugin, .Osc2Pitch, options);
        renderParam(plugin, .Osc2Detune, options);
        renderParam(plugin, .Osc2Volume, options);

        zgui.separatorText("Oscillators");
        renderParam(plugin, .PulseWidth, options);
        renderToggle(plugin, .OscSync, "Osc Sync", options);
        renderParam(plugin, .Crossmod, options);
        renderParam(plugin, .OscBrightness, options);

        zgui.separatorText("Noise");
        renderParam(plugin, .NoiseVolume, options);
        renderParam(plugin, .NoiseColor, options);

        zgui.separatorText("Ring Mod");
        renderParam(plugin, .RingModVolume, options);
    }
    zgui.endChild();

    zgui.sameLine(.{});

    // Middle Column: Filter, Envelopes
    if (zgui.beginChild("MiddleColumn", .{ .w = col_width, .h = 0 })) {
        zgui.separatorText("Filter");
        renderParam(plugin, .FilterCutoff, options);
        renderParam(plugin, .FilterResonance, options);
        renderParam(plugin, .FilterMode, options);
        renderToggle(plugin, .Filter4Pole, "4-Pole", options);
        renderToggle(plugin, .FilterBPBlend, "BP Blend", options);
        renderToggle(plugin, .FilterXpander, "Xpander", options);
        renderCombo(plugin, .FilterXpanderMode, &.{
            "LP4", "LP3", "LP2", "LP1", "BP4", "BP2", "HP4", "HP3", "HP2", "HP1", "N4", "N3", "N2", "AP4", "AP3",
        }, options);
        renderParam(plugin, .FilterEnvAmount, options);
        renderToggle(plugin, .FilterEnvInvert, "Env Invert", options);
        renderParam(plugin, .FilterKeyTrack, options);
        renderToggle(plugin, .Filter2PolePush, "2-Pole Push", options);

        zgui.separatorText("Amp Envelope");
        renderParam(plugin, .AmpAttack, options);
        renderParam(plugin, .AmpDecay, options);
        renderParam(plugin, .AmpSustain, options);
        renderParam(plugin, .AmpRelease, options);
        renderParam(plugin, .AmpAttackCurve, options);

        zgui.separatorText("Filter Envelope");
        renderParam(plugin, .FilterAttack, options);
        renderParam(plugin, .FilterDecay, options);
        renderParam(plugin, .FilterSustain, options);
        renderParam(plugin, .FilterRelease, options);
        renderParam(plugin, .FilterAttackCurve, options);
    }
    zgui.endChild();

    zgui.sameLine(.{});

    // Right Column: LFOs, Performance, Env Mod, Slop, Vibrato, Quality
    if (zgui.beginChild("RightColumn", .{ .w = col_width, .h = 0 })) {
        zgui.separatorText("LFO 1 (Global)");
        renderParam(plugin, .LFO1Rate, options);
        renderToggle(plugin, .LFO1Sync, "Tempo Sync", options);
        renderParam(plugin, .LFO1Wave1, options);
        renderParam(plugin, .LFO1Wave2, options);
        renderParam(plugin, .LFO1Wave3, options);
        renderParam(plugin, .LFO1PW, options);
        renderParam(plugin, .LFO1ModAmt1, options);
        renderParam(plugin, .LFO1ModAmt2, options);
        renderTriState(plugin, .LFO1ToOsc1Pitch, "LFO1 > Osc1 Pitch", options);
        renderTriState(plugin, .LFO1ToOsc2Pitch, "LFO1 > Osc2 Pitch", options);
        renderTriState(plugin, .LFO1ToCutoff, "LFO1 > Cutoff", options);
        renderTriState(plugin, .LFO1ToOsc1PW, "LFO1 > Osc1 PW", options);
        renderTriState(plugin, .LFO1ToOsc2PW, "LFO1 > Osc2 PW", options);
        renderTriState(plugin, .LFO1ToVolume, "LFO1 > Volume", options);

        zgui.separatorText("LFO 2 (Per-Voice)");
        renderParam(plugin, .LFO2Rate, options);
        renderToggle(plugin, .LFO2Sync, "Tempo Sync", options);
        renderParam(plugin, .LFO2Wave1, options);
        renderParam(plugin, .LFO2Wave2, options);
        renderParam(plugin, .LFO2Wave3, options);
        renderParam(plugin, .LFO2PW, options);
        renderParam(plugin, .LFO2ModAmt1, options);
        renderParam(plugin, .LFO2ModAmt2, options);
        renderTriState(plugin, .LFO2ToOsc1Pitch, "LFO2 > Osc1 Pitch", options);
        renderTriState(plugin, .LFO2ToOsc2Pitch, "LFO2 > Osc2 Pitch", options);
        renderTriState(plugin, .LFO2ToCutoff, "LFO2 > Cutoff", options);
        renderTriState(plugin, .LFO2ToOsc1PW, "LFO2 > Osc1 PW", options);
        renderTriState(plugin, .LFO2ToOsc2PW, "LFO2 > Osc2 PW", options);
        renderTriState(plugin, .LFO2ToVolume, "LFO2 > Volume", options);

        zgui.separatorText("Env Modulation");
        renderParam(plugin, .EnvToPitchAmt, options);
        renderToggle(plugin, .EnvToPitchInvert, "Pitch Invert", options);
        renderToggle(plugin, .EnvToPitchBothOscs, "Pitch Both Oscs", options);
        renderParam(plugin, .EnvToPWAmt, options);
        renderToggle(plugin, .EnvToPWInvert, "PW Invert", options);
        renderToggle(plugin, .EnvToPWBothOscs, "PW Both Oscs", options);

        zgui.separatorText("Performance");
        renderParam(plugin, .Volume, options);
        renderParam(plugin, .Portamento, options);
        renderParam(plugin, .Tune, options);
        renderParam(plugin, .Transpose, options);
        renderToggle(plugin, .Unison, "Unison", options);
        renderParam(plugin, .UnisonDetune, options);
        renderParam(plugin, .BendUpRange, options);
        renderParam(plugin, .BendDownRange, options);
        renderToggle(plugin, .BendOsc2Only, "Bend Osc2 Only", options);
        renderParam(plugin, .VelToAmp, options);
        renderParam(plugin, .VelToFilter, options);
        renderTriStateCombo(plugin, .NotePriority, "Note Priority", &.{ "Latest", "Lowest", "Highest" }, options);
        renderQuadCombo(plugin, .EnvLegatoMode, "Legato Mode", &.{ "Off", "Amp", "Filter", "Both" }, options);

        zgui.separatorText("Slop (Analog Character)");
        renderParam(plugin, .EnvSlop, options);
        renderParam(plugin, .FilterSlop, options);
        renderParam(plugin, .PortamentoSlop, options);
        renderParam(plugin, .LevelSlop, options);

        zgui.separatorText("Vibrato");
        renderParam(plugin, .VibratoRate, options);
        renderCombo(plugin, .VibratoWave, &.{ "Sine", "Square" }, options);

        zgui.separatorText("Quality");
        renderToggle(plugin, .HQMode, "HQ Mode", options);
    }
    zgui.endChild();
}

fn renderParam(plugin: *Plugin, param: Params.Parameter, options: DrawOptions) void {
    const index: u32 = @intFromEnum(param);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&plugin.plugin, index, &info)) {
        return;
    }

    var val: f32 = @floatCast(plugin.params.get(param).Float);
    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const name = std.mem.sliceTo(&info.name, 0);
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{name}) catch return;

    var text_buf: [256]u8 = [_]u8{0} ** 256;
    _ = Params._valueToText(&plugin.plugin, @enumFromInt(index), val, &text_buf, 256);

    if (zgui.sliderFloat(label, .{
        .v = &val,
        .min = @floatCast(info.min_value),
        .max = @floatCast(info.max_value),
        .cfmt = text_buf[0..255 :0],
    })) {
        plugin.params.set(param, .{ .Float = @floatCast(val) }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}

fn renderCombo(plugin: *Plugin, param: Params.Parameter, items: []const []const u8, options: DrawOptions) void {
    const index: u32 = @intFromEnum(param);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&plugin.plugin, index, &info)) {
        return;
    }

    const val: f32 = @floatCast(plugin.params.get(param).Float);
    var current: i32 = @intFromFloat(@round(@max(0.0, @min(@as(f32, @floatFromInt(items.len - 1)), val))));

    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const name = std.mem.sliceTo(&info.name, 0);
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{name}) catch return;

    // Build items array for combo
    var item_ptrs: [16][*:0]const u8 = undefined;
    for (items, 0..) |item, i| {
        if (i >= 16) break;
        item_ptrs[i] = @ptrCast(item.ptr);
    }

    if (zgui.combo(label, .{
        .current_item = &current,
        .items_separated_by_zeros = blk: {
            // Build null-separated string
            var buf: [512]u8 = [_]u8{0} ** 512;
            var pos: usize = 0;
            for (items) |item| {
                if (pos + item.len + 1 >= buf.len) break;
                @memcpy(buf[pos..][0..item.len], item);
                pos += item.len + 1; // include null separator
            }
            break :blk buf[0..pos :0];
        },
    })) {
        plugin.params.set(param, .{ .Float = @floatFromInt(current) }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}

fn renderToggle(plugin: *Plugin, param: Params.Parameter, label_text: []const u8, options: DrawOptions) void {
    const val: f32 = @floatCast(plugin.params.get(param).Float);
    var enabled: bool = val >= 0.5;

    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{label_text}) catch return;

    if (zgui.checkbox(label, .{ .v = &enabled })) {
        plugin.params.set(param, .{ .Float = if (enabled) 1.0 else 0.0 }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}

fn renderTriState(plugin: *Plugin, param: Params.Parameter, label_text: []const u8, options: DrawOptions) void {
    const val: f32 = @floatCast(plugin.params.get(param).Float);
    var current: i32 = if (val < 0.25) 0 else if (val < 0.75) 1 else 2;

    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{label_text}) catch return;

    if (zgui.combo(label, .{
        .current_item = &current,
        .items_separated_by_zeros = "Off\x00+\x00-\x00",
    })) {
        const new_val: f32 = switch (current) {
            0 => 0.0,
            1 => 0.5,
            2 => 1.0,
            else => 0.0,
        };
        plugin.params.set(param, .{ .Float = @floatCast(new_val) }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}

fn renderTriStateCombo(plugin: *Plugin, param: Params.Parameter, label_text: []const u8, items: []const []const u8, options: DrawOptions) void {
    const val: f32 = @floatCast(plugin.params.get(param).Float);
    var current: i32 = if (val < 0.25) 0 else if (val < 0.75) 1 else 2;

    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{label_text}) catch return;

    if (zgui.combo(label, .{
        .current_item = &current,
        .items_separated_by_zeros = blk: {
            var buf: [512]u8 = [_]u8{0} ** 512;
            var pos: usize = 0;
            for (items) |item| {
                if (pos + item.len + 1 >= buf.len) break;
                @memcpy(buf[pos..][0..item.len], item);
                pos += item.len + 1;
            }
            break :blk buf[0..pos :0];
        },
    })) {
        const new_val: f32 = switch (current) {
            0 => 0.0,
            1 => 0.5,
            2 => 1.0,
            else => 0.0,
        };
        plugin.params.set(param, .{ .Float = @floatCast(new_val) }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}

fn renderQuadCombo(plugin: *Plugin, param: Params.Parameter, label_text: []const u8, items: []const []const u8, options: DrawOptions) void {
    const val: f32 = @floatCast(plugin.params.get(param).Float);
    var current: i32 = if (val < 0.125) 0 else if (val < 0.375) 1 else if (val < 0.625) 2 else 3;

    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{label_text}) catch return;

    if (zgui.combo(label, .{
        .current_item = &current,
        .items_separated_by_zeros = blk: {
            var buf: [512]u8 = [_]u8{0} ** 512;
            var pos: usize = 0;
            for (items) |item| {
                if (pos + item.len + 1 >= buf.len) break;
                @memcpy(buf[pos..][0..item.len], item);
                pos += item.len + 1;
            }
            break :blk buf[0..pos :0];
        },
    })) {
        const new_val: f32 = switch (current) {
            0 => 0.0,
            1 => 0.33,
            2 => 0.66,
            3 => 1.0,
            else => 0.0,
        };
        plugin.params.set(param, .{ .Float = @floatCast(new_val) }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}
