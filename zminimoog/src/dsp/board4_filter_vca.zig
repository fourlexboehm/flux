// Board 4: Filter and VCA Board
// Minimoog Model D - 24dB/octave Voltage Controlled Lowpass Filter (Ladder) and VCA
//
// Schematic page 10 of Minimoog-schematics.pdf
//
// Circuit 6: Moog Ladder Filter
//   - 4-pole (24dB/octave) transistor ladder lowpass filter
//   - Resonance via feedback from output to input
//   - Exponential frequency control
//   - Transistor soft-clipping nonlinearity
//
// Circuit 7: Voltage Controlled Amplifier
//   - Differential pair VCA
//   - Controlled by loudness envelope
//
// D'Angelo & Välimäki ODE-based Moog Ladder Filter
// Based on: "Generalized Moog Ladder Filter: Part II -
// Explicit Nonlinear Model through a Novel Delay-Free Loop Implementation"
// IEEE/ACM Transactions on Audio, Speech, and Language Processing, 2014
//
// The continuous-time model (4 state variables = capacitor voltages):
//   dV1/dt = -(Ictl/2C) * [tanh(V1/2Vt) + tanh((Vin + k*V4)/2Vt)]
//   dVi/dt =  (Ictl/2C) * [tanh(Vi-1/2Vt) - tanh(Vi/2Vt)]  for i=2,3,4
//
// Discretized using semi-implicit trapezoidal integration (Huovilainen method).

const std = @import("std");

// ============================================================================
// Component Values from Schematic
// ============================================================================

pub const FilterComponents = struct {
    // Ladder capacitors (all identical for matched response)
    // From schematic: C1, C5, C11, C16 = 0.068uF
    pub const ladder_cap: comptime_float = 0.068e-6; // 0.068uF = 68nF

    // Transistor parameters (TIS91 approximation)
    pub const vt: comptime_float = 25.85e-3; // Thermal voltage at 25°C

    // Base resistance for each stage (approximation of transistor impedance)
    // Used for base cutoff calculation
    pub const stage_resistance: comptime_float = 10000.0; // ~10k base impedance

    // Resonance feedback scaling
    // The Moog ladder has k=4 at self-oscillation
    pub const max_resonance: comptime_float = 4.0;

    // Transistor saturation level (normalized)
    // Models the soft clipping in each differential pair
    pub const saturation_level: comptime_float = 1.0;
};

pub const VCAComponents = struct {
    // Differential pair parameters (2N4058)
    pub const vt: comptime_float = 25.85e-3;
    pub const beta: comptime_float = 100.0; // Current gain
    pub const input_r: comptime_float = 47000.0; // 47k input impedance
    pub const output_r: comptime_float = 1000.0; // 1k output
};

// ============================================================================
// Nonlinear Functions for Transistor Modeling
// ============================================================================

/// Fast tanh approximation for real-time use
/// Pade approximant: tanh(x) ≈ x(27 + x²) / (27 + 9x²) for |x| < 3
fn fastTanh(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    const x2 = x * x;
    // Clamp for stability at extreme values
    if (x > 3.0) return @as(T, 1.0);
    if (x < -3.0) return @as(T, -1.0);
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

// ============================================================================
// Moog Ladder Filter (4-Pole with Resonance)
// D'Angelo & Välimäki nonlinear ODE model
// ============================================================================

/// Classic Moog 4-pole ladder filter with resonance
/// Implements the D'Angelo & Välimäki nonlinear ODE model using
/// semi-implicit trapezoidal integration. Four cascaded nonlinear
/// integrator stages with global feedback from stage 4 to input.
///
/// At k=4, the filter self-oscillates with tanh providing amplitude limiting.
pub fn MoogLadderFilter(comptime T: type) type {
    return struct {
        // State variables: capacitor voltages for each stage
        V: [4]T = .{ 0.0, 0.0, 0.0, 0.0 },

        // Current parameters
        cutoff_hz: T = 1000.0,
        resonance: T = 0.0, // k factor: 0 to 4 (self-oscillation)
        sample_rate: T,

        // Parameter smoothing targets
        cutoff_target: T = 1000.0,
        resonance_target: T = 0.0,

        // Precomputed coefficient: g = tan(π * fc / fs)
        g: T = 0.0,

        // Feedback state (one-sample delay for stability)
        feedback: T = 0.0,

        // Compensation for gain loss at high resonance
        compensation: T = 1.0,
        compensation_target: T = 1.0,

        // Nonlinear mode: when false, skips tanh for CPU savings
        nonlinear: bool = true,

        // Thermal scale controls saturation character.
        // With normalized audio (-1..+1), physical Vt (25.85mV) puts everything
        // in hard saturation. thermal_scale ~1.0 gives musical saturation behavior.
        thermal_scale: T = 1.0,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            var self = Self{
                .sample_rate = sample_rate,
            };
            self.setCutoff(1000.0);
            self.updateCoefficients();
            return self;
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.updateCoefficients();
        }

        pub fn reset(self: *Self) void {
            self.V = .{ 0.0, 0.0, 0.0, 0.0 };
            self.feedback = 0.0;
            self.cutoff_hz = self.cutoff_target;
            self.resonance = self.resonance_target;
            self.compensation = self.compensation_target;
            self.updateCoefficients();
        }

        /// Set cutoff frequency in Hz
        pub fn setCutoff(self: *Self, frequency_hz: T) void {
            self.cutoff_target = @max(20.0, @min(frequency_hz, self.sample_rate * 0.49));
        }

        /// Set cutoff via 1V/octave CV (0V = 261.63 Hz, middle C)
        pub fn setCutoffCV(self: *Self, cv_volts: T) void {
            const base_freq: T = 261.63;
            const frequency_hz = base_freq * std.math.pow(T, 2.0, cv_volts);
            self.setCutoff(frequency_hz);
        }

        /// Set resonance (emphasis)
        /// 0.0 = no resonance
        /// ~3.9 = near self-oscillation
        /// 4.0 = self-oscillation
        pub fn setResonance(self: *Self, res: T) void {
            // Slightly boost feedback to compensate for one-sample delay loss.
            // The semi-implicit discretization with unit delay on feedback
            // reduces the effective loop gain; scale by ~1.12 so k=4 reliably
            // self-oscillates as the analog circuit does.
            const clamped = @max(0.0, @min(res, FilterComponents.max_resonance));
            self.resonance_target = clamped * 1.12;
            // Compensate for gain loss at high resonance
            self.compensation_target = 1.0 + clamped * 0.5;
        }

        /// Enable/disable transistor nonlinearity modeling
        pub fn setNonlinear(self: *Self, enabled: bool) void {
            self.nonlinear = enabled;
        }

        /// Set saturation level for nonlinear mode
        /// Controls the thermal_scale: higher = softer saturation
        pub fn setSaturation(self: *Self, level: T) void {
            self.thermal_scale = @max(0.1, level);
        }

        /// Compute the bilinear pre-warped cutoff coefficient
        fn updateCoefficients(self: *Self) void {
            const max_freq = self.sample_rate * 0.49;
            const clamped = @max(20.0, @min(self.cutoff_hz, max_freq));
            self.g = std.math.tan(std.math.pi * clamped / self.sample_rate);
        }

        /// Smooth parameter changes to avoid clicks
        fn smoothParam(current: T, target: T, coeff: T) T {
            return current + (target - current) * coeff;
        }

        /// Process one sample through the 4-pole nonlinear ladder filter
        pub inline fn processSample(self: *Self, input: T) T {
            // Parameter smoothing (~1ms time constant at 48kHz)
            const smooth_coeff: T = 0.02;

            // Smooth cutoff changes
            const prev_cutoff = self.cutoff_hz;
            self.cutoff_hz = smoothParam(self.cutoff_hz, self.cutoff_target, smooth_coeff);
            if (@abs(self.cutoff_hz - prev_cutoff) > 0.01) {
                self.updateCoefficients();
            }

            // Smooth resonance and compensation
            self.resonance = smoothParam(self.resonance, self.resonance_target, smooth_coeff);
            self.compensation = smoothParam(self.compensation, self.compensation_target, smooth_coeff);

            const g = self.g;
            const k = self.resonance;

            if (self.nonlinear) {
                const thermal_inv = 1.0 / self.thermal_scale;

                // Feedback from stage 4 (one-sample delay)
                const fb = k * fastTanh(self.feedback * thermal_inv);

                // Input with DC compensation and resonance feedback subtracted
                const u = (input * (1.0 + k * 0.5)) - fb;

                // Input nonlinearity
                var prev_tanh = fastTanh(u * thermal_inv);

                // Process 4 stages sequentially (semi-implicit)
                inline for (0..4) |i| {
                    const stage_tanh = fastTanh(self.V[i] * thermal_inv);
                    self.V[i] += g * (prev_tanh - stage_tanh);
                    prev_tanh = fastTanh(self.V[i] * thermal_inv);
                }

                // Store feedback for next sample
                self.feedback = self.V[3];

                return self.V[3] * self.compensation;
            } else {
                // Linear mode: skip tanh, becomes standard 4-pole cascade
                // V[i] += g * (prev - V[i]) => semi-implicit 1-pole lowpass
                const u = (input * (1.0 + k * 0.5)) - k * self.feedback;

                var prev = u;
                inline for (0..4) |i| {
                    self.V[i] += g * (prev - self.V[i]) / (1.0 + g);
                    prev = self.V[i];
                }

                self.feedback = self.V[3];

                return self.V[3] * self.compensation;
            }
        }

        /// Get intermediate outputs for multimode operation
        pub fn processSampleMultimode(self: *Self, input: T) FilterOutputs(T) {
            // Parameter smoothing
            const smooth_coeff: T = 0.02;

            const prev_cutoff = self.cutoff_hz;
            self.cutoff_hz = smoothParam(self.cutoff_hz, self.cutoff_target, smooth_coeff);
            if (@abs(self.cutoff_hz - prev_cutoff) > 0.01) {
                self.updateCoefficients();
            }

            self.resonance = smoothParam(self.resonance, self.resonance_target, smooth_coeff);
            self.compensation = smoothParam(self.compensation, self.compensation_target, smooth_coeff);

            const g = self.g;
            const k = self.resonance;

            if (self.nonlinear) {
                const thermal_inv = 1.0 / self.thermal_scale;

                const fb = k * fastTanh(self.feedback * thermal_inv);
                const u = (input * (1.0 + k * 0.5)) - fb;
                var prev_tanh = fastTanh(u * thermal_inv);

                inline for (0..4) |i| {
                    const stage_tanh = fastTanh(self.V[i] * thermal_inv);
                    self.V[i] += g * (prev_tanh - stage_tanh);
                    prev_tanh = fastTanh(self.V[i] * thermal_inv);
                }

                self.feedback = self.V[3];

                return .{
                    .lp6 = self.V[0] * self.compensation,
                    .lp12 = self.V[1] * self.compensation,
                    .lp18 = self.V[2] * self.compensation,
                    .lp24 = self.V[3] * self.compensation,
                };
            } else {
                const u = (input * (1.0 + k * 0.5)) - k * self.feedback;

                var prev = u;
                inline for (0..4) |i| {
                    self.V[i] += g * (prev - self.V[i]) / (1.0 + g);
                    prev = self.V[i];
                }

                self.feedback = self.V[3];

                return .{
                    .lp6 = self.V[0] * self.compensation,
                    .lp12 = self.V[1] * self.compensation,
                    .lp18 = self.V[2] * self.compensation,
                    .lp24 = self.V[3] * self.compensation,
                };
            }
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

test "moog ladder filter reduces high frequencies" {
    const TF = f64;
    const sample_rate: TF = 48000.0;

    var filter = MoogLadderFilter(TF).init(sample_rate);
    filter.setCutoff(1000.0); // 1kHz cutoff
    filter.setResonance(0.0); // No resonance
    filter.setNonlinear(false); // Linear for predictable test

    // Generate high frequency test signal (10kHz)
    var sum_input: TF = 0.0;
    var sum_output: TF = 0.0;
    const freq: TF = 10000.0;

    for (0..3000) |i| {
        const phase = @as(TF, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase);
        const output = filter.processSample(input);

        // Skip first 1000 samples for settling
        if (i >= 1000) {
            sum_input += input * input;
            sum_output += output * output;
        }
    }

    // 4-pole filter at 10kHz (10x cutoff) should attenuate significantly
    try std.testing.expect(sum_output < sum_input * 0.01);
}

test "moog ladder resonance increases peak" {
    const TF = f64;
    const sample_rate: TF = 48000.0;

    var filter_no_res = MoogLadderFilter(TF).init(sample_rate);
    filter_no_res.setCutoff(1000.0);
    filter_no_res.setResonance(0.0);
    filter_no_res.setNonlinear(false);

    var filter_res = MoogLadderFilter(TF).init(sample_rate);
    filter_res.setCutoff(1000.0);
    filter_res.setResonance(3.5);
    filter_res.setNonlinear(false);

    // Generate signal at cutoff frequency
    const freq: TF = 1000.0;

    // Warm up filters to reach steady state
    for (0..4000) |i| {
        const phase = @as(TF, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase) * 0.3;
        _ = filter_no_res.processSample(input);
        _ = filter_res.processSample(input);
    }

    // Measure steady-state response
    var sum_no_res: TF = 0.0;
    var sum_res: TF = 0.0;
    for (0..2000) |i| {
        const phase = @as(TF, @floatFromInt(i + 4000)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase) * 0.3;
        const out_no_res = filter_no_res.processSample(input);
        const out_res = filter_res.processSample(input);
        sum_no_res += out_no_res * out_no_res;
        sum_res += out_res * out_res;
    }

    const rms_no_res = @sqrt(sum_no_res / 2000.0);
    const rms_res = @sqrt(sum_res / 2000.0);

    // Resonance should boost signal at cutoff frequency
    try std.testing.expect(rms_res > rms_no_res * 1.2);
}

test "moog ladder nonlinear output is finite" {
    const TF = f64;
    const sample_rate: TF = 48000.0;

    var filter = MoogLadderFilter(TF).init(sample_rate);
    filter.setCutoff(1000.0);
    filter.setResonance(3.9); // Near self-oscillation
    filter.setNonlinear(true);

    var out: TF = 0.0;
    var max_out: TF = 0.0;
    for (0..4000) |i| {
        const input = @sin(@as(TF, @floatFromInt(i)) * 0.1) * 0.5;
        out = filter.processSample(input);
        try std.testing.expect(std.math.isFinite(out));
        max_out = @max(max_out, @abs(out));
    }

    // Should have some output
    try std.testing.expect(max_out > 0.01);
    // Should be bounded due to saturation
    try std.testing.expect(max_out < 10.0);
}

test "moog ladder self-oscillation" {
    const TF = f64;
    const sample_rate: TF = 48000.0;

    var filter = MoogLadderFilter(TF).init(sample_rate);
    filter.setCutoff(440.0); // A4
    filter.setResonance(4.0); // Self-oscillation
    filter.setNonlinear(true);

    // Force parameters to their targets immediately (bypass smoothing)
    filter.cutoff_hz = filter.cutoff_target;
    filter.resonance = filter.resonance_target;
    filter.compensation = filter.compensation_target;
    filter.updateCoefficients();

    // Give it a kick to start oscillation
    _ = filter.processSample(0.5);
    _ = filter.processSample(0.2);
    _ = filter.processSample(0.0);

    // Let it run with zero input - give it time to build up
    var sum: TF = 0.0;
    for (0..8000) |_| {
        const out = filter.processSample(0.0);
        sum += out * out;
    }

    // Should self-oscillate (have significant output with zero input)
    const rms = @sqrt(sum / 8000.0);
    try std.testing.expect(rms > 0.05);
}

test "board4 chain produces output" {
    const TF = f64;
    const sample_rate: TF = 48000.0;

    var board4 = Board4FilterVCA(TF).init(sample_rate);
    board4.setCutoff(800.0);
    board4.setResonance(2.5);
    board4.setAmplitude(0.9);

    var sum_out: TF = 0.0;
    for (0..2000) |i| {
        const input = @sin(@as(TF, @floatFromInt(i)) * 0.05);
        const out = board4.processSample(input);
        sum_out += out * out;
    }

    try std.testing.expect(sum_out > 1e-6);
}

test "vca gain control" {
    const TF = f64;

    var vca = VCA(TF).init();

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
    const TF = f64;
    const sample_rate: TF = 48000.0;

    var board4 = Board4FilterVCA(TF).init(sample_rate);
    board4.setCutoff(5000.0);
    board4.setResonance(1.0);
    board4.setAmplitude(0.8);

    // Process some samples
    var out: TF = 0.0;
    for (0..100) |i| {
        const input = @sin(@as(TF, @floatFromInt(i)) * 0.1);
        out = board4.processSample(input);
    }

    // Should produce output
    try std.testing.expect(@abs(out) > 0.0);
}

test "multimode outputs are progressively filtered" {
    const TF = f64;
    const sample_rate: TF = 48000.0;

    var filter = MoogLadderFilter(TF).init(sample_rate);
    filter.setCutoff(500.0);
    filter.setResonance(0.0);
    filter.setNonlinear(false);

    // High frequency signal
    const freq: TF = 8000.0;
    var sum_6: TF = 0.0;
    var sum_12: TF = 0.0;
    var sum_18: TF = 0.0;
    var sum_24: TF = 0.0;

    for (0..3000) |i| {
        const phase = @as(TF, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase);
        const outputs = filter.processSampleMultimode(input);

        if (i >= 1000) {
            sum_6 += outputs.lp6 * outputs.lp6;
            sum_12 += outputs.lp12 * outputs.lp12;
            sum_18 += outputs.lp18 * outputs.lp18;
            sum_24 += outputs.lp24 * outputs.lp24;
        }
    }

    // Each additional pole should attenuate more
    try std.testing.expect(sum_6 > sum_12);
    try std.testing.expect(sum_12 > sum_18);
    try std.testing.expect(sum_18 > sum_24);
}
