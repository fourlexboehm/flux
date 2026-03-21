const Params = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");
const mutex_io: std.Io = std.Io.Threaded.global_single_threaded.ioBasic();

const Plugin = @import("../plugin.zig");
const bridge = @import("../bridge.zig");

const Info = clap.ext.params.Info;

pub const mode_names = [_][]const u8{
    "Custom Patch",
    "Preset Instrument",
};

pub const instrument_names = [_][]const u8{
    "Violin",
    "Guitar",
    "Piano",
    "Flute",
    "Clarinet",
    "Oboe",
    "Trumpet",
    "Organ",
    "Horn",
    "Synthesizer",
    "Harpsichord",
    "Vibraphone",
    "S.Bass",
    "A.Bass",
    "E.Guitar",
};

pub const Parameter = enum {
    VoiceMode,
    Instrument,
    PitchWheelRange,
    FineTune,
    OutputLevel,

    ModAttack,
    CarAttack,
    ModDecay,
    CarDecay,
    ModSustain,
    CarSustain,
    ModRelease,
    CarRelease,
    ModMultiplier,
    CarMultiplier,
    Feedback,
    ModLevel,
    ModWave,
    CarWave,
    ModTremolo,
    CarTremolo,
    ModVibrato,
    CarVibrato,
};

pub const ParameterValue = union(enum) {
    Float: f64,

    pub fn asFloat(self: ParameterValue) f64 {
        return switch (self) {
            .Float => |value| value,
        };
    }
};

pub const ParameterArray = std.EnumArray(Parameter, ParameterValue);

pub const param_defaults = std.enums.EnumFieldStruct(Parameter, ParameterValue, null){
    .VoiceMode = .{ .Float = 1.0 },
    .Instrument = .{ .Float = 3.0 },
    .PitchWheelRange = .{ .Float = 3.0 },
    .FineTune = .{ .Float = 0.0 },
    .OutputLevel = .{ .Float = 0.8 },

    .ModAttack = .{ .Float = 0.0 },
    .CarAttack = .{ .Float = 0.0 },
    .ModDecay = .{ .Float = 0.0 },
    .CarDecay = .{ .Float = 0.0 },
    .ModSustain = .{ .Float = 1.0 },
    .CarSustain = .{ .Float = 1.0 },
    .ModRelease = .{ .Float = 0.0 },
    .CarRelease = .{ .Float = 0.0 },
    .ModMultiplier = .{ .Float = 1.1 / 15.0 },
    .CarMultiplier = .{ .Float = 1.1 / 15.0 },
    .Feedback = .{ .Float = 0.0 },
    .ModLevel = .{ .Float = 0.0 },
    .ModWave = .{ .Float = 0.0 },
    .CarWave = .{ .Float = 0.0 },
    .ModTremolo = .{ .Float = 0.0 },
    .CarTremolo = .{ .Float = 0.0 },
    .ModVibrato = .{ .Float = 0.0 },
    .CarVibrato = .{ .Float = 0.0 },
};

pub const param_count = std.meta.fields(Parameter).len;

values: ParameterArray = .init(param_defaults),
mutex: std.Io.Mutex,
events: std.ArrayList(clap.events.ParamValue),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Params {
    return .{
        .events = .empty,
        .mutex = .init,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Params) void {
    self.events.deinit(self.allocator);
}

pub fn get(self: *Params, param: Parameter) ParameterValue {
    self.mutex.lockUncancelable(mutex_io);
    defer self.mutex.unlock(mutex_io);
    return self.values.get(param);
}

const ParamSetFlags = struct {
    should_notify_host: bool = false,
};

pub fn set(self: *Params, param: Parameter, val: ParameterValue, flags: ParamSetFlags) !void {
    self.mutex.lockUncancelable(mutex_io);
    defer self.mutex.unlock(mutex_io);
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

fn copyString(dest: anytype, src: []const u8) void {
    std.mem.copyForwards(u8, dest, src);
}

fn baseInfo(param: Parameter) Info {
    return .{
        .id = @enumFromInt(@intFromEnum(param)),
        .flags = .{
            .is_automatable = true,
            .requires_process = true,
        },
        .cookie = null,
        .name = [_]u8{0} ** clap.name_capacity,
        .module = [_]u8{0} ** clap.path_capacity,
        .min_value = 0.0,
        .max_value = 1.0,
        .default_value = 0.0,
    };
}

fn patchParamFor(param: Parameter) ?bridge.PatchParam {
    return switch (param) {
        .ModAttack => .mod_attack,
        .CarAttack => .car_attack,
        .ModDecay => .mod_decay,
        .CarDecay => .car_decay,
        .ModSustain => .mod_sustain,
        .CarSustain => .car_sustain,
        .ModRelease => .mod_release,
        .CarRelease => .car_release,
        .ModMultiplier => .mod_multiplier,
        .CarMultiplier => .car_multiplier,
        .Feedback => .feedback,
        .ModLevel => .mod_level,
        .ModWave => .mod_wave,
        .CarWave => .car_wave,
        .ModTremolo => .mod_tremolo,
        .CarTremolo => .car_tremolo,
        .ModVibrato => .mod_vibrato,
        .CarVibrato => .car_vibrato,
        else => null,
    };
}

fn toggleName(value: f64) []const u8 {
    return if (value >= 0.5) "On" else "Off";
}

fn waveName(value: f64) []const u8 {
    return if (value >= 0.5) "Alt" else "Std";
}

fn modeName(value: f64) []const u8 {
    const index: usize = @intFromFloat(std.math.clamp(@round(value), 0.0, 1.0));
    return mode_names[index];
}

fn instrumentName(value: f64) []const u8 {
    const clamped = std.math.clamp(@round(value), 1.0, 15.0);
    const index: usize = @as(usize, @intFromFloat(clamped)) - 1;
    return instrument_names[index];
}

fn getParamInfo(param: Parameter) Info {
    var info = baseInfo(param);

    switch (param) {
        .VoiceMode => {
            info.default_value = param_defaults.VoiceMode.Float;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            info.flags.is_enum = true;
            copyString(&info.name, "Mode");
            copyString(&info.module, "Voice");
        },
        .Instrument => {
            info.default_value = param_defaults.Instrument.Float;
            info.min_value = 1.0;
            info.max_value = 15.0;
            info.flags.is_stepped = true;
            info.flags.is_enum = true;
            copyString(&info.name, "Instrument");
            copyString(&info.module, "Voice");
        },
        .PitchWheelRange => {
            info.default_value = param_defaults.PitchWheelRange.Float;
            info.min_value = 0.0;
            info.max_value = 12.0;
            info.flags.is_stepped = true;
            copyString(&info.name, "Pitch Wheel");
            copyString(&info.module, "Performance");
        },
        .FineTune => {
            info.default_value = param_defaults.FineTune.Float;
            info.min_value = -50.0;
            info.max_value = 50.0;
            copyString(&info.name, "Fine Tune");
            copyString(&info.module, "Performance");
        },
        .OutputLevel => {
            info.default_value = param_defaults.OutputLevel.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            copyString(&info.name, "Output");
            copyString(&info.module, "Output");
        },
        .ModAttack => {
            info.default_value = param_defaults.ModAttack.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Mod Attack");
            copyString(&info.module, "Patch/Modulator");
        },
        .CarAttack => {
            info.default_value = param_defaults.CarAttack.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Car Attack");
            copyString(&info.module, "Patch/Carrier");
        },
        .ModDecay => {
            info.default_value = param_defaults.ModDecay.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Mod Decay");
            copyString(&info.module, "Patch/Modulator");
        },
        .CarDecay => {
            info.default_value = param_defaults.CarDecay.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Car Decay");
            copyString(&info.module, "Patch/Carrier");
        },
        .ModSustain => {
            info.default_value = param_defaults.ModSustain.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Mod Sustain");
            copyString(&info.module, "Patch/Modulator");
        },
        .CarSustain => {
            info.default_value = param_defaults.CarSustain.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Car Sustain");
            copyString(&info.module, "Patch/Carrier");
        },
        .ModRelease => {
            info.default_value = param_defaults.ModRelease.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Mod Release");
            copyString(&info.module, "Patch/Modulator");
        },
        .CarRelease => {
            info.default_value = param_defaults.CarRelease.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Car Release");
            copyString(&info.module, "Patch/Carrier");
        },
        .ModMultiplier => {
            info.default_value = param_defaults.ModMultiplier.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Mod Mult");
            copyString(&info.module, "Patch/Modulator");
        },
        .CarMultiplier => {
            info.default_value = param_defaults.CarMultiplier.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Car Mult");
            copyString(&info.module, "Patch/Carrier");
        },
        .Feedback => {
            info.default_value = param_defaults.Feedback.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Feedback");
            copyString(&info.module, "Patch/Global");
        },
        .ModLevel => {
            info.default_value = param_defaults.ModLevel.Float;
            info.flags.is_stepped = true;
            copyString(&info.name, "Mod Level");
            copyString(&info.module, "Patch/Global");
        },
        .ModWave => {
            info.default_value = param_defaults.ModWave.Float;
            info.flags.is_stepped = true;
            info.flags.is_enum = true;
            copyString(&info.name, "Mod Wave");
            copyString(&info.module, "Patch/Modulator");
        },
        .CarWave => {
            info.default_value = param_defaults.CarWave.Float;
            info.flags.is_stepped = true;
            info.flags.is_enum = true;
            copyString(&info.name, "Car Wave");
            copyString(&info.module, "Patch/Carrier");
        },
        .ModTremolo => {
            info.default_value = param_defaults.ModTremolo.Float;
            info.flags.is_stepped = true;
            info.flags.is_enum = true;
            copyString(&info.name, "Mod Tremolo");
            copyString(&info.module, "Patch/Modulator");
        },
        .CarTremolo => {
            info.default_value = param_defaults.CarTremolo.Float;
            info.flags.is_stepped = true;
            info.flags.is_enum = true;
            copyString(&info.name, "Car Tremolo");
            copyString(&info.module, "Patch/Carrier");
        },
        .ModVibrato => {
            info.default_value = param_defaults.ModVibrato.Float;
            info.flags.is_stepped = true;
            info.flags.is_enum = true;
            copyString(&info.name, "Mod Vibrato");
            copyString(&info.module, "Patch/Modulator");
        },
        .CarVibrato => {
            info.default_value = param_defaults.CarVibrato.Float;
            info.flags.is_stepped = true;
            info.flags.is_enum = true;
            copyString(&info.name, "Car Vibrato");
            copyString(&info.module, "Patch/Carrier");
        },
    }

    return info;
}

pub fn _getInfo(_: *const clap.Plugin, index: u32, info: *Info) callconv(.c) bool {
    if (index >= param_count) return false;
    const param: Parameter = @enumFromInt(index);
    info.* = getParamInfo(param);
    return true;
}

fn _getValue(clap_plugin: *const clap.Plugin, param_id: clap.Id, value: *f64) callconv(.c) bool {
    const plugin = Plugin.fromClapPlugin(clap_plugin);
    const index = @intFromEnum(param_id);
    if (index >= param_count) return false;
    const param: Parameter = @enumFromInt(index);
    value.* = plugin.params.get(param).Float;
    return true;
}

pub fn _valueToText(
    _: *const clap.Plugin,
    param_id: clap.Id,
    value: f64,
    buffer: [*]u8,
    size: u32,
) callconv(.c) bool {
    const index = @intFromEnum(param_id);
    if (index >= param_count) return false;

    const out = buffer[0..@intCast(size)];
    const param: Parameter = @enumFromInt(index);

    switch (param) {
        .VoiceMode => {
            _ = std.fmt.bufPrintZ(out, "{s}", .{modeName(value)}) catch return false;
            return true;
        },
        .Instrument => {
            _ = std.fmt.bufPrintZ(out, "{s}", .{instrumentName(value)}) catch return false;
            return true;
        },
        .PitchWheelRange => {
            _ = std.fmt.bufPrintZ(out, "{d:.0} st", .{value}) catch return false;
            return true;
        },
        .FineTune => {
            _ = std.fmt.bufPrintZ(out, "{d:.1} ct", .{value}) catch return false;
            return true;
        },
        .OutputLevel => {
            _ = std.fmt.bufPrintZ(out, "{d:.0}%", .{value * 100.0}) catch return false;
            return true;
        },
        .ModWave, .CarWave => {
            _ = std.fmt.bufPrintZ(out, "{s}", .{waveName(value)}) catch return false;
            return true;
        },
        .ModTremolo, .CarTremolo, .ModVibrato, .CarVibrato => {
            _ = std.fmt.bufPrintZ(out, "{s}", .{toggleName(value)}) catch return false;
            return true;
        },
        else => {
            if (patchParamFor(param)) |patch_param| {
                return bridge.patchValueToText(patch_param, @floatCast(std.math.clamp(value, 0.0, 1.0)), out);
            }
            return false;
        },
    }
}

fn parseFloatWithOptionalSuffix(text: []const u8, suffix: []const u8) ?f64 {
    var parse_slice = text;
    if (suffix.len > 0 and std.mem.endsWith(u8, text, suffix)) {
        parse_slice = text[0 .. text.len - suffix.len];
    }
    return std.fmt.parseFloat(f64, std.mem.trim(u8, parse_slice, " \t")) catch null;
}

fn _textToValue(
    _: *const clap.Plugin,
    param_id: clap.Id,
    text: [*:0]const u8,
    value: *f64,
) callconv(.c) bool {
    const index = @intFromEnum(param_id);
    if (index >= param_count) return false;

    const param: Parameter = @enumFromInt(index);
    const slice = std.mem.trim(u8, std.mem.span(text), " \t");

    switch (param) {
        .VoiceMode => {
            if (std.ascii.eqlIgnoreCase(slice, "custom") or std.ascii.eqlIgnoreCase(slice, "custom patch")) {
                value.* = 0.0;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(slice, "preset") or std.ascii.eqlIgnoreCase(slice, "preset instrument")) {
                value.* = 1.0;
                return true;
            }
        },
        .Instrument => {
            for (instrument_names, 0..) |name, i| {
                if (std.ascii.eqlIgnoreCase(slice, name)) {
                    value.* = @floatFromInt(i + 1);
                    return true;
                }
            }
        },
        .ModWave, .CarWave => {
            if (std.ascii.eqlIgnoreCase(slice, "std")) {
                value.* = 0.0;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(slice, "alt")) {
                value.* = 1.0;
                return true;
            }
        },
        .ModTremolo, .CarTremolo, .ModVibrato, .CarVibrato => {
            if (std.ascii.eqlIgnoreCase(slice, "off")) {
                value.* = 0.0;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(slice, "on")) {
                value.* = 1.0;
                return true;
            }
        },
        else => {},
    }

    const parsed = switch (param) {
        .PitchWheelRange => parseFloatWithOptionalSuffix(slice, "st"),
        .FineTune => parseFloatWithOptionalSuffix(slice, "ct"),
        .OutputLevel => blk: {
            if (std.mem.endsWith(u8, slice, "%")) {
                if (parseFloatWithOptionalSuffix(slice, "%")) |percent| {
                    break :blk percent / 100.0;
                }
            }
            break :blk parseFloatWithOptionalSuffix(slice, "");
        },
        else => parseFloatWithOptionalSuffix(slice, ""),
    } orelse return false;

    value.* = parsed;
    return true;
}

fn processEvent(plugin: *Plugin, event: *const clap.events.Header) bool {
    if (event.space_id != clap.events.core_space_id) {
        return false;
    }
    if (event.type == .param_value) {
        const param_event: *align(1) const clap.events.ParamValue = @ptrCast(event);
        const index = @intFromEnum(param_event.param_id);
        if (index >= param_count) return false;

        const param: Parameter = @enumFromInt(index);
        plugin.params.set(param, .{ .Float = param_event.value }, .{}) catch unreachable;
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
        defer plugin.params.mutex.unlock(mutex_io);

        if (plugin.params.events.items.len > 0) {
            params_did_change = true;
        }
        while (plugin.params.events.pop()) |event_value| {
            var event = event_value;
            if (!output_events.tryPush(output_events, &event.header)) {
                std.debug.panic("Unable to push parameter event to host", .{});
            }
        }
    }

    if (params_did_change) {
        plugin.applyParamChanges(true);
    }
}
