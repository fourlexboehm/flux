// Noise Generator - White, Pink, and Red noise
// Ported from OB-Xf Noise.h
//
// White noise uses a linear congruential generator.
// Pink noise uses the Voss-McCartney algorithm (Phil Burk's implementation).
// Red noise (Brownian) integrates white noise with reflection clamping.

const std = @import("std");

pub const Noise = struct {
    const max_random_rows: u8 = 30;
    const random_bits: comptime_int = 24;
    const random_shift: u5 = @intCast(32 - random_bits); // 8

    // White noise state
    white_state: i32 = 0,
    white_vol_comp: f32 = 1.0,

    // Pink noise state (Voss-McCartney)
    pink_rows: [max_random_rows]i32 = [_]i32{0} ** max_random_rows,
    pink_running_sum: i32 = 0,
    pink_index: i32 = 0,
    pink_index_mask: i32 = 0,
    pink_scale: f32 = 0.0,

    // Red noise state
    red_state: f32 = 0.0,

    const Self = @This();

    pub fn init() Self {
        var self = Self{};
        self.setSampleRate(44100.0, 10);
        return self;
    }

    /// Configure the noise generator for a given sample rate.
    /// `num_pink_generators` controls the number of pink noise rows (default 10).
    pub fn setSampleRate(self: *Self, sr: f32, num_pink_generators: u8) void {
        self.white_vol_comp = (4.6567e-10 * 0.5) * @sqrt(sr / 44100.0);
        self.setPinkNoiseGen(num_pink_generators);
    }

    /// Set the starting seed for the white noise generator.
    /// Use this whenever you want to ensure a repeatable pseudo-random sequence.
    pub inline fn seedWhiteNoise(self: *Self, seed: i32) void {
        self.white_state = seed;
    }

    /// Get the next 32-bit signed integer value (full range) from the LCG.
    pub inline fn getRandomValue(self: *Self) i32 {
        // Use unsigned arithmetic to avoid overflow UB, matching the C++ version:
        //   state = int32_t(uint32_t(state) * 1103515245u + 12345u)
        const us: u32 = @bitCast(self.white_state);
        const next: u32 = us *% 1103515245 +% 12345;
        self.white_state = @bitCast(next);
        return self.white_state;
    }

    /// Get the next white noise sample, volume-compensated for sample rate.
    pub inline fn getWhite(self: *Self) f32 {
        const rv: f32 = @floatFromInt(self.getRandomValue());
        return rv * self.white_vol_comp;
    }

    /// Get the next pink noise sample.
    ///
    /// Adapted from Phil Burk's copyleft code:
    /// https://www.firstpr.com.au/dsp/pink-noise/phil_burk_19990905_patest_pink.c
    pub inline fn getPink(self: *Self) f32 {
        // Increment and mask index
        self.pink_index = (self.pink_index + 1) & self.pink_index_mask;

        // If index is zero, don't update any random values
        if (self.pink_index != 0) {
            var num_zeros: usize = 0;
            var n: i32 = self.pink_index;

            // Determine how many trailing zeroes there are in index
            while ((n & 1) == 0) {
                n = n >> 1;
                num_zeros += 1;
            }

            const random_value = self.getRandomValue() >> random_shift;

            // Replace the indexed row's random value.
            // Subtract and add back to running sum instead of adding all
            // the random values together -- only one changes each time.
            self.pink_running_sum -= self.pink_rows[num_zeros];
            self.pink_running_sum += random_value;
            self.pink_rows[num_zeros] = random_value;
        }

        // Add extra white noise value
        const random_value = self.getRandomValue() >> random_shift;

        const sum: f32 = @floatFromInt(self.pink_running_sum + random_value);
        return self.pink_scale * sum;
    }

    /// Get the next red (Brownian) noise sample.
    pub inline fn getRed(self: *Self) f32 {
        self.red_state += self.getWhite() * 0.05;

        if (self.red_state > 1.0) {
            self.red_state = 2.0 - self.red_state;
        } else if (self.red_state < -1.0) {
            self.red_state = -2.0 - self.red_state;
        }

        return self.red_state;
    }

    /// Reset all internal state to defaults.
    pub fn reset(self: *Self) void {
        self.white_state = 0;
        self.pink_rows = [_]i32{0} ** max_random_rows;
        self.pink_running_sum = 0;
        self.pink_index = 0;
        self.red_state = 0.0;
    }

    // ========================================================================
    // Private helpers
    // ========================================================================

    fn setPinkNoiseGen(self: *Self, num_generators: u8) void {
        self.pink_index = 0;
        self.pink_index_mask = (@as(i32, 1) << @intCast(num_generators)) - 1;

        // Calculate maximum possible signed random value
        const pmax: i32 = (@as(i32, @intCast(num_generators)) + 1) * (@as(i32, 1) << @as(u5, random_bits - 1));
        self.pink_scale = 1.0 / @as(f32, @floatFromInt(pmax));

        // Initialize rows
        for (0..@as(usize, num_generators)) |i| {
            self.pink_rows[i] = 0;
        }

        self.pink_running_sum = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "white noise produces non-zero output" {
    var noise = Noise.init();
    noise.seedWhiteNoise(42);

    var has_nonzero = false;
    for (0..100) |_| {
        const sample = noise.getWhite();
        if (@abs(sample) > 0.0) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);
}

test "white noise LCG produces deterministic sequence" {
    var noise1 = Noise.init();
    var noise2 = Noise.init();
    noise1.seedWhiteNoise(123);
    noise2.seedWhiteNoise(123);

    for (0..50) |_| {
        try std.testing.expectEqual(noise1.getRandomValue(), noise2.getRandomValue());
    }
}

test "pink noise produces non-zero output" {
    var noise = Noise.init();
    noise.seedWhiteNoise(99);

    var has_nonzero = false;
    for (0..200) |_| {
        const sample = noise.getPink();
        if (@abs(sample) > 0.0) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);
}

test "red noise stays bounded" {
    var noise = Noise.init();
    noise.seedWhiteNoise(7);

    for (0..10000) |_| {
        const sample = noise.getRed();
        try std.testing.expect(sample >= -2.0);
        try std.testing.expect(sample <= 2.0);
    }
}

test "sample rate affects volume compensation" {
    var noise1 = Noise.init();
    noise1.setSampleRate(44100.0, 10);
    const comp1 = noise1.white_vol_comp;

    var noise2 = Noise.init();
    noise2.setSampleRate(96000.0, 10);
    const comp2 = noise2.white_vol_comp;

    // Higher sample rate should produce a larger volume compensation factor
    try std.testing.expect(comp2 > comp1);
}
