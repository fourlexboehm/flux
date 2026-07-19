//! Multi-band parametric EQ processed by miniaudio biquads.
//! Covers DAWproject eqBandType: highPass, lowPass, bandPass, highShelf, lowShelf, bell, notch.

const std = @import("std");
const native = @import("native.zig");

pub const BandType = enum {
    high_pass,
    low_pass,
    band_pass,
    high_shelf,
    low_shelf,
    bell,
    notch,

    pub fn fromDawproject(s: []const u8) ?BandType {
        if (std.mem.eql(u8, s, "highPass")) return .high_pass;
        if (std.mem.eql(u8, s, "lowPass")) return .low_pass;
        if (std.mem.eql(u8, s, "bandPass")) return .band_pass;
        if (std.mem.eql(u8, s, "highShelf")) return .high_shelf;
        if (std.mem.eql(u8, s, "lowShelf")) return .low_shelf;
        if (std.mem.eql(u8, s, "bell")) return .bell;
        if (std.mem.eql(u8, s, "notch")) return .notch;
        return null;
    }

    pub fn toDawproject(self: BandType) []const u8 {
        return switch (self) {
            .high_pass => "highPass",
            .low_pass => "lowPass",
            .band_pass => "bandPass",
            .high_shelf => "highShelf",
            .low_shelf => "lowShelf",
            .bell => "bell",
            .notch => "notch",
        };
    }
};

pub const max_bands = 8;

pub const Band = struct {
    type: BandType = .bell,
    freq_hz: f64 = 1000,
    gain_db: f64 = 0,
    q: f64 = 0.707,
    enabled: bool = true,
};

const Biquad = struct {
    b0: f64 = 1,
    b1: f64 = 0,
    b2: f64 = 0,
    a1: f64 = 0,
    a2: f64 = 0,
    fn design(self: *Biquad, band: Band, sample_rate: f64) void {
        const sr = @max(sample_rate, 1.0);
        const f = std.math.clamp(band.freq_hz, 20.0, sr * 0.49);
        const q = @max(band.q, 0.05);
        const A = std.math.pow(f64, 10.0, band.gain_db / 40.0);
        const w0 = 2.0 * std.math.pi * f / sr;
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * q);

        var b0: f64 = 1;
        var b1: f64 = 0;
        var b2: f64 = 0;
        var a0: f64 = 1;
        var a1: f64 = 0;
        var a2: f64 = 0;

        switch (band.type) {
            .low_pass => {
                b0 = (1.0 - cos_w0) / 2.0;
                b1 = 1.0 - cos_w0;
                b2 = (1.0 - cos_w0) / 2.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_w0;
                a2 = 1.0 - alpha;
            },
            .high_pass => {
                b0 = (1.0 + cos_w0) / 2.0;
                b1 = -(1.0 + cos_w0);
                b2 = (1.0 + cos_w0) / 2.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_w0;
                a2 = 1.0 - alpha;
            },
            .band_pass => {
                b0 = alpha;
                b1 = 0;
                b2 = -alpha;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_w0;
                a2 = 1.0 - alpha;
            },
            .notch => {
                b0 = 1.0;
                b1 = -2.0 * cos_w0;
                b2 = 1.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_w0;
                a2 = 1.0 - alpha;
            },
            .bell => {
                b0 = 1.0 + alpha * A;
                b1 = -2.0 * cos_w0;
                b2 = 1.0 - alpha * A;
                a0 = 1.0 + alpha / A;
                a1 = -2.0 * cos_w0;
                a2 = 1.0 - alpha / A;
            },
            .low_shelf => {
                const two_sqrt_a_alpha = 2.0 * @sqrt(A) * alpha;
                b0 = A * ((A + 1.0) - (A - 1.0) * cos_w0 + two_sqrt_a_alpha);
                b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cos_w0);
                b2 = A * ((A + 1.0) - (A - 1.0) * cos_w0 - two_sqrt_a_alpha);
                a0 = (A + 1.0) + (A - 1.0) * cos_w0 + two_sqrt_a_alpha;
                a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cos_w0);
                a2 = (A + 1.0) + (A - 1.0) * cos_w0 - two_sqrt_a_alpha;
            },
            .high_shelf => {
                const two_sqrt_a_alpha = 2.0 * @sqrt(A) * alpha;
                b0 = A * ((A + 1.0) + (A - 1.0) * cos_w0 + two_sqrt_a_alpha);
                b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cos_w0);
                b2 = A * ((A + 1.0) + (A - 1.0) * cos_w0 - two_sqrt_a_alpha);
                a0 = (A + 1.0) - (A - 1.0) * cos_w0 + two_sqrt_a_alpha;
                a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cos_w0);
                a2 = (A + 1.0) - (A - 1.0) * cos_w0 - two_sqrt_a_alpha;
            },
        }

        self.b0 = b0 / a0;
        self.b1 = b1 / a0;
        self.b2 = b2 / a0;
        self.a1 = a1 / a0;
        self.a2 = a2 / a0;
    }

    /// |H(e^{jω})| in dB for the designed coefficients at `freq_hz`.
    fn magnitudeDb(self: Biquad, sample_rate: f64, freq_hz: f64) f64 {
        const sr = @max(sample_rate, 1.0);
        const f = std.math.clamp(freq_hz, 1.0, sr * 0.49);
        const w = 2.0 * std.math.pi * f / sr;
        const c1 = @cos(w);
        const s1 = @sin(w);
        const c2 = @cos(2.0 * w);
        const s2 = @sin(2.0 * w);
        // num = b0 + b1 z^{-1} + b2 z^{-2}
        const nr = self.b0 + self.b1 * c1 + self.b2 * c2;
        const ni = -self.b1 * s1 - self.b2 * s2;
        // den = 1 + a1 z^{-1} + a2 z^{-2}
        const dr = 1.0 + self.a1 * c1 + self.a2 * c2;
        const di = -self.a1 * s1 - self.a2 * s2;
        const n2 = nr * nr + ni * ni;
        const d2 = dr * dr + di * di;
        if (d2 < 1e-30) return 0;
        return 10.0 * std.math.log10(n2 / d2);
    }
};

/// True when the band type has a meaningful gain control (shown on the curve).
pub fn bandHasGain(t: BandType) bool {
    return switch (t) {
        .bell, .low_shelf, .high_shelf => true,
        .high_pass, .low_pass, .band_pass, .notch => false,
    };
}

pub const Equalizer = struct {
    bands: [max_bands]Band = .{
        .{ .type = .high_pass, .freq_hz = 80, .gain_db = 0, .q = 0.707, .enabled = false },
        .{ .type = .low_shelf, .freq_hz = 120, .gain_db = 0, .q = 0.7, .enabled = true },
        .{ .type = .bell, .freq_hz = 1000, .gain_db = 0, .q = 1.0, .enabled = true },
        .{ .type = .bell, .freq_hz = 3000, .gain_db = 0, .q = 1.0, .enabled = true },
        .{ .type = .high_shelf, .freq_hz = 8000, .gain_db = 0, .q = 0.7, .enabled = true },
        .{ .type = .low_pass, .freq_hz = 18000, .gain_db = 0, .q = 0.707, .enabled = false },
        .{},
        .{},
    },
    band_count: usize = 6,
    input_gain_db: f64 = 0,
    output_gain_db: f64 = 0,
    sample_rate: f64 = 44100,
    native_state: native.EqState align(16) = @splat(0),
    native_initialized: bool = false,
    dirty: bool = true,

    pub fn reset(self: *Equalizer) void {
        if (self.native_initialized) native.flux_eq_reset(&self.native_state);
        self.dirty = true;
    }

    pub fn setSampleRate(self: *Equalizer, sr: f64) void {
        if (self.sample_rate != sr) {
            self.sample_rate = sr;
            self.dirty = true;
        }
    }

    pub fn markDirty(self: *Equalizer) void {
        self.dirty = true;
    }

    /// Cascaded magnitude response in dB (input + bands + output). Safe on UI thread.
    pub fn responseDb(self: *const Equalizer, freq_hz: f64) f64 {
        var db = self.input_gain_db + self.output_gain_db;
        var bq: Biquad = .{};
        const count = @min(self.band_count, max_bands);
        for (0..count) |i| {
            if (!self.bands[i].enabled) continue;
            bq.design(self.bands[i], self.sample_rate);
            db += bq.magnitudeDb(self.sample_rate, freq_hz);
        }
        return db;
    }

    fn redesign(self: *Equalizer) void {
        if (!self.native_initialized) {
            native.flux_eq_init(&self.native_state);
            self.native_initialized = true;
        }
        const count = @min(self.band_count, max_bands);
        for (0..count) |i| {
            var bq: Biquad = .{};
            bq.design(self.bands[i], self.sample_rate);
            _ = native.flux_eq_configure(
                &self.native_state,
                @intCast(i),
                bq.b0,
                bq.b1,
                bq.b2,
                1,
                bq.a1,
                bq.a2,
            );
        }
        self.dirty = false;
    }

    pub fn process(self: *Equalizer, left: []f32, right: []f32) void {
        if (self.dirty) self.redesign();
        const n = @min(left.len, right.len);
        if (n == 0) return;
        const in_g: f32 = @floatCast(std.math.pow(f64, 10.0, self.input_gain_db / 20.0));
        const out_g: f32 = @floatCast(std.math.pow(f64, 10.0, self.output_gain_db / 20.0));
        const count = @min(self.band_count, max_bands);

        for (left[0..n], right[0..n]) |*l, *r| {
            l.* *= in_g;
            r.* *= in_g;
        }
        for (0..count) |band| {
            if (!self.bands[band].enabled) continue;
            native.flux_eq_process_band(&self.native_state, @intCast(band), left.ptr, right.ptr, @intCast(n));
        }
        for (left[0..n], right[0..n]) |*l, *r| {
            l.* *= out_g;
            r.* *= out_g;
        }
    }
};

test "miniaudio EQ high-pass rejects DC" {
    var eq: Equalizer = .{};
    eq.band_count = 1;
    eq.bands[0] = .{ .type = .high_pass, .freq_hz = 1000, .q = 0.707, .enabled = true };
    var left: [4096]f32 = @splat(1);
    var right = left;
    eq.process(&left, &right);
    try std.testing.expect(@abs(left[left.len - 1]) < 1e-4);
    try std.testing.expect(@abs(right[right.len - 1]) < 1e-4);
}
