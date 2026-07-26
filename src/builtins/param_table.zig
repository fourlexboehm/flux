//! Single source of truth for Flux stock FX parameters.
//! CLAP defs, DAWproject schema names/units, XML write order, and load mapping
//! all derive from these tables. No clap/shared deps so project format tests can import.

const std = @import("std");
pub const Kind = @import("kind.zig").Kind;

pub const Unit = enum {
    linear,
    decibel,
    seconds,
    hertz,
};

/// One row = one CLAP param for one or more device kinds.
/// Table order for a kind = DAWproject XSD child write order.
pub const BuiltinParam = struct {
    id: u32,
    schema: []const u8,
    name: [:0]const u8,
    unit: Unit,
    min: f64,
    max: f64,
    default: f64,
    is_bool: bool = false,
    kinds: []const Kind,
};

// Stable CLAP / DAWproject parameterID values
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
pub const id_eq_band0: u32 = 200; // +0 type … +4 enabled; stride 10

pub fn eqBandBase(band: usize) u32 {
    return id_eq_band0 + @as(u32, @intCast(band)) * 10;
}

/// Dynamics + EQ device-level params. Order matches project.xsd child sequence
/// (Attack … Threshold) so XML writers can iterate rows for a kind directly.
pub const params = [_]BuiltinParam{
    // --- Attack (per-kind ranges) ---
    .{
        .id = id_attack,
        .schema = "Attack",
        .name = "Attack",
        .unit = .seconds,
        .min = 0.0001,
        .max = 1,
        .default = 0.01,
        .kinds = &.{.compressor},
    },
    .{
        .id = id_attack,
        .schema = "Attack",
        .name = "Attack",
        .unit = .seconds,
        .min = 0.0001,
        .max = 1,
        .default = 0.001,
        .kinds = &.{.noise_gate},
    },
    .{
        .id = id_attack,
        .schema = "Attack",
        .name = "Attack",
        .unit = .seconds,
        .min = 0.0001,
        .max = 0.1,
        .default = 0.001,
        .kinds = &.{.limiter},
    },
    // --- AutoMakeup ---
    .{
        .id = id_auto_makeup,
        .schema = "AutoMakeup",
        .name = "AutoMakeup",
        .unit = .linear,
        .min = 0,
        .max = 1,
        .default = 1,
        .is_bool = true,
        .kinds = &.{.compressor},
    },
    // --- InputGain ---
    .{
        .id = id_input_gain,
        .schema = "InputGain",
        .name = "InputGain",
        .unit = .decibel,
        .min = -24,
        .max = 24,
        .default = 0,
        .kinds = &.{ .compressor, .limiter },
    },
    .{
        .id = id_eq_input_gain,
        .schema = "InputGain",
        .name = "InputGain",
        .unit = .decibel,
        .min = -24,
        .max = 24,
        .default = 0,
        .kinds = &.{.equalizer},
    },
    // --- OutputGain ---
    .{
        .id = id_output_gain,
        .schema = "OutputGain",
        .name = "OutputGain",
        .unit = .decibel,
        .min = -24,
        .max = 24,
        .default = 0,
        .kinds = &.{ .compressor, .limiter },
    },
    .{
        .id = id_eq_output_gain,
        .schema = "OutputGain",
        .name = "OutputGain",
        .unit = .decibel,
        .min = -24,
        .max = 24,
        .default = 0,
        .kinds = &.{.equalizer},
    },
    // --- Range (gate) ---
    .{
        .id = id_range,
        .schema = "Range",
        .name = "Range",
        .unit = .decibel,
        .min = -80,
        .max = 0,
        .default = -60,
        .kinds = &.{.noise_gate},
    },
    // --- Ratio ---
    .{
        .id = id_ratio,
        .schema = "Ratio",
        .name = "Ratio",
        .unit = .linear,
        .min = 1,
        .max = 20,
        .default = 4,
        .kinds = &.{.compressor},
    },
    .{
        .id = id_ratio,
        .schema = "Ratio",
        .name = "Ratio",
        .unit = .linear,
        .min = 1,
        .max = 20,
        .default = 10,
        .kinds = &.{.noise_gate},
    },
    // --- Release ---
    .{
        .id = id_release,
        .schema = "Release",
        .name = "Release",
        .unit = .seconds,
        .min = 0.001,
        .max = 2,
        .default = 0.1,
        .kinds = &.{ .compressor, .noise_gate },
    },
    .{
        .id = id_release,
        .schema = "Release",
        .name = "Release",
        .unit = .seconds,
        .min = 0.001,
        .max = 1,
        .default = 0.05,
        .kinds = &.{.limiter},
    },
    // --- Threshold (per-kind ranges) ---
    .{
        .id = id_threshold,
        .schema = "Threshold",
        .name = "Threshold",
        .unit = .decibel,
        .min = -60,
        .max = 0,
        .default = -18,
        .kinds = &.{.compressor},
    },
    .{
        .id = id_threshold,
        .schema = "Threshold",
        .name = "Threshold",
        .unit = .decibel,
        .min = -80,
        .max = 0,
        .default = -40,
        .kinds = &.{.noise_gate},
    },
    .{
        .id = id_threshold,
        .schema = "Threshold",
        .name = "Threshold",
        .unit = .decibel,
        .min = -24,
        .max = 0,
        .default = 0,
        .kinds = &.{.limiter},
    },
};

/// EQ band sub-fields (Band element children). offset from eqBandBase(b).
pub const EqBandField = struct {
    offset: u32,
    schema: []const u8,
    unit: Unit,
    min: f64,
    max: f64,
    is_bool: bool = false,
    stepped: bool = false,
};

pub const eq_band_fields = [_]EqBandField{
    .{ .offset = 0, .schema = "Type", .unit = .linear, .min = 0, .max = 6, .stepped = true },
    .{ .offset = 1, .schema = "Freq", .unit = .hertz, .min = 20, .max = 20000 },
    .{ .offset = 2, .schema = "Gain", .unit = .decibel, .min = -24, .max = 24 },
    .{ .offset = 3, .schema = "Q", .unit = .linear, .min = 0.1, .max = 10 },
    .{ .offset = 4, .schema = "Enabled", .unit = .linear, .min = 0, .max = 1, .is_bool = true, .stepped = true },
};

pub fn kindHas(row: BuiltinParam, kind: Kind) bool {
    for (row.kinds) |k| {
        if (k == kind) return true;
    }
    return false;
}

pub fn findById(kind: Kind, id: u32) ?BuiltinParam {
    for (params) |row| {
        if (row.id == id and kindHas(row, kind)) return row;
    }
    return null;
}

pub fn findBySchema(kind: Kind, schema: []const u8) ?BuiltinParam {
    for (params) |row| {
        if (kindHas(row, kind) and std.mem.eql(u8, row.schema, schema)) return row;
    }
    return null;
}

/// Schema name for a CLAP param id (any kind). Falls back to EQ band fields, then null.
pub fn schemaNameForId(id: u32) ?[]const u8 {
    for (params) |row| {
        if (row.id == id) return row.schema;
    }
    if (id >= id_eq_band0) {
        const offset = (id - id_eq_band0) % 10;
        for (eq_band_fields) |f| {
            if (f.offset == offset) return f.schema;
        }
    }
    return null;
}

pub fn unitForSchema(schema: []const u8) Unit {
    for (params) |row| {
        if (std.mem.eql(u8, row.schema, schema)) return row.unit;
    }
    for (eq_band_fields) |f| {
        if (std.mem.eql(u8, f.schema, schema)) return f.unit;
    }
    if (std.mem.endsWith(u8, schema, "Gain")) return .decibel;
    if (std.mem.endsWith(u8, schema, "Freq")) return .hertz;
    return .linear;
}

pub fn unitForId(id: u32) Unit {
    for (params) |row| {
        if (row.id == id) return row.unit;
    }
    if (id >= id_eq_band0) {
        const offset = (id - id_eq_band0) % 10;
        for (eq_band_fields) |f| {
            if (f.offset == offset) return f.unit;
        }
    }
    return .linear;
}

test "kind+schema unique; XSD schema order" {
    for (Kind.all) |kind| {
        var seen: [16][]const u8 = undefined;
        var n: usize = 0;
        for (params) |row| {
            if (!kindHas(row, kind)) continue;
            for (seen[0..n]) |s| {
                try std.testing.expect(!std.mem.eql(u8, s, row.schema));
            }
            seen[n] = row.schema;
            n += 1;
        }
    }

    const expectOrder = struct {
        fn call(kind: Kind, expected: []const []const u8) !void {
            var i: usize = 0;
            for (params) |row| {
                if (!kindHas(row, kind)) continue;
                try std.testing.expect(i < expected.len);
                try std.testing.expectEqualStrings(expected[i], row.schema);
                i += 1;
            }
            try std.testing.expectEqual(expected.len, i);
        }
    }.call;
    try expectOrder(.equalizer, &.{ "InputGain", "OutputGain" });
    try expectOrder(.compressor, &.{ "Attack", "AutoMakeup", "InputGain", "OutputGain", "Ratio", "Release", "Threshold" });
    try expectOrder(.noise_gate, &.{ "Attack", "Range", "Ratio", "Release", "Threshold" });
    try expectOrder(.limiter, &.{ "Attack", "InputGain", "OutputGain", "Release", "Threshold" });
}
