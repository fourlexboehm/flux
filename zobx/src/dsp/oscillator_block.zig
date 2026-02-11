// Oscillator Block - Two oscillators, noise, and ring modulation
// Ported from OB-Xf OscillatorBlock.h
//
// Original OB-Xd was written by Vadim Filatov, released under GPL3.
// OB-Xf is released under the GNU General Public Licence v3 or later.
//
// Combines two BLEP oscillators (each with saw, pulse, and triangle
// waveforms), a noise source, hard sync, cross-modulation, and ring
// modulation into a single processing block.

const std = @import("std");
const SawOsc = @import("saw_osc.zig").SawOsc;
const PulseOsc = @import("pulse_osc.zig").PulseOsc;
const TriangleOsc = @import("triangle_osc.zig").TriangleOsc;
const Noise = @import("noise.zig").Noise;
const DelayLine = @import("delay_line.zig").DelayLine;
const audio_utils = @import("audio_utils.zig");
const blep_data = @import("blep_data.zig");

pub const OscillatorBlock = struct {
    const one_third: f32 = 1.0 / 3.0;
    const two_thirds: f32 = 2.0 / 3.0;

    sample_rate: f32 = 1.0,
    sample_rate_inv: f32 = 1.0,

    // Oscillator state
    osc1_phase: f32 = 0,
    osc1_pitch: f32 = 0,
    osc1_tuning_slop: f32 = 0,
    osc1_pw: f32 = 0,

    osc2_phase: f32 = 0,
    osc2_pitch: f32 = 0,
    osc2_tuning_slop: f32 = 0,
    osc2_pw: f32 = 0,

    // Delay lines for sync, crossmod, and pitch.
    // The sync delay stores boolean reset flags as u8 because the generic
    // DelayLine initialises its buffer with zero which does not coerce to
    // bool in Zig.  We convert at the boundaries with @intFromBool / != 0.
    sync_delay: DelayLine(blep_data.b_samples, u8) = .{},
    sync_frac_delay: DelayLine(blep_data.b_samples, f32) = .{},
    crossmod_delay: DelayLine(blep_data.b_samples, f32) = .{},
    pitch_delay: DelayLine(blep_data.b_samples, f32) = .{},

    // Generators
    noise: Noise = .{},
    osc1_saw: SawOsc = .{},
    osc2_saw: SawOsc = .{},
    osc1_pulse: PulseOsc = .{},
    osc2_pulse: PulseOsc = .{},
    osc1_triangle: TriangleOsc = .{},
    osc2_triangle: TriangleOsc = .{},

    // Parameters (set externally)
    par: Parameters = .{},

    pub const Parameters = struct {
        pitch: Pitch = .{},
        osc: Osc = .{},
        mod: Mod = .{},
        mix: Mix = .{},

        pub const Pitch = struct {
            transpose: i32 = 0,
            tune: f32 = 0,
            unison_detune: f32 = 0,
            note_playing: f32 = 60,
        };

        pub const Osc = struct {
            pitch1: f32 = 0,
            pitch2: f32 = 0,
            detune: f32 = 0,
            pw: f32 = 0,
            saw1: bool = false,
            saw2: bool = false,
            pulse1: bool = false,
            pulse2: bool = false,
            crossmod: f32 = 0,
            sync: bool = false,
        };

        pub const Mod = struct {
            osc_pitch_noise: f32 = 0.1,
            osc1_pitch_mod: f32 = 0,
            osc2_pitch_mod: f32 = 0,
            osc1_pw_mod: f32 = 0,
            osc2_pw_mod: f32 = 0,
            env_to_pitch_invert: bool = false,
            env_to_pw_invert: bool = false,
        };

        pub const Mix = struct {
            osc1: f32 = 0,
            osc2: f32 = 0,
            ring_mod: f32 = 0,
            noise: f32 = 0,
            noise_color: f32 = 0,
        };
    };

    pub fn setDecimation(self: *OscillatorBlock) void {
        self.osc1_pulse.setDecimation();
        self.osc1_triangle.setDecimation();
        self.osc1_saw.setDecimation();
        self.osc2_pulse.setDecimation();
        self.osc2_triangle.setDecimation();
        self.osc2_saw.setDecimation();
    }

    pub fn removeDecimation(self: *OscillatorBlock) void {
        self.osc1_pulse.removeDecimation();
        self.osc1_triangle.removeDecimation();
        self.osc1_saw.removeDecimation();
        self.osc2_pulse.removeDecimation();
        self.osc2_triangle.removeDecimation();
        self.osc2_saw.removeDecimation();
    }

    pub fn setSampleRate(self: *OscillatorBlock, sr: f32) void {
        self.sample_rate = sr;
        self.sample_rate_inv = 1.0 / sr;
        self.noise.setSampleRate(sr, 10);
        self.noise.seedWhiteNoise(@truncate(@as(i64, @bitCast(@intFromPtr(self)))));
        self.osc1_tuning_slop = self.noise.getWhite();
        self.osc2_tuning_slop = self.noise.getWhite();
        self.osc1_phase = self.noise.getWhite();
        self.osc2_phase = self.noise.getWhite();
    }

    pub inline fn processSample(self: *OscillatorBlock) f32 {
        // 1. Calculate osc1 pitch from note + mods + noise
        self.osc1_pitch = audio_utils.getPitch(
            self.par.mod.osc_pitch_noise * self.noise.getWhite() +
                self.par.pitch.note_playing + self.par.osc.pitch1 +
                self.par.mod.osc1_pitch_mod + self.par.pitch.tune +
                @as(f32, @floatFromInt(self.par.pitch.transpose)) +
                self.par.pitch.unison_detune * self.osc1_tuning_slop,
        );

        var sync_reset: bool = false;
        var sync_frac: f32 = 0;
        var fs = @min(self.osc1_pitch * self.sample_rate_inv, 0.45);

        self.osc1_phase += fs;

        var osc1out: f32 = 0;
        var pwcalc = std.math.clamp((self.par.osc.pw + self.par.mod.osc1_pw_mod) * 0.5 + 0.5, 0.1, 1.0);

        // Process osc1 waveform (leader)
        if (self.par.osc.pulse1) {
            self.osc1_pulse.processLeader(self.osc1_phase, fs, pwcalc, self.osc1_pw);
        }
        if (self.par.osc.saw1) {
            self.osc1_saw.processLeader(self.osc1_phase, fs);
        } else if (!self.par.osc.pulse1) {
            self.osc1_triangle.processLeader(self.osc1_phase, fs);
        }

        // Phase wrap
        if (self.osc1_phase >= 1.0) {
            self.osc1_phase -= 1.0;
            sync_frac = self.osc1_phase / fs;
            sync_reset = true;
        }

        self.osc1_pw = pwcalc;
        sync_reset = sync_reset and self.par.osc.sync;

        // Delayed sync signals (stored as u8 for DelayLine compatibility)
        const delayed_sync_u8 = self.sync_delay.feedReturn(@intFromBool(sync_reset));
        sync_frac = self.sync_frac_delay.feedReturn(sync_frac);
        sync_reset = delayed_sync_u8 != 0;

        // Get osc1 value
        if (self.par.osc.pulse1) {
            osc1out += self.osc1_pulse.getValue(self.osc1_phase, pwcalc) + self.osc1_pulse.aliasReduction();
        }
        if (self.par.osc.saw1) {
            osc1out += self.osc1_saw.getValue(self.osc1_phase) + self.osc1_saw.aliasReduction();
        } else if (!self.par.osc.pulse1) {
            osc1out = self.osc1_triangle.getValue(self.osc1_phase) + self.osc1_triangle.aliasReduction();
        }

        // 2. Calculate osc2 pitch with crossmod from osc1
        self.osc2_pitch = audio_utils.getPitch(self.pitch_delay.feedReturn(
            self.par.mod.osc_pitch_noise * self.noise.getWhite() +
                self.par.pitch.note_playing + self.par.osc.detune + self.par.osc.pitch2 +
                self.par.mod.osc2_pitch_mod + osc1out * self.par.osc.crossmod +
                self.par.pitch.tune + @as(f32, @floatFromInt(self.par.pitch.transpose)) +
                self.par.pitch.unison_detune * self.osc2_tuning_slop,
        ));

        fs = @min(self.osc2_pitch * self.sample_rate_inv, 0.45);
        pwcalc = std.math.clamp((self.par.osc.pw + self.par.mod.osc2_pw_mod) * 0.5 + 0.5, 0.1, 1.0);

        var osc2out: f32 = 0;
        self.osc2_phase += fs;

        // Process osc2 waveform (follower - with hard sync)
        if (self.par.osc.pulse2) {
            self.osc2_pulse.processFollower(self.osc2_phase, fs, sync_reset, sync_frac, pwcalc, self.osc2_pw);
        }
        if (self.par.osc.saw2) {
            self.osc2_saw.processFollower(self.osc2_phase, fs, sync_reset, sync_frac);
        } else if (!self.par.osc.pulse2) {
            self.osc2_triangle.processFollower(self.osc2_phase, fs, sync_reset, sync_frac);
        }

        // Phase wrap
        if (self.osc2_phase >= 1.0) {
            self.osc2_phase -= 1.0;
        }

        self.osc2_pw = pwcalc;

        // Hard sync reset
        if (sync_reset) {
            self.osc2_phase = fs * sync_frac;
        }

        // Delayed crossmod
        osc1out = self.crossmod_delay.feedReturn(osc1out);

        // Get osc2 value
        if (self.par.osc.pulse2) {
            osc2out += self.osc2_pulse.getValue(self.osc2_phase, pwcalc) + self.osc2_pulse.aliasReduction();
        }
        if (self.par.osc.saw2) {
            osc2out += self.osc2_saw.getValue(self.osc2_phase) + self.osc2_saw.aliasReduction();
        } else if (!self.par.osc.pulse2) {
            osc2out = self.osc2_triangle.getValue(self.osc2_phase) + self.osc2_triangle.aliasReduction();
        }

        // 3. Mix: ring mod, noise, oscillator volumes
        const rm_out = osc1out * osc2out;
        var noise_val: f32 = 0;

        if (self.par.mix.noise_color < one_third) {
            noise_val = self.noise.getWhite();
        } else if (self.par.mix.noise_color < two_thirds) {
            noise_val = self.noise.getPink();
        } else {
            noise_val = self.noise.getRed();
        }

        const out = (osc1out * self.par.mix.osc1) + (osc2out * self.par.mix.osc2) +
            (noise_val * (self.par.mix.noise + 0.0006)) + (rm_out * self.par.mix.ring_mod);

        return out * 3.0;
    }
};
