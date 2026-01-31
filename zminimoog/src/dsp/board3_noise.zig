// Board 3: Power Supply and Noise Board
// Minimoog Model D - Noise Generator Section
//
// Schematic page 7 of Minimoog-schematics.pdf
//
// Contains:
//   - White Noise Generator (reverse-biased transistor junction)
//   - Pink Noise Filter (-3dB/octave)

const std = @import("std");
const wdft = @import("zig_wdf");

// ============================================================================
// Component Values from Schematic
// ============================================================================

pub const NoiseComponents = struct {
    // Pink noise filter capacitor
    pub const pink_filter_cap: comptime_float = 0.047e-6; // 0.047µF

    // Pink filter resistance
    pub const pink_filter_r: comptime_float = 10000.0; // ~10k

    // Transistor noise source parameters (Q15: 2N3392 reverse-biased BE junction)
    // Real transistor noise has bandwidth limited by junction capacitance
    pub const noise_bandwidth: comptime_float = 100000.0; // ~100kHz bandwidth
    pub const junction_cap: comptime_float = 10.0e-12; // ~10pF junction capacitance

    // Spectral characteristics
    pub const pink_tilt: comptime_float = 0.1; // Slight pink tilt from junction capacitance
};

// ============================================================================
// White Noise Generator
// ============================================================================

/// White noise generator using xorshift algorithm
/// Simulates the reverse-biased transistor junction noise source
pub fn WhiteNoiseGenerator(comptime T: type) type {
    return struct {
        state: u64,

        const Self = @This();

        pub fn init() Self {
            return .{
                .state = 0x853c49e6748fea9b, // Default seed
            };
        }

        pub fn initSeed(seed: u64) Self {
            return .{
                .state = if (seed == 0) 1 else seed,
            };
        }

        pub fn reset(self: *Self) void {
            self.state = 0x853c49e6748fea9b;
        }

        pub fn setSeed(self: *Self, seed: u64) void {
            self.state = if (seed == 0) 1 else seed;
        }

        /// Generate next random value (internal)
        inline fn nextRaw(self: *Self) u64 {
            // xorshift64*
            var x = self.state;
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            self.state = x;
            return x *% 0x2545F4914F6CDD1D;
        }

        /// Generate one sample of white noise (-1.0 to 1.0)
        pub inline fn processSample(self: *Self) T {
            const raw = self.nextRaw();
            // Convert to float in range -1.0 to 1.0
            const normalized = @as(T, @floatFromInt(@as(i64, @bitCast(raw)))) / @as(T, @floatFromInt(std.math.maxInt(i64)));
            return normalized;
        }
    };
}

// ============================================================================
// Transistor Noise Source (Authentic Analog Model)
// ============================================================================

/// Transistor noise source modeling reverse-biased BE junction
///
/// Circuit (from schematic):
///   Q15 (2N3392) with reverse-biased base-emitter junction produces
///   avalanche/shot noise. The noise is then amplified and filtered.
///
/// Characteristics:
///   - Shot noise from reverse-biased junction (Poisson process)
///   - Bandwidth limited by junction capacitance (~100kHz)
///   - Slight pink tilt from capacitive loading
///   - Temperature-dependent noise amplitude
///
/// This creates more authentic noise character than pure PRNG white noise.
pub fn TransistorNoiseSource(comptime T: type) type {
    return struct {
        // Core PRNG for quantum randomness (models shot noise statistics)
        prng: WhiteNoiseGenerator(T),

        // Bandwidth limiting filter state (models junction capacitance)
        lp_state: T = 0.0,
        lp_alpha: T = 0.0,

        // Additional filtering for spectral shaping
        hp_state: T = 0.0,
        hp_alpha: T = 0.0,

        // Pink tilt filter (slight 1/f characteristic)
        pink_state: T = 0.0,
        pink_coeff: T = 0.0,

        // Output scaling
        output_gain: T = 1.0,

        sample_rate: T,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            // Calculate filter coefficients

            // Lowpass for bandwidth limiting (~100kHz)
            const lp_cutoff = NoiseComponents.noise_bandwidth;
            const lp_alpha = calcLowpassAlpha(lp_cutoff, sample_rate);

            // Highpass to remove DC (~20Hz)
            const hp_cutoff: T = 20.0;
            const hp_alpha = calcHighpassAlpha(hp_cutoff, sample_rate);

            // Pink tilt coefficient
            const pink_coeff: T = NoiseComponents.pink_tilt;

            return Self{
                .prng = WhiteNoiseGenerator(T).init(),
                .lp_alpha = lp_alpha,
                .hp_alpha = hp_alpha,
                .pink_coeff = pink_coeff,
                .sample_rate = sample_rate,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.lp_alpha = calcLowpassAlpha(NoiseComponents.noise_bandwidth, sample_rate);
            self.hp_alpha = calcHighpassAlpha(20.0, sample_rate);
        }

        pub fn reset(self: *Self) void {
            self.prng.reset();
            self.lp_state = 0.0;
            self.hp_state = 0.0;
            self.pink_state = 0.0;
        }

        pub fn setSeed(self: *Self, seed: u64) void {
            self.prng.setSeed(seed);
        }

        /// Calculate lowpass filter coefficient
        fn calcLowpassAlpha(cutoff: T, sample_rate: T) T {
            const omega = 2.0 * std.math.pi * cutoff / sample_rate;
            return omega / (omega + 1.0);
        }

        /// Calculate highpass filter coefficient
        fn calcHighpassAlpha(cutoff: T, sample_rate: T) T {
            const omega = 2.0 * std.math.pi * cutoff / sample_rate;
            return 1.0 / (omega + 1.0);
        }

        /// Generate one sample of transistor noise
        /// Models the full analog noise source characteristics
        pub inline fn processSample(self: *Self) T {
            // Get raw shot noise (modeled as white noise)
            const raw = self.prng.processSample();

            // Apply bandwidth limiting (junction capacitance effect)
            // This is a simple one-pole lowpass at ~100kHz
            self.lp_state += self.lp_alpha * (raw - self.lp_state);

            // Apply slight pink tilt (capacitive loading effect)
            // This adds a subtle 1/f characteristic
            self.pink_state = self.pink_coeff * self.pink_state + (1.0 - self.pink_coeff) * self.lp_state;

            // Remove DC with highpass filter
            const ac_coupled = self.lp_state - self.hp_state;
            self.hp_state += self.hp_alpha * (self.lp_state - self.hp_state);

            // Blend pink tilt with bandwidth-limited noise
            const output = ac_coupled * (1.0 - self.pink_coeff) + self.pink_state * self.pink_coeff;

            return output * self.output_gain;
        }

        /// Set output gain
        pub fn setGain(self: *Self, gain: T) void {
            self.output_gain = gain;
        }
    };
}

// ============================================================================
// Pink Noise Filter (-3dB/octave)
// ============================================================================

/// Pink noise filter using Paul Kellet's approximation
/// Converts white noise to pink noise with -3dB/octave rolloff
pub fn PinkNoiseFilter(comptime T: type) type {
    return struct {
        // Filter state variables (Kellet's algorithm)
        b0: T = 0.0,
        b1: T = 0.0,
        b2: T = 0.0,
        b3: T = 0.0,
        b4: T = 0.0,
        b5: T = 0.0,
        b6: T = 0.0,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.b0 = 0.0;
            self.b1 = 0.0;
            self.b2 = 0.0;
            self.b3 = 0.0;
            self.b4 = 0.0;
            self.b5 = 0.0;
            self.b6 = 0.0;
        }

        /// Process white noise sample to produce pink noise
        pub inline fn processSample(self: *Self, white: T) T {
            // Paul Kellet's economy method
            // http://www.firstpr.com.au/dsp/pink-noise/
            self.b0 = 0.99886 * self.b0 + white * 0.0555179;
            self.b1 = 0.99332 * self.b1 + white * 0.0750759;
            self.b2 = 0.96900 * self.b2 + white * 0.1538520;
            self.b3 = 0.86650 * self.b3 + white * 0.3104856;
            self.b4 = 0.55000 * self.b4 + white * 0.5329522;
            self.b5 = -0.7616 * self.b5 - white * 0.0168980;

            const pink = self.b0 + self.b1 + self.b2 + self.b3 + self.b4 + self.b5 + self.b6 + white * 0.5362;
            self.b6 = white * 0.115926;

            // Scale to roughly unit amplitude
            return pink * 0.11;
        }
    };
}

// ============================================================================
// Complete Noise Source (Transistor + Pink)
// ============================================================================

/// Complete noise generator with transistor-modeled white and pink outputs
/// Uses TransistorNoiseSource for authentic analog noise character
pub fn NoiseSource(comptime T: type) type {
    return struct {
        // Transistor noise source (authentic analog model)
        transistor_noise: TransistorNoiseSource(T),
        pink_filter: PinkNoiseFilter(T),

        // Output mix (0.0 = white only, 1.0 = pink only)
        pink_mix: T = 0.5,

        sample_rate: T,

        const Self = @This();

        pub fn init() Self {
            return initWithSampleRate(48000.0); // Default sample rate
        }

        pub fn initWithSampleRate(sample_rate: T) Self {
            return .{
                .transistor_noise = TransistorNoiseSource(T).init(sample_rate),
                .pink_filter = PinkNoiseFilter(T).init(),
                .sample_rate = sample_rate,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.transistor_noise.prepare(sample_rate);
        }

        pub fn reset(self: *Self) void {
            self.transistor_noise.reset();
            self.pink_filter.reset();
        }

        pub fn setSeed(self: *Self, seed: u64) void {
            self.transistor_noise.setSeed(seed);
        }

        /// Set mix between white (0.0) and pink (1.0)
        pub fn setPinkMix(self: *Self, mix: T) void {
            self.pink_mix = @max(0.0, @min(1.0, mix));
        }

        /// Generate white noise sample (using transistor model)
        pub inline fn processWhite(self: *Self) T {
            return self.transistor_noise.processSample();
        }

        /// Generate pink noise sample
        pub inline fn processPink(self: *Self) T {
            const white = self.transistor_noise.processSample();
            return self.pink_filter.processSample(white);
        }

        /// Generate both white and pink outputs
        pub fn processSampleBoth(self: *Self) NoiseOutputs(T) {
            const white = self.transistor_noise.processSample();
            const pink = self.pink_filter.processSample(white);
            return .{
                .white = white,
                .pink = pink,
            };
        }

        /// Generate mixed output based on pink_mix setting
        pub inline fn processSample(self: *Self) T {
            const white = self.transistor_noise.processSample();
            const pink = self.pink_filter.processSample(white);
            return white * (1.0 - self.pink_mix) + pink * self.pink_mix;
        }
    };
}

pub fn NoiseOutputs(comptime T: type) type {
    return struct {
        white: T,
        pink: T,
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

test "white noise is bounded" {
    const T = f64;

    var noise = WhiteNoiseGenerator(T).init();

    var min_val: T = 1.0;
    var max_val: T = -1.0;

    for (0..10000) |_| {
        const sample = noise.processSample();
        min_val = @min(min_val, sample);
        max_val = @max(max_val, sample);
    }

    // Should be within -1 to 1 range
    try std.testing.expect(min_val >= -1.0);
    try std.testing.expect(max_val <= 1.0);

    // Should use most of the range
    try std.testing.expect(min_val < -0.5);
    try std.testing.expect(max_val > 0.5);
}

test "white noise has zero mean" {
    const T = f64;

    var noise = WhiteNoiseGenerator(T).init();

    var sum: T = 0.0;
    const count: usize = 100000;

    for (0..count) |_| {
        sum += noise.processSample();
    }

    const mean = sum / @as(T, @floatFromInt(count));

    // Mean should be close to zero
    try expectApproxEq(mean, 0.0, 0.02);
}

test "pink noise has lower high frequency content" {
    const T = f64;

    var noise = NoiseSource(T).init();

    // Compute variance of sample differences (proxy for high freq energy)
    var white_diff_var: T = 0.0;
    var pink_diff_var: T = 0.0;

    var prev_white: T = 0.0;
    var prev_pink: T = 0.0;

    const count: usize = 10000;
    for (0..count) |_| {
        const outputs = noise.processSampleBoth();

        const white_diff = outputs.white - prev_white;
        const pink_diff = outputs.pink - prev_pink;

        white_diff_var += white_diff * white_diff;
        pink_diff_var += pink_diff * pink_diff;

        prev_white = outputs.white;
        prev_pink = outputs.pink;
    }

    // Pink noise should have lower variance in differences (less high freq)
    try std.testing.expect(pink_diff_var < white_diff_var);
}

test "noise source produces both outputs" {
    const T = f64;

    var noise = NoiseSource(T).init();

    var has_white = false;
    var has_pink = false;

    for (0..1000) |_| {
        const outputs = noise.processSampleBoth();
        if (@abs(outputs.white) > 0.1) has_white = true;
        if (@abs(outputs.pink) > 0.05) has_pink = true;
    }

    try std.testing.expect(has_white);
    try std.testing.expect(has_pink);
}
