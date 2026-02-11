// Pulse/Square Wave Oscillator with BLEP (Band-Limited Step) anti-aliasing
// Ported from OB-Xf PulseOsc.h
//
// Original OB-Xd was written by Vadim Filatov, released under GPL3.
// OB-Xf is released under the GNU General Public Licence v3 or later.

const blep_data = @import("blep_data.zig");
const DelayLine = @import("delay_line.zig").DelayLine;

const b_oversampling = blep_data.b_oversampling;
const b_samples = blep_data.b_samples;
const b_samples_x2 = blep_data.b_samples_x2;

pub const PulseOsc = struct {
    delay: DelayLine(b_samples, f32) = DelayLine(b_samples, f32).init(),
    buffer: [b_samples_x2]f32 = [_]f32{0.0} ** b_samples_x2,
    use_decimation: bool = false,
    pw1t: bool = false,
    buffer_pos: usize = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub inline fn setDecimation(self: *Self) void {
        self.use_decimation = true;
    }

    pub inline fn removeDecimation(self: *Self) void {
        self.use_decimation = false;
    }

    pub inline fn aliasReduction(self: *Self) f32 {
        return -self.getNextBlep();
    }

    pub inline fn processLeader(self: *Self, x: f32, delta: f32, pulse_width: f32, pulse_width_was: f32) void {
        var xv = x;
        const sum = delta - (pulse_width - pulse_width_was);

        if (self.pw1t and xv >= 1.0) {
            xv -= 1.0;

            if (self.pw1t) {
                self.mixInImpulseCenter(xv / delta, 1.0);
            }

            self.pw1t = false;
        }

        if ((!self.pw1t) and (xv >= pulse_width) and (xv - sum <= pulse_width)) {
            const frac = (xv - pulse_width) / sum;

            self.pw1t = true;

            self.mixInImpulseCenter(frac, -1.0);
        }

        if (self.pw1t and xv >= 1.0) {
            xv -= 1.0;

            if (self.pw1t) {
                self.mixInImpulseCenter(xv / delta, 1.0);
            }

            self.pw1t = false;
        }
    }

    pub inline fn getValue(self: *Self, x: f32, pulse_width: f32) f32 {
        const oscmix = if (x >= pulse_width)
            1.0 - (0.5 - pulse_width) - 0.5
        else
            -(0.5 - pulse_width) - 0.5;

        return self.delay.feedReturn(oscmix);
    }

    pub inline fn getValueFast(x: f32, pulse_width: f32) f32 {
        return if (x >= pulse_width)
            1.0 - (0.5 - pulse_width) - 0.5
        else
            -(0.5 - pulse_width) - 0.5;
    }

    pub inline fn processFollower(
        self: *Self,
        x: f32,
        delta: f32,
        hard_sync_reset: bool,
        hard_sync_frac: f32,
        pulse_width: f32,
        pulse_width_was: f32,
    ) void {
        var xv = x;
        const sum = delta - (pulse_width - pulse_width_was);

        if (self.pw1t and xv >= 1.0) {
            xv -= 1.0;

            // De Morgan processed equation
            if ((!hard_sync_reset) or (xv / delta > hard_sync_frac)) {
                if (self.pw1t) {
                    self.mixInImpulseCenter(xv / delta, 1.0);
                }

                self.pw1t = false;
            } else {
                xv += 1.0;
            }
        }

        if ((!self.pw1t) and (xv >= pulse_width) and (xv - sum <= pulse_width)) {
            const frac = (xv - pulse_width) / sum;

            self.pw1t = true;

            // De Morgan processed equation
            if ((!hard_sync_reset) or (frac > hard_sync_frac)) {
                // transition to 1
                self.mixInImpulseCenter(frac, -1.0);
            } else {
                // if transition didn't occur
                self.pw1t = false;
            }
        }

        if (self.pw1t and xv >= 1.0) {
            xv -= 1.0;

            // De Morgan processed equation
            if ((!hard_sync_reset) or (xv / delta > hard_sync_frac)) {
                if (self.pw1t) {
                    self.mixInImpulseCenter(xv / delta, 1.0);
                }

                self.pw1t = false;
            } else {
                xv += 1.0;
            }
        }

        if (hard_sync_reset) {
            const trans: f32 = if (self.pw1t) 1.0 else 0.0;

            self.mixInImpulseCenter(hard_sync_frac, trans);

            self.pw1t = false;
        }
    }

    inline fn mixInImpulseCenter(self: *Self, offset: f32, scale: f32) void {
        const table = if (self.use_decimation) &blep_data.blepd2 else &blep_data.blep;
        const table_size: usize = table.len;

        const lp_in_init: usize = @intFromFloat(
            @as(f32, @floatFromInt(b_oversampling)) * offset,
        );
        const max_iter_num: usize = (table_size - 1 - (lp_in_init + 1)) / b_oversampling + 1;
        const safe_samples: usize = @min(b_samples, max_iter_num);
        const safe_n: usize = @min(b_samples_x2, max_iter_num);
        const frac = offset * @as(f32, @floatFromInt(b_oversampling)) - @as(f32, @floatFromInt(lp_in_init));
        const f1 = 1.0 - frac;

        var lp_in = lp_in_init;

        for (0..safe_samples) |i| {
            const mix_value = table[lp_in] * f1 + table[lp_in + 1] * frac;
            self.buffer[(self.buffer_pos + i) & (b_samples_x2 - 1)] += mix_value * scale;
            lp_in += b_oversampling;
        }

        for (safe_samples..safe_n) |i| {
            const mix_value = table[lp_in] * f1 + table[lp_in + 1] * frac;
            self.buffer[(self.buffer_pos + i) & (b_samples_x2 - 1)] -= mix_value * scale;
            lp_in += b_oversampling;
        }
    }

    inline fn getNextBlep(self: *Self) f32 {
        self.buffer[self.buffer_pos] = 0.0;
        self.buffer_pos += 1;

        // wrap position
        self.buffer_pos &= (b_samples_x2 - 1);

        return self.buffer[self.buffer_pos];
    }
};
