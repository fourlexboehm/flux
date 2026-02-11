// ADSR Envelope Generator with exponential attack curve
// Ported from OB-Xf AdsrEnvelope.h
//
// Original OB-Xd was written by Vadim Filatov, released under GPL3.
// OB-Xf is released under the GNU General Public Licence v3 or later.
//
// This envelope uses an exponential attack curve with a configurable blend
// between exponential and linear attack shapes. The decay and release phases
// use exponential curves. A small DC offset is added during release to prevent
// denormals.

const std = @import("std");
const audio_utils = @import("audio_utils.zig");

const dc = audio_utils.dc;

pub const AdsrEnvelope = struct {
    // Attack curve constants.
    // See https://github.com/surge-synthesizer/OB-Xf/issues/116#issuecomment-2981640815
    // atkCoefStart is fixed, atkCoefEnd is an overshoot speed factor (1 = no overshoot),
    // atkValueEnd is the distance from 1.0 before an attack ends.
    const atk_coef_start: f32 = 0.001;
    const atk_coef_end: f32 = 1.3;
    const atk_value_end: f32 = 0.1;
    const atk_time_adjustment: f32 = 1.0 / 3.0;
    const ms_to_sec: f32 = 0.001;
    const default_time: f32 = 0.0001;
    const default_level: f32 = 1.0;

    const State = enum(u8) {
        attack = 1,
        decay = 2,
        sustain = 3,
        release = 4,
        silent = 5,
    };

    const Parameters = struct {
        a: f32 = default_time,
        d: f32 = default_time,
        s: f32 = default_level,
        r: f32 = default_time,
    };

    state: State = .silent,

    // Parameter sets: original values, offset intermediates, final values
    orig: Parameters = .{},
    offset: Parameters = .{},
    par: Parameters = .{},

    coef: f32 = 0.0,
    coef_lin: f32 = 0.0,
    output: f32 = 0.0,
    output_lin: f32 = 0.0,
    sample_rate: f32 = 1.0,
    offset_factor: f32 = 1.0,

    attack_curve: f32 = 0.0, // 0 == exp, 1 == lin

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Reset the envelope to its initial silent state.
    pub fn resetEnvelopeState(self: *Self) void {
        self.output = 0.0;
        self.output_lin = 0.0;
        self.state = .silent;
    }

    pub fn setSampleRate(self: *Self, sr: f32) void {
        self.sample_rate = sr;
    }

    /// Apply slop offsets to all envelope parameters.
    pub fn setEnvOffsets(self: *Self, v: f32) void {
        self.offset_factor = v;

        self.setAttack(self.orig.a);
        self.setDecay(self.orig.d);
        self.setSustain(self.orig.s);
        self.setRelease(self.orig.r);
    }

    pub fn setAttackCurve(self: *Self, c: f32) void {
        self.attack_curve = c;
    }

    pub fn setAttack(self: *Self, a: f32) void {
        self.orig.a = a;
        self.offset.a = a / atk_time_adjustment;
        self.par.a = a * self.offset_factor / atk_time_adjustment;

        if (self.state == .attack) {
            self.updateAttackCoeff();
        }
    }

    pub fn setDecay(self: *Self, d: f32) void {
        self.orig.d = d;
        self.offset.d = d;
        self.par.d = d * self.offset_factor;

        if (self.state == .decay) {
            self.coef = @floatCast((@log(@as(f64, @min(self.par.s + 0.0001, 0.99))) - @log(1.0)) /
                (@as(f64, self.sample_rate) * @as(f64, self.par.d) * @as(f64, ms_to_sec)));
        }
    }

    pub fn setSustain(self: *Self, s: f32) void {
        self.orig.s = s;
        self.offset.s = s;
        self.par.s = s;

        if (self.state == .decay) {
            self.coef = @floatCast((@log(@as(f64, @min(self.par.s + 0.0001, 0.99))) - @log(1.0)) /
                (@as(f64, self.sample_rate) * @as(f64, self.par.d) * @as(f64, ms_to_sec)));
        }
    }

    pub fn setRelease(self: *Self, r: f32) void {
        self.orig.r = r;
        self.offset.r = r;
        self.par.r = r * self.offset_factor;

        if (self.state == .release) {
            self.coef = @floatCast((@log(0.00001) - @log(@as(f64, self.output) + 0.0001)) /
                (@as(f64, self.sample_rate) * @as(f64, self.par.r) * @as(f64, ms_to_sec)));
        }
    }

    /// Trigger the attack phase. Recalculates attack coefficients and
    /// distributes the current output level between the exponential and
    /// linear attack paths.
    pub fn triggerAttack(self: *Self) void {
        self.state = .attack;

        self.updateAttackCoeff();

        // Calculate initial output/outputLin from the current level.
        // From the atksim python script the exp value is on average 1.6x
        // the linear value. So give 1.6/2.6 of the value to exp and 1/2.6 to lin.
        if (self.output != 0) {
            const co: f64 = @as(f64, self.output);
            const fudge_e: f64 = 1.6 / 2.6;
            const fudge_l: f64 = 1.0 / 2.6;

            const a: f64 = @as(f64, self.attack_curve);
            const x = co / ((1.0 - a) * fudge_e + a * fudge_l);
            self.output = @floatCast(fudge_e * x);
            self.output_lin = @floatCast(fudge_l * x);
        } else {
            self.output_lin = 0.0;
        }
    }

    fn updateAttackCoeff(self: *Self) void {
        self.coef = @floatCast((@log(@as(f64, atk_coef_start)) - @log(@as(f64, atk_coef_end))) /
            (@as(f64, self.sample_rate) * @as(f64, self.par.a) * @as(f64, ms_to_sec)));

        const exp_rate: f64 = @log(@as(f64, atk_value_end)) / @log(@as(f64, atk_coef_start));
        const exp_time: f64 = @as(f64, self.par.a) * exp_rate;
        const lin_samp: f64 = (1.0 - exp_rate * @as(f64, atk_value_end)) * exp_time *
            @as(f64, self.sample_rate) * @as(f64, ms_to_sec);

        self.coef_lin = @floatCast((1.0 - @as(f64, atk_value_end)) / lin_samp);
    }

    /// Trigger the release phase. If currently in attack, blends the
    /// exponential and linear outputs before transitioning.
    pub fn triggerRelease(self: *Self) void {
        if (self.state == .attack) {
            const to = (1.0 - self.attack_curve) * self.output + self.attack_curve * self.output_lin;
            self.output = @min(to, 0.99);
        }

        if (self.state != .release) {
            self.coef = @floatCast((@log(0.00001) - @log(@as(f64, self.output) + 0.0001)) /
                (@as(f64, self.sample_rate) * @as(f64, self.par.r) * @as(f64, ms_to_sec)));
        }

        self.state = .release;
    }

    /// Returns true if the envelope is producing output (not silent).
    pub inline fn isActive(self: *const Self) bool {
        return self.state != .silent;
    }

    /// Returns true if the envelope is in a gated state (attack, decay, or sustain).
    pub inline fn isGated(self: *const Self) bool {
        return self.state != .silent and self.state != .release;
    }

    /// Process one sample of the envelope and return the output level.
    pub inline fn processSample(self: *Self) f32 {
        var result: f32 = self.output;

        switch (self.state) {
            .attack => {
                if (self.output - 1.0 > -atk_value_end) {
                    // Attack phase complete -- transition to decay
                    const to = (1.0 - self.attack_curve) * self.output + self.attack_curve * self.output_lin;
                    self.output = @min(to, 0.99);
                    self.state = .decay;
                    self.coef = @floatCast((@log(@as(f64, @min(self.par.s + 0.0001, 0.99))) - @log(1.0)) /
                        (@as(f64, self.sample_rate) * @as(f64, self.par.d) * @as(f64, ms_to_sec)));
                    // Fall through to decay processing (mirrors the C++ goto dec)
                    result = self.processDecay();
                } else {
                    self.output = self.output - (1.0 - self.output) * self.coef;
                    self.output_lin += self.coef_lin;
                    result = (1.0 - self.attack_curve) * self.output + self.attack_curve * self.output_lin;
                }
            },
            .decay => {
                result = self.processDecay();
            },
            .sustain => {
                self.output = @min(self.par.s, 0.9);
                result = self.output;
            },
            .release => {
                if (self.output > 20e-6) {
                    self.output = self.output + (self.output * self.coef) + dc;
                    result = self.output;
                } else {
                    self.state = .silent;
                }
            },
            .silent => {
                self.output = 0.0;
                result = self.output;
            },
        }

        return result;
    }

    /// Process the decay stage. Extracted to allow the attack-to-decay
    /// fallthrough without using goto.
    inline fn processDecay(self: *Self) f32 {
        if (self.output - self.par.s < 10e-6) {
            self.state = .sustain;
            return self.output;
        } else {
            self.output = self.output + self.output * self.coef;
            return self.output;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "adsr envelope starts silent" {
    const env = AdsrEnvelope.init();
    try std.testing.expect(!env.isActive());
    try std.testing.expect(!env.isGated());
}

test "adsr envelope produces output after attack trigger" {
    var env = AdsrEnvelope.init();
    env.setSampleRate(44100.0);
    env.setAttack(10.0);
    env.setDecay(100.0);
    env.setSustain(0.5);
    env.setRelease(200.0);

    env.triggerAttack();
    try std.testing.expect(env.isActive());
    try std.testing.expect(env.isGated());

    // Run a few samples and verify output rises
    var prev: f32 = 0.0;
    var rising = false;
    for (0..1000) |_| {
        const val = env.processSample();
        if (val > prev + 1e-8) {
            rising = true;
        }
        prev = val;
    }
    try std.testing.expect(rising);
}

test "adsr envelope reaches sustain level" {
    var env = AdsrEnvelope.init();
    env.setSampleRate(44100.0);
    env.setAttack(1.0);
    env.setDecay(10.0);
    env.setSustain(0.5);
    env.setRelease(100.0);

    env.triggerAttack();

    // Run enough samples to pass through attack and decay
    var val: f32 = 0.0;
    for (0..44100) |_| {
        val = env.processSample();
    }

    // Should be near the sustain level
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), val, 0.05);
    try std.testing.expect(env.state == .sustain);
}

test "adsr envelope goes silent after release" {
    var env = AdsrEnvelope.init();
    env.setSampleRate(44100.0);
    env.setAttack(1.0);
    env.setDecay(10.0);
    env.setSustain(0.5);
    env.setRelease(10.0);

    env.triggerAttack();

    // Run through attack/decay to sustain
    for (0..22050) |_| {
        _ = env.processSample();
    }

    env.triggerRelease();
    try std.testing.expect(env.state == .release);

    // Run through release
    for (0..44100) |_| {
        _ = env.processSample();
    }

    try std.testing.expect(!env.isActive());
}

test "adsr reset clears state" {
    var env = AdsrEnvelope.init();
    env.setSampleRate(44100.0);
    env.setAttack(10.0);
    env.setDecay(100.0);
    env.setSustain(0.5);
    env.setRelease(200.0);

    env.triggerAttack();
    for (0..1000) |_| {
        _ = env.processSample();
    }

    env.resetEnvelopeState();
    try std.testing.expect(!env.isActive());
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), env.output, 1e-10);
}

test "adsr attack curve parameter affects output" {
    var env_exp = AdsrEnvelope.init();
    env_exp.setSampleRate(44100.0);
    env_exp.setAttack(20.0);
    env_exp.setDecay(100.0);
    env_exp.setSustain(0.5);
    env_exp.setRelease(200.0);
    env_exp.setAttackCurve(0.0); // pure exponential

    var env_lin = AdsrEnvelope.init();
    env_lin.setSampleRate(44100.0);
    env_lin.setAttack(20.0);
    env_lin.setDecay(100.0);
    env_lin.setSustain(0.5);
    env_lin.setRelease(200.0);
    env_lin.setAttackCurve(1.0); // pure linear

    env_exp.triggerAttack();
    env_lin.triggerAttack();

    // After a few samples the curves should differ
    var val_exp: f32 = 0.0;
    var val_lin: f32 = 0.0;
    for (0..200) |_| {
        val_exp = env_exp.processSample();
        val_lin = env_lin.processSample();
    }

    // The two curves should produce different outputs at the same point
    try std.testing.expect(@abs(val_exp - val_lin) > 0.001);
}
