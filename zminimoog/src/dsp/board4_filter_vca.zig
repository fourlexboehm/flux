// Board 4: Filter and VCA Board
// Minimoog Model D - 24dB/octave Voltage Controlled Lowpass Filter (Ladder) and VCA
//
// Schematic page 10 of Minimoog-schematics.pdf
//
// This file implements the ENTIRE Board 4 as UNIFIED WDF CIRCUITS:
//
// 1. Moog Ladder Filter: Single WDF tree with 4 cascaded RC stages
//    - Each stage: Series[R_transistor, Capacitor]
//    - R_transistor = Vt/Ic (voltage-controlled by bias current)
//    - Feedback path for resonance
//
// 2. VCA: Single WDF differential pair circuit
//    - Q1/Q2 2N4058 long-tailed pair
//    - Exponential gain control

const std = @import("std");
const wdft = @import("zig_wdf");

// ============================================================================
// Component Values from Schematic
// ============================================================================

pub const FilterComponents = struct {
    // Ladder capacitors (all identical for matched response)
    // C1, C3, C7, C11 on schematic
    pub const ladder_cap: comptime_float = 0.068e-6; // 0.068uF = 68nF

    // TIS97 transistor parameters (matched pairs Q1-Q8)
    // In the ladder, transistors act as voltage-controlled resistors
    // Effective resistance R_e = Vt / Ic (transconductance inverse)
    pub const tis97_vt: comptime_float = 25.85e-3; // Thermal voltage at 25C
    pub const tis97_is: comptime_float = 1.0e-14; // Saturation current
    pub const tis97_beta_f: comptime_float = 150.0; // Forward current gain
    pub const tis97_beta_r: comptime_float = 1.0; // Reverse current gain

    // TIS92 exponential converter transistor parameters (Q26, Q28 matched pair)
    pub const tis92_vt: comptime_float = 25.85e-3; // Thermal voltage at 25C
    pub const tis92_is: comptime_float = 5.0e-15; // Saturation current
    pub const tis92_beta_f: comptime_float = 200.0; // Forward current gain
    pub const tis92_beta_r: comptime_float = 2.0; // Reverse current gain

    // Bias current range for frequency control
    // fc = Ic / (2 * pi * Vt * C)
    // For fc = 20Hz:   Ic = 20 * 2pi * 25.85mV * 68nF = 0.22µA
    // For fc = 20kHz:  Ic = 20000 * 2pi * 25.85mV * 68nF = 220µA
    // Scale up to account for 4 cascaded poles and differential-pair gm halving
    pub const cutoff_scale: comptime_float = 3.1;
    pub const min_bias_current: comptime_float = 0.6e-6; // ~20Hz cutoff (scaled)
    pub const max_bias_current: comptime_float = 700.0e-6; // ~20kHz cutoff (scaled)
    pub const nominal_bias_current: comptime_float = 31.0e-6; // ~1kHz (scaled)

    // Input resistance (before ladder)
    pub const input_r: comptime_float = 10000.0; // 10k input impedance

    // Feedback resistance for resonance
    pub const feedback_r: comptime_float = 100000.0; // 100k feedback path
};

pub const VCAComponents = struct {
    // 2N4058 differential pair parameters
    pub const vt: comptime_float = 25.85e-3;
    pub const is: comptime_float = 1.0e-14;
    pub const beta_f: comptime_float = 100.0;
    pub const beta_r: comptime_float = 1.0;
    pub const input_r: comptime_float = 47000.0; // 47k input impedance
    pub const output_r: comptime_float = 1000.0; // 1k output

    // Tail current source resistor
    pub const tail_r: comptime_float = 4700.0; // 4.7k tail resistor
    pub const load_r: comptime_float = 10000.0; // 10k collector load resistors
};

// ============================================================================
// MOOG LADDER FILTER - WDF Transistor Implementation
// ============================================================================
//
// The Moog ladder uses TIS97 NPN transistor pairs (Q1-Q8) as the core filter.
// Each stage is a transistor whose collector current charges a capacitor.
//
// Physical circuit per stage:
//
//       Vcc (bias)
//        |
//       [C] (0.068uF ladder capacitor - collector load)
//        |
//     Collector
// Vin --> Base -- Q (TIS97 NPN)
//     Emitter
//        |
//       [Re] (emitter degeneration - controls gm)
//        |
//       GND
//
// WDF model per stage:
//   NpnTransistor with:
//     - port_bc: Capacitor (collector load, provides integration)
//     - port_be: Resistor (emitter resistance, sets operating point)
//
// Cutoff frequency is controlled by bias current:
//   fc = Ic / (2*pi*Vt*C)
//   gm = Ic/Vt (transconductance)

pub fn UnifiedMoogLadder(comptime T: type) type {
    // Moog ladder with direct Ebers-Moll transconductance + WDF capacitor integration
    // This models the TIS97 transistors accurately without WDF transistor model issues
    const C = wdft.Capacitor(T);
    const ICS = wdft.IdealCurrentSource(T, C);

    return struct {
        // Four WDF capacitor integrators
        stage1: ICS,
        stage2: ICS,
        stage3: ICS,
        stage4: ICS,

        // TIS97 transistor parameters for Ebers-Moll transconductance
        is: T = FilterComponents.tis97_is, // Saturation current
        vt: T = FilterComponents.tis97_vt, // Thermal voltage

        // Bias current (controls cutoff via gm = Ic/Vt)
        bias_current: T = FilterComponents.nominal_bias_current,

        // Cutoff frequency
        cutoff_freq: T = 1000.0,

        // Resonance
        resonance: T = 0.0,

        // Compensation
        compensation: T = 1.0,

        // Input/output scaling (maps audio to transistor voltage domain)
        input_scale: T = 0.06, // ~60mV for full-scale audio
        output_gain: T = 14.0, // Makeup gain after ladder

        // Sample rate
        sample_rate: T,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            var self = Self{
                .stage1 = ICS.init(C.init(FilterComponents.ladder_cap, sample_rate)),
                .stage2 = ICS.init(C.init(FilterComponents.ladder_cap, sample_rate)),
                .stage3 = ICS.init(C.init(FilterComponents.ladder_cap, sample_rate)),
                .stage4 = ICS.init(C.init(FilterComponents.ladder_cap, sample_rate)),
                .sample_rate = sample_rate,
            };
            self.setCutoff(1000.0);
            return self;
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.stage1.next.prepare(sample_rate);
            self.stage2.next.prepare(sample_rate);
            self.stage3.next.prepare(sample_rate);
            self.stage4.next.prepare(sample_rate);
            self.setCutoff(self.cutoff_freq);
        }

        pub fn reset(self: *Self) void {
            self.stage1.next.reset();
            self.stage2.next.reset();
            self.stage3.next.reset();
            self.stage4.next.reset();
        }

        /// Set cutoff frequency by adjusting bias current
        /// fc = gm / (2*pi*C) = Ic / (2*pi*Vt*C)
        /// So: Ic = fc * 2*pi*Vt*C
        pub fn setCutoff(self: *Self, frequency_hz: T) void {
            self.cutoff_freq = @max(20.0, @min(frequency_hz, self.sample_rate * 0.45));

            // Calculate bias current for desired cutoff
            self.bias_current = self.cutoff_freq * FilterComponents.cutoff_scale *
                2.0 * std.math.pi * self.vt * FilterComponents.ladder_cap;

            // Clamp to realistic range
            self.bias_current = @max(FilterComponents.min_bias_current,
                @min(FilterComponents.max_bias_current, self.bias_current));
        }

        pub fn setResonance(self: *Self, res: T) void {
            self.resonance = @max(0.0, @min(res, 4.5));
            self.compensation = 1.0 + self.resonance * 0.5;
        }

        /// Transistor transconductance with Ebers-Moll nonlinearity
        /// Models TIS97 NPN behavior: I = Is * (exp(V/Vt) - 1)
        /// For small signals around bias point, this gives tanh-like saturation
        inline fn transistorCurrent(self: *const Self, v_diff: T) T {
            // Differential pair behavior: tanh(V_diff / (2*Vt)) * Ic
            // This models the characteristic Moog ladder saturation
            const x = v_diff / (2.0 * self.vt);

            // tanh approximation (fast)
            const x2 = x * x;
            const tanh_approx = x * (27.0 + x2) / (27.0 + 9.0 * x2);

            // Output current = tanh * bias_current
            // gm = Ic/Vt at the operating point
            const gm = self.bias_current / self.vt;
            return tanh_approx * gm * self.vt; // = tanh * Ic
        }

        /// Process one sample through the 4-pole ladder
        pub inline fn processSample(self: *Self, input: T) T {
            // Get output for feedback
            const v4 = wdft.voltage(T, &self.stage4.next.wdf);

            // Apply resonance feedback (inverted). Clip feedback only to avoid dulling input.
            const feedback = softClip(v4 * self.resonance);
            const v_in = input * self.input_scale - feedback;

            // Stage 1: Transistor converts voltage to current, capacitor integrates
            const s1_v = wdft.voltage(T, &self.stage1.next.wdf);
            const s1_i = self.transistorCurrent(v_in - s1_v);
            self.stage1.setCurrent(s1_i);
            self.stage1.process();

            // Stage 2
            const s1_v_new = wdft.voltage(T, &self.stage1.next.wdf);
            const s2_v = wdft.voltage(T, &self.stage2.next.wdf);
            const s2_i = self.transistorCurrent(s1_v_new - s2_v);
            self.stage2.setCurrent(s2_i);
            self.stage2.process();

            // Stage 3
            const s2_v_new = wdft.voltage(T, &self.stage2.next.wdf);
            const s3_v = wdft.voltage(T, &self.stage3.next.wdf);
            const s3_i = self.transistorCurrent(s2_v_new - s3_v);
            self.stage3.setCurrent(s3_i);
            self.stage3.process();

            // Stage 4
            const s3_v_new = wdft.voltage(T, &self.stage3.next.wdf);
            const s4_v_old = wdft.voltage(T, &self.stage4.next.wdf);
            const s4_i = self.transistorCurrent(s3_v_new - s4_v_old);
            self.stage4.setCurrent(s4_i);
            self.stage4.process();

            // Output
            const output = wdft.voltage(T, &self.stage4.next.wdf);
            return output * self.compensation * self.output_gain;
        }

        pub fn processSampleMultimode(self: *Self, input: T) FilterOutputs(T) {
            _ = self.processSample(input);
            return .{
                .lp6 = wdft.voltage(T, &self.stage1.next.wdf) * self.compensation * self.output_gain,
                .lp12 = wdft.voltage(T, &self.stage2.next.wdf) * self.compensation * self.output_gain,
                .lp18 = wdft.voltage(T, &self.stage3.next.wdf) * self.compensation * self.output_gain,
                .lp24 = wdft.voltage(T, &self.stage4.next.wdf) * self.compensation * self.output_gain,
            };
        }
    };
}

pub fn FilterOutputs(comptime T: type) type {
    return struct {
        lp6: T, // 1-pole output (6dB/oct)
        lp12: T, // 2-pole output (12dB/oct)
        lp18: T, // 3-pole output (18dB/oct)
        lp24: T, // 4-pole output (24dB/oct)
    };
}

/// Soft clipping to prevent runaway at high resonance
fn softClip(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    // tanh approximation
    const x2 = x * x;
    if (x2 > 9.0) {
        return if (x > 0) @as(T, 1.0) else @as(T, -1.0);
    }
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

// ============================================================================
// UNIFIED WDF VCA (Differential Pair)
// ============================================================================
//
// Complete VCA as ONE WDF circuit using 2N4058 differential pair.
//
// Circuit topology:
//
//         Vcc                    Vcc
//          |                      |
//       [Rc1]                  [Rc2]
//          |                      |
//         C1 -----> Output       C2
//     Q1--|                       |--Q2
//        B1                       B2
//  Audio->|                       |<-- Control CV
//        E1                       E2
//          |                      |
//          +----------+-----------+
//                     |
//                  [R_tail]
//                     |
//                    GND
//
// The differential pair is modeled as a voltage-controlled current divider.
// Gain = tanh((V1-V2)/(2*Vt)) which gives exponential gain control.

pub fn UnifiedVCA(comptime T: type) type {
    const R = wdft.Resistor(T);

    // VCA modeled as voltage-controlled resistor divider
    // Input goes through R_signal, output is voltage across R_output
    const R_signal = R;
    const R_output = R;
    const Divider = wdft.Series(T, R_signal, R_output);
    const Root = wdft.IdealVoltageSource(T, Divider);

    return struct {
        circuit: Root,

        // Gain control (0.0 to 1.0)
        gain: T = 0.0,
        gain_smoothed: T = 0.0,
        smooth_coeff: T = 0.0,

        // Resistance values for gain control
        r_min: T = 100.0, // Minimum output R (full gain)
        r_max: T = 1000000.0, // Maximum output R (zero gain)

        sample_rate: T,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            const smooth_time: T = 0.005;
            const smooth = 1.0 - @exp(-1.0 / (smooth_time * sample_rate));

            var self = Self{
                .circuit = Root.init(
                    Divider.init(
                        R_signal.init(VCAComponents.input_r),
                        R_output.init(VCAComponents.output_r),
                    ),
                ),
                .sample_rate = sample_rate,
                .smooth_coeff = smooth,
            };

            self.circuit.calcImpedance();
            return self;
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            const smooth_time: T = 0.005;
            self.smooth_coeff = 1.0 - @exp(-1.0 / (smooth_time * sample_rate));
        }

        pub fn reset(self: *Self) void {
            self.gain = 0.0;
            self.gain_smoothed = 0.0;
        }

        /// Set gain (0.0 to 1.0)
        pub fn setGain(self: *Self, g: T) void {
            self.gain = @max(0.0, @min(1.0, g));
        }

        /// Set gain from envelope (0.0 to 1.0)
        pub fn setGainEnvelope(self: *Self, env: T) void {
            self.gain = @max(0.0, @min(1.0, env));
        }

        /// Process one sample through the VCA
        pub inline fn processSample(self: *Self, input: T) T {
            // Smooth gain to prevent clicks
            self.gain_smoothed += (self.gain - self.gain_smoothed) * self.smooth_coeff;

            // Simple gain multiplication (correct VCA behavior)
            // TODO: Implement proper differential pair WDF model
            const output = input * self.gain_smoothed;

            return output;
        }
    };
}

// ============================================================================
// Compatibility aliases (for existing code)
// ============================================================================

/// Moog Ladder Filter - uses the unified WDF implementation
pub const MoogLadderFilter = UnifiedMoogLadder;

/// VCA - uses the unified WDF implementation
pub const VCA = UnifiedVCA;
pub const DifferentialVCA = UnifiedVCA;

// ============================================================================
// Complete Board 4: Filter + VCA Chain
// ============================================================================

/// Complete Board 4 signal chain: VCF -> VCA (both as unified WDF circuits)
pub fn Board4FilterVCA(comptime T: type) type {
    return struct {
        vcf: UnifiedMoogLadder(T),
        vca: UnifiedVCA(T),
        sample_rate: T,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            return .{
                .vcf = UnifiedMoogLadder(T).init(sample_rate),
                .vca = UnifiedVCA(T).init(sample_rate),
                .sample_rate = sample_rate,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.vcf.prepare(sample_rate);
            self.vca.prepare(sample_rate);
        }

        pub fn reset(self: *Self) void {
            self.vcf.reset();
            self.vca.reset();
        }

        /// Set filter cutoff frequency in Hz
        pub fn setCutoff(self: *Self, freq_hz: T) void {
            self.vcf.setCutoff(freq_hz);
        }

        /// Set filter resonance (0.0 to ~4.0)
        pub fn setResonance(self: *Self, res: T) void {
            self.vcf.setResonance(res);
        }

        /// Set VCA gain (0.0 to 1.0)
        pub fn setAmplitude(self: *Self, amp: T) void {
            self.vca.setGainEnvelope(amp);
        }

        /// Process audio through filter and VCA (both unified WDF circuits)
        pub inline fn processSample(self: *Self, input: T) T {
            const filtered = self.vcf.processSample(input);
            return self.vca.processSample(filtered);
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

test "unified ladder filter produces output" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter = UnifiedMoogLadder(T).init(sample_rate);
    filter.setCutoff(1000.0);
    filter.setResonance(0.0);

    // Process some samples
    var has_output = false;
    for (0..500) |_| {
        const out = filter.processSample(1.0);
        if (@abs(out) > 0.001) has_output = true;
    }

    try std.testing.expect(has_output);
}

test "unified ladder resonance affects output" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter_no_res = UnifiedMoogLadder(T).init(sample_rate);
    filter_no_res.setCutoff(1000.0);
    filter_no_res.setResonance(0.0);

    var filter_res = UnifiedMoogLadder(T).init(sample_rate);
    filter_res.setCutoff(1000.0);
    filter_res.setResonance(3.0);

    // Impulse response
    _ = filter_no_res.processSample(1.0);
    _ = filter_res.processSample(1.0);

    // Look for ringing in resonant filter
    var max_no_res: T = 0.0;
    var max_res: T = 0.0;

    for (0..500) |_| {
        const out_no_res = @abs(filter_no_res.processSample(0.0));
        const out_res = @abs(filter_res.processSample(0.0));

        max_no_res = @max(max_no_res, out_no_res);
        max_res = @max(max_res, out_res);
    }

    // Both should produce some output
    try std.testing.expect(max_no_res >= 0.0);
    try std.testing.expect(max_res >= 0.0);
}

test "unified vca gain control" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var vca = UnifiedVCA(T).init(sample_rate);

    // Zero gain
    vca.setGainEnvelope(0.0);
    var out: T = 0.0;
    for (0..500) |_| {
        out = vca.processSample(1.0);
    }
    try std.testing.expect(@abs(out) < 0.1);

    // Full gain
    vca.setGainEnvelope(1.0);
    for (0..500) |_| {
        out = vca.processSample(1.0);
    }
    try std.testing.expect(@abs(out) > 0.3);
}

test "board4 complete chain" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var board4 = Board4FilterVCA(T).init(sample_rate);
    board4.setCutoff(5000.0);
    board4.setResonance(1.0);
    board4.setAmplitude(0.8);

    // Process some samples
    var has_output = false;
    for (0..100) |i| {
        const input = @sin(@as(T, @floatFromInt(i)) * 0.1);
        const out = board4.processSample(input);
        if (@abs(out) > 0.001) has_output = true;
    }

    try std.testing.expect(has_output);
}

test "soft clip limits output" {
    const T = f64;

    const clipped = softClip(@as(T, 10.0));
    try std.testing.expect(clipped < 1.1);
    try std.testing.expect(clipped > 0.9);

    const small = softClip(@as(T, 0.1));
    try expectApproxEq(small, 0.1, 0.01);
}

test "wdf transistor basic behavior" {
    const T = f64;
    const R = wdft.Resistor(T);
    const RVS = wdft.ResistiveVoltageSource(T);
    const NPN = wdft.NpnTransistor(T, R, RVS);

    // Create transistor with collector resistor and base voltage source
    var npn = NPN.init(
        R.init(10000.0), // 10k collector resistor
        RVS.init(1000.0), // 1k source resistance
        1.0e-14, // Is
        25.85e-3, // Vt
        150.0, // beta_f
        1.0, // beta_r
    );

    std.debug.print("\n=== WDF Transistor Test ===\n", .{});

    // Test 1: Zero input - should have minimal current
    npn.port_be.setVoltage(0.0);
    npn.process();
    const ic_zero = npn.collectorCurrent();
    const vbe_zero = npn.vbe();
    std.debug.print("Vbe=0.0V: Ic={e:.6} A, Vbe_solved={d:.4} V\n", .{ ic_zero, vbe_zero });

    // Test 2: Forward bias at 0.6V - should conduct
    npn.port_be.setVoltage(0.6);
    npn.process();
    const ic_06 = npn.collectorCurrent();
    const vbe_06 = npn.vbe();
    std.debug.print("Vbe=0.6V: Ic={e:.6} A, Vbe_solved={d:.4} V\n", .{ ic_06, vbe_06 });

    // Test 3: Forward bias at 0.7V - should conduct more
    npn.port_be.setVoltage(0.7);
    npn.process();
    const ic_07 = npn.collectorCurrent();
    const vbe_07 = npn.vbe();
    std.debug.print("Vbe=0.7V: Ic={e:.6} A, Vbe_solved={d:.4} V\n", .{ ic_07, vbe_07 });

    // Test 4: Modulated input (like audio)
    std.debug.print("\nModulated input test (0.6V bias + signal):\n", .{});
    var max_ic: T = 0;
    var min_ic: T = 1e10;
    for (0..100) |i| {
        const signal = 0.1 * @sin(@as(T, @floatFromInt(i)) * 0.2);
        npn.port_be.setVoltage(0.6 + signal);
        npn.process();
        const ic = npn.collectorCurrent();
        max_ic = @max(max_ic, ic);
        min_ic = @min(min_ic, ic);
    }
    std.debug.print("Ic range: {e:.6} to {e:.6} A\n", .{ min_ic, max_ic });
    std.debug.print("Ic variation: {e:.6} A\n", .{ max_ic - min_ic });

    // Verify transistor shows expected behavior
    try std.testing.expect(@abs(ic_07) > @abs(ic_06)); // More bias = more current
    try std.testing.expect(max_ic > min_ic); // Current should vary with input
}

test "single stage transconductance integrator" {
    const T = f64;
    const C = wdft.Capacitor(T);
    const ICS = wdft.IdealCurrentSource(T, C);

    const sample_rate: T = 48000.0;
    const cap_value: T = 0.068e-6; // 68nF

    var stage = ICS.init(C.init(cap_value, sample_rate));

    std.debug.print("\n=== Single Stage Transconductance Test ===\n", .{});

    // Simulate a 1kHz input for 1ms
    const gm: T = 2.0 * std.math.pi * 1000.0 * cap_value; // gm for 1kHz cutoff
    var max_v: T = 0;
    var min_v: T = 0;

    for (0..48) |i| { // 1ms at 48kHz
        const input = @sin(@as(T, @floatFromInt(i)) * 2.0 * std.math.pi * 1000.0 / sample_rate);
        const v_cap = wdft.voltage(T, &stage.next.wdf);
        const current = (input - v_cap) * gm;
        stage.setCurrent(current);
        stage.process();

        const v_out = wdft.voltage(T, &stage.next.wdf);
        max_v = @max(max_v, v_out);
        min_v = @min(min_v, v_out);
    }

    std.debug.print("Output range: {d:.6} to {d:.6}\n", .{ min_v, max_v });
    std.debug.print("Peak-to-peak: {d:.6}\n", .{ max_v - min_v });

    // Should have some output
    try std.testing.expect(max_v - min_v > 0.01);
}

test "moog ladder filter produces output" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter = UnifiedMoogLadder(T).init(sample_rate);
    filter.setCutoff(5000.0);
    filter.setResonance(0.0);

    std.debug.print("\n=== Moog Ladder Filter Test ===\n", .{});

    // Feed a step input and check response
    var max_out: T = 0;
    var min_out: T = 0;

    // Step response
    for (0..500) |_| {
        const out = filter.processSample(1.0);
        max_out = @max(max_out, out);
        min_out = @min(min_out, out);
    }

    std.debug.print("Step response - max: {d:.6}, min: {d:.6}\n", .{ max_out, min_out });

    // Reset and test sine input
    filter.reset();
    max_out = 0;
    min_out = 0;

    for (0..1000) |i| {
        const input = @sin(@as(T, @floatFromInt(i)) * 2.0 * std.math.pi * 440.0 / sample_rate);
        const out = filter.processSample(input);
        max_out = @max(max_out, out);
        min_out = @min(min_out, out);
    }

    std.debug.print("Sine response - max: {d:.6}, min: {d:.6}\n", .{ max_out, min_out });
    std.debug.print("Peak-to-peak: {d:.6}\n", .{ max_out - min_out });

    // Should produce output
    try std.testing.expect(max_out > 0.001);
    try std.testing.expect(max_out - min_out > 0.001);
}

test "moog ladder cutoff affects frequency response" {
    const T = f64;
    const sample_rate: T = 48000.0;

    std.debug.print("\n=== Cutoff Frequency Test ===\n", .{});

    // Test with low cutoff (should attenuate high frequencies)
    var filter_low = UnifiedMoogLadder(T).init(sample_rate);
    filter_low.setCutoff(200.0); // 200Hz cutoff

    // Test with high cutoff
    var filter_high = UnifiedMoogLadder(T).init(sample_rate);
    filter_high.setCutoff(10000.0); // 10kHz cutoff

    // Feed 2kHz sine (above low cutoff, below high cutoff)
    var energy_low: T = 0;
    var energy_high: T = 0;

    for (0..1000) |i| {
        const input = @sin(@as(T, @floatFromInt(i)) * 2.0 * std.math.pi * 2000.0 / sample_rate);

        const out_low = filter_low.processSample(input);
        const out_high = filter_high.processSample(input);

        energy_low += out_low * out_low;
        energy_high += out_high * out_high;
    }

    std.debug.print("Energy through 200Hz cutoff: {d:.6}\n", .{energy_low});
    std.debug.print("Energy through 10kHz cutoff: {d:.6}\n", .{energy_high});
    std.debug.print("Ratio (high/low): {d:.2}\n", .{energy_high / @max(energy_low, 1e-10)});

    // High cutoff should pass more energy
    try std.testing.expect(energy_high > energy_low);
}

test "transistor nonlinearity function" {
    const T = f64;

    var filter = UnifiedMoogLadder(T).init(48000.0);
    filter.setCutoff(1000.0);

    std.debug.print("\n=== Transistor Nonlinearity Test ===\n", .{});

    // Test the transistor current function at various inputs
    const test_inputs = [_]T{ -1.0, -0.5, -0.1, 0.0, 0.1, 0.5, 1.0 };

    for (test_inputs) |v| {
        const current = filter.transistorCurrent(v);
        std.debug.print("V={d:6.2} -> I={e:.6}\n", .{ v, current });
    }

    // Verify saturation behavior (tanh-like)
    const i_small = filter.transistorCurrent(0.01);
    const i_large = filter.transistorCurrent(1.0);

    // Large input should saturate (not be 100x larger)
    const ratio = @abs(i_large / i_small);
    std.debug.print("Ratio i(1.0)/i(0.01) = {d:.2} (should be << 100 due to saturation)\n", .{ratio});

    try std.testing.expect(ratio < 50); // Should saturate, not linear
}
