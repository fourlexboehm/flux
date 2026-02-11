// Delay Line for BLEP processing
// Ported from OB-Xf DelayLine.h
//
// A simple fixed-size circular delay line. Always feed first then get
// the delayed sample. The buffer size must be a power of 2 so we can
// wrap the index with a bitmask instead of a modulo.

const std = @import("std");

pub const delay_buffer_size: usize = 64;

// Compile-time check: delay_buffer_size must be a power of 2.
comptime {
    if ((delay_buffer_size & (delay_buffer_size - 1)) != 0) {
        @compileError("delay_buffer_size must be a power of 2");
    }
}

/// Fixed-size circular delay line.
///
/// `S` is the delay length in samples (must be < delay_buffer_size - 1).
/// `T` is the sample type (e.g. f32 or f64).
pub fn DelayLine(comptime S: comptime_int, comptime T: type) type {
    comptime {
        if (S >= delay_buffer_size - 1) {
            @compileError("delay length S must be < delay_buffer_size - 1");
        }
    }

    const mask: usize = delay_buffer_size - 1;

    return struct {
        dl: [delay_buffer_size]T = [_]T{0} ** delay_buffer_size,
        iidx: usize = 0,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        /// Feed a sample into the delay line and return the sample that is
        /// `S` steps behind the current write position.
        pub inline fn feedReturn(self: *Self, sample: T) T {
            self.dl[self.iidx] = sample;
            self.iidx = (self.iidx -% 1) & mask;
            return self.dl[(self.iidx + S) & mask];
        }

        /// Reset all delay line contents to zero.
        pub fn fillZeroes(self: *Self) void {
            self.dl = [_]T{0} ** delay_buffer_size;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "delay line S=1 returns same sample immediately" {
    // S=1 means the read position is the same as the write position,
    // so feedReturn returns the sample just written (zero effective delay).
    var dl = DelayLine(1, f32).init();

    const out0 = dl.feedReturn(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out0, 1e-10);

    const out1 = dl.feedReturn(2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), out1, 1e-10);
}

test "delay line S=4 gives S-1 samples of latency" {
    // With S=4, feedReturn should produce S-1 = 3 zero samples before
    // returning the first value we wrote.
    var dl = DelayLine(4, f32).init();

    const out0 = dl.feedReturn(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out0, 1e-10);

    const out1 = dl.feedReturn(2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out1, 1e-10);

    const out2 = dl.feedReturn(3.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out2, 1e-10);

    // Fourth call should return the first value (1.0)
    const out3 = dl.feedReturn(4.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out3, 1e-10);

    // Fifth call should return the second value (2.0)
    const out4 = dl.feedReturn(5.0);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), out4, 1e-10);
}

test "delay line fill zeroes resets state" {
    var dl = DelayLine(4, f32).init();

    _ = dl.feedReturn(5.0);
    _ = dl.feedReturn(10.0);
    _ = dl.feedReturn(15.0);
    _ = dl.feedReturn(20.0);

    dl.fillZeroes();

    // After reset, all reads should return zero again
    const out = dl.feedReturn(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out, 1e-10);
}

test "delay line with longer delay" {
    const delay = 8;
    var dl = DelayLine(delay, f32).init();

    // Feed values 1..delay-1, all should return 0 (S-1 = 7 samples of latency)
    for (0..delay - 1) |i| {
        const val: f32 = @floatFromInt(i + 1);
        const out = dl.feedReturn(val);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), out, 1e-10);
    }

    // The (delay)th feed should return the first value we fed (1.0)
    const out = dl.feedReturn(100.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out, 1e-10);
}
