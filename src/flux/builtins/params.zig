//! Parameter layout matching DAWproject project.xsd builtins.
//! Stable CLAP ids = parameterID in XML for Bitwig interchange.
//! CLAP extension callbacks live in `shared.ext.params`.

const std = @import("std");
const clap = @import("clap-bindings");
const shared_params = @import("shared").ext.params;
const Kind = @import("kind.zig").Kind;
const eq_dsp = @import("dsp/equalizer.zig");

pub const max_params = 64;
pub const ParamDef = shared_params.ParamDef;
pub const UnitTag = shared_params.UnitTag;

// Stable param IDs (also written as parameterID bit pattern)
pub const id_attack: u32 = 1;
pub const id_release: u32 = 2;
pub const id_threshold: u32 = 3;
pub const id_ratio: u32 = 4;
pub const id_input_gain: u32 = 5;
pub const id_output_gain: u32 = 6;
pub const id_auto_makeup: u32 = 7;
pub const id_range: u32 = 8;

pub const id_eq_input_gain: u32 = 100;
pub const id_eq_output_gain: u32 = 101;
pub const id_eq_band0: u32 = 200; // +0 type, +1 freq, +2 gain, +3 q, +4 enabled; stride 10

pub fn eqBandBase(band: usize) u32 {
    return id_eq_band0 + @as(u32, @intCast(band)) * 10;
}

pub const Params = struct {
    kind: Kind,
    values: [max_params]f64 = @splat(0),
    defs: [max_params]ParamDef = undefined,
    count: u32 = 0,
    dirty: bool = true,

    pub fn init(kind: Kind) Params {
        var p: Params = .{ .kind = kind };
        switch (kind) {
            .compressor => {
                p.add(.{ .id = id_threshold, .name = "Threshold", .schema_name = "Threshold", .min = -60, .max = 0, .default = -18, .unit = .decibel, .display = .number });
                p.add(.{ .id = id_ratio, .name = "Ratio", .schema_name = "Ratio", .min = 1, .max = 20, .default = 4 });
                p.add(.{ .id = id_attack, .name = "Attack", .schema_name = "Attack", .min = 0.0001, .max = 1, .default = 0.01, .unit = .seconds, .display = .seconds });
                p.add(.{ .id = id_release, .name = "Release", .schema_name = "Release", .min = 0.001, .max = 2, .default = 0.1, .unit = .seconds, .display = .seconds });
                p.add(.{ .id = id_input_gain, .name = "InputGain", .schema_name = "InputGain", .min = -24, .max = 24, .default = 0, .unit = .decibel });
                p.add(.{ .id = id_output_gain, .name = "OutputGain", .schema_name = "OutputGain", .min = -24, .max = 24, .default = 0, .unit = .decibel });
                p.add(.{ .id = id_auto_makeup, .name = "AutoMakeup", .schema_name = "AutoMakeup", .min = 0, .max = 1, .default = 1, .is_bool = true, .stepped = true, .display = .bool_on_off });
            },
            .noise_gate => {
                p.add(.{ .id = id_threshold, .name = "Threshold", .schema_name = "Threshold", .min = -80, .max = 0, .default = -40, .unit = .decibel });
                p.add(.{ .id = id_ratio, .name = "Ratio", .schema_name = "Ratio", .min = 1, .max = 20, .default = 10 });
                p.add(.{ .id = id_attack, .name = "Attack", .schema_name = "Attack", .min = 0.0001, .max = 1, .default = 0.001, .unit = .seconds, .display = .seconds });
                p.add(.{ .id = id_release, .name = "Release", .schema_name = "Release", .min = 0.001, .max = 2, .default = 0.1, .unit = .seconds, .display = .seconds });
                p.add(.{ .id = id_range, .name = "Range", .schema_name = "Range", .min = -80, .max = 0, .default = -60, .unit = .decibel });
            },
            .limiter => {
                p.add(.{ .id = id_threshold, .name = "Threshold", .schema_name = "Threshold", .min = -24, .max = 0, .default = 0, .unit = .decibel });
                p.add(.{ .id = id_attack, .name = "Attack", .schema_name = "Attack", .min = 0.0001, .max = 0.1, .default = 0.001, .unit = .seconds, .display = .seconds });
                p.add(.{ .id = id_release, .name = "Release", .schema_name = "Release", .min = 0.001, .max = 1, .default = 0.05, .unit = .seconds, .display = .seconds });
                p.add(.{ .id = id_input_gain, .name = "InputGain", .schema_name = "InputGain", .min = -24, .max = 24, .default = 0, .unit = .decibel });
                p.add(.{ .id = id_output_gain, .name = "OutputGain", .schema_name = "OutputGain", .min = -24, .max = 24, .default = 0, .unit = .decibel });
            },
            .equalizer => {
                p.add(.{ .id = id_eq_input_gain, .name = "InputGain", .schema_name = "InputGain", .min = -24, .max = 24, .default = 0, .unit = .decibel });
                p.add(.{ .id = id_eq_output_gain, .name = "OutputGain", .schema_name = "OutputGain", .min = -24, .max = 24, .default = 0, .unit = .decibel });
                const eq_defaults = eq_dsp.Equalizer{};
                const band_names = [_][5][:0]const u8{
                    .{ "B1 Type", "B1 Freq", "B1 Gain", "B1 Q", "B1 Enabled" },
                    .{ "B2 Type", "B2 Freq", "B2 Gain", "B2 Q", "B2 Enabled" },
                    .{ "B3 Type", "B3 Freq", "B3 Gain", "B3 Q", "B3 Enabled" },
                    .{ "B4 Type", "B4 Freq", "B4 Gain", "B4 Q", "B4 Enabled" },
                    .{ "B5 Type", "B5 Freq", "B5 Gain", "B5 Q", "B5 Enabled" },
                    .{ "B6 Type", "B6 Freq", "B6 Gain", "B6 Q", "B6 Enabled" },
                };
                for (0..eq_defaults.band_count) |b| {
                    const base = eqBandBase(b);
                    const band = eq_defaults.bands[b];
                    const names = band_names[b];
                    p.add(.{ .id = base + 0, .name = names[0], .schema_name = "Type", .min = 0, .max = 6, .default = @floatFromInt(@intFromEnum(band.type)), .stepped = true });
                    p.add(.{ .id = base + 1, .name = names[1], .schema_name = "Freq", .min = 20, .max = 20000, .default = band.freq_hz, .unit = .hertz, .display = .hz });
                    p.add(.{ .id = base + 2, .name = names[2], .schema_name = "Gain", .min = -24, .max = 24, .default = band.gain_db, .unit = .decibel });
                    p.add(.{ .id = base + 3, .name = names[3], .schema_name = "Q", .min = 0.1, .max = 10, .default = band.q });
                    p.add(.{ .id = base + 4, .name = names[4], .schema_name = "Enabled", .min = 0, .max = 1, .default = if (band.enabled) 1 else 0, .is_bool = true, .stepped = true, .display = .bool_on_off });
                }
            },
        }
        return p;
    }

    fn add(self: *Params, def: ParamDef) void {
        if (self.count >= max_params) return;
        self.defs[self.count] = def;
        self.values[self.count] = def.default;
        self.count += 1;
    }

    pub fn indexOf(self: *const Params, id: u32) ?u32 {
        for (0..self.count) |i| {
            if (self.defs[i].id == id) return @intCast(i);
        }
        return null;
    }

    pub fn get(self: *const Params, id: u32) f64 {
        if (self.indexOf(id)) |i| return self.values[i];
        return 0;
    }

    pub fn getBool(self: *const Params, id: u32) bool {
        return self.get(id) >= 0.5;
    }

    pub fn set(self: *Params, id: u32, value: f64) void {
        if (self.indexOf(id)) |i| {
            const d = self.defs[i];
            self.values[i] = std.math.clamp(value, d.min, d.max);
            self.dirty = true;
        }
    }

    pub fn setByIndex(self: *Params, index: u32, value: f64) void {
        if (index >= self.count) return;
        const d = self.defs[index];
        self.values[index] = std.math.clamp(value, d.min, d.max);
        self.dirty = true;
    }

    pub fn unitToDawproject(u: UnitTag) []const u8 {
        return u.toDawproject();
    }

    pub fn createExt(comptime PluginType: type) clap.ext.params.Plugin {
        return shared_params.tableCreate(PluginType);
    }
};
