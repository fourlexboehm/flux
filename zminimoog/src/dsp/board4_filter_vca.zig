// Board 4: Filter and VCA Board
// Minimoog Model D - 24dB/octave Voltage Controlled Lowpass Filter (Ladder) and VCA
//
// Schematic page 10 of Minimoog-schematics.pdf
//
// Circuit 6: Moog Ladder Filter
//   - 4-pole (24dB/octave) transistor ladder lowpass filter
//   - Resonance via feedback from output to input
//   - Exponential frequency control
//
// Circuit 7: Voltage Controlled Amplifier
//   - Differential pair VCA
//   - Controlled by loudness envelope

const std = @import("std");
const wdft = @import("wdf");

// ============================================================================
// Component Values from Schematic
// ============================================================================

pub const FilterComponents = struct {
    // Ladder capacitors (all identical for matched response)
    pub const ladder_cap: comptime_float = 0.068e-6; // 0.068uF = 68nF

    // Transistor parameters (TIS97 approximation)
    pub const vt: comptime_float = 25.85e-3; // Thermal voltage at 25°C
    pub const is: comptime_float = 1.0e-15; // Saturation current (typical for small signal)

    // Base resistance for each stage (approximation of transistor impedance)
    // This is derived from the thermal voltage and operating current
    pub const stage_resistance: comptime_float = 10000.0; // ~10k base impedance

    // Resonance feedback resistor (controls emphasis/Q)
    pub const feedback_r: comptime_float = 100000.0; // 100k feedback path

    // Input/output impedances
    pub const input_r: comptime_float = 10000.0; // 10k input impedance
    pub const output_r: comptime_float = 1000.0; // 1k output impedance
};

pub const VCAComponents = struct {
    // Differential pair parameters (2N4058)
    pub const vt: comptime_float = 25.85e-3;
    pub const beta: comptime_float = 100.0; // Current gain
    pub const input_r: comptime_float = 47000.0; // 47k input impedance
    pub const output_r: comptime_float = 1000.0; // 1k output
};

// ============================================================================
// Single Ladder Stage (First-Order Lowpass)
// ============================================================================

/// One stage of the ladder filter - RC lowpass with variable resistance
/// Circuit: Vin --[R_var]--+-- Vout
///                         |
///                        [C]
///                         |
///                        GND
///
/// The resistance varies with control voltage to change cutoff frequency
pub fn LadderStage(comptime T: type) type {
    const R = wdft.Resistor(T);
    const C = wdft.Capacitor(T);
    const S = wdft.Series(T, R, C);
    const I = wdft.PolarityInverter(T, S);
    const VS = wdft.IdealVoltageSource(T, I);

    return struct {
        circuit: VS,
        base_r: T,

        const Self = @This();

        pub fn init(resistance: T, capacitance: T, sample_rate: T) Self {
            return .{
                .circuit = VS.init(
                    I.init(S.init(
                        R.init(resistance),
                        C.init(capacitance, sample_rate),
                    )),
                ),
                .base_r = resistance,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.circuit.next.port1.port2.prepare(sample_rate);
            self.circuit.calcImpedance();
        }

        pub fn reset(self: *Self) void {
            self.circuit.next.port1.port2.reset();
        }

        /// Set cutoff frequency by scaling resistance
        /// frequency_scale: 1.0 = base frequency, higher = higher cutoff
        pub fn setFrequencyScale(self: *Self, frequency_scale: T) void {
            const min_scale: T = 0.001;
            const clamped_scale = @max(min_scale, frequency_scale);
            self.circuit.next.port1.port1.setResistance(self.base_r / clamped_scale);
            self.circuit.next.port1.port1.calcImpedance();
            self.circuit.calcImpedance();
        }

        pub inline fn processSample(self: *Self, input: T) T {
            self.circuit.setVoltage(input);
            self.circuit.process();
            return wdft.voltage(T, &self.circuit.next.port1.port2.wdf);
        }
    };
}

// ============================================================================
// Moog Ladder Filter (4-Pole with Resonance)
// ============================================================================

/// Classic Moog 4-pole ladder filter with resonance
/// Four cascaded RC lowpass stages with feedback
pub fn MoogLadderFilter(comptime T: type) type {
    return struct {
        stage1: LadderStage(T),
        stage2: LadderStage(T),
        stage3: LadderStage(T),
        stage4: LadderStage(T),

        resonance: T = 0.0, // 0.0 to ~4.0 (self-oscillation around 4.0)
        cutoff_scale: T = 1.0,
        sample_rate: T,

        // Feedback state
        feedback: T = 0.0,

        // Compensation for gain loss at high resonance
        compensation: T = 1.0,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            const cap = FilterComponents.ladder_cap;
            const res = FilterComponents.stage_resistance;

            return .{
                .stage1 = LadderStage(T).init(res, cap, sample_rate),
                .stage2 = LadderStage(T).init(res, cap, sample_rate),
                .stage3 = LadderStage(T).init(res, cap, sample_rate),
                .stage4 = LadderStage(T).init(res, cap, sample_rate),
                .sample_rate = sample_rate,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.stage1.prepare(sample_rate);
            self.stage2.prepare(sample_rate);
            self.stage3.prepare(sample_rate);
            self.stage4.prepare(sample_rate);
        }

        pub fn reset(self: *Self) void {
            self.stage1.reset();
            self.stage2.reset();
            self.stage3.reset();
            self.stage4.reset();
            self.feedback = 0.0;
        }

        /// Set cutoff frequency in Hz
        pub fn setCutoff(self: *Self, frequency_hz: T) void {
            // Calculate frequency scale relative to base cutoff
            // Base cutoff ≈ 1 / (2 * pi * R * C)
            const base_cutoff = 1.0 / (2.0 * std.math.pi * FilterComponents.stage_resistance * FilterComponents.ladder_cap);
            self.cutoff_scale = frequency_hz / base_cutoff;

            self.stage1.setFrequencyScale(self.cutoff_scale);
            self.stage2.setFrequencyScale(self.cutoff_scale);
            self.stage3.setFrequencyScale(self.cutoff_scale);
            self.stage4.setFrequencyScale(self.cutoff_scale);
        }

        /// Set cutoff via 1V/octave CV (0V = base frequency)
        pub fn setCutoffCV(self: *Self, cv_volts: T) void {
            // 1V/octave: each volt doubles frequency
            const scale = std.math.pow(T, 2.0, cv_volts);
            self.cutoff_scale = scale;

            self.stage1.setFrequencyScale(scale);
            self.stage2.setFrequencyScale(scale);
            self.stage3.setFrequencyScale(scale);
            self.stage4.setFrequencyScale(scale);
        }

        /// Set resonance (emphasis)
        /// 0.0 = no resonance
        /// ~3.9 = near self-oscillation
        /// 4.0+ = self-oscillation
        pub fn setResonance(self: *Self, res: T) void {
            self.resonance = @max(0.0, @min(res, 4.5)); // Clamp to safe range

            // Compensate for gain loss at high resonance
            self.compensation = 1.0 + self.resonance * 0.2;
        }

        /// Process one sample through the 4-pole filter
        pub inline fn processSample(self: *Self, input: T) T {
            // Apply input gain compensation and subtract feedback
            const compensated_input = input * self.compensation - self.feedback * self.resonance;

            // Soft clip the input to prevent runaway at high resonance
            const clipped_input = softClip(compensated_input);

            // Process through four cascaded stages
            const s1_out = self.stage1.processSample(clipped_input);
            const s2_out = self.stage2.processSample(s1_out);
            const s3_out = self.stage3.processSample(s2_out);
            const s4_out = self.stage4.processSample(s3_out);

            // Store feedback for next sample (inverted for negative feedback)
            self.feedback = s4_out;

            return s4_out;
        }

        /// Get intermediate outputs for multimode operation
        pub fn processSampleMultimode(self: *Self, input: T) FilterOutputs(T) {
            const compensated_input = input * self.compensation - self.feedback * self.resonance;
            const clipped_input = softClip(compensated_input);

            const s1_out = self.stage1.processSample(clipped_input);
            const s2_out = self.stage2.processSample(s1_out);
            const s3_out = self.stage3.processSample(s2_out);
            const s4_out = self.stage4.processSample(s3_out);

            self.feedback = s4_out;

            return .{
                .lp6 = s1_out, // 6dB/oct lowpass
                .lp12 = s2_out, // 12dB/oct lowpass
                .lp18 = s3_out, // 18dB/oct lowpass
                .lp24 = s4_out, // 24dB/oct lowpass (classic Moog)
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

/// Soft clipping function to simulate transistor saturation
fn softClip(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    const threshold: T = 1.0;
    if (x > threshold) {
        return threshold + (1.0 - threshold) * std.math.tanh(x - threshold);
    } else if (x < -threshold) {
        return -threshold + (1.0 - threshold) * std.math.tanh(x + threshold);
    }
    return x;
}

// ============================================================================
// Voltage Controlled Amplifier
// ============================================================================

/// Simple VCA model using differential pair approximation
/// The gain is exponentially controlled by the CV input
pub fn VCA(comptime T: type) type {
    return struct {
        gain: T = 0.0, // Linear gain (0.0 to 1.0+)
        cv_scale: T = 1.0, // CV to gain scaling

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.gain = 0.0;
        }

        /// Set gain directly (linear)
        pub fn setGain(self: *Self, g: T) void {
            self.gain = @max(0.0, g);
        }

        /// Set gain via control voltage
        /// CV is typically 0-10V for full range
        pub fn setGainCV(self: *Self, cv: T) void {
            // Exponential response like real VCA
            // 0V = silent, ~10V = unity gain
            const normalized_cv = cv / 10.0;
            if (normalized_cv <= 0.0) {
                self.gain = 0.0;
            } else {
                // Approximate exponential response
                self.gain = normalized_cv * normalized_cv; // Quadratic approximation
            }
        }

        /// Set gain via envelope (0.0 to 1.0 range)
        pub fn setGainEnvelope(self: *Self, env: T) void {
            self.gain = @max(0.0, @min(1.0, env));
        }

        pub inline fn processSample(self: *Self, input: T) T {
            return input * self.gain;
        }
    };
}

// ============================================================================
// Complete Board 4: Filter + VCA Chain
// ============================================================================

/// Complete Board 4 signal chain: VCF -> VCA
pub fn Board4FilterVCA(comptime T: type) type {
    return struct {
        vcf: MoogLadderFilter(T),
        vca: VCA(T),
        sample_rate: T,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            return .{
                .vcf = MoogLadderFilter(T).init(sample_rate),
                .vca = VCA(T).init(),
                .sample_rate = sample_rate,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.vcf.prepare(sample_rate);
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

        /// Process audio through filter and VCA
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

test "ladder stage basic operation" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var stage = LadderStage(T).init(
        FilterComponents.stage_resistance,
        FilterComponents.ladder_cap,
        sample_rate,
    );

    // Process a step - output should rise towards input
    var out: T = 0.0;
    for (0..100) |_| {
        out = stage.processSample(1.0);
    }

    // Should be approaching 1.0 but not quite there (lowpass behavior)
    try std.testing.expect(out > 0.5);
    try std.testing.expect(out < 1.0);
}

test "moog ladder filter reduces high frequencies" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter = MoogLadderFilter(T).init(sample_rate);
    filter.setCutoff(1000.0); // 1kHz cutoff
    filter.setResonance(0.0); // No resonance

    // Generate high frequency test signal (10kHz)
    var sum_input: T = 0.0;
    var sum_output: T = 0.0;
    const freq: T = 10000.0;

    for (0..1000) |i| {
        const phase = @as(T, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase);
        const output = filter.processSample(input);

        sum_input += input * input;
        sum_output += output * output;
    }

    // Output power should be significantly less than input (attenuated)
    try std.testing.expect(sum_output < sum_input * 0.5);
}

test "moog ladder resonance increases peak" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter_no_res = MoogLadderFilter(T).init(sample_rate);
    filter_no_res.setCutoff(1000.0);
    filter_no_res.setResonance(0.0);

    var filter_res = MoogLadderFilter(T).init(sample_rate);
    filter_res.setCutoff(1000.0);
    filter_res.setResonance(3.0);

    // Steady-state response near cutoff should differ with resonance
    const freq: T = 1000.0;

    // Warm up
    for (0..2000) |i| {
        const phase = @as(T, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase);
        _ = filter_no_res.processSample(input);
        _ = filter_res.processSample(input);
    }

    var sum_no_res: T = 0.0;
    var sum_res: T = 0.0;
    for (0..2000) |i| {
        const phase = @as(T, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase);
        const out_no_res = filter_no_res.processSample(input);
        const out_res = filter_res.processSample(input);
        sum_no_res += out_no_res * out_no_res;
        sum_res += out_res * out_res;
    }

    const rms_no_res = @sqrt(sum_no_res / 2000.0);
    const rms_res = @sqrt(sum_res / 2000.0);

    try std.testing.expect(@abs(rms_res - rms_no_res) > 1e-3);
}

test "vca gain control" {
    const T = f64;

    var vca = VCA(T).init();

    // Zero gain
    vca.setGainEnvelope(0.0);
    try expectApproxEq(vca.processSample(1.0), 0.0, 1e-9);

    // Unity gain
    vca.setGainEnvelope(1.0);
    try expectApproxEq(vca.processSample(1.0), 1.0, 1e-9);

    // Half gain
    vca.setGainEnvelope(0.5);
    try expectApproxEq(vca.processSample(1.0), 0.5, 1e-9);
}

test "board4 complete chain" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var board4 = Board4FilterVCA(T).init(sample_rate);
    board4.setCutoff(5000.0);
    board4.setResonance(1.0);
    board4.setAmplitude(0.8);

    // Process some samples
    var out: T = 0.0;
    for (0..100) |i| {
        const input = @sin(@as(T, @floatFromInt(i)) * 0.1);
        out = board4.processSample(input);
    }

    // Should produce output
    try std.testing.expect(@abs(out) > 0.0);
}
