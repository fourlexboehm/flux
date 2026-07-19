//! Dynamics processors for DAWproject stock devices.
//! Compressor/limiter use sndfilter's 0BSD WebAudio/Chromium-derived core.

const std = @import("std");
const native = @import("native.zig");

fn dbToLin(db: f64) f64 {
    return std.math.pow(f64, 10.0, db / 20.0);
}

fn linToDb(lin: f64) f64 {
    return 20.0 * std.math.log10(@max(lin, 1e-12));
}

fn coeff(seconds: f64, sample_rate: f64) f64 {
    return std.math.exp(-2.1972245773362196 / (@max(seconds, 1e-6) * @max(sample_rate, 1.0)));
}

fn rate(sample_rate: f64) u32 {
    return @intFromFloat(std.math.clamp(sample_rate, 1.0, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
}

pub const Compressor = struct {
    native_state: native.CompState align(16) = @splat(0),
    configured: bool = false,
    sample_rate: f64 = 44100,
    threshold_db: f64 = -18,
    ratio: f64 = 4,
    attack_s: f64 = 0.01,
    release_s: f64 = 0.1,
    input_gain_db: f64 = 0,
    output_gain_db: f64 = 0,
    auto_makeup: bool = true,

    pub fn configure(self: *Compressor) void {
        native.flux_compressor_configure(
            &self.native_state,
            rate(self.sample_rate),
            @floatCast(self.input_gain_db),
            @floatCast(self.threshold_db),
            @floatCast(@max(self.ratio, 1)),
            @floatCast(@max(self.attack_s, 1e-6)),
            @floatCast(@max(self.release_s, 1e-6)),
            @floatCast(self.output_gain_db),
            @intFromBool(self.auto_makeup),
        );
        self.configured = true;
    }

    pub fn reset(self: *Compressor) void {
        native.flux_dynamics_reset(&self.native_state);
        self.configure();
    }

    pub fn setSampleRate(self: *Compressor, sample_rate: f64) void {
        self.sample_rate = sample_rate;
        self.configured = false;
    }

    pub fn process(self: *Compressor, left: []f32, right: []f32) void {
        const n = @min(left.len, right.len);
        if (n == 0) return;
        if (!self.configured) self.configure();
        native.flux_compressor_process(&self.native_state, left.ptr, right.ptr, @intCast(n));
    }
};

/// Stereo-linked downward expander with attack/release-smoothed gain.
/// The gain computer follows the standard DRC equations from Giannoulis,
/// Massberg and Reiss, "Digital Dynamic Range Compressor Design" (JAES 2012).
pub const NoiseGate = struct {
    gain_db: f64 = -60,
    sample_rate: f64 = 44100,
    threshold_db: f64 = -40,
    ratio: f64 = 10,
    attack_s: f64 = 0.001,
    release_s: f64 = 0.1,
    range_db: f64 = -60,

    pub fn reset(self: *NoiseGate) void {
        self.gain_db = @min(self.range_db, 0);
    }

    pub fn setSampleRate(self: *NoiseGate, sample_rate: f64) void {
        self.sample_rate = sample_rate;
    }

    pub fn process(self: *NoiseGate, left: []f32, right: []f32) void {
        const n = @min(left.len, right.len);
        const open_coeff = coeff(self.attack_s, self.sample_rate);
        const close_coeff = coeff(self.release_s, self.sample_rate);
        const ratio = @max(self.ratio, 1);
        const floor = @min(self.range_db, 0);

        for (left[0..n], right[0..n]) |*l, *r| {
            const level_db = linToDb(@max(@abs(@as(f64, l.*)), @abs(@as(f64, r.*))));
            const target_db = if (level_db < self.threshold_db)
                @max((level_db - self.threshold_db) * (ratio - 1), floor)
            else
                0;
            const c = if (target_db > self.gain_db) open_coeff else close_coeff;
            self.gain_db = c * self.gain_db + (1 - c) * target_db;
            const gain: f32 = @floatCast(dbToLin(self.gain_db));
            l.* *= gain;
            r.* *= gain;
        }
    }
};

pub const Limiter = struct {
    native_state: native.CompState align(16) = @splat(0),
    configured: bool = false,
    sample_rate: f64 = 44100,
    threshold_db: f64 = 0,
    attack_s: f64 = 0.001,
    release_s: f64 = 0.05,
    input_gain_db: f64 = 0,
    output_gain_db: f64 = 0,

    pub fn configure(self: *Limiter) void {
        native.flux_limiter_configure(
            &self.native_state,
            rate(self.sample_rate),
            @floatCast(self.input_gain_db),
            @floatCast(self.threshold_db),
            @floatCast(@max(self.attack_s, 1e-6)),
            @floatCast(@max(self.release_s, 1e-6)),
            @floatCast(self.output_gain_db),
        );
        self.configured = true;
    }

    pub fn reset(self: *Limiter) void {
        native.flux_dynamics_reset(&self.native_state);
        self.configure();
    }

    pub fn setSampleRate(self: *Limiter, sample_rate: f64) void {
        self.sample_rate = sample_rate;
        self.configured = false;
    }

    pub fn process(self: *Limiter, left: []f32, right: []f32) void {
        const n = @min(left.len, right.len);
        if (n == 0) return;
        if (!self.configured) self.configure();
        native.flux_limiter_process(
            &self.native_state,
            left.ptr,
            right.ptr,
            @intCast(n),
            @floatCast(self.threshold_db + self.output_gain_db),
        );
    }
};

test "gate reaches its configured floor" {
    var gate: NoiseGate = .{ .attack_s = 0.0001, .release_s = 0.001, .range_db = -40 };
    gate.reset();
    var left: [2048]f32 = @splat(0.001);
    var right = left;
    gate.process(&left, &right);
    try std.testing.expectApproxEqRel(@as(f32, 0.00001), left[left.len - 1], 0.03);
}

test "gate opens for signal above threshold" {
    var gate: NoiseGate = .{ .attack_s = 0.0001, .range_db = -60 };
    gate.reset();
    var left: [1024]f32 = @splat(1);
    var right = left;
    gate.process(&left, &right);
    try std.testing.expect(left[left.len - 1] > 0.99);
}

test "compressor handles arbitrary frame counts and links stereo" {
    var compressor: Compressor = .{ .threshold_db = -24, .ratio = 8, .auto_makeup = false };
    compressor.configure();
    var left: [1009]f32 = @splat(1);
    var right: [1009]f32 = @splat(0.25);
    compressor.process(&left, &right);
    try std.testing.expect(std.math.isFinite(left[left.len - 1]));
    try std.testing.expect(left[left.len - 1] < 0.5);
    try std.testing.expectApproxEqRel(@as(f32, 4), left[left.len - 1] / right[right.len - 1], 0.001);
}

test "limiter enforces ceiling" {
    var limiter: Limiter = .{ .threshold_db = -6 };
    limiter.configure();
    var left: [257]f32 = @splat(4);
    var right: [257]f32 = @splat(-3);
    limiter.process(&left, &right);
    const ceiling: f32 = @floatCast(dbToLin(-6));
    for (left, right) |l, r| {
        try std.testing.expect(@abs(l) <= ceiling);
        try std.testing.expect(@abs(r) <= ceiling);
    }
}
