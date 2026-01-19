const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap-bindings");
const zgui = @import("zgui");

const Params = @import("../params.zig");
const Plugin = @import("../../plugin.zig");
const Undo = @import("../undo.zig");

const polyblep = @import("../../audio/polyblep.zig");
const waves = @import("../../audio/waves.zig");
const voices = @import("../../audio/voices.zig");
const Voice = voices.Voice;
const Wave = waves.Wave;
const Filter = @import("../../audio/filter.zig").FilterType;

pub const DrawOptions = struct {
    notify_host: bool = true,
    show_title: bool = true,
};

fn polyblepWaveform(wave: Wave) polyblep.Waveform {
    return switch (wave) {
        .Sine => .Sine,
        .Saw => .Saw,
        .Triangle => .Triangle,
        .Square => .Square,
    };
}

pub fn drawWindow(plugin: *Plugin) void {
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    const display_size = zgui.io.getDisplaySize();
    zgui.setNextWindowSize(.{ .w = display_size[0], .h = display_size[1], .cond = .always });

    if (zgui.begin(
        "Tool window",
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
        zgui.text("ZSynth by juge", .{});
        zgui.sameLine(.{});
        zgui.text("Voices: {} / {}", .{ plugin.voices.getVoiceCount(), plugin.voices.getVoiceCapacity() });
    }

    if (plugin.sample_rate == null) {
        zgui.textUnformatted("Synth engine inactive.");
        return;
    }

    zgui.separatorText("Parameters##Sep");
    if (zgui.beginChild("Parameters##Child", .{
        .w = zgui.getContentRegionAvail()[0] * 0.5,
        .child_flags = .{},
        .window_flags = .{},
    })) {
        if (zgui.beginChild("Oscillator 1##Child", .{ .child_flags = .{
            .border = true,
            .auto_resize_y = true,
            .always_auto_resize = true,
        } })) {
            zgui.text("Oscillator 1", .{});
            zgui.sameLine(.{});
            renderMix(plugin, true, options);
            renderParam(plugin, Params.Parameter.WaveShape1, options);
            renderParam(plugin, Params.Parameter.Octave1, options);
            renderParam(plugin, Params.Parameter.Pitch1, options);
            zgui.endChild();
        }
        if (zgui.beginChild("Oscillator 2##Child", .{ .child_flags = .{
            .border = true,
            .auto_resize_y = true,
            .always_auto_resize = true,
        } })) {
            zgui.text("Oscillator 2", .{});
            zgui.sameLine(.{});
            renderMix(plugin, false, options);
            renderParam(plugin, Params.Parameter.WaveShape2, options);
            renderParam(plugin, Params.Parameter.Octave2, options);
            renderParam(plugin, Params.Parameter.Pitch2, options);
            zgui.endChild();
        }
        if (zgui.beginChild("ADSR##Child", .{ .child_flags = .{
            .border = true,
            .auto_resize_y = true,
            .always_auto_resize = true,
        } })) {
            zgui.text("Voice Envelope", .{});
            renderParam(plugin, Params.Parameter.Attack, options);
            renderParam(plugin, Params.Parameter.Decay, options);
            renderParam(plugin, Params.Parameter.Sustain, options);
            renderParam(plugin, Params.Parameter.Release, options);
            zgui.endChild();
        }
        if (zgui.beginChild("Options##Child", .{ .child_flags = .{
            .border = true,
            .auto_resize_y = true,
            .always_auto_resize = true,
        } })) {
            zgui.text("Options", .{});
            renderParam(plugin, Params.Parameter.ScaleVoices, options);
            if (builtin.mode == .Debug) {
                zgui.sameLine(.{});
                renderParam(plugin, Params.Parameter.DebugBool1, options);
                zgui.sameLine(.{});
                renderParam(plugin, Params.Parameter.DebugBool2, options);
            }
            zgui.endChild();
        }
        zgui.endChild();
    }
    zgui.sameLine(.{});
    if (zgui.beginChild("Display##Child", .{})) {
        if (zgui.beginChild("Filter##Child", .{ .child_flags = .{
            .border = true,
            .auto_resize_y = true,
            .always_auto_resize = true,
        } })) {
            zgui.text("Filter", .{});
            zgui.sameLine(.{});
            renderParam(plugin, Params.Parameter.FilterEnable, options);
            renderParam(plugin, Params.Parameter.FilterType, options);
            renderParam(plugin, Params.Parameter.FilterFreq, options);
            renderParam(plugin, Params.Parameter.FilterQ, options);
            zgui.endChild();
        }
        zgui.spacing();
        zgui.separatorText("Display##Sep");
        if (zgui.beginChild("Oscillators##Display", .{ .child_flags = .{
            .border = true,
            .auto_resize_y = true,
            .always_auto_resize = true,
        } })) {
            const resolution = 256;
            const sample_rate = plugin.sample_rate.?;
            var diag_voice = Voice.init(sample_rate);
            diag_voice.key = @enumFromInt(57);

            const osc1_wave_shape = plugin.params.get(.WaveShape1).Wave;
            const osc1_octave = plugin.params.get(.Octave1).Float;
            const osc1_detune = plugin.params.get(.Pitch1).Float;
            const osc2_wave_shape = plugin.params.get(.WaveShape2).Wave;
            const osc2_octave = plugin.params.get(.Octave2).Float;
            const osc2_detune = plugin.params.get(.Pitch2).Float;
            const oscillator_mix: f32 = @floatCast(plugin.params.get(.Mix).Float);

            var xv: [resolution]f32 = [_]f32{0} ** resolution;
            var osc1_yv: [resolution]f32 = [_]f32{0} ** resolution;
            var osc2_yv: [resolution]f32 = [_]f32{0} ** resolution;
            var sum_yv: [resolution]f32 = [_]f32{0} ** resolution;
            const osc1_key = diag_voice.getTunedKey(osc1_detune, osc1_octave);
            const osc2_key = diag_voice.getTunedKey(osc2_detune, osc2_octave);
            var osc1 = polyblep.PolyBLEP.init(sample_rate, polyblepWaveform(osc1_wave_shape), waves.getFrequency(osc1_key), 0.0);
            var osc2 = polyblep.PolyBLEP.init(sample_rate, polyblepWaveform(osc2_wave_shape), waves.getFrequency(osc2_key), 0.0);
            for (0..resolution) |i| {
                xv[i] = @floatFromInt(i);
                osc1_yv[i] = @floatCast(osc1.getAndInc());
                osc2_yv[i] = @floatCast(osc2.getAndInc());
                sum_yv[i] = osc1_yv[i] + osc2_yv[i];
                sum_yv[i] = (osc1_yv[i] * (1 - oscillator_mix)) + (osc2_yv[i] * oscillator_mix);
            }

            if (zgui.plot.beginPlot("Wave Form##Plot", .{
                .flags = .{
                    .no_box_select = true,
                    .no_mouse_text = true,
                    .no_inputs = true,
                    .no_legend = true,
                    .no_menus = true,
                    .no_frame = true,
                },
                .h = 200,
            })) {
                zgui.plot.setupAxis(.x1, .{ .flags = .{
                    .no_label = true,
                    .no_tick_labels = true,
                    .no_tick_marks = true,
                } });
                zgui.plot.setupAxis(.y1, .{ .flags = .{
                    .no_label = true,
                    .no_tick_labels = true,
                    .no_tick_marks = true,
                    .auto_fit = true,
                } });
                zgui.plot.plotLine("Both", f32, .{
                    .xv = &xv,
                    .yv = &sum_yv,
                });
                zgui.plot.endPlot();
            }
            zgui.endChild();
        }
        zgui.endChild();
    }
}

fn renderParam(plugin: *Plugin, param: Params.Parameter, options: DrawOptions) void {
    const index: u32 = @intFromEnum(param);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&plugin.plugin, index, &info)) {
        return;
    }

    const param_type = std.enums.fromInt(Params.Parameter, index) orelse {
        std.debug.panic("Unable to cast index to parameter enum! {d}", .{index});
        return;
    };

    const name = std.mem.sliceTo(&info.name, 0);
    const value_text: [:0]u8 = info.name[0..name.len :0];
    switch (param_type) {
        .Attack,
        .Release,
        .Decay,
        .Pitch1,
        .Pitch2,
        .FilterFreq,
        .FilterQ,
        => {
            var val: f32 = @floatCast(plugin.params.get(param_type).Float);
            var param_text_buf: [256]u8 = [_]u8{0} ** 256;
            _ = Params._valueToText(&plugin.plugin, @enumFromInt(index), val, &param_text_buf, 256);
            if (zgui.sliderFloat(
                value_text,
                .{
                    .v = &val,
                    .min = @floatCast(info.min_value),
                    .max = @floatCast(info.max_value),
                    .cfmt = param_text_buf[0..255 :0],
                    .flags = .{
                        .logarithmic = param_type == .FilterFreq,
                    },
                },
            )) {
                plugin.params.set(param_type, .{ .Float = @as(f64, @floatCast(val)) }, .{
                    .should_notify_host = options.notify_host,
                }) catch return;
                if (!options.notify_host) {
                    plugin.applyParamChanges(false);
                }
            }
            // Undo support: track slider drag start/end
            if (zgui.isItemActivated()) {
                Undo.beginChange();
            }
            if (zgui.isItemDeactivated()) {
                Undo.changeMade(value_text);
            }
        },
        .Sustain, .Mix => {
            var val: f32 = @floatCast(plugin.params.get(param_type).Float);
            var param_text_buf: [256]u8 = [_]u8{0} ** 256;
            _ = Params._valueToText(&plugin.plugin, @enumFromInt(index), val, &param_text_buf, 256);
            if (std.mem.indexOf(u8, &param_text_buf, "%")) |percent_index| {
                if (percent_index < 255) {
                    param_text_buf[percent_index + 1] = '%';
                }
            }
            if (zgui.sliderFloat(
                value_text,
                .{
                    .v = &val,
                    .min = @floatCast(info.min_value),
                    .max = @floatCast(info.max_value),
                    .cfmt = param_text_buf[0..255 :0],
                },
            )) {
                plugin.params.set(param_type, .{ .Float = @as(f64, @floatCast(val)) }, .{
                    .should_notify_host = options.notify_host,
                }) catch return;
                if (!options.notify_host) {
                    plugin.applyParamChanges(false);
                }
            }
            // Undo support
            if (zgui.isItemActivated()) {
                Undo.beginChange();
            }
            if (zgui.isItemDeactivated()) {
                Undo.changeMade(value_text);
            }
        },
        .Octave1, .Octave2 => {
            const val_float: f32 = @floatCast(plugin.params.get(param_type).Float);
            var val: i32 = @intFromFloat(val_float);
            var param_text_buf: [256]u8 = [_]u8{0} ** 256;
            _ = Params._valueToText(&plugin.plugin, @enumFromInt(index), val_float, &param_text_buf, 256);
            if (zgui.sliderInt(
                value_text,
                .{
                    .v = &val,
                    .min = @intFromFloat(info.min_value),
                    .max = @intFromFloat(info.max_value),
                    .cfmt = param_text_buf[0..255 :0],
                },
            )) {
                plugin.params.set(param_type, .{ .Float = @as(f64, @floatFromInt(val)) }, .{
                    .should_notify_host = options.notify_host,
                }) catch return;
                if (!options.notify_host) {
                    plugin.applyParamChanges(false);
                }
            }
            // Undo support
            if (zgui.isItemActivated()) {
                Undo.beginChange();
            }
            if (zgui.isItemDeactivated()) {
                Undo.changeMade(value_text);
            }
        },
        .FilterEnable, .ScaleVoices, .DebugBool1, .DebugBool2 => {
            if (builtin.mode == .Debug) {
                var val: bool = plugin.params.get(param_type).Bool;
                if (zgui.checkbox(value_text, .{
                    .v = &val,
                })) {
                    // Instant change: begin + complete immediately
                    Undo.beginChange();
                    plugin.params.set(param_type, .{ .Bool = val }, .{
                        .should_notify_host = options.notify_host,
                    }) catch return;
                    if (!options.notify_host) {
                        plugin.applyParamChanges(false);
                    }
                    Undo.changeMade(value_text);
                }
            }
        },
        .WaveShape1, .WaveShape2 => {
            inline for (std.meta.fields(Wave), 0..) |field, i| {
                if (i > 0) {
                    zgui.sameLine(.{});
                }
                const wave: Wave = @enumFromInt(field.value);
                if (zgui.radioButton(field.name, .{
                    .active = plugin.params.get(param_type).Wave == wave,
                })) {
                    // Instant change
                    Undo.beginChange();
                    plugin.params.set(param_type, .{ .Wave = wave }, .{
                        .should_notify_host = options.notify_host,
                    }) catch return;
                    if (!options.notify_host) {
                        plugin.applyParamChanges(false);
                    }
                    Undo.changeMade(value_text);
                }
            }
        },
        .FilterType => {
            inline for (std.meta.fields(Filter), 0..) |field, i| {
                if (i > 0) {
                    zgui.sameLine(.{});
                }
                const filter: Filter = @enumFromInt(field.value);
                if (zgui.radioButton(field.name, .{
                    .active = plugin.params.get(param_type).Filter == filter,
                })) {
                    // Instant change
                    Undo.beginChange();
                    plugin.params.set(param_type, .{ .Filter = filter }, .{
                        .should_notify_host = options.notify_host,
                    }) catch return;
                    if (!options.notify_host) {
                        plugin.applyParamChanges(false);
                    }
                    Undo.changeMade(value_text);
                }
            }
        },
    }
}

fn renderMix(plugin: *Plugin, osc1: bool, options: DrawOptions) void {
    const index: u32 = @intFromEnum(Params.Parameter.Mix);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&plugin.plugin, index, &info)) {
        return;
    }

    var val: f32 = @floatCast(plugin.params.get(.Mix).Float);
    if (osc1) {
        val = 1 - val;
    }

    var param_text_buf: [256]u8 = [_]u8{0} ** 256;
    _ = Params._valueToText(&plugin.plugin, @enumFromInt(index), val, &param_text_buf, 256);
    if (std.mem.indexOf(u8, &param_text_buf, "%")) |percent_index| {
        if (percent_index < 255) {
            param_text_buf[percent_index + 1] = '%';
        }
    }
    const slider_label = if (osc1) "Mix##Osc1" else "Mix##Osc2";
    if (zgui.sliderFloat(
        slider_label,
        .{
            .v = &val,
            .min = @floatCast(info.min_value),
            .max = @floatCast(info.max_value),
            .cfmt = param_text_buf[0..255 :0],
        },
    )) {
        if (osc1) {
            val = 1 - val;
        }
        plugin.params.set(.Mix, .{ .Float = @as(f64, @floatCast(val)) }, .{
            .should_notify_host = options.notify_host,
        }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
    // Undo support
    if (zgui.isItemActivated()) {
        Undo.beginChange();
    }
    if (zgui.isItemDeactivated()) {
        Undo.changeMade("Mix");
    }
}
