// 2-pole and 4-pole ladder filter with Xpander multimode
// Ported from OB-Xf Filter.h
//
// Original OB-Xd was written by Vadim Filatov, released under GPL3.
// OB-Xf is released under the GNU General Public Licence v3 or later.
//
// Implements:
//   - 2-pole SVF-like filter with diode pair approximation for self-oscillation
//   - 4-pole cascade ladder filter with TPT processing
//   - Xpander multimode output mixing via pole mix factors
//   - Standard multimode crossfade between pole outputs

const std = @import("std");
const audio_utils = @import("audio_utils.zig");

const pi: f32 = std.math.pi;

/// Number of Xpander filter modes.
pub const num_xpander_modes: usize = 15;

/// Pole mix factors for each Xpander mode.
/// Each row contains 5 coefficients [y0, y1, y2, y3, y4] that are used
/// to mix the outputs of the four ladder filter poles plus the input.
///
///  0: LP4         4-pole lowpass
///  1: LP3         3-pole lowpass
///  2: LP2         2-pole lowpass
///  3: LP1         1-pole lowpass
///  4: HP3         3-pole highpass
///  5: HP2         2-pole highpass
///  6: HP1         1-pole highpass
///  7: BP4         4-pole bandpass
///  8: BP2         2-pole bandpass
///  9: N2          2-pole notch
/// 10: PH3         3-pole phaser
/// 11: HP2+LP1     highpass 2 + lowpass 1
/// 12: HP3+LP1     highpass 3 + lowpass 1
/// 13: N2+LP1      notch 2 + lowpass 1
/// 14: PH3+LP1     phaser 3 + lowpass 1
const pole_mix_factors = [num_xpander_modes][5]f32{
    .{ 0, 0, 0, 0, 1 }, // LP4
    .{ 0, 0, 0, 1, 0 }, // LP3
    .{ 0, 0, 1, 0, 0 }, // LP2
    .{ 0, 1, 0, 0, 0 }, // LP1
    .{ 1, -3, 3, -1, 0 }, // HP3
    .{ 1, -2, 1, 0, 0 }, // HP2
    .{ 1, -1, 0, 0, 0 }, // HP1
    .{ 0, 0, 2, -4, 2 }, // BP4
    .{ 0, -2, 2, 0, 0 }, // BP2
    .{ 1, -2, 2, 0, 0 }, // N2
    .{ 1, -3, 6, -4, 0 }, // PH3
    .{ 0, -1, 2, -1, 0 }, // HP2+LP1
    .{ 0, -1, 3, -3, 1 }, // HP3+LP1
    .{ 0, -1, 2, -2, 0 }, // N2+LP1
    .{ 0, -1, 3, -6, 4 }, // PH3+LP1
};

pub const Filter = struct {
    // --- Filter state ---------------------------------------------------
    pole1: f32 = 0.0,
    pole2: f32 = 0.0,
    pole3: f32 = 0.0,
    pole4: f32 = 0.0,

    res_2pole: f32 = 1.0,
    res_4pole: f32 = 0.0,

    res_correction: f32 = 1.0,
    res_correction_inv: f32 = 1.0,

    multimode_xfade: f32 = 0.0,
    multimode_pole: i32 = 0,

    sample_rate: f32 = 1.0,
    sample_rate_inv: f32 = 1.0,

    // --- Parameters (public) --------------------------------------------
    par: Parameters = .{},

    pub const Parameters = struct {
        bp_blend_2pole: bool = false,
        push_2pole: bool = false,
        xpander_4pole: bool = false,

        multimode: f32 = 0.0,
        xpander_mode: u8 = 0,
    };

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Reset all filter state (pole memories) to zero.
    pub fn reset(self: *Self) void {
        self.pole1 = 0.0;
        self.pole2 = 0.0;
        self.pole3 = 0.0;
        self.pole4 = 0.0;
    }

    /// Set the multimode parameter and pre-compute the crossfade position.
    pub fn setMultimode(self: *Self, m: f32) void {
        self.par.multimode = m;
        self.multimode_pole = @intFromFloat(self.par.multimode * 3.0);
        self.multimode_xfade = self.par.multimode * 3.0 - @as(f32, @floatFromInt(self.multimode_pole));
    }

    /// Set the sample rate and pre-compute correction factors.
    pub fn setSampleRate(self: *Self, sr: f32) void {
        self.sample_rate = sr;
        self.sample_rate_inv = 1.0 / sr;

        const rc_rate = @sqrt(44000.0 / sr);

        self.res_correction = (970.0 / 44000.0) * rc_rate;
        self.res_correction_inv = 1.0 / self.res_correction;
    }

    /// Set the resonance amount. Computes internal coefficients for both
    /// the 2-pole and 4-pole filter modes.
    pub inline fn setResonance(self: *Self, res: f32) void {
        self.res_2pole = 1.0 - res;
        self.res_4pole = 3.5 * res;
    }

    // ====================================================================
    // 2-pole filter
    // ====================================================================

    /// Apply the 2-pole filter to a single sample at the given cutoff frequency.
    ///
    /// The cutoff `g` is in Hz and is pre-warped internally via tan().
    /// Output mode depends on `bpBlend2Pole` and `multimode` parameters.
    pub inline fn apply2Pole(self: *Self, sample: f32, g_hz: f32) f32 {
        const gpw = @tan(g_hz * self.sample_rate_inv * pi);
        const g = gpw;

        const v = self.resolveFeedback2Pole(sample, g);

        const y1 = v * g + self.pole1;
        self.pole1 = v * g + y1;

        const y2 = y1 * g + self.pole2;
        self.pole2 = y1 * g + y2;

        var out: f32 = undefined;

        if (self.par.bp_blend_2pole) {
            if (self.par.multimode < 0.5) {
                out = 2.0 * ((0.5 - self.par.multimode) * y2 + (self.par.multimode * y1));
            } else {
                out = 2.0 * ((1.0 - self.par.multimode) * y1 + (self.par.multimode - 0.5) * v);
            }
        } else {
            out = (1.0 - self.par.multimode) * y2 + (self.par.multimode * v);
        }

        return out;
    }

    // ====================================================================
    // 4-pole filter
    // ====================================================================

    /// Apply the 4-pole ladder filter to a single sample at the given cutoff frequency.
    ///
    /// The cutoff `g` is in Hz and is pre-warped internally via tan().
    /// When `xpander4Pole` is true, the output is computed using the Xpander
    /// pole mix factors. Otherwise, the standard multimode crossfade is used.
    pub inline fn apply4Pole(self: *Self, sample: f32, g_hz: f32) f32 {
        const g1 = @tan(g_hz * self.sample_rate_inv * pi);
        const g = g1;

        const lpc = g / (1.0 + g);
        const y0 = self.resolveFeedback4Pole(sample, g, lpc);

        // First lowpass in the cascade
        const v_d: f64 = (@as(f64, y0) - @as(f64, self.pole1)) * @as(f64, lpc);
        const res_d: f64 = v_d + @as(f64, self.pole1);

        self.pole1 = @floatCast(res_d + v_d);

        // Damping via atan saturation
        self.pole1 = @floatCast(
            std.math.atan(@as(f64, self.pole1) * @as(f64, self.res_correction)) *
                @as(f64, self.res_correction_inv),
        );

        const g_over_one_plus_g = g / (1.0 + g);
        const y1: f32 = @floatCast(res_d);
        const y2 = audio_utils.tptProcessScaledCutoff(&self.pole2, y1, g_over_one_plus_g);
        const y3 = audio_utils.tptProcessScaledCutoff(&self.pole3, y2, g_over_one_plus_g);
        const y4 = audio_utils.tptProcessScaledCutoff(&self.pole4, y3, g_over_one_plus_g);

        var out: f32 = undefined;

        if (self.par.xpander_4pole) {
            const mode = self.par.xpander_mode;
            const factors = pole_mix_factors[mode];
            out = (y0 * factors[0]) +
                (y1 * factors[1]) +
                (y2 * factors[2]) +
                (y3 * factors[3]) +
                (y4 * factors[4]);
        } else {
            switch (self.multimode_pole) {
                0 => {
                    out = (1.0 - self.multimode_xfade) * y4 + self.multimode_xfade * y3;
                },
                1 => {
                    out = (1.0 - self.multimode_xfade) * y3 + self.multimode_xfade * y2;
                },
                2 => {
                    out = (1.0 - self.multimode_xfade) * y2 + self.multimode_xfade * y1;
                },
                3 => {
                    out = y1;
                },
                else => {
                    out = 0.0;
                },
            }
        }

        // Half volume compensation
        return out * (1.0 + self.res_4pole * 0.45);
    }

    // ====================================================================
    // Private helpers
    // ====================================================================

    /// Taylor approximation of a slightly mismatched diode pair.
    /// Used for the 2-pole filter's nonlinear feedback.
    inline fn diodePairResistanceApprox(x: f32) f32 {
        return ((((0.0103592 * x + 0.00920833) * x + 0.185) * x + 0.05) * x + 1.0);
    }

    /// Resolve the 2-pole feedback path including diode pair nonlinearity.
    inline fn resolveFeedback2Pole(self: *Self, sample: f32, g: f32) f32 {
        // Boosting non-linearity
        const push: f32 = -1.0 - @as(f32, if (self.par.push_2pole) 0.035 else 0.0);

        const tc_fb = diodePairResistanceApprox(self.pole1 * 0.0876) + push;

        // Resolve linear feedback
        const y = (sample - 2.0 * (self.pole1 * (self.res_2pole + tc_fb)) - g * self.pole1 -
            self.pole2) /
            (1.0 + g * (2.0 * (self.res_2pole + tc_fb) + g));

        return y;
    }

    /// Resolve the 4-pole feedback path for the ladder filter.
    inline fn resolveFeedback4Pole(self: *Self, sample: f32, g: f32, lpc: f32) f32 {
        const ml = 1.0 / (1.0 + g);
        const s_val = (lpc * (lpc * (lpc * self.pole1 + self.pole2) + self.pole3) + self.pole4) * ml;
        const big_g = lpc * lpc * lpc * lpc;
        const y = (sample - self.res_4pole * s_val) / (1.0 + self.res_4pole * big_g);

        return y;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "filter init has zero state" {
    const flt = Filter.init();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), flt.pole1, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), flt.pole2, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), flt.pole3, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), flt.pole4, 1e-10);
}

test "filter reset clears poles" {
    var flt = Filter.init();
    flt.setSampleRate(44100.0);

    // Push some signal through
    _ = flt.apply4Pole(1.0, 1000.0);
    _ = flt.apply4Pole(0.5, 1000.0);

    flt.reset();

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), flt.pole1, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), flt.pole2, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), flt.pole3, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), flt.pole4, 1e-10);
}

test "filter set sample rate computes correction" {
    var flt = Filter.init();
    flt.setSampleRate(44100.0);

    try std.testing.expect(flt.res_correction > 0.0);
    try std.testing.expect(flt.res_correction_inv > 0.0);
    try std.testing.expectApproxEqAbs(1.0 / flt.res_correction, flt.res_correction_inv, 1e-6);
}

test "filter 4pole lowpass passes DC" {
    var flt = Filter.init();
    flt.setSampleRate(44100.0);
    flt.setResonance(0.0);
    flt.setMultimode(0.0); // full LP4

    // Feed DC signal for a while
    var out: f32 = 0.0;
    for (0..44100) |_| {
        out = flt.apply4Pole(1.0, 10000.0);
    }

    // With a high cutoff and no resonance, DC should pass through
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out, 0.05);
}

test "filter 4pole lowpass attenuates high frequencies" {
    var flt = Filter.init();
    flt.setSampleRate(44100.0);
    flt.setResonance(0.0);
    flt.setMultimode(0.0);

    // Feed a high-frequency signal (alternating +1/-1 = Nyquist/2)
    var sum: f32 = 0.0;
    var sign: f32 = 1.0;
    for (0..4410) |_| {
        const out = flt.apply4Pole(sign, 200.0); // low cutoff
        sum += @abs(out);
        sign = -sign;
    }

    // The average output should be much less than 1.0 (heavily filtered)
    const avg = sum / 4410.0;
    try std.testing.expect(avg < 0.1);
}

test "filter 2pole produces output" {
    var flt = Filter.init();
    flt.setSampleRate(44100.0);
    flt.setResonance(0.3);
    flt.setMultimode(0.0);

    var out: f32 = 0.0;
    for (0..4410) |_| {
        out = flt.apply2Pole(1.0, 5000.0);
    }

    // Should converge toward 1.0 for DC input with lowpass
    try std.testing.expect(out > 0.5);
}

test "filter multimode crossfade changes output" {
    var flt1 = Filter.init();
    flt1.setSampleRate(44100.0);
    flt1.setResonance(0.2);
    flt1.setMultimode(0.0); // full LP4

    var flt2 = Filter.init();
    flt2.setSampleRate(44100.0);
    flt2.setResonance(0.2);
    flt2.setMultimode(1.0); // full LP1

    // Feed a step response and accumulate absolute output difference
    var diff_sum: f32 = 0.0;
    for (0..4410) |i| {
        const input: f32 = if (i < 100) 1.0 else 0.0;
        const o1 = flt1.apply4Pole(input, 2000.0);
        const o2 = flt2.apply4Pole(input, 2000.0);
        diff_sum += @abs(o1 - o2);
    }

    // Different multimode settings should produce measurably different outputs
    try std.testing.expect(diff_sum > 0.1);
}

test "filter xpander mode produces output" {
    var flt = Filter.init();
    flt.setSampleRate(44100.0);
    flt.setResonance(0.3);
    flt.par.xpander_4pole = true;
    flt.par.xpander_mode = 0; // LP4

    var out: f32 = 0.0;
    for (0..4410) |_| {
        out = flt.apply4Pole(1.0, 5000.0);
    }

    try std.testing.expect(out > 0.5);
}

test "filter resonance affects output" {
    var flt_low_res = Filter.init();
    flt_low_res.setSampleRate(44100.0);
    flt_low_res.setResonance(0.0);
    flt_low_res.setMultimode(0.0);

    var flt_high_res = Filter.init();
    flt_high_res.setSampleRate(44100.0);
    flt_high_res.setResonance(0.9);
    flt_high_res.setMultimode(0.0);

    // Feed a step and compare after a few samples
    for (0..100) |_| {
        _ = flt_low_res.apply4Pole(1.0, 2000.0);
        _ = flt_high_res.apply4Pole(1.0, 2000.0);
    }

    // The high-res filter should ring more, producing different output
    const out_lo = flt_low_res.apply4Pole(0.0, 2000.0);
    const out_hi = flt_high_res.apply4Pole(0.0, 2000.0);
    try std.testing.expect(@abs(out_lo - out_hi) > 0.001);
}

test "diode pair resistance approx near zero is near 1" {
    const val = Filter.diodePairResistanceApprox(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), val, 1e-6);
}

test "pole mix factors table dimensions" {
    try std.testing.expectEqual(@as(usize, num_xpander_modes), pole_mix_factors.len);
    for (pole_mix_factors) |row| {
        try std.testing.expectEqual(@as(usize, 5), row.len);
    }
}
