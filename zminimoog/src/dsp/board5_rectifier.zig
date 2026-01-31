// Board 5: Rectifier Board
// Minimoog Model D Power Rectification Circuit
//
// This board converts AC from the transformer to raw DC rails.
// Schematic page 12 of Minimoog-schematics.pdf
//
// Circuit topology:
//   AC Input (15 VAC) comes from transformer with center tap (ground)
//
//   Full-wave bridge rectifier using four 1N4004 diodes:
//     CR3, CR4 form positive half (connect to PLUS_20V_UNREG)
//     CR1, CR2 form negative half (connect to MINUS_20V_UNREG)
//
//   Smoothing capacitors:
//     C1: 1000uF - main smoothing for negative rail
//     C2: 1000uF - main smoothing for positive rail
//     C3: 0.01uF - HF decoupling for positive rail
//     C4: 470uF  - additional smoothing for negative rail
//
// For audio DSP, this models power supply ripple and sag effects.

const std = @import("std");
const wdft = @import("zig_wdf");

// Component values from schematic
pub const ComponentValues = struct {
    // Diodes (1N4004)
    pub const diode_is: comptime_float = 1.0e-9; // Saturation current (typical for 1N4004)
    pub const diode_vt: comptime_float = 25.85e-3; // Thermal voltage at 25°C
    pub const diode_n: comptime_float = 1.8; // Ideality factor for 1N4004

    // Capacitors
    pub const c1_value: comptime_float = 1000.0e-6; // 1000uF
    pub const c2_value: comptime_float = 1000.0e-6; // 1000uF
    pub const c3_value: comptime_float = 0.01e-6; // 0.01uF (10nF)
    pub const c4_value: comptime_float = 470.0e-6; // 470uF

    // AC Input
    pub const ac_voltage_peak: comptime_float = 15.0 * std.math.sqrt2; // 15 VAC RMS -> peak
    pub const ac_frequency: comptime_float = 60.0; // 60 Hz mains

    // Internal resistance (ESR of transformer + wiring)
    pub const source_resistance: comptime_float = 1.0; // ~1 ohm source impedance
};

/// Half-wave rectifier with smoothing capacitor
/// Models one rail (positive or negative) of the power supply
/// Circuit: Vin --[Rsrc]--[D]--+-- Vout
///                             |
///                            [C]
///                             |
///                            GND
pub fn HalfWaveRectifier(comptime T: type) type {
    const Rsrc = wdft.ResistiveVoltageSource(T);
    const C = wdft.Capacitor(T);
    const S = wdft.Series(T, Rsrc, C);
    const D = wdft.Diode(T, S);

    return struct {
        circuit: D,

        const Self = @This();

        pub fn init(source_resistance: T, capacitance: T, sample_rate: T) Self {
            return .{
                .circuit = D.init(
                    S.init(
                        Rsrc.init(source_resistance),
                        C.init(capacitance, sample_rate),
                    ),
                    ComponentValues.diode_is,
                    ComponentValues.diode_vt,
                    ComponentValues.diode_n,
                ),
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.circuit.next.port2.prepare(sample_rate);
            self.circuit.calcImpedance();
        }

        pub fn reset(self: *Self) void {
            self.circuit.next.port2.reset();
        }

        pub fn setInputVoltage(self: *Self, v: T) void {
            self.circuit.next.port1.setVoltage(v);
        }

        pub fn getOutputVoltage(self: *Self) T {
            return wdft.voltage(T, &self.circuit.next.port2.wdf);
        }

        pub inline fn process(self: *Self) void {
            self.circuit.process();
        }

        pub inline fn processSample(self: *Self, input: T) T {
            self.setInputVoltage(input);
            self.process();
            return self.getOutputVoltage();
        }
    };
}

/// Full-wave rectifier for single rail with parallel smoothing capacitors
/// Models the positive or negative rail with main cap + secondary cap
/// Circuit: |AC1|--[D1]--+
///                       |
///          |AC2|--[D2]--+--[C_main]--+--[C_secondary]-- Vout
///                                    |
///                                   GND
pub fn FullWaveRailRectifier(comptime T: type) type {
    const Rsrc = wdft.ResistiveVoltageSource(T);
    const C1 = wdft.Capacitor(T);
    const C2 = wdft.Capacitor(T);
    const ParallelCaps = wdft.Parallel(T, C1, C2);
    const S = wdft.Series(T, Rsrc, ParallelCaps);
    const D = wdft.Diode(T, S);

    return struct {
        circuit: D,

        const Self = @This();

        pub fn init(
            source_resistance: T,
            main_capacitance: T,
            secondary_capacitance: T,
            sample_rate: T,
        ) Self {
            return .{
                .circuit = D.init(
                    S.init(
                        Rsrc.init(source_resistance),
                        ParallelCaps.init(
                            C1.init(main_capacitance, sample_rate),
                            C2.init(secondary_capacitance, sample_rate),
                        ),
                    ),
                    ComponentValues.diode_is,
                    ComponentValues.diode_vt,
                    ComponentValues.diode_n,
                ),
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.circuit.next.port2.port1.prepare(sample_rate);
            self.circuit.next.port2.port2.prepare(sample_rate);
            self.circuit.calcImpedance();
        }

        pub fn reset(self: *Self) void {
            self.circuit.next.port2.port1.reset();
            self.circuit.next.port2.port2.reset();
        }

        pub fn setInputVoltage(self: *Self, v: T) void {
            self.circuit.next.port1.setVoltage(v);
        }

        pub fn getOutputVoltage(self: *Self) T {
            return wdft.voltage(T, &self.circuit.next.port2.wdf);
        }

        pub inline fn process(self: *Self) void {
            self.circuit.process();
        }

        pub inline fn processSample(self: *Self, input: T) T {
            self.setInputVoltage(input);
            self.process();
            return self.getOutputVoltage();
        }
    };
}

/// Board 5 Rectifier - Complete dual-rail power supply
/// Provides both +20V and -20V unregulated rails from AC input
pub fn Board5Rectifier(comptime T: type) type {
    return struct {
        positive_rail: FullWaveRailRectifier(T),
        negative_rail: FullWaveRailRectifier(T),
        sample_rate: T,
        phase: T = 0.0,
        phase_increment: T,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            const phase_inc = (2.0 * std.math.pi * ComponentValues.ac_frequency) / sample_rate;

            return .{
                // Positive rail: C2 (1000uF) + C3 (0.01uF)
                .positive_rail = FullWaveRailRectifier(T).init(
                    ComponentValues.source_resistance,
                    ComponentValues.c2_value,
                    ComponentValues.c3_value,
                    sample_rate,
                ),
                // Negative rail: C1 (1000uF) + C4 (470uF)
                .negative_rail = FullWaveRailRectifier(T).init(
                    ComponentValues.source_resistance,
                    ComponentValues.c1_value,
                    ComponentValues.c4_value,
                    sample_rate,
                ),
                .sample_rate = sample_rate,
                .phase_increment = phase_inc,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.phase_increment = (2.0 * std.math.pi * ComponentValues.ac_frequency) / sample_rate;
            self.positive_rail.prepare(sample_rate);
            self.negative_rail.prepare(sample_rate);
        }

        pub fn reset(self: *Self) void {
            self.phase = 0.0;
            self.positive_rail.reset();
            self.negative_rail.reset();
        }

        /// Process one sample with internal AC generation
        /// Returns struct with both rail voltages
        pub fn processSample(self: *Self) RailVoltages(T) {
            // Generate AC input (simulating transformer output)
            const ac_voltage = ComponentValues.ac_voltage_peak * @sin(self.phase);
            self.phase += self.phase_increment;
            if (self.phase >= 2.0 * std.math.pi) {
                self.phase -= 2.0 * std.math.pi;
            }

            return self.processSampleWithAC(ac_voltage);
        }

        /// Process one sample with external AC input
        pub fn processSampleWithAC(self: *Self, ac_voltage: T) RailVoltages(T) {
            // Positive rail rectifies positive half-cycle
            const v_plus = self.positive_rail.processSample(ac_voltage);

            // Negative rail rectifies negative half-cycle (inverted input)
            const v_minus = self.negative_rail.processSample(-ac_voltage);

            return .{
                .plus_20v = v_plus,
                .minus_20v = -v_minus, // Invert to get negative voltage
            };
        }

        /// Get current rail voltages without processing
        pub fn getRailVoltages(self: *Self) RailVoltages(T) {
            return .{
                .plus_20v = self.positive_rail.getOutputVoltage(),
                .minus_20v = -self.negative_rail.getOutputVoltage(),
            };
        }
    };
}

pub fn RailVoltages(comptime T: type) type {
    return struct {
        plus_20v: T,
        minus_20v: T,

        const Self = @This();

        /// Get the total rail-to-rail voltage
        pub fn totalVoltage(self: Self) T {
            return self.plus_20v - self.minus_20v;
        }

        /// Get average deviation from nominal (ripple indicator)
        pub fn ripple(self: Self, nominal_plus: T, nominal_minus: T) T {
            const plus_dev = self.plus_20v - nominal_plus;
            const minus_dev = self.minus_20v - nominal_minus;
            return (plus_dev - minus_dev) * 0.5;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

fn expectApproxEq(actual: f64, expected: f64, tolerance: f64) !void {
    if (@abs(actual - expected) >= tolerance) {
        std.debug.print("Expected: {d}, Actual: {d}, Diff: {d}\n", .{ expected, actual, actual - expected });
        return error.TestExpectedApproxEq;
    }
}

test "half-wave rectifier basic operation" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var rectifier = HalfWaveRectifier(T).init(
        ComponentValues.source_resistance,
        ComponentValues.c2_value,
        sample_rate,
    );

    // Process positive input - should charge capacitor
    const v1 = rectifier.processSample(10.0);
    try std.testing.expect(v1 > 0.0);

    // Process more positive cycles to charge up
    var last_v: T = v1;
    for (0..1000) |_| {
        const v = rectifier.processSample(10.0);
        try std.testing.expect(v >= last_v - 0.01); // Should stay roughly same or increase
        last_v = v;
    }

    // Negative input should not increase voltage (diode blocks)
    const v_before = rectifier.getOutputVoltage();
    _ = rectifier.processSample(-10.0);
    const v_after = rectifier.getOutputVoltage();
    try std.testing.expect(v_after <= v_before + 0.001);
}

test "board5 rectifier produces dual rails" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var board5 = Board5Rectifier(T).init(sample_rate);

    // Run for several AC cycles to charge capacitors
    const samples_per_cycle = @as(usize, @intFromFloat(sample_rate / ComponentValues.ac_frequency));
    for (0..samples_per_cycle * 10) |_| {
        _ = board5.processSample();
    }

    const voltages = board5.getRailVoltages();

    // Positive rail should be positive
    try std.testing.expect(voltages.plus_20v > 0.0);

    // Negative rail should be negative
    try std.testing.expect(voltages.minus_20v < 0.0);

    // Total voltage should be reasonable (should approach ~40V after charging)
    const total = voltages.totalVoltage();
    try std.testing.expect(total > 20.0); // At least some charging
}

test "board5 rectifier ripple is bounded" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var board5 = Board5Rectifier(T).init(sample_rate);

    // Run for several cycles to reach steady state
    const samples_per_cycle = @as(usize, @intFromFloat(sample_rate / ComponentValues.ac_frequency));
    for (0..samples_per_cycle * 100) |_| {
        _ = board5.processSample();
    }

    // Measure ripple over one cycle
    var max_plus: T = -std.math.inf(T);
    var min_plus: T = std.math.inf(T);
    var max_minus: T = -std.math.inf(T);
    var min_minus: T = std.math.inf(T);

    for (0..samples_per_cycle) |_| {
        const v = board5.processSample();
        max_plus = @max(max_plus, v.plus_20v);
        min_plus = @min(min_plus, v.plus_20v);
        max_minus = @max(max_minus, v.minus_20v);
        min_minus = @min(min_minus, v.minus_20v);
    }

    const ripple_plus = max_plus - min_plus;
    const ripple_minus = max_minus - min_minus;

    // With large smoothing caps, ripple should be small (< 5V for this simplified model)
    try std.testing.expect(ripple_plus < 5.0);
    try std.testing.expect(ripple_minus < 5.0);
}
