const Params = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");

const Plugin = @import("../plugin.zig");

const Info = clap.ext.params.Info;

pub const Parameter = enum {
    // Oscillator 1
    Osc1Level,
    Osc1Waveform,
    Osc1Range,

    // Oscillator 2
    Osc2Level,
    Osc2Waveform,
    Osc2Range,
    Osc2Detune,

    // Oscillator 3
    Osc3Level,
    Osc3Waveform,
    Osc3Range,
    Osc3Detune,
    Osc3KeyboardCtrl,

    // Noise
    NoiseLevel,
    NoiseType,

    // Filter
    FilterCutoff,
    FilterEmphasis,
    FilterContour,
    FilterKeyTracking,

    // Modulation
    Osc3ToFilter,
    Osc3ToOsc,

    // Envelope
    Attack,
    Decay,
    Sustain,
    Release,

    // Controllers
    Glide,
    PitchBendRange,
    MasterVolume,
};

pub const ParameterValue = union(enum) {
    Float: f64,

    pub fn asFloat(parameterValue: ParameterValue) f64 {
        return switch (parameterValue) {
            .Float => |value| value,
        };
    }
};

pub const ParameterArray = std.EnumArray(Parameter, ParameterValue);

pub const param_defaults = std.enums.EnumFieldStruct(Parameter, ParameterValue, null){
    // Oscillator 1
    .Osc1Level = .{ .Float = 1.0 },
    .Osc1Waveform = .{ .Float = 2.0 }, // 0=tri, 1=shark, 2=saw, 3=sq, 4=wide, 5=narrow
    .Osc1Range = .{ .Float = 3.0 }, // 0=LO, 1=32', 2=16', 3=8', 4=4', 5=2'

    // Oscillator 2
    .Osc2Level = .{ .Float = 0.0 },
    .Osc2Waveform = .{ .Float = 2.0 },
    .Osc2Range = .{ .Float = 3.0 },
    .Osc2Detune = .{ .Float = 0.0 }, // cents (-100 to +100)

    // Oscillator 3
    .Osc3Level = .{ .Float = 0.0 },
    .Osc3Waveform = .{ .Float = 2.0 },
    .Osc3Range = .{ .Float = 3.0 },
    .Osc3Detune = .{ .Float = 0.0 },
    .Osc3KeyboardCtrl = .{ .Float = 1.0 }, // 0=off (LFO mode), 1=on

    // Noise
    .NoiseLevel = .{ .Float = 0.0 },
    .NoiseType = .{ .Float = 0.0 }, // 0=white, 1=pink

    // Filter
    .FilterCutoff = .{ .Float = 5000.0 }, // Hz
    .FilterEmphasis = .{ .Float = 0.0 }, // Resonance 0-4
    .FilterContour = .{ .Float = 0.5 }, // Envelope amount 0-1
    .FilterKeyTracking = .{ .Float = 1.0 }, // 0=off, 1=half, 2=full

    // Modulation
    .Osc3ToFilter = .{ .Float = 0.0 }, // 0=off, 1=on
    .Osc3ToOsc = .{ .Float = 0.0 }, // 0=off, 1=on

    // Envelope (seconds)
    .Attack = .{ .Float = 0.01 },
    .Decay = .{ .Float = 0.3 },
    .Sustain = .{ .Float = 0.7 },
    .Release = .{ .Float = 0.3 },

    // Controllers
    .Glide = .{ .Float = 0.0 }, // Glide time in seconds
    .PitchBendRange = .{ .Float = 2.0 }, // semitones
    .MasterVolume = .{ .Float = 0.8 },
};

pub const param_count = std.meta.fields(Parameter).len;

values: ParameterArray = .init(param_defaults),
mutex: std.Thread.Mutex,
events: std.ArrayList(clap.events.ParamValue),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Params {
    return .{
        .events = .empty,
        .mutex = .{},
        .allocator = allocator,
    };
}

pub fn deinit(self: *Params) void {
    self.events.deinit(self.allocator);
}

pub fn get(self: *Params, param: Parameter) ParameterValue {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.values.get(param);
}

const ParamSetFlags = struct {
    should_notify_host: bool = false,
};

pub fn set(self: *Params, param: Parameter, val: ParameterValue, flags: ParamSetFlags) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.values.set(param, val);

    if (flags.should_notify_host) {
        const param_index: usize = @intFromEnum(param);
        const event = clap.events.ParamValue{
            .header = .{
                .type = .param_value,
                .size = @sizeOf(clap.events.ParamValue),
                .space_id = clap.events.core_space_id,
                .sample_offset = 0,
                .flags = .{},
            },
            .note_id = .unspecified,
            .channel = .unspecified,
            .key = .unspecified,
            .port_index = .unspecified,
            .param_id = @enumFromInt(param_index),
            .value = val.asFloat(),
            .cookie = null,
        };

        try self.events.append(self.allocator, event);
    }
}

pub inline fn create() clap.ext.params.Plugin {
    return .{
        .count = _count,
        .getInfo = _getInfo,
        .getValue = _getValue,
        .valueToText = _valueToText,
        .textToValue = _textToValue,
        .flush = _flush,
    };
}

fn _count(_: *const clap.Plugin) callconv(.c) u32 {
    return @intCast(param_count);
}

pub fn _getInfo(_: *const clap.Plugin, index: u32, info: *Info) callconv(.c) bool {
    if (index >= _count(undefined)) return false;

    const param_type: Parameter = @enumFromInt(index);
    info.* = getParamInfo(param_type);
    return true;
}

fn getParamInfo(param: Parameter) Info {
    var info: Info = .{
        .cookie = null,
        .default_value = 0,
        .min_value = 0,
        .max_value = 1,
        .name = [_]u8{0} ** 256,
        .flags = .{ .is_automatable = true },
        .id = @enumFromInt(@intFromEnum(param)),
        .module = [_]u8{0} ** 1024,
    };

    switch (param) {
        // Oscillator 1
        .Osc1Level => {
            info.default_value = param_defaults.Osc1Level.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Osc 1 Level");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc1");
        },
        .Osc1Waveform => {
            info.default_value = param_defaults.Osc1Waveform.Float;
            info.min_value = 0.0;
            info.max_value = 5.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc 1 Waveform");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc1");
        },
        .Osc1Range => {
            info.default_value = param_defaults.Osc1Range.Float;
            info.min_value = 0.0;
            info.max_value = 5.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc 1 Range");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc1");
        },
        // Oscillator 2
        .Osc2Level => {
            info.default_value = param_defaults.Osc2Level.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Osc 2 Level");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc2");
        },
        .Osc2Waveform => {
            info.default_value = param_defaults.Osc2Waveform.Float;
            info.min_value = 0.0;
            info.max_value = 5.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc 2 Waveform");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc2");
        },
        .Osc2Range => {
            info.default_value = param_defaults.Osc2Range.Float;
            info.min_value = 0.0;
            info.max_value = 5.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc 2 Range");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc2");
        },
        .Osc2Detune => {
            info.default_value = param_defaults.Osc2Detune.Float;
            info.min_value = -100.0;
            info.max_value = 100.0;
            std.mem.copyForwards(u8, &info.name, "Osc 2 Detune");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc2");
        },
        // Oscillator 3
        .Osc3Level => {
            info.default_value = param_defaults.Osc3Level.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Osc 3 Level");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc3");
        },
        .Osc3Waveform => {
            info.default_value = param_defaults.Osc3Waveform.Float;
            info.min_value = 0.0;
            info.max_value = 5.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc 3 Waveform");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc3");
        },
        .Osc3Range => {
            info.default_value = param_defaults.Osc3Range.Float;
            info.min_value = 0.0;
            info.max_value = 5.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc 3 Range");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc3");
        },
        .Osc3Detune => {
            info.default_value = param_defaults.Osc3Detune.Float;
            info.min_value = -100.0;
            info.max_value = 100.0;
            std.mem.copyForwards(u8, &info.name, "Osc 3 Detune");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc3");
        },
        .Osc3KeyboardCtrl => {
            info.default_value = param_defaults.Osc3KeyboardCtrl.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc 3 Keyboard");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc3");
        },
        // Noise
        .NoiseLevel => {
            info.default_value = param_defaults.NoiseLevel.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Noise Level");
            std.mem.copyForwards(u8, &info.module, "Mixer/Noise");
        },
        .NoiseType => {
            info.default_value = param_defaults.NoiseType.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Noise Type");
            std.mem.copyForwards(u8, &info.module, "Mixer/Noise");
        },
        // Filter
        .FilterCutoff => {
            info.default_value = param_defaults.FilterCutoff.Float;
            info.min_value = 20.0;
            info.max_value = 20000.0;
            std.mem.copyForwards(u8, &info.name, "Cutoff");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .FilterEmphasis => {
            info.default_value = param_defaults.FilterEmphasis.Float;
            info.min_value = 0.0;
            info.max_value = 4.0;
            std.mem.copyForwards(u8, &info.name, "Emphasis");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .FilterContour => {
            info.default_value = param_defaults.FilterContour.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Contour Amt");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .FilterKeyTracking => {
            info.default_value = param_defaults.FilterKeyTracking.Float;
            info.min_value = 0.0;
            info.max_value = 2.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Key Tracking");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        // Modulation
        .Osc3ToFilter => {
            info.default_value = param_defaults.Osc3ToFilter.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc3 > Filter");
            std.mem.copyForwards(u8, &info.module, "Modulation");
        },
        .Osc3ToOsc => {
            info.default_value = param_defaults.Osc3ToOsc.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc3 > Osc");
            std.mem.copyForwards(u8, &info.module, "Modulation");
        },
        // Envelope
        .Attack => {
            info.default_value = param_defaults.Attack.Float;
            info.min_value = 0.001;
            info.max_value = 10.0;
            std.mem.copyForwards(u8, &info.name, "Attack");
            std.mem.copyForwards(u8, &info.module, "Envelope");
        },
        .Decay => {
            info.default_value = param_defaults.Decay.Float;
            info.min_value = 0.001;
            info.max_value = 10.0;
            std.mem.copyForwards(u8, &info.name, "Decay");
            std.mem.copyForwards(u8, &info.module, "Envelope");
        },
        .Sustain => {
            info.default_value = param_defaults.Sustain.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Sustain");
            std.mem.copyForwards(u8, &info.module, "Envelope");
        },
        .Release => {
            info.default_value = param_defaults.Release.Float;
            info.min_value = 0.001;
            info.max_value = 10.0;
            std.mem.copyForwards(u8, &info.name, "Release");
            std.mem.copyForwards(u8, &info.module, "Envelope");
        },
        // Controllers
        .Glide => {
            info.default_value = param_defaults.Glide.Float;
            info.min_value = 0.0;
            info.max_value = 5.0;
            std.mem.copyForwards(u8, &info.name, "Glide");
            std.mem.copyForwards(u8, &info.module, "Controllers");
        },
        .PitchBendRange => {
            info.default_value = param_defaults.PitchBendRange.Float;
            info.min_value = 0.0;
            info.max_value = 12.0;
            std.mem.copyForwards(u8, &info.name, "Bend Range");
            std.mem.copyForwards(u8, &info.module, "Controllers");
        },
        .MasterVolume => {
            info.default_value = param_defaults.MasterVolume.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Master Volume");
            std.mem.copyForwards(u8, &info.module, "Output");
        },
    }

    return info;
}

fn _getValue(clap_plugin: *const clap.Plugin, param_id: clap.Id, value: *f64) callconv(.c) bool {
    const plugin = Plugin.fromClapPlugin(clap_plugin);
    const index = @intFromEnum(param_id);
    if (index >= param_count) return false;
    const param: Parameter = @enumFromInt(index);
    value.* = plugin.params.get(param).Float;
    return true;
}

const waveform_names = [_][]const u8{ "Triangle", "Shark", "Sawtooth", "Square", "Wide Pulse", "Narrow Pulse" };
const range_names = [_][]const u8{ "LO", "32'", "16'", "8'", "4'", "2'" };
const noise_names = [_][]const u8{ "White", "Pink" };
const tracking_names = [_][]const u8{ "Off", "Half", "Full" };
const switch_names = [_][]const u8{ "Off", "On" };

pub fn _valueToText(
    _: *const clap.Plugin,
    param_id: clap.Id,
    value: f64,
    buffer: [*]u8,
    size: u32,
) callconv(.c) bool {
    const index = @intFromEnum(param_id);
    if (index >= param_count) return false;
    const param: Parameter = @enumFromInt(index);

    // Format with units based on parameter type
    const out = switch (param) {
        .FilterCutoff => std.fmt.bufPrintZ(buffer[0..size], "{d:.0} Hz", .{value}),
        .Attack, .Decay, .Release, .Glide => std.fmt.bufPrintZ(buffer[0..size], "{d:.3} s", .{value}),
        .Osc2Detune, .Osc3Detune => std.fmt.bufPrintZ(buffer[0..size], "{d:.1} ct", .{value}),
        .PitchBendRange => std.fmt.bufPrintZ(buffer[0..size], "{d:.0} st", .{value}),
        .Osc1Waveform, .Osc2Waveform, .Osc3Waveform => blk: {
            const idx: usize = @intFromFloat(@round(@max(0.0, @min(5.0, value))));
            break :blk std.fmt.bufPrintZ(buffer[0..size], "{s}", .{waveform_names[idx]});
        },
        .Osc1Range, .Osc2Range, .Osc3Range => blk: {
            const idx: usize = @intFromFloat(@round(@max(0.0, @min(5.0, value))));
            break :blk std.fmt.bufPrintZ(buffer[0..size], "{s}", .{range_names[idx]});
        },
        .NoiseType => blk: {
            const idx: usize = @intFromFloat(@round(@max(0.0, @min(1.0, value))));
            break :blk std.fmt.bufPrintZ(buffer[0..size], "{s}", .{noise_names[idx]});
        },
        .FilterKeyTracking => blk: {
            const idx: usize = @intFromFloat(@round(@max(0.0, @min(2.0, value))));
            break :blk std.fmt.bufPrintZ(buffer[0..size], "{s}", .{tracking_names[idx]});
        },
        .Osc3KeyboardCtrl, .Osc3ToFilter, .Osc3ToOsc => blk: {
            const idx: usize = @intFromFloat(@round(@max(0.0, @min(1.0, value))));
            break :blk std.fmt.bufPrintZ(buffer[0..size], "{s}", .{switch_names[idx]});
        },
        .FilterEmphasis => std.fmt.bufPrintZ(buffer[0..size], "{d:.2}", .{value}),
        else => std.fmt.bufPrintZ(buffer[0..size], "{d:.2}", .{value}),
    } catch return false;
    _ = out;
    return true;
}

fn _textToValue(
    _: *const clap.Plugin,
    _: clap.Id,
    text: [*:0]const u8,
    value: *f64,
) callconv(.c) bool {
    const slice = std.mem.span(text);
    // Try to parse, stripping common suffixes
    var parse_slice: []const u8 = slice;
    if (std.mem.endsWith(u8, slice, " Hz")) {
        parse_slice = slice[0 .. slice.len - 3];
    } else if (std.mem.endsWith(u8, slice, " s")) {
        parse_slice = slice[0 .. slice.len - 2];
    }
    value.* = std.fmt.parseFloat(f64, parse_slice) catch return false;
    return true;
}

fn processEvent(plugin: *Plugin, event: *const clap.events.Header) bool {
    if (event.space_id != clap.events.core_space_id) {
        return false;
    }
    if (event.type == .param_value) {
        const param_event: *align(1) const clap.events.ParamValue = @ptrCast(event);
        const index = @intFromEnum(param_event.param_id);
        if (index >= param_count) {
            return false;
        }

        const param: Parameter = @enumFromInt(index);
        const value: ParameterValue = .{ .Float = param_event.value };
        plugin.params.set(param, value, .{}) catch unreachable;
        return true;
    }
    return false;
}

pub fn _flush(
    clap_plugin: *const clap.Plugin,
    input_events: *const clap.events.InputEvents,
    output_events: *const clap.events.OutputEvents,
) callconv(.c) void {
    const zone = tracy.ZoneN(@src(), "Flush parameters");
    defer zone.End();

    const plugin = Plugin.fromClapPlugin(clap_plugin);
    var params_did_change = false;
    for (0..input_events.size(input_events)) |i| {
        const event = input_events.get(input_events, @intCast(i));
        if (processEvent(plugin, event)) {
            params_did_change = true;
        }
    }

    if (plugin.params.mutex.tryLock()) {
        defer plugin.params.mutex.unlock();

        if (plugin.params.events.items.len > 0) {
            params_did_change = true;
        }
        while (plugin.params.events.pop()) |event_value| {
            var event = event_value;
            if (!output_events.tryPush(output_events, &event.header)) {
                std.debug.panic("Unable to notify DAW of parameter event changes!", .{});
            }
        }
    }

    if (params_did_change) {
        plugin.applyParamChanges(true);
    }
}
