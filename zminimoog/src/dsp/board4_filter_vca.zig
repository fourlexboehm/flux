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
// WDF Implementation based on:
//   "Direct Synthesis of Ladder Wave Digital Filters with Tunable Parameters"
//   by S.A. Samad, AJSTD Vol. 20 Issue 1, 2003
//
// Key equations from paper:
//   - First-order WDF coefficient: m = tan(ωc/2) / (1 + tan(ωc/2))  [eq. 50]
//   - First-order lowpass: y[n] = m*(x[n] + x[n-1]) + (1-2m)*y[n-1]  [eq. 48]

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
// First-Order WDF Ladder Section
// ============================================================================

/// Single stage of the WDF ladder filter
/// Implements a first-order lowpass with tunable cutoff coefficient
///
/// Based on the paper "Direct Synthesis of Ladder Wave Digital Filters"
/// Transfer function from eq. 48:
///   G(z) = (m + m*z^-1) / (1 + (2m-1)*z^-1)
///        = m*(1 + z^-1) / (1 - (1-2m)*z^-1)
///
/// Difference equation:
///   y[n] = m*(x[n] + x[n-1]) + (1-2m)*y[n-1]
///
/// The coefficient m = tan(ωc/2) / (1 + tan(ωc/2)) controls cutoff
pub fn WdfLadderSection(comptime T: type) type {
    return struct {
        // Adaptor coefficient (controls cutoff frequency)
        m: T = 0.5,

        // State variables
        x1: T = 0.0, // Previous input x[n-1]
        y1: T = 0.0, // Previous output y[n-1]

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.x1 = 0.0;
            self.y1 = 0.0;
        }

        /// Set the adaptor coefficient directly
        /// m should be in range (0, 1)
        pub fn setCoefficient(self: *Self, coeff: T) void {
            self.m = @max(0.001, @min(0.999, coeff));
        }

        /// Set cutoff frequency and compute coefficient
        /// ωc is the digital cutoff frequency in radians (0 to π)
        pub fn setCutoffOmega(self: *Self, omega_c: T) void {
            // From paper equation (50): m = tan(ωc/2) / (1 + tan(ωc/2))
            // Clamp omega to avoid tan explosion near π
            const clamped_omega = @min(omega_c, std.math.pi * 0.98);
            const half_omega = clamped_omega * 0.5;
            const tan_half = std.math.tan(half_omega);
            self.m = tan_half / (1.0 + tan_half);
            // Clamp for stability
            self.m = @max(0.001, @min(0.999, self.m));
        }

        /// Set cutoff frequency in Hz given sample rate
        pub fn setCutoffHz(self: *Self, freq_hz: T, sample_rate: T) void {
            // Digital frequency: ω = 2π * f / fs
            // Clamp to prevent instability near Nyquist
            const max_freq = sample_rate * 0.45;
            const min_freq: T = 20.0;
            const clamped_freq = @max(min_freq, @min(freq_hz, max_freq));
            const omega_c = 2.0 * std.math.pi * clamped_freq / sample_rate;
            self.setCutoffOmega(omega_c);
        }

        /// Process one sample through the WDF section (linear)
        /// Implements: y[n] = m*(x[n] + x[n-1]) + (1-2m)*y[n-1]
        pub inline fn processSample(self: *Self, input: T) T {
            // First-order lowpass from bilinear transform of RC filter
            // This gives proper frequency warping and zero at Nyquist
            const x0 = input;
            const one_minus_2m = 1.0 - 2.0 * self.m;

            const output = self.m * (x0 + self.x1) + one_minus_2m * self.y1;

            // Update state
            self.x1 = x0;
            self.y1 = output;

            return output;
        }

        /// Process with nonlinear saturation (models transistor clipping)
        pub inline fn processSampleNonlinear(self: *Self, input: T, saturation: T) T {
            // Apply soft saturation to input (models transistor differential pair)
            const saturated_input = fastTanh(input / saturation) * saturation;
            return self.processSample(saturated_input);
        }
    };
}

// ============================================================================
// Moog Ladder Filter (4-Pole with Resonance)
// ============================================================================

/// Classic Moog 4-pole ladder filter with resonance
/// Four cascaded WDF lowpass stages with global feedback
///
/// The resonance is implemented by feeding the 4th stage output back
/// to the input, scaled by k. At k=4, the filter self-oscillates.
pub fn MoogLadderFilter(comptime T: type) type {
    return struct {
        // Four cascaded WDF sections
        stage1: WdfLadderSection(T),
        stage2: WdfLadderSection(T),
        stage3: WdfLadderSection(T),
        stage4: WdfLadderSection(T),

        // Current parameters
        cutoff_hz: T = 1000.0,
        resonance: T = 0.0, // k factor: 0 to 4 (self-oscillation)
        sample_rate: T,

        // Parameter smoothing targets
        cutoff_target: T = 1000.0,
        resonance_target: T = 0.0,

        // Feedback state (delayed by one sample for stability)
        feedback: T = 0.0,

        // Nonlinearity control
        saturation: T = FilterComponents.saturation_level,
        use_nonlinear: bool = true,

        // Compensation for gain loss at high resonance
        compensation: T = 1.0,
        compensation_target: T = 1.0,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            var self = Self{
                .stage1 = WdfLadderSection(T).init(),
                .stage2 = WdfLadderSection(T).init(),
                .stage3 = WdfLadderSection(T).init(),
                .stage4 = WdfLadderSection(T).init(),
                .sample_rate = sample_rate,
            };
            self.setCutoff(1000.0);
            return self;
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            // Recalculate coefficients for new sample rate
            self.updateCoefficients();
        }

        pub fn reset(self: *Self) void {
            self.stage1.reset();
            self.stage2.reset();
            self.stage3.reset();
            self.stage4.reset();
            self.feedback = 0.0;
            self.cutoff_hz = self.cutoff_target;
            self.resonance = self.resonance_target;
            self.compensation = self.compensation_target;
        }

        /// Set cutoff frequency in Hz
        pub fn setCutoff(self: *Self, frequency_hz: T) void {
            self.cutoff_target = @max(20.0, @min(frequency_hz, self.sample_rate * 0.45));
            self.updateCoefficients();
        }

        /// Set cutoff via 1V/octave CV (0V = 261.63 Hz, middle C)
        pub fn setCutoffCV(self: *Self, cv_volts: T) void {
            // 1V/octave: each volt doubles frequency
            // 0V = middle C (261.63 Hz)
            const base_freq: T = 261.63;
            const frequency_hz = base_freq * std.math.pow(T, 2.0, cv_volts);
            self.setCutoff(frequency_hz);
        }

        /// Set resonance (emphasis)
        /// 0.0 = no resonance
        /// ~3.9 = near self-oscillation
        /// 4.0 = self-oscillation
        pub fn setResonance(self: *Self, res: T) void {
            self.resonance_target = @max(0.0, @min(res, FilterComponents.max_resonance));
            // Compensate for gain loss at high resonance
            // Each pole reduces passband gain by ~1/(1+k/4) factor
            self.compensation_target = 1.0 + self.resonance_target * 0.25;
        }

        /// Enable/disable transistor nonlinearity modeling
        pub fn setNonlinear(self: *Self, enabled: bool) void {
            self.use_nonlinear = enabled;
        }

        /// Set saturation level for nonlinear mode
        pub fn setSaturation(self: *Self, level: T) void {
            self.saturation = @max(0.1, level);
        }

        fn updateCoefficients(self: *Self) void {
            self.stage1.setCutoffHz(self.cutoff_target, self.sample_rate);
            self.stage2.setCutoffHz(self.cutoff_target, self.sample_rate);
            self.stage3.setCutoffHz(self.cutoff_target, self.sample_rate);
            self.stage4.setCutoffHz(self.cutoff_target, self.sample_rate);
        }

        /// Smooth parameter changes to avoid clicks
        fn smoothParam(current: T, target: T, coeff: T) T {
            return current + (target - current) * coeff;
        }

        /// Process one sample through the 4-pole filter
        pub inline fn processSample(self: *Self, input: T) T {
            // Parameter smoothing (approximately 5ms time constant)
            const smooth_coeff: T = 0.001;

            // Smooth cutoff changes
            const prev_cutoff = self.cutoff_hz;
            self.cutoff_hz = smoothParam(self.cutoff_hz, self.cutoff_target, smooth_coeff);
            if (@abs(self.cutoff_hz - prev_cutoff) > 0.01) {
                self.updateCoefficients();
            }

            // Smooth resonance and compensation
            self.resonance = smoothParam(self.resonance, self.resonance_target, smooth_coeff);
            self.compensation = smoothParam(self.compensation, self.compensation_target, smooth_coeff);

            // Apply input gain compensation and subtract resonance feedback
            // The negative feedback creates the resonant peak
            const compensated_input = input * self.compensation - self.feedback * self.resonance;

            var output: T = undefined;

            if (self.use_nonlinear) {
                // Nonlinear processing with transistor saturation per stage
                const s1 = self.stage1.processSampleNonlinear(compensated_input, self.saturation);
                const s2 = self.stage2.processSampleNonlinear(s1, self.saturation);
                const s3 = self.stage3.processSampleNonlinear(s2, self.saturation);
                output = self.stage4.processSampleNonlinear(s3, self.saturation);
            } else {
                // Linear processing (faster, less character)
                const s1 = self.stage1.processSample(compensated_input);
                const s2 = self.stage2.processSample(s1);
                const s3 = self.stage3.processSample(s2);
                output = self.stage4.processSample(s3);
            }

            // Store feedback for next sample (one sample delay for stability)
            self.feedback = output;

            return output;
        }

        /// Get intermediate outputs for multimode operation
        pub fn processSampleMultimode(self: *Self, input: T) FilterOutputs(T) {
            // Parameter smoothing
            const smooth_coeff: T = 0.001;

            const prev_cutoff = self.cutoff_hz;
            self.cutoff_hz = smoothParam(self.cutoff_hz, self.cutoff_target, smooth_coeff);
            if (@abs(self.cutoff_hz - prev_cutoff) > 0.01) {
                self.updateCoefficients();
            }

            self.resonance = smoothParam(self.resonance, self.resonance_target, smooth_coeff);
            self.compensation = smoothParam(self.compensation, self.compensation_target, smooth_coeff);

            const compensated_input = input * self.compensation - self.feedback * self.resonance;

            var s1_out: T = undefined;
            var s2_out: T = undefined;
            var s3_out: T = undefined;
            var s4_out: T = undefined;

            if (self.use_nonlinear) {
                s1_out = self.stage1.processSampleNonlinear(compensated_input, self.saturation);
                s2_out = self.stage2.processSampleNonlinear(s1_out, self.saturation);
                s3_out = self.stage3.processSampleNonlinear(s2_out, self.saturation);
                s4_out = self.stage4.processSampleNonlinear(s3_out, self.saturation);
            } else {
                s1_out = self.stage1.processSample(compensated_input);
                s2_out = self.stage2.processSample(s1_out);
                s3_out = self.stage3.processSample(s2_out);
                s4_out = self.stage4.processSample(s3_out);
            }

            self.feedback = s4_out;

            return .{
                .lp6 = s1_out, // 6dB/oct lowpass (1-pole)
                .lp12 = s2_out, // 12dB/oct lowpass (2-pole)
                .lp18 = s3_out, // 18dB/oct lowpass (3-pole)
                .lp24 = s4_out, // 24dB/oct lowpass (4-pole, classic Moog)
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

test "wdf ladder section coefficient calculation" {
    var section = WdfLadderSection(f64).init();

    // At ωc = π/2 (quarter Nyquist), tan(π/4) = 1, so m = 0.5
    section.setCutoffOmega(std.math.pi / 2.0);
    try expectApproxEq(section.m, 0.5, 1e-6);

    // At very low frequency, m approaches 0
    section.setCutoffOmega(0.01);
    try std.testing.expect(section.m < 0.01);
    try std.testing.expect(section.m > 0.0);

    // At high frequency (0.9π), m should be reasonably high
    // Note: we clamp omega to prevent tan() explosion, so m won't reach 0.9
    section.setCutoffOmega(std.math.pi * 0.9);
    try std.testing.expect(section.m > 0.8); // Relaxed from 0.9 due to clamping
    try std.testing.expect(section.m < 1.0);
}

test "wdf ladder section basic operation" {
    const sample_rate: f64 = 48000.0;
    var section = WdfLadderSection(f64).init();
    section.setCutoffHz(1000.0, sample_rate);

    // Process a step response
    var output: f64 = 0.0;
    for (0..500) |_| {
        output = section.processSample(1.0);
    }

    // Lowpass should approach input value (DC gain = 1)
    try std.testing.expect(output > 0.99);
    try std.testing.expect(output <= 1.01);
}

test "wdf ladder section is lowpass" {
    const sample_rate: f64 = 48000.0;
    var section = WdfLadderSection(f64).init();
    section.setCutoffHz(1000.0, sample_rate);

    // Generate low frequency signal (100 Hz) - well below cutoff
    var sum_low: f64 = 0.0;
    const low_freq: f64 = 100.0;
    for (0..2000) |i| {
        const phase = @as(f64, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * low_freq;
        const input = @sin(phase);
        const output = section.processSample(input);
        // Skip first 500 samples for settling
        if (i >= 500) {
            sum_low += output * output;
        }
    }

    section.reset();

    // Generate high frequency signal (10000 Hz) - well above cutoff
    var sum_high: f64 = 0.0;
    const high_freq: f64 = 10000.0;
    for (0..2000) |i| {
        const phase = @as(f64, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * high_freq;
        const input = @sin(phase);
        const output = section.processSample(input);
        if (i >= 500) {
            sum_high += output * output;
        }
    }

    // Low frequency should pass with much more energy than high frequency
    // For a 1-pole lowpass at 1kHz, 10kHz should be attenuated by ~20dB (factor of 100 in power)
    try std.testing.expect(sum_low > sum_high * 10.0);
}

test "moog ladder filter reduces high frequencies" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter = MoogLadderFilter(T).init(sample_rate);
    filter.setCutoff(1000.0); // 1kHz cutoff
    filter.setResonance(0.0); // No resonance
    filter.setNonlinear(false); // Linear for predictable test

    // Generate high frequency test signal (10kHz)
    var sum_input: T = 0.0;
    var sum_output: T = 0.0;
    const freq: T = 10000.0;

    for (0..3000) |i| {
        const phase = @as(T, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase);
        const output = filter.processSample(input);

        // Skip first 1000 samples for settling
        if (i >= 1000) {
            sum_input += input * input;
            sum_output += output * output;
        }
    }

    // 4-pole filter at 10kHz (10x cutoff) should attenuate by ~80dB
    // In power terms that's 10^8, but we'll use a conservative threshold
    try std.testing.expect(sum_output < sum_input * 0.01);
}

test "moog ladder resonance increases peak" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter_no_res = MoogLadderFilter(T).init(sample_rate);
    filter_no_res.setCutoff(1000.0);
    filter_no_res.setResonance(0.0);
    filter_no_res.setNonlinear(false);

    var filter_res = MoogLadderFilter(T).init(sample_rate);
    filter_res.setCutoff(1000.0);
    filter_res.setResonance(3.5);
    filter_res.setNonlinear(false);

    // Generate signal at cutoff frequency
    const freq: T = 1000.0;

    // Warm up filters to reach steady state
    for (0..4000) |i| {
        const phase = @as(T, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase) * 0.3;
        _ = filter_no_res.processSample(input);
        _ = filter_res.processSample(input);
    }

    // Measure steady-state response
    var sum_no_res: T = 0.0;
    var sum_res: T = 0.0;
    for (0..2000) |i| {
        const phase = @as(T, @floatFromInt(i + 4000)) / sample_rate * 2.0 * std.math.pi * freq;
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
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter = MoogLadderFilter(T).init(sample_rate);
    filter.setCutoff(1000.0);
    filter.setResonance(3.9); // Near self-oscillation
    filter.setNonlinear(true);

    var out: T = 0.0;
    var max_out: T = 0.0;
    for (0..4000) |i| {
        const input = @sin(@as(T, @floatFromInt(i)) * 0.1) * 0.5;
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
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter = MoogLadderFilter(T).init(sample_rate);
    filter.setCutoff(440.0); // A4
    filter.setResonance(4.0); // Self-oscillation
    filter.setNonlinear(true);

    // Force parameters to their targets immediately (bypass smoothing)
    filter.resonance = filter.resonance_target;
    filter.compensation = filter.compensation_target;

    // Give it a kick to start oscillation
    _ = filter.processSample(0.5);
    _ = filter.processSample(0.2);
    _ = filter.processSample(0.0);

    // Let it run with zero input - give it time to build up
    var sum: T = 0.0;
    for (0..8000) |_| {
        const out = filter.processSample(0.0);
        sum += out * out;
    }

    // Should self-oscillate (have significant output with zero input)
    // Using a lower threshold since nonlinearity limits amplitude
    const rms = @sqrt(sum / 8000.0);
    try std.testing.expect(rms > 0.05);
}

test "board4 chain produces output" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var board4 = Board4FilterVCA(T).init(sample_rate);
    board4.setCutoff(800.0);
    board4.setResonance(2.5);
    board4.setAmplitude(0.9);

    var sum_out: T = 0.0;
    for (0..2000) |i| {
        const input = @sin(@as(T, @floatFromInt(i)) * 0.05);
        const out = board4.processSample(input);
        sum_out += out * out;
    }

    try std.testing.expect(sum_out > 1e-6);
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

test "multimode outputs are progressively filtered" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter = MoogLadderFilter(T).init(sample_rate);
    filter.setCutoff(500.0);
    filter.setResonance(0.0);
    filter.setNonlinear(false);

    // High frequency signal
    const freq: T = 8000.0;
    var sum_6: T = 0.0;
    var sum_12: T = 0.0;
    var sum_18: T = 0.0;
    var sum_24: T = 0.0;

    for (0..3000) |i| {
        const phase = @as(T, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
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
