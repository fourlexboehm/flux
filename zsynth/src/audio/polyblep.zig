const std = @import("std");

// PolyBLEP Waveform generator ported from the Jesusonic code by Tale
// http://www.taletn.com/reaper/mono_synth/
//
// Permission has been granted to release this port under the WDL/IPlug license:
//
//     This software is provided 'as-is', without any express or implied
//     warranty.  In no event will the authors be held liable for any damages
//     arising from the use of this software.
//
//     Permission is granted to anyone to use this software for any purpose,
//     including commercial applications, and to alter it and redistribute it
//     freely, subject to the following restrictions:
//
//     1. The origin of this software must not be misrepresented; you must not
//        claim that you wrote the original software. If you use this software
//        in a product, an acknowledgment in the product documentation would be
//        appreciated but is not required.
//     2. Altered source versions must be plainly marked as such, and must not be
//        misrepresented as being the original software.
//     3. This notice may not be removed or altered from any source distribution.

pub const Waveform = enum {
    Sine,
    Triangle,
    Square,
    Saw,
};

pub const PolyBLEP = struct {
    waveform: Waveform,
    sample_rate: f64,
    dt: f64,
    phase: f64,
    pulse_width: f64 = 0.5,
    amplitude: f64 = 1.0,

    pub fn init(sample_rate: f64, waveform: Waveform, frequency: f64, phase: f64) PolyBLEP {
        var osc = PolyBLEP{
            .waveform = waveform,
            .sample_rate = sample_rate,
            .dt = 0,
            .phase = 0,
        };
        osc.setFrequency(frequency);
        osc.sync(phase);
        return osc;
    }

    pub fn setFrequency(self: *PolyBLEP, freq_hz: f64) void {
        self.dt = freq_hz / self.sample_rate;
    }

    pub fn setSampleRate(self: *PolyBLEP, sample_rate: f64) void {
        const freq_hz = self.getFrequency();
        self.sample_rate = sample_rate;
        self.setFrequency(freq_hz);
    }

    pub fn getFrequency(self: *const PolyBLEP) f64 {
        return self.dt * self.sample_rate;
    }

    pub fn setPulseWidth(self: *PolyBLEP, pulse_width: f64) void {
        self.pulse_width = pulse_width;
    }

    pub fn sync(self: *PolyBLEP, phase: f64) void {
        self.phase = wrap01(phase);
    }

    pub fn setWaveform(self: *PolyBLEP, waveform: Waveform) void {
        self.waveform = waveform;
    }

    pub fn get(self: *const PolyBLEP) f64 {
        if (self.getFrequency() >= self.sample_rate / 4.0) {
            return self.sin();
        }
        return switch (self.waveform) {
            .Sine => self.sin(),
            .Triangle => self.tri(),
            .Square => self.sqr(),
            .Saw => self.saw(),
        };
    }

    pub fn inc(self: *PolyBLEP) void {
        self.phase = wrap01(self.phase + self.dt);
    }

    pub fn getAndInc(self: *PolyBLEP) f64 {
        const sample = self.get();
        self.inc();
        return sample;
    }

    fn sin(self: *const PolyBLEP) f64 {
        return self.amplitude * std.math.sin(2.0 * std.math.pi * self.phase);
    }

    fn tri(self: *const PolyBLEP) f64 {
        const t1 = wrap01(self.phase + 0.25);
        const t2 = wrap01(self.phase + 0.75);

        var y = self.phase * 4.0;
        if (y >= 3.0) {
            y -= 4.0;
        } else if (y > 1.0) {
            y = 2.0 - y;
        }

        y += 4.0 * self.dt * (blamp(t1, self.dt) - blamp(t2, self.dt));
        return self.amplitude * y;
    }

    fn sqr(self: *const PolyBLEP) f64 {
        const t2 = wrap01(self.phase + 0.5);
        var y: f64 = if (self.phase < 0.5) 1.0 else -1.0;
        y += blep(self.phase, self.dt) - blep(t2, self.dt);
        return self.amplitude * y;
    }

    fn saw(self: *const PolyBLEP) f64 {
        const t = wrap01(self.phase + 0.5);
        var y = (2.0 * t) - 1.0;
        y -= blep(t, self.dt);
        return self.amplitude * y;
    }
};

fn wrap01(value: f64) f64 {
    return value - @floor(value);
}

fn square(value: f64) f64 {
    return value * value;
}

fn blep(t: f64, dt: f64) f64 {
    if (t < dt) {
        return -square(t / dt - 1.0);
    } else if (t > 1.0 - dt) {
        return square((t - 1.0) / dt + 1.0);
    }
    return 0.0;
}

fn blamp(t_in: f64, dt: f64) f64 {
    var t = t_in;
    if (t < dt) {
        t = t / dt - 1.0;
        return -(1.0 / 3.0) * square(t) * t;
    } else if (t > 1.0 - dt) {
        t = (t - 1.0) / dt + 1.0;
        return (1.0 / 3.0) * square(t) * t;
    }
    return 0.0;
}
