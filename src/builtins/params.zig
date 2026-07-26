//! Parameter layout matching DAWproject project.xsd builtins.
//! Stable CLAP ids = parameterID in XML for Bitwig interchange.
//! Definitions live in `param_table.zig`; this file builds CLAP ParamDef lists.
//! CLAP extension callbacks live in `shared.ext.params`.

const std = @import("std");
const clap = @import("clap-bindings");
const shared_params = @import("shared").ext.params;
const eq_dsp = @import("dsp/equalizer.zig");
const table = @import("flux_param_table");
const Kind = table.Kind;

pub const max_params = 64;
pub const ParamDef = shared_params.ParamDef;
pub const UnitTag = shared_params.UnitTag;

// Re-export stable ids for plugin / view code
pub const id_attack = table.id_attack;
pub const id_release = table.id_release;
pub const id_threshold = table.id_threshold;
pub const id_ratio = table.id_ratio;
pub const id_input_gain = table.id_input_gain;
pub const id_output_gain = table.id_output_gain;
pub const id_auto_makeup = table.id_auto_makeup;
pub const id_range = table.id_range;
pub const id_eq_input_gain = table.id_eq_input_gain;
pub const id_eq_output_gain = table.id_eq_output_gain;
pub const id_eq_band0 = table.id_eq_band0;
pub const eqBandBase = table.eqBandBase;
pub const param_table = table;

pub const Params = struct {
    kind: Kind,
    values: [max_params]f64 = @splat(0),
    defs: [max_params]ParamDef = undefined,
    count: u32 = 0,
    dirty: bool = true,

    pub fn init(kind: Kind) Params {
        var p: Params = .{ .kind = kind };
        for (table.params) |row| {
            if (!table.kindHas(row, kind)) continue;
            p.add(toParamDef(row));
        }
        if (kind == .equalizer) {
            addEqBands(&p);
        }
        return p;
    }

    fn addEqBands(p: *Params) void {
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
            const defaults = [_]f64{
                @floatFromInt(@intFromEnum(band.type)),
                band.freq_hz,
                band.gain_db,
                band.q,
                if (band.enabled) 1 else 0,
            };
            for (table.eq_band_fields, 0..) |field, fi| {
                p.add(.{
                    .id = base + field.offset,
                    .name = names[fi],
                    .schema_name = field.schema,
                    .min = field.min,
                    .max = field.max,
                    .default = defaults[fi],
                    .unit = toUnitTag(field.unit),
                    .is_bool = field.is_bool,
                    .stepped = field.stepped or field.is_bool,
                    .display = displayFor(field.unit, field.is_bool),
                });
            }
        }
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

fn toUnitTag(u: table.Unit) UnitTag {
    return switch (u) {
        .linear => .linear,
        .decibel => .decibel,
        .seconds => .seconds,
        .hertz => .hertz,
    };
}

fn displayFor(u: table.Unit, is_bool: bool) shared_params.Display {
    if (is_bool) return .bool_on_off;
    return toUnitTag(u).toDisplay();
}

fn toParamDef(row: table.BuiltinParam) ParamDef {
    return .{
        .id = row.id,
        .name = row.name,
        .schema_name = row.schema,
        .min = row.min,
        .max = row.max,
        .default = row.default,
        .unit = toUnitTag(row.unit),
        .is_bool = row.is_bool,
        .stepped = row.is_bool,
        .display = displayFor(row.unit, row.is_bool),
    };
}
