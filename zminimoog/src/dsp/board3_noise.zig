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
// Complete Noise Source (White + Pink)
// ============================================================================

/// Complete noise generator with white and pink outputs
pub fn NoiseSource(comptime T: type) type {
    return struct {
        white_gen: WhiteNoiseGenerator(T),
        pink_filter: PinkNoiseFilter(T),

        // Output mix (0.0 = white only, 1.0 = pink only)
        pink_mix: T = 0.5,

        const Self = @This();

        pub fn init() Self {
            return .{
                .white_gen = WhiteNoiseGenerator(T).init(),
                .pink_filter = PinkNoiseFilter(T).init(),
            };
        }

        pub fn reset(self: *Self) void {
            self.white_gen.reset();
            self.pink_filter.reset();
        }

        pub fn setSeed(self: *Self, seed: u64) void {
            self.white_gen.setSeed(seed);
        }

        /// Set mix between white (0.0) and pink (1.0)
        pub fn setPinkMix(self: *Self, mix: T) void {
            self.pink_mix = @max(0.0, @min(1.0, mix));
        }

        /// Generate white noise sample
        pub inline fn processWhite(self: *Self) T {
            return self.white_gen.processSample();
        }

        /// Generate pink noise sample
        pub inline fn processPink(self: *Self) T {
            const white = self.white_gen.processSample();
            return self.pink_filter.processSample(white);
        }

        /// Generate both white and pink outputs
        pub fn processSampleBoth(self: *Self) NoiseOutputs(T) {
            const white = self.white_gen.processSample();
            const pink = self.pink_filter.processSample(white);
            return .{
                .white = white,
                .pink = pink,
            };
        }

        /// Generate mixed output based on pink_mix setting
        pub inline fn processSample(self: *Self) T {
            const white = self.white_gen.processSample();
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
