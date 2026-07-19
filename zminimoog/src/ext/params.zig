const std = @import("std");
const clap = @import("clap-bindings");
const shared_params = @import("shared").ext.params;
const Plugin = @import("../plugin.zig");

pub const Parameter = enum {
    Osc1Level,
    Osc1Waveform,
    Osc1Range,
    Osc2Level,
    Osc2Waveform,
    Osc2Range,
    Osc2Detune,
    Osc3Level,
    Osc3Waveform,
    Osc3Range,
    Osc3Detune,
    Osc3KeyboardCtrl,
    NoiseLevel,
    NoiseType,
    FilterCutoff,
    FilterEmphasis,
    FilterContour,
    FilterKeyTracking,
    Osc3ToFilter,
    Osc3ToOsc,
    Attack,
    Decay,
    Sustain,
    Release,
    Glide,
    PitchBendRange,
    MasterVolume,
    OversampleFactor,
};

pub const ParameterValue = union(enum) {
    Float: f64,

    pub fn asFloat(parameterValue: ParameterValue) f64 {
        return switch (parameterValue) {
            .Float => |value| value,
        };
    }
};

pub const param_defaults = std.enums.EnumFieldStruct(Parameter, ParameterValue, null){
    .Osc1Level = .{ .Float = 1.0 },
    .Osc1Waveform = .{ .Float = 2.0 },
    .Osc1Range = .{ .Float = 3.0 },
    .Osc2Level = .{ .Float = 0.0 },
    .Osc2Waveform = .{ .Float = 2.0 },
    .Osc2Range = .{ .Float = 3.0 },
    .Osc2Detune = .{ .Float = 0.0 },
    .Osc3Level = .{ .Float = 0.0 },
    .Osc3Waveform = .{ .Float = 2.0 },
    .Osc3Range = .{ .Float = 3.0 },
    .Osc3Detune = .{ .Float = 0.0 },
    .Osc3KeyboardCtrl = .{ .Float = 1.0 },
    .NoiseLevel = .{ .Float = 0.0 },
    .NoiseType = .{ .Float = 0.0 },
    .FilterCutoff = .{ .Float = 5000.0 },
    .FilterEmphasis = .{ .Float = 0.0 },
    .FilterContour = .{ .Float = 0.5 },
    .FilterKeyTracking = .{ .Float = 1.0 },
    .Osc3ToFilter = .{ .Float = 0.0 },
    .Osc3ToOsc = .{ .Float = 0.0 },
    .Attack = .{ .Float = 0.01 },
    .Decay = .{ .Float = 0.3 },
    .Sustain = .{ .Float = 0.7 },
    .Release = .{ .Float = 0.3 },
    .Glide = .{ .Float = 0.0 },
    .PitchBendRange = .{ .Float = 2.0 },
    .MasterVolume = .{ .Float = 0.8 },
    .OversampleFactor = .{ .Float = 2.0 },
};

pub const waveform_names = [_][]const u8{ "Triangle", "Shark", "Sawtooth", "Square", "Wide Pulse", "Narrow Pulse" };
pub const range_names = [_][]const u8{ "LO", "32'", "16'", "8'", "4'", "2'" };
pub const noise_names = [_][]const u8{ "White", "Pink" };
pub const tracking_names = [_][]const u8{ "Off", "Half", "Full" };
pub const switch_names = [_][]const u8{ "Off", "On" };
pub const oversample_names = [_][]const u8{ "1x", "2x", "4x" };

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
        .Osc1Level => .{ .id = id(param), .name = "Osc 1 Level", .module = "Oscillators/Osc1", .min = 0, .max = 1, .default = d.Osc1Level.Float },
        .Osc1Waveform => .{ .id = id(param), .name = "Osc 1 Waveform", .module = "Oscillators/Osc1", .min = 0, .max = 5, .default = d.Osc1Waveform.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &waveform_names },
        .Osc1Range => .{ .id = id(param), .name = "Osc 1 Range", .module = "Oscillators/Osc1", .min = 0, .max = 5, .default = d.Osc1Range.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &range_names },
        .Osc2Level => .{ .id = id(param), .name = "Osc 2 Level", .module = "Oscillators/Osc2", .min = 0, .max = 1, .default = d.Osc2Level.Float },
        .Osc2Waveform => .{ .id = id(param), .name = "Osc 2 Waveform", .module = "Oscillators/Osc2", .min = 0, .max = 5, .default = d.Osc2Waveform.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &waveform_names },
        .Osc2Range => .{ .id = id(param), .name = "Osc 2 Range", .module = "Oscillators/Osc2", .min = 0, .max = 5, .default = d.Osc2Range.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &range_names },
        .Osc2Detune => .{ .id = id(param), .name = "Osc 2 Detune", .module = "Oscillators/Osc2", .min = -100, .max = 100, .default = d.Osc2Detune.Float, .display = .cents },
        .Osc3Level => .{ .id = id(param), .name = "Osc 3 Level", .module = "Oscillators/Osc3", .min = 0, .max = 1, .default = d.Osc3Level.Float },
        .Osc3Waveform => .{ .id = id(param), .name = "Osc 3 Waveform", .module = "Oscillators/Osc3", .min = 0, .max = 5, .default = d.Osc3Waveform.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &waveform_names },
        .Osc3Range => .{ .id = id(param), .name = "Osc 3 Range", .module = "Oscillators/Osc3", .min = 0, .max = 5, .default = d.Osc3Range.Float, .stepped = true, .is_enum = true, .display = .labels, .labels = &range_names },
        .Osc3Detune => .{ .id = id(param), .name = "Osc 3 Detune", .module = "Oscillators/Osc3", .min = -100, .max = 100, .default = d.Osc3Detune.Float, .display = .cents },
        .Osc3KeyboardCtrl => .{ .id = id(param), .name = "Osc 3 Keyboard", .module = "Oscillators/Osc3", .min = 0, .max = 1, .default = d.Osc3KeyboardCtrl.Float, .stepped = true, .display = .labels, .labels = &switch_names },
        .NoiseLevel => .{ .id = id(param), .name = "Noise Level", .module = "Mixer/Noise", .min = 0, .max = 1, .default = d.NoiseLevel.Float },
        .NoiseType => .{ .id = id(param), .name = "Noise Type", .module = "Mixer/Noise", .min = 0, .max = 1, .default = d.NoiseType.Float, .stepped = true, .display = .labels, .labels = &noise_names },
        .FilterCutoff => .{ .id = id(param), .name = "Cutoff", .module = "Filter", .min = 20, .max = 20000, .default = d.FilterCutoff.Float, .display = .hz },
        .FilterEmphasis => .{ .id = id(param), .name = "Emphasis", .module = "Filter", .min = 0, .max = 4, .default = d.FilterEmphasis.Float },
        .FilterContour => .{ .id = id(param), .name = "Contour Amt", .module = "Filter", .min = 0, .max = 1, .default = d.FilterContour.Float },
        .FilterKeyTracking => .{ .id = id(param), .name = "Key Tracking", .module = "Filter", .min = 0, .max = 2, .default = d.FilterKeyTracking.Float, .stepped = true, .display = .labels, .labels = &tracking_names },
        .Osc3ToFilter => .{ .id = id(param), .name = "Osc3 > Filter", .module = "Modulation", .min = 0, .max = 1, .default = d.Osc3ToFilter.Float, .stepped = true, .display = .labels, .labels = &switch_names },
        .Osc3ToOsc => .{ .id = id(param), .name = "Osc3 > Osc", .module = "Modulation", .min = 0, .max = 1, .default = d.Osc3ToOsc.Float, .stepped = true, .display = .labels, .labels = &switch_names },
        .Attack => .{ .id = id(param), .name = "Attack", .module = "Envelope", .min = 0.001, .max = 10, .default = d.Attack.Float, .display = .seconds },
        .Decay => .{ .id = id(param), .name = "Decay", .module = "Envelope", .min = 0.001, .max = 10, .default = d.Decay.Float, .display = .seconds },
        .Sustain => .{ .id = id(param), .name = "Sustain", .module = "Envelope", .min = 0, .max = 1, .default = d.Sustain.Float },
        .Release => .{ .id = id(param), .name = "Release", .module = "Envelope", .min = 0.001, .max = 10, .default = d.Release.Float, .display = .seconds },
        .Glide => .{ .id = id(param), .name = "Glide", .module = "Controllers", .min = 0, .max = 5, .default = d.Glide.Float, .display = .seconds },
        .PitchBendRange => .{ .id = id(param), .name = "Bend Range", .module = "Controllers", .min = 0, .max = 12, .default = d.PitchBendRange.Float, .display = .semitones },
        .MasterVolume => .{ .id = id(param), .name = "Master Volume", .module = "Output", .min = 0, .max = 1, .default = d.MasterVolume.Float },
        .OversampleFactor => .{ .id = id(param), .name = "Oversample", .module = "Quality", .min = 0, .max = 2, .default = d.OversampleFactor.Float, .stepped = true, .display = .labels, .labels = &oversample_names },
    };
}

pub fn create() clap.ext.params.Plugin {
    return clap_ext;
}

const clap_ext = shared_params.enumCreate(
    Plugin,
    Parameter,
    ParameterValue,
    meta,
    shared_params.fromFloatOnly(Parameter, ParameterValue),
    null,
    null,
);

pub const _flush = clap_ext.flush;
pub const _getInfo = clap_ext.getInfo;
pub const _valueToText = clap_ext.valueToText;
