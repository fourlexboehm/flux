const std = @import("std");
const clap = @import("clap-bindings");
const regex = @import("regex");
const shared_params = @import("shared").ext.params;

const Plugin = @import("../plugin.zig");
const Wave = @import("../audio/waves.zig").Wave;
const FilterType = @import("../audio/filter.zig").FilterType;

pub const Parameter = enum {
    Attack,
    Decay,
    Sustain,
    Release,
    WaveShape1,
    WaveShape2,
    Octave1,
    Octave2,
    Pitch1,
    Pitch2,
    Mix,
    ScaleVoices,
    FilterEnable,
    FilterType,
    FilterFreq,
    FilterQ,
    DebugBool1,
    DebugBool2,
};

pub const ParameterValue = union(enum) {
    Float: f64,
    Wave: Wave,
    Filter: FilterType,
    Bool: bool,

    pub fn asFloat(parameterValue: ParameterValue) f64 {
        return switch (parameterValue) {
            .Float => |v| v,
            .Wave => |w| @floatFromInt(@intFromEnum(w)),
            .Filter => |f| @floatFromInt(@intFromEnum(f)),
            .Bool => |b| if (b) 1.0 else 0.0,
        };
    }
};

pub const param_defaults = std.enums.EnumFieldStruct(Parameter, ParameterValue, null){
    .Attack = .{ .Float = 5.0 },
    .Decay = .{ .Float = 5.0 },
    .Sustain = .{ .Float = 0.5 },
    .Release = .{ .Float = 200.0 },
    .WaveShape1 = .{ .Wave = Wave.Saw },
    .WaveShape2 = .{ .Wave = Wave.Sine },
    .Pitch1 = .{ .Float = 0.0 },
    .Pitch2 = .{ .Float = 0.0 },
    .Octave1 = .{ .Float = 0.0 },
    .Octave2 = .{ .Float = -1.0 },
    .Mix = .{ .Float = 0.0 },
    .FilterEnable = .{ .Bool = false },
    .FilterType = .{ .Filter = FilterType.LowPass },
    .FilterFreq = .{ .Float = 20000 },
    .FilterQ = .{ .Float = 1.0 },
    .ScaleVoices = .{ .Bool = false },
    .DebugBool1 = .{ .Bool = false },
    .DebugBool2 = .{ .Bool = false },
};

pub const Store = shared_params.EnumStore(Parameter, ParameterValue, param_defaults);
pub const ParameterArray = Store.ParameterArray;
pub const param_count = Store.param_count;
pub const defaults = param_defaults;

fn id(p: Parameter) u32 {
    return @intFromEnum(p);
}

pub fn meta(param: Parameter) shared_params.ParamDef {
    const d = param_defaults;
    return switch (param) {
        .Attack => .{ .id = id(param), .name = "Attack", .module = "Envelope", .min = 0, .max = 20000, .default = d.Attack.Float, .stepped = true },
        .Decay => .{ .id = id(param), .name = "Decay", .module = "Envelope", .min = 0, .max = 20000, .default = d.Decay.Float, .stepped = true },
        .Sustain => .{ .id = id(param), .name = "Sustain", .module = "Envelope", .min = 0, .max = 1, .default = d.Sustain.Float },
        .Release => .{ .id = id(param), .name = "Release", .module = "Envelope", .min = 0, .max = 20000, .default = d.Release.Float, .stepped = true },
        .WaveShape1 => .{ .id = id(param), .name = "Wave 1", .module = "Oscillator/1", .min = 0, .max = @floatFromInt(std.meta.fieldNames(Wave).len - 1), .default = d.WaveShape1.asFloat(), .stepped = true, .is_enum = true },
        .WaveShape2 => .{ .id = id(param), .name = "Wave 2", .module = "Oscillator/2", .min = 0, .max = @floatFromInt(std.meta.fieldNames(Wave).len - 1), .default = d.WaveShape2.asFloat(), .stepped = true, .is_enum = true },
        .Octave1 => .{ .id = id(param), .name = "Octave 1", .module = "Oscillator/1", .min = -3, .max = 3, .default = d.Octave1.Float, .stepped = true },
        .Octave2 => .{ .id = id(param), .name = "Octave 2", .module = "Oscillator/2", .min = -3, .max = 3, .default = d.Octave2.Float, .stepped = true },
        .Pitch1 => .{ .id = id(param), .name = "Pitch 1", .module = "Oscillator/1", .min = -12, .max = 12, .default = d.Pitch1.Float, .display = .semitones },
        .Pitch2 => .{ .id = id(param), .name = "Pitch 2", .module = "Oscillator/2", .min = -12, .max = 12, .default = d.Pitch2.Float, .display = .semitones },
        .Mix => .{ .id = id(param), .name = "Mix", .module = "Oscillator", .min = 0, .max = 1, .default = d.Mix.Float, .display = .percent },
        .ScaleVoices => .{ .id = id(param), .name = "Scale Voices", .module = "Voices", .min = 0, .max = 1, .default = d.ScaleVoices.asFloat(), .stepped = true, .is_bool = true, .display = .bool_on_off },
        .FilterEnable => .{ .id = id(param), .name = "Enable", .module = "Filter", .min = 0, .max = 1, .default = d.FilterEnable.asFloat(), .stepped = true, .is_bool = true, .display = .bool_on_off },
        .FilterType => .{ .id = id(param), .name = "Type", .module = "Filter", .min = 0, .max = @floatFromInt(std.meta.fieldNames(FilterType).len - 1), .default = d.FilterType.asFloat(), .stepped = true, .is_enum = true },
        .FilterFreq => .{ .id = id(param), .name = "Frequency", .module = "Filter", .min = 20, .max = 20000, .default = d.FilterFreq.Float, .display = .hz },
        .FilterQ => .{ .id = id(param), .name = "Q", .module = "Filter", .min = 0.1, .max = 20, .default = d.FilterQ.Float },
        .DebugBool1 => .{ .id = id(param), .name = "Bool1", .module = "Debug/Bool1", .min = 0, .max = 1, .default = d.DebugBool1.asFloat(), .stepped = true, .is_bool = true },
        .DebugBool2 => .{ .id = id(param), .name = "Bool2", .module = "Debug/Bool2", .min = 0, .max = 1, .default = d.DebugBool2.asFloat(), .stepped = true, .is_bool = true },
    };
}

pub fn fromFloat(param: Parameter, value: f64) ParameterValue {
    return switch (param) {
        .Attack, .Decay, .Release, .Sustain, .Octave1, .Octave2, .Pitch1, .Pitch2, .Mix, .FilterFreq, .FilterQ => .{ .Float = value },
        .WaveShape1, .WaveShape2 => .{ .Wave = @enumFromInt(@as(usize, @intFromFloat(value))) },
        .FilterType => .{ .Filter = @enumFromInt(@as(usize, @intFromFloat(value))) },
        .FilterEnable, .ScaleVoices, .DebugBool1, .DebugBool2 => .{ .Bool = value == 1.0 },
    };
}

fn valueToText(
    _: *const clap.Plugin,
    param: Parameter,
    value: f64,
    buffer: [*]u8,
    size: u32,
) bool {
    const out_buf = buffer[0..size];
    var buf_slice: []u8 = undefined;
    switch (param) {
        .Attack, .Decay, .Release => {
            if (value >= 1000) {
                buf_slice = std.fmt.bufPrint(out_buf, "{d:.3} s", .{value / 1000}) catch return false;
            } else {
                buf_slice = std.fmt.bufPrint(out_buf, "{d:.0} ms", .{value}) catch return false;
            }
        },
        .FilterFreq => buf_slice = std.fmt.bufPrint(out_buf, "{d:.2} Hz", .{value}) catch return false,
        .Sustain, .Mix => buf_slice = std.fmt.bufPrint(out_buf, "{d:.2}%", .{value * 100}) catch return false,
        .Pitch1, .Pitch2 => buf_slice = std.fmt.bufPrint(out_buf, "{d:.2} st", .{value}) catch return false,
        .Octave1, .Octave2 => buf_slice = std.fmt.bufPrint(out_buf, "{d:.0}'", .{std.math.pow(f64, 2, 3 - value)}) catch return false,
        .FilterQ => buf_slice = std.fmt.bufPrint(out_buf, "{d:.0}", .{value}) catch return false,
        .WaveShape1, .WaveShape2 => {
            const wave = std.enums.fromInt(Wave, @as(u32, @intFromFloat(value))) orelse return false;
            buf_slice = std.fmt.bufPrint(out_buf, "{s}", .{@tagName(wave)}) catch return false;
        },
        .FilterType => {
            const filter = std.enums.fromInt(FilterType, @as(u32, @intFromFloat(value))) orelse return false;
            buf_slice = std.fmt.bufPrint(out_buf, "{s}", .{@tagName(filter)}) catch return false;
        },
        .FilterEnable, .ScaleVoices, .DebugBool1, .DebugBool2 => {
            buf_slice = std.fmt.bufPrint(out_buf, "{s}", .{if (value != 0.0) "true" else "false"}) catch return false;
        },
    }
    if (buf_slice.len < size) out_buf[buf_slice.len] = 0;
    return true;
}

fn anyUnitEql(unit: []const u8, cmps: []const []const u8) bool {
    for (cmps) |cmp| {
        if (std.mem.startsWith(u8, unit, cmp)) return true;
    }
    return false;
}

fn textToValue(
    clap_plugin: *const clap.Plugin,
    param: Parameter,
    value: []const u8,
    out_value: *f64,
) bool {
    switch (param) {
        .WaveShape1, .WaveShape2 => {
            for (std.meta.fieldNames(Wave), 0..) |name, i| {
                if (std.mem.startsWith(u8, value, name)) {
                    out_value.* = @floatFromInt(i);
                    return true;
                }
            }
            return false;
        },
        .FilterType => {
            for (std.meta.fieldNames(FilterType), 0..) |name, i| {
                if (std.mem.startsWith(u8, value, name)) {
                    out_value.* = @floatFromInt(i);
                    return true;
                }
            }
            return false;
        },
        .FilterEnable, .ScaleVoices, .DebugBool1, .DebugBool2 => {
            out_value.* = if (std.mem.startsWith(u8, value, "t")) 1.0 else 0.0;
            return true;
        },
        else => {},
    }

    const plugin = Plugin.fromClapPlugin(clap_plugin);
    var unit_string: [64]u8 = undefined;
    @memset(&unit_string, 0);
    const pattern = "\\s*(\\d+\\.?\\d*)\\s*(S|s|seconds|MS|Ms|ms|millis|milliseconds|%|st|Hz|hz|HZ)?\\s*";
    var re = regex.Regex.compile(plugin.allocator, pattern) catch return false;
    defer re.deinit();

    var caps = re.captures(value) catch return false;
    if (caps == null) return false;
    defer caps.?.deinit();
    const value_string = caps.?.sliceAt(1).?;
    var unit_slice: ?[]const u8 = null;
    if (caps.?.len() == 3) unit_slice = caps.?.sliceAt(2);
    if (unit_slice) |u| std.mem.copyForwards(u8, &unit_string, u);

    const val_float = std.fmt.parseFloat(f64, value_string) catch return false;

    switch (param) {
        .Attack, .Decay, .Release => {
            if (anyUnitEql(&unit_string, &.{ "S", "s", "seconds" })) {
                out_value.* = val_float * 1000;
            } else if (unit_slice == null or anyUnitEql(&unit_string, &.{ "MS", "Ms", "ms", "millis", "milliseconds" })) {
                out_value.* = val_float;
            } else return false;
        },
        .Sustain, .Mix => {
            out_value.* = if (std.mem.startsWith(u8, &unit_string, "%")) val_float / 100 else val_float;
        },
        .Pitch1, .Pitch2, .Octave1, .Octave2, .FilterFreq, .FilterQ => out_value.* = val_float,
        else => return false,
    }
    return true;
}

const clap_ext = shared_params.enumCreate(
    Plugin,
    Parameter,
    ParameterValue,
    meta,
    fromFloat,
    valueToText,
    textToValue,
);

pub fn create() clap.ext.params.Plugin {
    return clap_ext;
}

pub const _flush = clap_ext.flush;
pub const _getInfo = clap_ext.getInfo;
pub const _valueToText = clap_ext.valueToText;
