// Polyphase halfband decimation filters for 2x oversampling
// Ported from OB-Xf Decimator.h
//
// MusicDsp / T. Rochebois
//
// Decimator17 - 17th order halfband filter (higher quality)
// Decimator9  - 9th order halfband filter (lower CPU)
//
// Both take two input samples (x0, x1) from the 2x oversampled stream
// and return one output sample at the base rate.

const std = @import("std");

/// 17th-order polyphase halfband decimation filter.
pub const Decimator17 = struct {
    // Filter coefficients
    const h0: f32 = 0.5;
    const h1: f32 = 0.314356238;
    const h3: f32 = -0.0947515890;
    const h5: f32 = 0.0463142134;
    const h7: f32 = -0.0240881704;
    const h9: f32 = 0.0120250406;
    const h11: f32 = -0.00543170841;
    const h13: f32 = 0.00207426259;
    const h15: f32 = -0.000572688237;
    const h17: f32 = 5.18944944e-5;

    // State registers
    r1: f32 = 0.0,
    r2: f32 = 0.0,
    r3: f32 = 0.0,
    r4: f32 = 0.0,
    r5: f32 = 0.0,
    r6: f32 = 0.0,
    r7: f32 = 0.0,
    r8: f32 = 0.0,
    r9: f32 = 0.0,
    r10: f32 = 0.0,
    r11: f32 = 0.0,
    r12: f32 = 0.0,
    r13: f32 = 0.0,
    r14: f32 = 0.0,
    r15: f32 = 0.0,
    r16: f32 = 0.0,
    r17: f32 = 0.0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Reset all state registers to zero.
    pub fn reset(self: *Self) void {
        self.r1 = 0.0;
        self.r2 = 0.0;
        self.r3 = 0.0;
        self.r4 = 0.0;
        self.r5 = 0.0;
        self.r6 = 0.0;
        self.r7 = 0.0;
        self.r8 = 0.0;
        self.r9 = 0.0;
        self.r10 = 0.0;
        self.r11 = 0.0;
        self.r12 = 0.0;
        self.r13 = 0.0;
        self.r14 = 0.0;
        self.r15 = 0.0;
        self.r16 = 0.0;
        self.r17 = 0.0;
    }

    /// Decimate two 2x-oversampled input samples down to one output sample.
    pub inline fn decimate(self: *Self, x0: f32, x1: f32) f32 {
        const h17x0 = h17 * x0;
        const h15x0 = h15 * x0;
        const h13x0 = h13 * x0;
        const h11x0 = h11 * x0;
        const h9x0 = h9 * x0;
        const h7x0 = h7 * x0;
        const h5x0 = h5 * x0;
        const h3x0 = h3 * x0;
        const h1x0 = h1 * x0;

        const r18 = self.r17 + h17x0;

        self.r17 = self.r16 + h15x0;
        self.r16 = self.r15 + h13x0;
        self.r15 = self.r14 + h11x0;
        self.r14 = self.r13 + h9x0;
        self.r13 = self.r12 + h7x0;
        self.r12 = self.r11 + h5x0;
        self.r11 = self.r10 + h3x0;
        self.r10 = self.r9 + h1x0;
        self.r9 = self.r8 + h1x0 + h0 * x1;
        self.r8 = self.r7 + h3x0;
        self.r7 = self.r6 + h5x0;
        self.r6 = self.r5 + h7x0;
        self.r5 = self.r4 + h9x0;
        self.r4 = self.r3 + h11x0;
        self.r3 = self.r2 + h13x0;
        self.r2 = self.r1 + h15x0;
        self.r1 = h17x0;

        return r18;
    }
};

/// 9th-order polyphase halfband decimation filter.
pub const Decimator9 = struct {
    // Filter coefficients
    const h0: f32 = 8192.0 / 16384.0;
    const h1: f32 = 5042.0 / 16384.0;
    const h3: f32 = -1277.0 / 16384.0;
    const h5: f32 = 429.0 / 16384.0;
    const h7: f32 = -116.0 / 16384.0;
    const h9: f32 = 18.0 / 16384.0;

    // State registers
    r1: f32 = 0.0,
    r2: f32 = 0.0,
    r3: f32 = 0.0,
    r4: f32 = 0.0,
    r5: f32 = 0.0,
    r6: f32 = 0.0,
    r7: f32 = 0.0,
    r8: f32 = 0.0,
    r9: f32 = 0.0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Reset all state registers to zero.
    pub fn reset(self: *Self) void {
        self.r1 = 0.0;
        self.r2 = 0.0;
        self.r3 = 0.0;
        self.r4 = 0.0;
        self.r5 = 0.0;
        self.r6 = 0.0;
        self.r7 = 0.0;
        self.r8 = 0.0;
        self.r9 = 0.0;
    }

    /// Decimate two 2x-oversampled input samples down to one output sample.
    pub inline fn decimate(self: *Self, x0: f32, x1: f32) f32 {
        const h9x0 = h9 * x0;
        const h7x0 = h7 * x0;
        const h5x0 = h5 * x0;
        const h3x0 = h3 * x0;
        const h1x0 = h1 * x0;

        const r10 = self.r9 + h9x0;

        self.r9 = self.r8 + h7x0;
        self.r8 = self.r7 + h5x0;
        self.r7 = self.r6 + h3x0;
        self.r6 = self.r5 + h1x0;
        self.r5 = self.r4 + h1x0 + h0 * x1;
        self.r4 = self.r3 + h3x0;
        self.r3 = self.r2 + h5x0;
        self.r2 = self.r1 + h7x0;
        self.r1 = h9x0;

        return r10;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "decimator17 passes DC unchanged" {
    var dec = Decimator17.init();

    // Feed constant DC signal through the decimator
    var out: f32 = 0.0;
    for (0..100) |_| {
        out = dec.decimate(1.0, 1.0);
    }

    // DC should pass through at unity (sum of all symmetric halfband coefficients = 1)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out, 0.01);
}

test "decimator9 passes DC unchanged" {
    var dec = Decimator9.init();

    var out: f32 = 0.0;
    for (0..100) |_| {
        out = dec.decimate(1.0, 1.0);
    }

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out, 0.01);
}

test "decimator17 reset clears state" {
    var dec = Decimator17.init();

    // Feed some signal
    for (0..50) |_| {
        _ = dec.decimate(1.0, 1.0);
    }

    dec.reset();

    // After reset, feeding zeros should produce zero
    const out = dec.decimate(0.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out, 1e-10);
}

test "decimator9 reset clears state" {
    var dec = Decimator9.init();

    for (0..50) |_| {
        _ = dec.decimate(1.0, 1.0);
    }

    dec.reset();

    const out = dec.decimate(0.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out, 1e-10);
}

test "decimator17 attenuates nyquist" {
    var dec = Decimator17.init();

    // Nyquist at 2x rate: alternating +1/-1
    var out: f32 = 0.0;
    for (0..200) |_| {
        out = dec.decimate(1.0, -1.0);
    }

    // Nyquist should be heavily attenuated
    try std.testing.expect(@abs(out) < 0.1);
}
