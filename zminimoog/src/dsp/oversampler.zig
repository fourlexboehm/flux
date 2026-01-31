// Global Oversampler with Kaiser Window FIR
// For whole-synth oversampling (more efficient than per-oscillator)
//
// Kaiser window provides excellent stopband attenuation (~70dB with β=8)
// while maintaining reasonable transition band width.

const std = @import("std");

/// Bessel I0 function approximation for Kaiser window
fn besselI0(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    // Polynomial approximation valid for |x| <= 15
    var sum: T = 1.0;
    var term: T = 1.0;
    const x_sq = x * x * 0.25;

    // 20 iterations gives good accuracy for β up to ~12
    inline for (1..21) |k| {
        const kf: T = @floatFromInt(k);
        term *= x_sq / (kf * kf);
        sum += term;
    }
    return sum;
}

/// Generate Kaiser window coefficients at comptime
fn generateKaiserWindow(comptime T: type, comptime n: usize, comptime beta: comptime_float) [n]T {
    var window: [n]T = undefined;
    const bessel_beta = besselI0(@as(T, beta));
    const half_n: T = @as(T, @floatFromInt(n - 1)) * 0.5;

    for (0..n) |i| {
        const x = (@as(T, @floatFromInt(i)) - half_n) / half_n;
        const arg = beta * @sqrt(1.0 - x * x);
        window[i] = besselI0(arg) / bessel_beta;
    }
    return window;
}

/// Generate lowpass FIR coefficients with Kaiser window at comptime
fn generateKaiserFIR(comptime T: type, comptime n: usize, comptime factor: usize, comptime beta: comptime_float) [n]T {
    const window = generateKaiserWindow(T, n, beta);
    var coeffs: [n]T = undefined;

    // Cutoff frequency: slightly below Nyquist/factor to ensure good stopband
    const fc: T = 0.45 / @as(T, @floatFromInt(factor));
    const half_n: T = @as(T, @floatFromInt(n - 1)) * 0.5;

    var sum: T = 0.0;
    for (0..n) |i| {
        const x = @as(T, @floatFromInt(i)) - half_n;
        if (@abs(x) < 1e-10) {
            coeffs[i] = 2.0 * fc * window[i];
        } else {
            // sinc function * window
            const sinc = @sin(2.0 * std.math.pi * fc * x) / (std.math.pi * x);
            coeffs[i] = sinc * window[i];
        }
        sum += coeffs[i];
    }

    // Normalize for unity gain at DC
    for (0..n) |i| {
        coeffs[i] /= sum;
    }

    return coeffs;
}

/// Global oversampler supporting runtime factor selection
/// Uses 31-tap Kaiser-windowed FIR filter (β=8, ~70dB stopband)
pub fn GlobalOversampler(comptime T: type, comptime max_factor: comptime_int) type {
    comptime if (max_factor != 2 and max_factor != 4) @compileError("max_factor must be 2 or 4");

    const num_taps = 31;

    return struct {
        filter_state: [num_taps]T = [_]T{0.0} ** num_taps,

        // Pre-computed Kaiser window coefficients (β=8, ~70dB stopband attenuation)
        const coeffs_2x = generateKaiserFIR(T, num_taps, 2, 8.0);
        const coeffs_4x = generateKaiserFIR(T, num_taps, 4, 8.0);

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.filter_state = [_]T{0.0} ** num_taps;
        }

        /// Decimate from 2x oversampled rate
        pub fn decimate2x(self: *Self, samples: [2]T) T {
            // Push samples into filter state
            for (samples) |sample| {
                // Shift state
                var i: usize = num_taps - 1;
                while (i > 0) : (i -= 1) {
                    self.filter_state[i] = self.filter_state[i - 1];
                }
                self.filter_state[0] = sample;
            }

            // Apply FIR filter
            var result: T = 0.0;
            inline for (0..num_taps) |i| {
                result += coeffs_2x[i] * self.filter_state[i];
            }
            return result;
        }

        /// Decimate from 4x oversampled rate
        pub fn decimate4x(self: *Self, samples: [4]T) T {
            // Push samples into filter state
            for (samples) |sample| {
                // Shift state
                var i: usize = num_taps - 1;
                while (i > 0) : (i -= 1) {
                    self.filter_state[i] = self.filter_state[i - 1];
                }
                self.filter_state[0] = sample;
            }

            // Apply FIR filter
            var result: T = 0.0;
            inline for (0..num_taps) |i| {
                result += coeffs_4x[i] * self.filter_state[i];
            }
            return result;
        }

        /// Generic decimate function for runtime factor selection
        pub fn decimate(self: *Self, samples: []const T) T {
            return switch (samples.len) {
                1 => samples[0], // 1x = passthrough
                2 => self.decimate2x(samples[0..2].*),
                4 => self.decimate4x(samples[0..4].*),
                else => unreachable,
            };
        }
    };
}

/// Oversample factor enum for parameter control
pub const OversampleFactor = enum(u8) {
    x1 = 1,
    x2 = 2,
    x4 = 4,

    pub fn toFloat(self: OversampleFactor, comptime T: type) T {
        return @floatFromInt(@intFromEnum(self));
    }

    pub fn fromParamValue(value: f64) OversampleFactor {
        const rounded: u8 = @intFromFloat(@round(@max(0.0, @min(2.0, value))));
        return switch (rounded) {
            0 => .x1,
            1 => .x2,
            2 => .x4,
            else => .x4,
        };
    }

    pub fn toParamValue(self: OversampleFactor) f64 {
        return switch (self) {
            .x1 => 0.0,
            .x2 => 1.0,
            .x4 => 2.0,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "kaiser window is symmetric" {
    const window = generateKaiserWindow(f64, 31, 8.0);

    // Check symmetry
    for (0..15) |i| {
        try std.testing.expectApproxEqAbs(window[i], window[30 - i], 1e-10);
    }

    // Center should be 1.0
    try std.testing.expectApproxEqAbs(window[15], 1.0, 1e-10);
}

test "fir coefficients sum to approximately 1" {
    const coeffs = generateKaiserFIR(f64, 31, 4, 8.0);

    var sum: f64 = 0.0;
    for (coeffs) |c| {
        sum += c;
    }

    try std.testing.expectApproxEqAbs(sum, 1.0, 1e-10);
}

test "oversampler decimates DC correctly" {
    var os = GlobalOversampler(f64, 4).init();

    // DC signal at 0.5 should pass through unchanged
    const dc_samples_4x = [_]f64{ 0.5, 0.5, 0.5, 0.5 };

    // Need to run several times to fill the filter state
    var out: f64 = 0.0;
    for (0..20) |_| {
        out = os.decimate4x(dc_samples_4x);
    }

    try std.testing.expectApproxEqAbs(out, 0.5, 0.01);
}

test "oversample factor enum conversions" {
    try std.testing.expectEqual(OversampleFactor.x1, OversampleFactor.fromParamValue(0.0));
    try std.testing.expectEqual(OversampleFactor.x2, OversampleFactor.fromParamValue(1.0));
    try std.testing.expectEqual(OversampleFactor.x4, OversampleFactor.fromParamValue(2.0));

    try std.testing.expectEqual(@as(f64, 0.0), OversampleFactor.x1.toParamValue());
    try std.testing.expectEqual(@as(f64, 1.0), OversampleFactor.x2.toParamValue());
    try std.testing.expectEqual(@as(f64, 2.0), OversampleFactor.x4.toParamValue());
}
