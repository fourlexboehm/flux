// One-pole parameter smoother
// Ported from OB-Xf Smoother.h
//
// Simple one-pole lowpass filter for smoothing parameter changes.
// The smoothing coefficient (PSSC) is scaled by the sample rate ratio
// relative to 44 kHz.

const std = @import("std");
const audio_utils = @import("audio_utils.zig");

pub const Smoother = struct {
    const pssc: f32 = 0.0030;

    step_value: f32 = 0.0,
    integral_value: f32 = 0.0,
    sr_cor: f32 = 1.0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Advance the smoother by one sample and return the current smoothed value.
    pub inline fn smoothStep(self: *Self) f32 {
        self.integral_value = self.integral_value +
            (self.step_value - self.integral_value) * pssc * self.sr_cor + audio_utils.dc;
        return self.integral_value;
    }

    /// Set the target value that the smoother converges toward.
    pub inline fn setStep(self: *Self, value: f32) void {
        self.step_value = value;
    }

    /// Update the sample rate correction factor.
    pub fn setSampleRate(self: *Self, sr: f32) void {
        self.sr_cor = sr / 44000.0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "smoother converges to step value" {
    var s = Smoother.init();
    s.setSampleRate(44100.0);
    s.setStep(1.0);

    var val: f32 = 0.0;
    // Run for many iterations to converge
    for (0..50000) |_| {
        val = s.smoothStep();
    }

    // Should be very close to the target of 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), val, 0.01);
}

test "smoother starts at zero" {
    var s = Smoother.init();
    s.setSampleRate(44100.0);
    s.setStep(0.0);

    const val = s.smoothStep();
    // Should be near zero (just the dc offset)
    try std.testing.expect(@abs(val) < 0.001);
}

test "smoother sr correction scales with sample rate" {
    var s1 = Smoother.init();
    s1.setSampleRate(44000.0);

    var s2 = Smoother.init();
    s2.setSampleRate(88000.0);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s1.sr_cor, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), s2.sr_cor, 1e-6);
}

test "smoother responds to step change" {
    var s = Smoother.init();
    s.setSampleRate(44100.0);

    // Start at 0, target 1
    s.setStep(1.0);
    var prev: f32 = 0.0;

    // Each step should move toward 1.0 (monotonically increasing)
    for (0..100) |_| {
        const val = s.smoothStep();
        try std.testing.expect(val >= prev);
        prev = val;
    }

    // Should be moving toward 1.0 but not there yet after only 100 steps
    try std.testing.expect(prev > 0.0);
    try std.testing.expect(prev < 1.0);
}
