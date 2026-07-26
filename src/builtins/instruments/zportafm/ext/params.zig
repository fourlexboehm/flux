const std = @import("std");
const clap = @import("clap-bindings");
const shared_params = @import("shared").ext.params;
const Plugin = @import("../plugin.zig");
const bridge = @import("../bridge.zig");

pub const mode_names = [_][]const u8{
    "Custom Patch",
    "Preset Instrument",
};

pub const bank_names = bridge.tone_bank_names;

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
    Bank,
};

pub const ParameterValue = union(enum) {
    Float: f64,

    pub fn asFloat(self: ParameterValue) f64 {
        return switch (self) {
            .Float => |value| value,
        };
    }
};

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
    .Bank = .{ .Float = 0.0 },
};

pub const Store = shared_params.EnumStore(Parameter, ParameterValue, param_defaults);
pub const ParameterArray = Store.ParameterArray;
pub const param_count = Store.param_count;
pub const defaults = param_defaults;

const wave_names = [_][]const u8{ "Std", "Alt" };
const toggle_names = [_][]const u8{ "Off", "On" };

fn id(p: Parameter) u32 {
    return @intFromEnum(p);
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

fn bankFromValue(value: f64) bridge.ToneBank {
    const clamped = std.math.clamp(
        @round(value),
        0.0,
        @as(f64, @floatFromInt(bank_names.len - 1)),
    );
    return bridge.toneBankFromInt(@intFromFloat(clamped));
}

pub fn instrumentNames(plugin: *Plugin) []const []const u8 {
    return bridge.presetProgramNames(bankFromValue(plugin.params.get(.Bank).Float));
}

pub fn meta(param: Parameter) shared_params.ParamDef {
    const d = param_defaults;
    const bank_max: f64 = @floatFromInt(bank_names.len - 1);
    var def: shared_params.ParamDef = switch (param) {
        .VoiceMode => .{ .id = id(param), .name = "Mode", .module = "Voice", .min = 0, .max = 1, .default = d.VoiceMode.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &mode_names },
        .Instrument => .{ .id = id(param), .name = "Instrument", .module = "Voice", .min = 1, .max = 15, .default = d.Instrument.Float, .stepped = true, .is_enum = true },
        .Bank => .{ .id = id(param), .name = "Bank", .module = "Voice", .min = 0, .max = bank_max, .default = d.Bank.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &bank_names },
        .PitchWheelRange => .{ .id = id(param), .name = "Pitch Wheel", .module = "Performance", .min = 0, .max = 12, .default = d.PitchWheelRange.Float, .stepped = true, .display = .semitones },
        .FineTune => .{ .id = id(param), .name = "Fine Tune", .module = "Performance", .min = -50, .max = 50, .default = d.FineTune.Float, .display = .cents },
        .OutputLevel => .{ .id = id(param), .name = "Output", .module = "Output", .min = 0, .max = 1, .default = d.OutputLevel.Float, .display = .percent },
        .ModAttack => .{ .id = id(param), .name = "Mod Attack", .module = "Patch/Modulator", .default = d.ModAttack.Float, .stepped = true },
        .CarAttack => .{ .id = id(param), .name = "Car Attack", .module = "Patch/Carrier", .default = d.CarAttack.Float, .stepped = true },
        .ModDecay => .{ .id = id(param), .name = "Mod Decay", .module = "Patch/Modulator", .default = d.ModDecay.Float, .stepped = true },
        .CarDecay => .{ .id = id(param), .name = "Car Decay", .module = "Patch/Carrier", .default = d.CarDecay.Float, .stepped = true },
        .ModSustain => .{ .id = id(param), .name = "Mod Sustain", .module = "Patch/Modulator", .default = d.ModSustain.Float, .stepped = true },
        .CarSustain => .{ .id = id(param), .name = "Car Sustain", .module = "Patch/Carrier", .default = d.CarSustain.Float, .stepped = true },
        .ModRelease => .{ .id = id(param), .name = "Mod Release", .module = "Patch/Modulator", .default = d.ModRelease.Float, .stepped = true },
        .CarRelease => .{ .id = id(param), .name = "Car Release", .module = "Patch/Carrier", .default = d.CarRelease.Float, .stepped = true },
        .ModMultiplier => .{ .id = id(param), .name = "Mod Mult", .module = "Patch/Modulator", .default = d.ModMultiplier.Float, .stepped = true },
        .CarMultiplier => .{ .id = id(param), .name = "Car Mult", .module = "Patch/Carrier", .default = d.CarMultiplier.Float, .stepped = true },
        .Feedback => .{ .id = id(param), .name = "Feedback", .module = "Patch/Global", .default = d.Feedback.Float, .stepped = true },
        .ModLevel => .{ .id = id(param), .name = "Mod Level", .module = "Patch/Global", .default = d.ModLevel.Float, .stepped = true },
        .ModWave => .{ .id = id(param), .name = "Mod Wave", .module = "Patch/Modulator", .default = d.ModWave.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &wave_names },
        .CarWave => .{ .id = id(param), .name = "Car Wave", .module = "Patch/Carrier", .default = d.CarWave.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &wave_names },
        .ModTremolo => .{ .id = id(param), .name = "Mod Tremolo", .module = "Patch/Modulator", .default = d.ModTremolo.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &toggle_names },
        .CarTremolo => .{ .id = id(param), .name = "Car Tremolo", .module = "Patch/Carrier", .default = d.CarTremolo.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &toggle_names },
        .ModVibrato => .{ .id = id(param), .name = "Mod Vibrato", .module = "Patch/Modulator", .default = d.ModVibrato.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &toggle_names },
        .CarVibrato => .{ .id = id(param), .name = "Car Vibrato", .module = "Patch/Carrier", .default = d.CarVibrato.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &toggle_names },
    };
    def.requires_process = true;
    return def;
}

fn valueToText(
    clap_plugin: *const clap.Plugin,
    param: Parameter,
    value: f64,
    buffer: [*]u8,
    size: u32,
) bool {
    const out = buffer[0..@intCast(size)];
    switch (param) {
        .Instrument => {
            const plugin = Plugin.fromClapPlugin(clap_plugin);
            const bank = bankFromValue(plugin.params.get(.Bank).Float);
            const clamped = std.math.clamp(@round(value), 1.0, 15.0);
            const index: usize = @as(usize, @intFromFloat(clamped)) - 1;
            const name = bridge.presetProgramNames(bank)[index];
            _ = std.fmt.bufPrintSentinel(out, "{s}", .{name}, 0) catch return false;
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

fn textToValue(
    clap_plugin: *const clap.Plugin,
    param: Parameter,
    slice: []const u8,
    value: *f64,
) bool {
    switch (param) {
        .Instrument => {
            const plugin = Plugin.fromClapPlugin(clap_plugin);
            for (bridge.presetProgramNames(bankFromValue(plugin.params.get(.Bank).Float)), 0..) |name, i| {
                if (std.ascii.eqlIgnoreCase(slice, name)) {
                    value.* = @floatFromInt(i + 1);
                    return true;
                }
            }
            return false;
        },
        .VoiceMode => {
            if (std.ascii.eqlIgnoreCase(slice, "custom") or std.ascii.eqlIgnoreCase(slice, "custom patch")) {
                value.* = 0.0;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(slice, "preset") or std.ascii.eqlIgnoreCase(slice, "preset instrument")) {
                value.* = 1.0;
                return true;
            }
            return false;
        },
        else => return false,
    }
}

const clap_ext = shared_params.enumCreate(
    Plugin,
    Parameter,
    ParameterValue,
    meta,
    shared_params.fromFloatOnly(Parameter, ParameterValue),
    valueToText,
    textToValue,
);

pub fn create() clap.ext.params.Plugin {
    return clap_ext;
}

pub const _flush = clap_ext.flush;
pub const _getInfo = clap_ext.getInfo;
pub const _valueToText = clap_ext.valueToText;
