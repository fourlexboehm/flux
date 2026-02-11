// Multi-waveform LFO with tempo sync
// Ported from OB-Xf Lfo.h
//
// Original OB-Xd was written by Vadim Filatov, released under GPL3.
// OB-Xf is released under the GNU General Public Licence v3 or later.
//
// Features:
//   - Block-based processing (blockFactor = 8) for efficiency
//   - Waveforms: sine, square, saw, triangle, sample-hold, sample-glide
//   - Three wave blend parameters with positive = first, negative = second
//   - Tempo sync with host BPM
//   - Output smoothing via TPT lowpass

const std = @import("std");
const audio_utils = @import("audio_utils.zig");

const pi: f32 = std.math.pi;
const two_pi: f32 = 2.0 * pi;
const inv_pi: f32 = 1.0 / pi;
const inv_two_pi: f32 = 1.0 / two_pi;
const half_pi: f32 = pi / 2.0;
const two_by_pi: f32 = 2.0 / pi;

/// Tempo-synced rate table. Index with a normalised parameter (0..1) mapped to
/// 0..syncedRates.len-1.
pub const synced_rates = [_]f32{
    1.0 / 12.0, // 4/1
    1.0 / 8.0, //  3/1
    1.0 / 6.0, //  2/1
    3.0 / 16.0, // 1/1 D
    1.0 / 4.0, //  1/1
    1.0 / 3.0, //  1/2 D
    3.0 / 8.0, //  1/1 T
    1.0 / 2.0, //  1/2
    2.0 / 3.0, //  1/4 D
    3.0 / 4.0, //  1/2 T
    1.0, //        1/4
    3.0 / 2.0, //  1/4 T
    4.0 / 3.0, //  1/8 D
    2.0, //        1/8
    8.0 / 3.0, //  1/16 D
    3.0, //        1/8 T
    4.0, //        1/16
    6.0, //        1/32 D
    8.0, //        1/16 T
    12.0, //       1/32
    16.0, //       1/32 T
};

pub const synced_rates_count: usize = synced_rates.len;

/// Simple LCG pseudo-random number generator.
/// Produces float values in the range [-1, 1] or [0, 1].
const Lcg = struct {
    state: u32 = 0x12345678,

    const Self = @This();

    fn initWithSeed(seed: u32) Self {
        return .{ .state = seed };
    }

    /// Return the next u32 from the LCG.
    inline fn next(self: *Self) u32 {
        self.state = self.state *% 1103515245 +% 12345;
        return self.state;
    }

    /// Return a float in [0, 1).
    inline fn nextFloat(self: *Self) f32 {
        return @as(f32, @floatFromInt(self.next() >> 1)) / @as(f32, @floatFromInt(@as(u32, 1) << 31));
    }
};

pub const Lfo = struct {
    const block_factor: i32 = 8;

    sample_rate: f32 = 1.0,
    sample_rate_inv: f32 = 1.0,

    // --- State ---------------------------------------------------------
    phase: f32 = 0.0,
    phase_inc: f32 = 0.0,

    tempo_synced: bool = false,
    synced_rate: f32 = 1.0,
    unsynced_rate: f32 = 0.0,
    raw_synced_rate: f32 = 0.0,

    smoothed_output: f32 = 0.0,

    rng: Lcg = Lcg.initWithSeed(0x12345678),

    wave: Waves = .{},

    block_target: f32 = 0.0,
    block_pos: i32 = block_factor - 1,

    // --- Parameters (public) -------------------------------------------
    par: Parameters = .{},

    const Waves = struct {
        sine: f32 = 0.0,
        square: f32 = 0.0,
        saw: f32 = 0.0,
        tri: f32 = 0.0,
        samplehold: f32 = 0.0,
        sampleglide: f32 = 0.0,
        history: f32 = 0.0,
    };

    pub const Parameters = struct {
        unipolar_pulse: f32 = 0.0,
        pw: f32 = 0.0,
        wave1blend: f32 = 0.0,
        wave2blend: f32 = 0.0,
        wave3blend: f32 = 0.0,
    };

    const Self = @This();

    pub fn init() Self {
        var self = Self{};
        // Initialize sample-hold with a random value
        self.wave.samplehold = self.rng.nextFloat() * 2.0 - 1.0;
        self.wave.history = self.wave.samplehold;
        return self;
    }

    pub fn setSampleRate(self: *Self, sr: f32) void {
        self.sample_rate = sr;
        self.sample_rate_inv = 1.0 / sr;
    }

    pub fn setTempoSync(self: *Self, ts: bool) void {
        if (ts) {
            self.tempo_synced = true;
            self.recalcRate(self.raw_synced_rate);
        } else {
            self.tempo_synced = false;
            self.phase_inc = self.unsynced_rate;
        }
    }

    /// Sync LFO phase and rate to the host transport.
    pub fn hostSyncRetrigger(self: *Self, bpm: f32, quarters: f32, reset_position: bool) void {
        if (self.tempo_synced) {
            self.phase_inc = (bpm / 60.0) * self.synced_rate;

            if (reset_position) {
                self.phase = self.phase_inc * quarters;
                self.phase -= @mod(self.phase, 1.0) * two_pi - pi;
            }
        }
    }

    /// Set the free-running (unsynced) LFO rate in Hz.
    pub fn setRate(self: *Self, val: f32) void {
        self.unsynced_rate = val;

        if (!self.tempo_synced) {
            self.phase_inc = val;
        }
    }

    /// Set the tempo-synced rate from a normalised parameter (0..1).
    pub fn setRateNormalized(self: *Self, param: f32) void {
        self.raw_synced_rate = param;

        if (self.tempo_synced) {
            self.recalcRate(param);
        }
    }

    /// Set LFO phase directly from a normalised value (0..1).
    pub fn setPhaseDirectly(self: *Self, val: f32) void {
        if (val >= 0.0 and val <= 1.0) {
            self.phase = (val * two_pi) - pi;
        }
    }

    /// Advance the LFO by one sample. If `phase_only` is true, the smoother
    /// is bypassed and the output jumps directly to the block target.
    pub inline fn update(self: *Self, phase_only: bool) void {
        if (self.block_pos >= block_factor - 1) {
            self.block_pos = 0;
            self.phase += @as(f32, @floatFromInt(block_factor)) * (self.phase_inc * two_pi * self.sample_rate_inv);

            while (self.phase > pi) {
                self.phase -= two_pi;
                self.wave.history = self.wave.samplehold;
                self.wave.samplehold = self.rng.nextFloat() * 2.0 - 1.0;
            }

            // Compute all waveforms from the current phase
            self.wave.sine = @sin(self.phase);

            // Triangle: uses the identity |phase + pi/2| mapped to [-1, 1]
            const tri_phase = self.phase + half_pi -
                @as(f32, if (self.phase > half_pi) two_pi else 0.0);
            self.wave.tri = (two_by_pi * @abs(tri_phase)) - 1.0;

            // Square wave with pulse width and optional unipolar offset
            self.wave.square = if (self.phase > (pi * self.par.pw * 0.9))
                -1.0 + self.par.unipolar_pulse
            else
                1.0;

            // Saw with bend-based pulse width modulation
            self.wave.saw = bend(-self.phase * inv_pi, -self.par.pw);

            // Sample-glide: linear interpolation between held random values
            self.wave.sampleglide = self.wave.history +
                (self.wave.samplehold - self.wave.history) * (pi + self.phase) * inv_two_pi;

            self.recalculateBlockTarget();

            if (phase_only) {
                self.smoothed_output = self.block_target;
            }
        } else {
            self.block_pos += 1;
        }
    }

    /// Get the smoothed LFO output value.
    pub inline fn getVal(self: *Self) f32 {
        return audio_utils.tptLpUnwarped(&self.smoothed_output, self.block_target, 250.0, self.sample_rate_inv);
    }

    // ====================================================================
    // Private helpers
    // ====================================================================

    fn recalculateBlockTarget(self: *Self) void {
        var result: f32 = 0.0;

        if (self.par.wave1blend >= 0.0) {
            result += self.wave.tri * self.par.wave1blend;
        } else {
            result += self.wave.sine * -self.par.wave1blend;
        }

        if (self.par.wave2blend >= 0.0) {
            result += self.wave.saw * self.par.wave2blend;
        } else {
            result += self.wave.square * -self.par.wave2blend;
        }

        if (self.par.wave3blend >= 0.0) {
            result += self.wave.sampleglide * self.par.wave3blend;
        } else {
            result += self.wave.samplehold * -self.par.wave3blend;
        }

        self.block_target = result;
    }

    fn recalcRate(self: *Self, param: f32) void {
        const clamped = @max(0.0, @min(1.0, param));
        const parval: usize = @intFromFloat(clamped * @as(f32, @floatFromInt(synced_rates_count - 1)));
        self.synced_rate = synced_rates[parval];
    }
};

/// Apply a gentle nonlinear curve to `x` using pulse-width parameter `d`.
/// Three iterations of the quadratic bend formula: x = x - a*x*x + a.
fn bend(x: f32, d: f32) f32 {
    if (d == 0.0) {
        return x;
    }

    const a: f64 = 0.5 * @as(f64, d);
    var xv: f64 = @as(f64, x);

    xv = xv - a * xv * xv + a;
    xv = xv - a * xv * xv + a;
    xv = xv - a * xv * xv + a;

    return @floatCast(xv);
}

// ============================================================================
// Tests
// ============================================================================

test "lfo init produces zero output" {
    var lfo = Lfo.init();
    lfo.setSampleRate(44100.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lfo.getVal(), 0.01);
}

test "lfo update advances phase" {
    var lfo = Lfo.init();
    lfo.setSampleRate(44100.0);
    lfo.setRate(1.0); // 1 Hz

    const initial_phase = lfo.phase;
    lfo.update(false);

    // After one update the phase should have advanced
    try std.testing.expect(lfo.phase != initial_phase);
}

test "lfo sine wave produces bounded output" {
    var lfo = Lfo.init();
    lfo.setSampleRate(44100.0);
    lfo.setRate(10.0);
    lfo.par.wave1blend = -1.0; // pure sine

    for (0..44100) |_| {
        lfo.update(false);
        const val = lfo.getVal();
        try std.testing.expect(val >= -1.5);
        try std.testing.expect(val <= 1.5);
    }
}

test "lfo square wave produces bounded output" {
    var lfo = Lfo.init();
    lfo.setSampleRate(44100.0);
    lfo.setRate(5.0);
    lfo.par.wave2blend = -1.0; // pure square

    for (0..44100) |_| {
        lfo.update(false);
        const val = lfo.getVal();
        try std.testing.expect(val >= -1.5);
        try std.testing.expect(val <= 1.5);
    }
}

test "lfo saw wave produces bounded output" {
    var lfo = Lfo.init();
    lfo.setSampleRate(44100.0);
    lfo.setRate(5.0);
    lfo.par.wave2blend = 1.0; // pure saw

    for (0..44100) |_| {
        lfo.update(false);
        const val = lfo.getVal();
        try std.testing.expect(val >= -1.5);
        try std.testing.expect(val <= 1.5);
    }
}

test "lfo triangle wave produces bounded output" {
    var lfo = Lfo.init();
    lfo.setSampleRate(44100.0);
    lfo.setRate(5.0);
    lfo.par.wave1blend = 1.0; // pure triangle

    for (0..44100) |_| {
        lfo.update(false);
        const val = lfo.getVal();
        try std.testing.expect(val >= -1.5);
        try std.testing.expect(val <= 1.5);
    }
}

test "lfo sample hold produces bounded output" {
    var lfo = Lfo.init();
    lfo.setSampleRate(44100.0);
    lfo.setRate(5.0);
    lfo.par.wave3blend = -1.0; // pure sample-hold

    for (0..44100) |_| {
        lfo.update(false);
        const val = lfo.getVal();
        try std.testing.expect(val >= -1.5);
        try std.testing.expect(val <= 1.5);
    }
}

test "lfo tempo sync sets rate from table" {
    var lfo = Lfo.init();
    lfo.setSampleRate(44100.0);

    lfo.setRateNormalized(0.5); // middle of table
    lfo.setTempoSync(true);

    try std.testing.expect(lfo.tempo_synced);
    try std.testing.expect(lfo.synced_rate > 0.0);
}

test "lfo phase_only mode skips smoothing" {
    var lfo = Lfo.init();
    lfo.setSampleRate(44100.0);
    lfo.setRate(10.0);
    lfo.par.wave1blend = -1.0; // sine

    lfo.update(true);

    // smoothedOutput should equal blockTarget exactly
    try std.testing.expectApproxEqAbs(lfo.block_target, lfo.smoothed_output, 1e-10);
}

test "bend with zero d is identity" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), bend(0.5, 0.0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f32, -0.3), bend(-0.3, 0.0), 1e-10);
}

test "bend produces bounded output" {
    // Test a range of inputs and d values
    var d: f32 = -1.0;
    while (d <= 1.0) : (d += 0.2) {
        var x: f32 = -1.0;
        while (x <= 1.0) : (x += 0.1) {
            const result = bend(x, d);
            try std.testing.expect(result >= -3.0);
            try std.testing.expect(result <= 3.0);
        }
    }
}

test "synced rates table has correct count" {
    try std.testing.expectEqual(@as(usize, 21), synced_rates_count);
}

test "lcg produces varying values" {
    var rng = Lcg.initWithSeed(42);
    const a = rng.nextFloat();
    const b = rng.nextFloat();
    const c = rng.nextFloat();

    // All three should be different
    try std.testing.expect(a != b);
    try std.testing.expect(b != c);

    // All should be in [0, 1)
    try std.testing.expect(a >= 0.0 and a < 1.0);
    try std.testing.expect(b >= 0.0 and b < 1.0);
    try std.testing.expect(c >= 0.0 and c < 1.0);
}
