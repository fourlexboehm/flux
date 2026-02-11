const Params = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");
const mutex_io: std.Io = std.Io.Threaded.global_single_threaded.ioBasic();

const Plugin = @import("../plugin.zig");

const Info = clap.ext.params.Info;

pub const Parameter = enum {
    // Oscillators
    Osc1Saw,
    Osc1Pulse,
    Osc2Saw,
    Osc2Pulse,
    Osc1Pitch,
    Osc2Pitch,
    Osc2Detune,
    PulseWidth,
    OscSync,
    Crossmod,
    OscBrightness,
    Osc2PWOffset,

    // Mixer
    Osc1Volume,
    Osc2Volume,
    NoiseVolume,
    NoiseColor,
    RingModVolume,

    // Filter
    FilterCutoff,
    FilterResonance,
    FilterMode,
    Filter4Pole,
    FilterBPBlend,
    FilterXpander,
    FilterXpanderMode,
    FilterEnvAmount,
    FilterEnvInvert,
    FilterKeyTrack,
    Filter2PolePush,

    // Amp Envelope
    AmpAttack,
    AmpDecay,
    AmpSustain,
    AmpRelease,
    AmpAttackCurve,

    // Filter Envelope
    FilterAttack,
    FilterDecay,
    FilterSustain,
    FilterRelease,
    FilterAttackCurve,

    // LFO 1 (Global)
    LFO1Rate,
    LFO1Sync,
    LFO1Wave1,
    LFO1Wave2,
    LFO1Wave3,
    LFO1PW,
    LFO1ModAmt1,
    LFO1ModAmt2,
    LFO1ToOsc1Pitch,
    LFO1ToOsc2Pitch,
    LFO1ToCutoff,
    LFO1ToOsc1PW,
    LFO1ToOsc2PW,
    LFO1ToVolume,

    // LFO 2 (Per-voice)
    LFO2Rate,
    LFO2Sync,
    LFO2Wave1,
    LFO2Wave2,
    LFO2Wave3,
    LFO2PW,
    LFO2ModAmt1,
    LFO2ModAmt2,
    LFO2ToOsc1Pitch,
    LFO2ToOsc2Pitch,
    LFO2ToCutoff,
    LFO2ToOsc1PW,
    LFO2ToOsc2PW,
    LFO2ToVolume,

    // Envelope Modulation
    EnvToPitchAmt,
    EnvToPitchInvert,
    EnvToPitchBothOscs,
    EnvToPWAmt,
    EnvToPWInvert,
    EnvToPWBothOscs,

    // Performance
    Volume,
    Portamento,
    Tune,
    Transpose,
    Unison,
    UnisonDetune,
    BendUpRange,
    BendDownRange,
    BendOsc2Only,
    VelToAmp,
    VelToFilter,
    NotePriority,
    EnvLegatoMode,

    // Slop (Analog Character)
    EnvSlop,
    FilterSlop,
    PortamentoSlop,
    LevelSlop,

    // Quality
    HQMode,

    // Vibrato
    VibratoRate,
    VibratoWave,
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
    // Oscillators
    .Osc1Saw = .{ .Float = 1.0 },
    .Osc1Pulse = .{ .Float = 0.0 },
    .Osc2Saw = .{ .Float = 1.0 },
    .Osc2Pulse = .{ .Float = 0.0 },
    .Osc1Pitch = .{ .Float = 0.5 },
    .Osc2Pitch = .{ .Float = 0.5 },
    .Osc2Detune = .{ .Float = 0.0 },
    .PulseWidth = .{ .Float = 0.5 },
    .OscSync = .{ .Float = 0.0 },
    .Crossmod = .{ .Float = 0.0 },
    .OscBrightness = .{ .Float = 1.0 },
    .Osc2PWOffset = .{ .Float = 0.0 },

    // Mixer
    .Osc1Volume = .{ .Float = 1.0 },
    .Osc2Volume = .{ .Float = 0.0 },
    .NoiseVolume = .{ .Float = 0.0 },
    .NoiseColor = .{ .Float = 0.33 },
    .RingModVolume = .{ .Float = 0.0 },

    // Filter
    .FilterCutoff = .{ .Float = 1.0 },
    .FilterResonance = .{ .Float = 0.0 },
    .FilterMode = .{ .Float = 0.0 },
    .Filter4Pole = .{ .Float = 1.0 },
    .FilterBPBlend = .{ .Float = 0.0 },
    .FilterXpander = .{ .Float = 0.0 },
    .FilterXpanderMode = .{ .Float = 0.0 },
    .FilterEnvAmount = .{ .Float = 0.5 },
    .FilterEnvInvert = .{ .Float = 0.0 },
    .FilterKeyTrack = .{ .Float = 0.5 },
    .Filter2PolePush = .{ .Float = 0.0 },

    // Amp Envelope
    .AmpAttack = .{ .Float = 0.0 },
    .AmpDecay = .{ .Float = 0.3 },
    .AmpSustain = .{ .Float = 0.7 },
    .AmpRelease = .{ .Float = 0.2 },
    .AmpAttackCurve = .{ .Float = 0.0 },

    // Filter Envelope
    .FilterAttack = .{ .Float = 0.0 },
    .FilterDecay = .{ .Float = 0.3 },
    .FilterSustain = .{ .Float = 0.0 },
    .FilterRelease = .{ .Float = 0.2 },
    .FilterAttackCurve = .{ .Float = 0.0 },

    // LFO 1 (Global)
    .LFO1Rate = .{ .Float = 0.3 },
    .LFO1Sync = .{ .Float = 0.0 },
    .LFO1Wave1 = .{ .Float = 0.5 },
    .LFO1Wave2 = .{ .Float = 0.0 },
    .LFO1Wave3 = .{ .Float = 0.0 },
    .LFO1PW = .{ .Float = 0.0 },
    .LFO1ModAmt1 = .{ .Float = 0.0 },
    .LFO1ModAmt2 = .{ .Float = 0.0 },
    .LFO1ToOsc1Pitch = .{ .Float = 0.0 },
    .LFO1ToOsc2Pitch = .{ .Float = 0.0 },
    .LFO1ToCutoff = .{ .Float = 0.0 },
    .LFO1ToOsc1PW = .{ .Float = 0.0 },
    .LFO1ToOsc2PW = .{ .Float = 0.0 },
    .LFO1ToVolume = .{ .Float = 0.0 },

    // LFO 2 (Per-voice)
    .LFO2Rate = .{ .Float = 0.3 },
    .LFO2Sync = .{ .Float = 0.0 },
    .LFO2Wave1 = .{ .Float = 0.5 },
    .LFO2Wave2 = .{ .Float = 0.0 },
    .LFO2Wave3 = .{ .Float = 0.0 },
    .LFO2PW = .{ .Float = 0.0 },
    .LFO2ModAmt1 = .{ .Float = 0.0 },
    .LFO2ModAmt2 = .{ .Float = 0.0 },
    .LFO2ToOsc1Pitch = .{ .Float = 0.0 },
    .LFO2ToOsc2Pitch = .{ .Float = 0.0 },
    .LFO2ToCutoff = .{ .Float = 0.0 },
    .LFO2ToOsc1PW = .{ .Float = 0.0 },
    .LFO2ToOsc2PW = .{ .Float = 0.0 },
    .LFO2ToVolume = .{ .Float = 0.0 },

    // Envelope Modulation
    .EnvToPitchAmt = .{ .Float = 0.0 },
    .EnvToPitchInvert = .{ .Float = 0.0 },
    .EnvToPitchBothOscs = .{ .Float = 1.0 },
    .EnvToPWAmt = .{ .Float = 0.0 },
    .EnvToPWInvert = .{ .Float = 0.0 },
    .EnvToPWBothOscs = .{ .Float = 1.0 },

    // Performance
    .Volume = .{ .Float = 0.7 },
    .Portamento = .{ .Float = 0.0 },
    .Tune = .{ .Float = 0.5 },
    .Transpose = .{ .Float = 0.5 },
    .Unison = .{ .Float = 0.0 },
    .UnisonDetune = .{ .Float = 0.3 },
    .BendUpRange = .{ .Float = 0.042 },
    .BendDownRange = .{ .Float = 0.042 },
    .BendOsc2Only = .{ .Float = 0.0 },
    .VelToAmp = .{ .Float = 0.0 },
    .VelToFilter = .{ .Float = 0.0 },
    .NotePriority = .{ .Float = 0.0 },
    .EnvLegatoMode = .{ .Float = 0.0 },

    // Slop (Analog Character)
    .EnvSlop = .{ .Float = 0.0 },
    .FilterSlop = .{ .Float = 0.0 },
    .PortamentoSlop = .{ .Float = 0.0 },
    .LevelSlop = .{ .Float = 0.0 },

    // Quality
    .HQMode = .{ .Float = 0.0 },

    // Vibrato
    .VibratoRate = .{ .Float = 0.3 },
    .VibratoWave = .{ .Float = 0.0 },
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
        // Oscillators
        .Osc1Saw => {
            info.default_value = param_defaults.Osc1Saw.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc 1 Saw");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc1");
        },
        .Osc1Pulse => {
            info.default_value = param_defaults.Osc1Pulse.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc 1 Pulse");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc1");
        },
        .Osc2Saw => {
            info.default_value = param_defaults.Osc2Saw.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc 2 Saw");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc2");
        },
        .Osc2Pulse => {
            info.default_value = param_defaults.Osc2Pulse.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc 2 Pulse");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc2");
        },
        .Osc1Pitch => {
            info.default_value = param_defaults.Osc1Pitch.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Osc 1 Pitch");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc1");
        },
        .Osc2Pitch => {
            info.default_value = param_defaults.Osc2Pitch.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Osc 2 Pitch");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc2");
        },
        .Osc2Detune => {
            info.default_value = param_defaults.Osc2Detune.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Osc 2 Detune");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc2");
        },
        .PulseWidth => {
            info.default_value = param_defaults.PulseWidth.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Pulse Width");
            std.mem.copyForwards(u8, &info.module, "Oscillators");
        },
        .OscSync => {
            info.default_value = param_defaults.OscSync.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Osc Sync");
            std.mem.copyForwards(u8, &info.module, "Oscillators");
        },
        .Crossmod => {
            info.default_value = param_defaults.Crossmod.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Cross Mod");
            std.mem.copyForwards(u8, &info.module, "Oscillators");
        },
        .OscBrightness => {
            info.default_value = param_defaults.OscBrightness.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Osc Brightness");
            std.mem.copyForwards(u8, &info.module, "Oscillators");
        },
        .Osc2PWOffset => {
            info.default_value = param_defaults.Osc2PWOffset.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Osc 2 PW Offset");
            std.mem.copyForwards(u8, &info.module, "Oscillators/Osc2");
        },

        // Mixer
        .Osc1Volume => {
            info.default_value = param_defaults.Osc1Volume.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Osc 1 Volume");
            std.mem.copyForwards(u8, &info.module, "Mixer");
        },
        .Osc2Volume => {
            info.default_value = param_defaults.Osc2Volume.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Osc 2 Volume");
            std.mem.copyForwards(u8, &info.module, "Mixer");
        },
        .NoiseVolume => {
            info.default_value = param_defaults.NoiseVolume.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Noise Volume");
            std.mem.copyForwards(u8, &info.module, "Mixer");
        },
        .NoiseColor => {
            info.default_value = param_defaults.NoiseColor.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Noise Color");
            std.mem.copyForwards(u8, &info.module, "Mixer");
        },
        .RingModVolume => {
            info.default_value = param_defaults.RingModVolume.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Ring Mod Volume");
            std.mem.copyForwards(u8, &info.module, "Mixer");
        },

        // Filter
        .FilterCutoff => {
            info.default_value = param_defaults.FilterCutoff.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Cutoff");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .FilterResonance => {
            info.default_value = param_defaults.FilterResonance.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Resonance");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .FilterMode => {
            info.default_value = param_defaults.FilterMode.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Filter Mode");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .Filter4Pole => {
            info.default_value = param_defaults.Filter4Pole.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "4-Pole");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .FilterBPBlend => {
            info.default_value = param_defaults.FilterBPBlend.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "BP Blend");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .FilterXpander => {
            info.default_value = param_defaults.FilterXpander.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Xpander Mode");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .FilterXpanderMode => {
            info.default_value = param_defaults.FilterXpanderMode.Float;
            info.min_value = 0.0;
            info.max_value = 14.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Xpander Type");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .FilterEnvAmount => {
            info.default_value = param_defaults.FilterEnvAmount.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Env Amount");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .FilterEnvInvert => {
            info.default_value = param_defaults.FilterEnvInvert.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Env Invert");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .FilterKeyTrack => {
            info.default_value = param_defaults.FilterKeyTrack.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Key Track");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },
        .Filter2PolePush => {
            info.default_value = param_defaults.Filter2PolePush.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "2-Pole Push");
            std.mem.copyForwards(u8, &info.module, "Filter");
        },

        // Amp Envelope
        .AmpAttack => {
            info.default_value = param_defaults.AmpAttack.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Attack");
            std.mem.copyForwards(u8, &info.module, "Amp Envelope");
        },
        .AmpDecay => {
            info.default_value = param_defaults.AmpDecay.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Decay");
            std.mem.copyForwards(u8, &info.module, "Amp Envelope");
        },
        .AmpSustain => {
            info.default_value = param_defaults.AmpSustain.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Sustain");
            std.mem.copyForwards(u8, &info.module, "Amp Envelope");
        },
        .AmpRelease => {
            info.default_value = param_defaults.AmpRelease.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Release");
            std.mem.copyForwards(u8, &info.module, "Amp Envelope");
        },
        .AmpAttackCurve => {
            info.default_value = param_defaults.AmpAttackCurve.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Attack Curve");
            std.mem.copyForwards(u8, &info.module, "Amp Envelope");
        },

        // Filter Envelope
        .FilterAttack => {
            info.default_value = param_defaults.FilterAttack.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Attack");
            std.mem.copyForwards(u8, &info.module, "Filter Envelope");
        },
        .FilterDecay => {
            info.default_value = param_defaults.FilterDecay.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Decay");
            std.mem.copyForwards(u8, &info.module, "Filter Envelope");
        },
        .FilterSustain => {
            info.default_value = param_defaults.FilterSustain.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Sustain");
            std.mem.copyForwards(u8, &info.module, "Filter Envelope");
        },
        .FilterRelease => {
            info.default_value = param_defaults.FilterRelease.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Release");
            std.mem.copyForwards(u8, &info.module, "Filter Envelope");
        },
        .FilterAttackCurve => {
            info.default_value = param_defaults.FilterAttackCurve.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Attack Curve");
            std.mem.copyForwards(u8, &info.module, "Filter Envelope");
        },

        // LFO 1 (Global)
        .LFO1Rate => {
            info.default_value = param_defaults.LFO1Rate.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Rate");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1Sync => {
            info.default_value = param_defaults.LFO1Sync.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Tempo Sync");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1Wave1 => {
            info.default_value = param_defaults.LFO1Wave1.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Sine/Tri");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1Wave2 => {
            info.default_value = param_defaults.LFO1Wave2.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Square/Saw");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1Wave3 => {
            info.default_value = param_defaults.LFO1Wave3.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "S&H/S&G");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1PW => {
            info.default_value = param_defaults.LFO1PW.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Pulse Width");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1ModAmt1 => {
            info.default_value = param_defaults.LFO1ModAmt1.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Mod Amt 1");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1ModAmt2 => {
            info.default_value = param_defaults.LFO1ModAmt2.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Mod Amt 2");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1ToOsc1Pitch => {
            info.default_value = param_defaults.LFO1ToOsc1Pitch.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Osc1 Pitch");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1ToOsc2Pitch => {
            info.default_value = param_defaults.LFO1ToOsc2Pitch.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Osc2 Pitch");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1ToCutoff => {
            info.default_value = param_defaults.LFO1ToCutoff.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Cutoff");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1ToOsc1PW => {
            info.default_value = param_defaults.LFO1ToOsc1PW.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Osc1 PW");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1ToOsc2PW => {
            info.default_value = param_defaults.LFO1ToOsc2PW.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Osc2 PW");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },
        .LFO1ToVolume => {
            info.default_value = param_defaults.LFO1ToVolume.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Volume");
            std.mem.copyForwards(u8, &info.module, "LFO 1");
        },

        // LFO 2 (Per-voice)
        .LFO2Rate => {
            info.default_value = param_defaults.LFO2Rate.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Rate");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2Sync => {
            info.default_value = param_defaults.LFO2Sync.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Tempo Sync");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2Wave1 => {
            info.default_value = param_defaults.LFO2Wave1.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Sine/Tri");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2Wave2 => {
            info.default_value = param_defaults.LFO2Wave2.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Square/Saw");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2Wave3 => {
            info.default_value = param_defaults.LFO2Wave3.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "S&H/S&G");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2PW => {
            info.default_value = param_defaults.LFO2PW.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Pulse Width");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2ModAmt1 => {
            info.default_value = param_defaults.LFO2ModAmt1.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Mod Amt 1");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2ModAmt2 => {
            info.default_value = param_defaults.LFO2ModAmt2.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Mod Amt 2");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2ToOsc1Pitch => {
            info.default_value = param_defaults.LFO2ToOsc1Pitch.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Osc1 Pitch");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2ToOsc2Pitch => {
            info.default_value = param_defaults.LFO2ToOsc2Pitch.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Osc2 Pitch");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2ToCutoff => {
            info.default_value = param_defaults.LFO2ToCutoff.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Cutoff");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2ToOsc1PW => {
            info.default_value = param_defaults.LFO2ToOsc1PW.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Osc1 PW");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2ToOsc2PW => {
            info.default_value = param_defaults.LFO2ToOsc2PW.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Osc2 PW");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },
        .LFO2ToVolume => {
            info.default_value = param_defaults.LFO2ToVolume.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "To Volume");
            std.mem.copyForwards(u8, &info.module, "LFO 2");
        },

        // Envelope Modulation
        .EnvToPitchAmt => {
            info.default_value = param_defaults.EnvToPitchAmt.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Env > Pitch Amt");
            std.mem.copyForwards(u8, &info.module, "Env Modulation");
        },
        .EnvToPitchInvert => {
            info.default_value = param_defaults.EnvToPitchInvert.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Env > Pitch Inv");
            std.mem.copyForwards(u8, &info.module, "Env Modulation");
        },
        .EnvToPitchBothOscs => {
            info.default_value = param_defaults.EnvToPitchBothOscs.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Env > Pitch Both");
            std.mem.copyForwards(u8, &info.module, "Env Modulation");
        },
        .EnvToPWAmt => {
            info.default_value = param_defaults.EnvToPWAmt.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Env > PW Amt");
            std.mem.copyForwards(u8, &info.module, "Env Modulation");
        },
        .EnvToPWInvert => {
            info.default_value = param_defaults.EnvToPWInvert.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Env > PW Invert");
            std.mem.copyForwards(u8, &info.module, "Env Modulation");
        },
        .EnvToPWBothOscs => {
            info.default_value = param_defaults.EnvToPWBothOscs.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Env > PW Both");
            std.mem.copyForwards(u8, &info.module, "Env Modulation");
        },

        // Performance
        .Volume => {
            info.default_value = param_defaults.Volume.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Volume");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .Portamento => {
            info.default_value = param_defaults.Portamento.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Portamento");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .Tune => {
            info.default_value = param_defaults.Tune.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Tune");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .Transpose => {
            info.default_value = param_defaults.Transpose.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Transpose");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .Unison => {
            info.default_value = param_defaults.Unison.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Unison");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .UnisonDetune => {
            info.default_value = param_defaults.UnisonDetune.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Unison Detune");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .BendUpRange => {
            info.default_value = param_defaults.BendUpRange.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Bend Up Range");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .BendDownRange => {
            info.default_value = param_defaults.BendDownRange.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Bend Down Range");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .BendOsc2Only => {
            info.default_value = param_defaults.BendOsc2Only.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Bend Osc2 Only");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .VelToAmp => {
            info.default_value = param_defaults.VelToAmp.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Vel > Amp");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .VelToFilter => {
            info.default_value = param_defaults.VelToFilter.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Vel > Filter");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .NotePriority => {
            info.default_value = param_defaults.NotePriority.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Note Priority");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },
        .EnvLegatoMode => {
            info.default_value = param_defaults.EnvLegatoMode.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Legato Mode");
            std.mem.copyForwards(u8, &info.module, "Performance");
        },

        // Slop (Analog Character)
        .EnvSlop => {
            info.default_value = param_defaults.EnvSlop.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Env Slop");
            std.mem.copyForwards(u8, &info.module, "Slop");
        },
        .FilterSlop => {
            info.default_value = param_defaults.FilterSlop.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Filter Slop");
            std.mem.copyForwards(u8, &info.module, "Slop");
        },
        .PortamentoSlop => {
            info.default_value = param_defaults.PortamentoSlop.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Portamento Slop");
            std.mem.copyForwards(u8, &info.module, "Slop");
        },
        .LevelSlop => {
            info.default_value = param_defaults.LevelSlop.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Level Slop");
            std.mem.copyForwards(u8, &info.module, "Slop");
        },

        // Quality
        .HQMode => {
            info.default_value = param_defaults.HQMode.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "HQ Mode");
            std.mem.copyForwards(u8, &info.module, "Quality");
        },

        // Vibrato
        .VibratoRate => {
            info.default_value = param_defaults.VibratoRate.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            std.mem.copyForwards(u8, &info.name, "Vibrato Rate");
            std.mem.copyForwards(u8, &info.module, "Vibrato");
        },
        .VibratoWave => {
            info.default_value = param_defaults.VibratoWave.Float;
            info.min_value = 0.0;
            info.max_value = 1.0;
            info.flags.is_stepped = true;
            std.mem.copyForwards(u8, &info.name, "Vibrato Wave");
            std.mem.copyForwards(u8, &info.module, "Vibrato");
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

const switch_names = [_][]const u8{ "Off", "On" };
const tristate_names = [_][]const u8{ "Off", "+", "-" };
const priority_names = [_][]const u8{ "Latest", "Lowest", "Highest" };
const legato_names = [_][]const u8{ "Off", "Amp", "Filter", "Both" };
const vibrato_wave_names = [_][]const u8{ "Sine", "Square" };
const xpander_mode_names = [_][]const u8{
    "LP4", "LP3", "LP2", "LP1", "BP4", "BP2", "HP4", "HP3", "HP2", "HP1", "N4", "N3", "N2", "AP4", "AP3",
};

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

    const out = switch (param) {
        // Boolean switch params
        .Osc1Saw,
        .Osc1Pulse,
        .Osc2Saw,
        .Osc2Pulse,
        .OscSync,
        .Filter4Pole,
        .FilterBPBlend,
        .FilterXpander,
        .FilterEnvInvert,
        .Filter2PolePush,
        .Unison,
        .BendOsc2Only,
        .EnvToPitchInvert,
        .EnvToPitchBothOscs,
        .EnvToPWInvert,
        .EnvToPWBothOscs,
        .LFO1Sync,
        .LFO2Sync,
        .HQMode,
        => blk: {
            const idx: usize = @intFromFloat(@round(@max(0.0, @min(1.0, value))));
            break :blk std.fmt.bufPrintZ(buffer[0..size], "{s}", .{switch_names[idx]});
        },

        // Tri-state params (0=Off, 0.5=+, 1=-)
        .LFO1ToOsc1Pitch,
        .LFO1ToOsc2Pitch,
        .LFO1ToCutoff,
        .LFO1ToOsc1PW,
        .LFO1ToOsc2PW,
        .LFO1ToVolume,
        .LFO2ToOsc1Pitch,
        .LFO2ToOsc2Pitch,
        .LFO2ToCutoff,
        .LFO2ToOsc1PW,
        .LFO2ToOsc2PW,
        .LFO2ToVolume,
        => blk: {
            const idx: usize = if (value < 0.25) 0 else if (value < 0.75) 1 else 2;
            break :blk std.fmt.bufPrintZ(buffer[0..size], "{s}", .{tristate_names[idx]});
        },

        // Note priority (0=Latest, 0.5=Lowest, 1=Highest)
        .NotePriority => blk: {
            const idx: usize = if (value < 0.25) 0 else if (value < 0.75) 1 else 2;
            break :blk std.fmt.bufPrintZ(buffer[0..size], "{s}", .{priority_names[idx]});
        },

        // Legato mode (0=Off, 0.33=Amp, 0.66=Filter, 1=Both)
        .EnvLegatoMode => blk: {
            const idx: usize = if (value < 0.125) 0 else if (value < 0.375) 1 else if (value < 0.625) 2 else 3;
            break :blk std.fmt.bufPrintZ(buffer[0..size], "{s}", .{legato_names[idx]});
        },

        // Xpander mode (0-14 stepped)
        .FilterXpanderMode => blk: {
            const idx: usize = @intFromFloat(@round(@max(0.0, @min(14.0, value))));
            break :blk std.fmt.bufPrintZ(buffer[0..size], "{s}", .{xpander_mode_names[idx]});
        },

        // Noise color (0=White, ~0.33=Pink, ~1=Red)
        .NoiseColor => blk: {
            if (value < 0.17) {
                break :blk std.fmt.bufPrintZ(buffer[0..size], "White", .{});
            } else if (value < 0.5) {
                break :blk std.fmt.bufPrintZ(buffer[0..size], "Pink", .{});
            } else {
                break :blk std.fmt.bufPrintZ(buffer[0..size], "Red", .{});
            }
        },

        // Vibrato wave
        .VibratoWave => blk: {
            const idx: usize = @intFromFloat(@round(@max(0.0, @min(1.0, value))));
            break :blk std.fmt.bufPrintZ(buffer[0..size], "{s}", .{vibrato_wave_names[idx]});
        },

        // Percentage display for continuous 0-1 params
        .Osc1Volume,
        .Osc2Volume,
        .NoiseVolume,
        .RingModVolume,
        .FilterCutoff,
        .FilterResonance,
        .FilterMode,
        .FilterEnvAmount,
        .FilterKeyTrack,
        .AmpAttack,
        .AmpDecay,
        .AmpSustain,
        .AmpRelease,
        .AmpAttackCurve,
        .FilterAttack,
        .FilterDecay,
        .FilterSustain,
        .FilterRelease,
        .FilterAttackCurve,
        .LFO1Rate,
        .LFO1Wave1,
        .LFO1Wave2,
        .LFO1Wave3,
        .LFO1PW,
        .LFO1ModAmt1,
        .LFO1ModAmt2,
        .LFO2Rate,
        .LFO2Wave1,
        .LFO2Wave2,
        .LFO2Wave3,
        .LFO2PW,
        .LFO2ModAmt1,
        .LFO2ModAmt2,
        .EnvToPitchAmt,
        .EnvToPWAmt,
        .Volume,
        .Portamento,
        .UnisonDetune,
        .BendUpRange,
        .BendDownRange,
        .VelToAmp,
        .VelToFilter,
        .EnvSlop,
        .FilterSlop,
        .PortamentoSlop,
        .LevelSlop,
        .VibratoRate,
        .Osc1Pitch,
        .Osc2Pitch,
        .Osc2Detune,
        .PulseWidth,
        .Crossmod,
        .OscBrightness,
        .Osc2PWOffset,
        .Tune,
        .Transpose,
        => std.fmt.bufPrintZ(buffer[0..size], "{d:.2}", .{value}),
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
    value.* = std.fmt.parseFloat(f64, slice) catch return false;
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
        defer plugin.params.mutex.unlock(mutex_io);

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
