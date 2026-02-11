// Voice - Single synthesizer voice
// Ported from OB-Xf Voice.h
//
// Original OB-Xd was written by Vadim Filatov, released under GPL3.
// OB-Xf is released under the GNU General Public Licence v3 or later.
//
// Combines oscillator block, ladder/SVF filter, two ADSR envelopes (amp
// and filter), a per-voice LFO, noise generator, portamento, brightness
// filter, and all modulation routing into one self-contained voice.

const std = @import("std");
const OscillatorBlock = @import("oscillator_block.zig").OscillatorBlock;
const Filter = @import("filter.zig").Filter;
const AdsrEnvelope = @import("adsr.zig").AdsrEnvelope;
const Lfo = @import("lfo.zig").Lfo;
const Noise = @import("noise.zig").Noise;
const DelayLine = @import("delay_line.zig").DelayLine;
const audio_utils = @import("audio_utils.zig");
const blep_data = @import("blep_data.zig");

pub const Voice = struct {
    sample_rate: f32 = 1.0,
    sample_rate_inv: f32 = 1.0,

    velocity: f32 = 0,
    gated: bool = false,
    gated_with_sustain: bool = false,
    amp_env_level: f32 = 0,
    sounding: bool = false,

    // Internal state
    osc_block_state: f32 = 0,
    brightness_state: f32 = 0,
    brightness_coef: f32 = 0,
    portamento_state: f32 = 0,

    // Slop values (randomized per voice)
    slop_amp_env: f32 = 0,
    slop_filter_env: f32 = 0,
    slop_cutoff: f32 = 0,
    slop_portamento: f32 = 0,
    slop_level: f32 = 0,

    // Sub-modules
    oscs: OscillatorBlock = .{},
    filter: Filter = .{},
    filter_env: AdsrEnvelope = .{},
    amp_env: AdsrEnvelope = .{},
    noise_gen: Noise = .{},
    lfo2: Lfo = .{},

    // Delayed modulation values
    amp_env_delayed: DelayLine(blep_data.b_samples * OVERSAMPLE_FACTOR, f32) = .{},
    filter_env_delayed: DelayLine(blep_data.b_samples * OVERSAMPLE_FACTOR, f32) = .{},
    lfo1_delayed: DelayLine(blep_data.b_samples * OVERSAMPLE_FACTOR, f32) = .{},
    lfo2_delayed: DelayLine(blep_data.b_samples * OVERSAMPLE_FACTOR, f32) = .{},

    // External inputs
    midi_note: i32 = 60,
    pitch_bend: f32 = 0,
    sustain_hold: bool = false,
    lfo1_in: f32 = 0,
    vibrato_lfo_in: f32 = 0,

    // Parameters
    par: Parameters = .{},

    const OVERSAMPLE_FACTOR = 2;

    pub const Parameters = struct {
        slop: Slop = .{},
        osc: Osc = .{},
        filter: FilterParams = .{},
        extmod: ExtMod = .{},
        lfo1: LfoMod = .{},
        lfo2: LfoMod = .{},
        oversample: bool = false,

        pub const Slop = struct {
            cutoff: f32 = 0,
            portamento: f32 = 0,
            level: f32 = 0,
        };

        pub const Osc = struct {
            portamento: f32 = 0,
            brightness: f32 = 1,
            pw_osc2_offset: f32 = 0,
            env_pitch_amt: f32 = 0,
            env_pw_amt: f32 = 0,
            env_pitch_both_oscs: bool = true,
            env_pw_both_oscs: bool = true,
        };

        pub const FilterParams = struct {
            cutoff: f32 = 0,
            keytrack: f32 = 0,
            env_amt: f32 = 0,
            invert_env: bool = false,
            invert_env_scale: f32 = 1,
            push_2pole: bool = false,
            four_pole: bool = false,
        };

        pub const ExtMod = struct {
            pb_up: f32 = 0,
            pb_down: f32 = 0,
            pb_osc2_only: bool = false,
            vel_to_amp: f32 = 0,
            vel_to_filter: f32 = 0,
            env_legato_mode: i32 = 0,
        };

        pub const LfoMod = struct {
            amt1: f32 = 0,
            amt2: f32 = 0,
            osc1_pitch: f32 = 0,
            osc2_pitch: f32 = 0,
            cutoff: f32 = 0,
            osc1_pw: f32 = 0,
            osc2_pw: f32 = 0,
            volume: f32 = 0,
            abs_volume: f32 = 0,
        };
    };

    pub fn initRandom(self: *Voice) void {
        // Use pointer address as unique seed per voice
        const seed: i32 = @truncate(@as(i64, @bitCast(@intFromPtr(self))));
        self.noise_gen.seedWhiteNoise(seed);
        self.slop_level = self.noise_gen.getWhite() * 1923;
        self.slop_amp_env = self.noise_gen.getWhite() * 1923;
        self.slop_filter_env = self.noise_gen.getWhite() * 1923;
        self.slop_cutoff = self.noise_gen.getWhite() * 1923;
        self.slop_portamento = self.noise_gen.getWhite() * 1923;
    }

    pub fn setSampleRate(self: *Voice, sr: f32) void {
        self.sample_rate = sr;
        self.sample_rate_inv = 1.0 / sr;
        self.oscs.setSampleRate(sr);
        self.filter.setSampleRate(sr);
        self.filter_env.setSampleRate(sr);
        self.lfo2.setSampleRate(sr);
        self.amp_env.setSampleRate(sr);
        self.noise_gen.setSampleRate(sr, 10);
        self.noise_gen.seedWhiteNoise(@truncate(@as(i64, @bitCast(@intFromPtr(self)))));
        self.setBrightness(self.par.osc.brightness);
    }

    pub fn setBrightness(self: *Voice, val: f32) void {
        self.par.osc.brightness = val;
        self.brightness_coef = @tan(@min(val, self.sample_rate * 0.5 - 10) * std.math.pi * self.sample_rate_inv);
    }

    pub fn setEnvTimingOffset(self: *Voice, d: f32) void {
        self.amp_env.setEnvOffsets(1.0 + self.slop_amp_env * d);
        self.filter_env.setEnvOffsets(1.0 + self.slop_filter_env * d);
    }

    pub fn setFilter2PolePush(self: *Voice, d: bool) void {
        self.par.filter.push_2pole = d;
        self.filter.par.push_2pole = d;
    }

    pub fn setHqMode(self: *Voice, hq: bool) void {
        if (hq) {
            self.oscs.setDecimation();
        } else {
            self.oscs.removeDecimation();
        }
        self.filter.reset();
        self.par.oversample = hq;
    }

    pub fn updateSoundingState(self: *Voice) bool {
        self.sounding = self.amp_env.isActive();
        return self.sounding;
    }

    pub fn isSounding(self: *const Voice) bool {
        return self.sounding;
    }

    pub fn isGated(self: *const Voice) bool {
        return self.gated;
    }

    pub fn getVoiceAmpEnvStatus(self: *const Voice) f32 {
        return if (self.sounding) self.amp_env_level else 0;
    }

    pub fn resetEnvelope(self: *Voice) void {
        self.amp_env.resetEnvelopeState();
        self.filter_env.resetEnvelopeState();
    }

    const reuse_velocity_sentinel: f32 = -0.5;

    pub fn noteOn(self: *Voice, note: i32, vel: f32) void {
        if (!self.sounding) {
            self.amp_env_delayed.fillZeroes();
            self.filter_env_delayed.fillZeroes();
            self.resetEnvelope();
        }
        self.sounding = true;
        if (vel > reuse_velocity_sentinel) {
            self.velocity = vel;
        }
        self.midi_note = note;
        if (!self.gated_with_sustain or (self.par.extmod.env_legato_mode & 1) != 0) {
            self.amp_env.triggerAttack();
        }
        if (!self.gated_with_sustain or (self.par.extmod.env_legato_mode & 2) != 0) {
            self.filter_env.triggerAttack();
        }
        self.lfo2.setPhaseDirectly(0);
        self.gated = true;
        self.gated_with_sustain = true;
    }

    pub fn noteOff(self: *Voice) void {
        if (!self.sustain_hold) {
            self.amp_env.triggerRelease();
            self.filter_env.triggerRelease();
        }
        self.gated = false;
        self.gated_with_sustain = self.sustain_hold;
    }

    pub fn sustOn(self: *Voice) void {
        self.sustain_hold = true;
    }

    pub fn sustOff(self: *Voice) void {
        self.sustain_hold = false;
        if (!self.gated) {
            self.amp_env.triggerRelease();
            self.filter_env.triggerRelease();
            self.gated_with_sustain = false;
        }
    }

    pub inline fn processSample(self: *Voice) f32 {
        self.lfo2.update(false);
        const lfo2_in = self.lfo2.getVal();

        // Portamento (RC circuit)
        const tuned_note: f32 = @floatFromInt(self.midi_note);
        const porta_processed = audio_utils.tptLpUnwarped(
            &self.portamento_state,
            tuned_note - 93,
            self.par.osc.portamento * (1 + self.slop_portamento * self.par.slop.portamento),
            self.sample_rate_inv,
        );

        // Pitch bend
        const pitch_bend_scaled = if (self.pitch_bend < 0)
            self.pitch_bend * self.par.extmod.pb_down
        else
            self.pitch_bend * self.par.extmod.pb_up;

        self.oscs.par.pitch.note_playing = porta_processed;

        // Delayed modulation
        const filter_lfo1_mod = self.lfo1_delayed.feedReturn(self.lfo1_in);
        const filter_lfo2_mod = self.lfo2_delayed.feedReturn(lfo2_in);

        // Filter envelope
        const mod_env = self.par.filter.invert_env_scale * self.filter_env.processSample() *
            (1 - (1 - self.velocity) * self.par.extmod.vel_to_filter);

        // Filter cutoff calculation
        const noisy_cutoff = self.noise_gen.getWhite() * 3.365;

        const cutoff_pitch = audio_utils.getPitch(
            (self.par.lfo1.cutoff * filter_lfo1_mod * self.par.lfo1.amt1) +
                (self.par.lfo2.cutoff * filter_lfo2_mod * self.par.lfo2.amt1) +
                self.par.filter.cutoff +
                self.slop_cutoff * self.par.slop.cutoff +
                self.par.filter.env_amt * self.filter_env_delayed.feedReturn(mod_env) - 45 +
                (self.par.filter.keytrack * (pitch_bend_scaled + self.oscs.par.pitch.note_playing + 40)),
        );

        var cutoffcalc = @min(cutoff_pitch + noisy_cutoff, self.sample_rate * 0.5 - 120.0);

        if (self.par.filter.push_2pole) {
            cutoffcalc = @min(cutoffcalc, 19000.0 + 5000.0 * @as(f32, if (self.par.oversample) 1.0 else 0.0));
        }

        // Pulse width modulation
        const pwenv = mod_env * (if (self.oscs.par.mod.env_to_pw_invert) @as(f32, -1) else @as(f32, 1));

        self.oscs.par.mod.osc1_pw_mod =
            (self.par.lfo1.osc1_pw * self.lfo1_in * self.par.lfo1.amt2) +
            (self.par.lfo2.osc1_pw * lfo2_in * self.par.lfo2.amt2) +
            (if (self.par.osc.env_pw_both_oscs) self.par.osc.env_pw_amt * pwenv else 0);
        self.oscs.par.mod.osc2_pw_mod =
            (self.par.lfo1.osc2_pw * self.lfo1_in * self.par.lfo1.amt2) +
            (self.par.lfo2.osc2_pw * lfo2_in * self.par.lfo2.amt2) +
            (self.par.osc.env_pw_amt * pwenv) + self.par.osc.pw_osc2_offset;

        // Pitch modulation
        const pitch_env = mod_env * (if (self.oscs.par.mod.env_to_pitch_invert) @as(f32, -1) else @as(f32, 1));

        self.oscs.par.mod.osc1_pitch_mod =
            (if (!self.par.extmod.pb_osc2_only) pitch_bend_scaled else 0) +
            (self.par.lfo1.osc1_pitch * self.lfo1_in * self.par.lfo1.amt1) +
            (self.par.lfo2.osc1_pitch * lfo2_in * self.par.lfo2.amt1) +
            (if (self.par.osc.env_pitch_both_oscs) self.par.osc.env_pitch_amt * pitch_env else 0) +
            self.vibrato_lfo_in;
        self.oscs.par.mod.osc2_pitch_mod =
            pitch_bend_scaled +
            (self.par.lfo1.osc2_pitch * self.lfo1_in * self.par.lfo1.amt1) +
            (self.par.lfo2.osc2_pitch * lfo2_in * self.par.lfo2.amt1) +
            (self.par.osc.env_pitch_amt * pitch_env) +
            self.vibrato_lfo_in;

        // Process oscillator block
        var osc_sample = self.oscs.processSample() * (1 - self.par.slop.level * self.slop_level);

        // Brightness filter (highpass + lowpass)
        osc_sample = osc_sample - audio_utils.tptLpUnwarped(&self.osc_block_state, osc_sample, 12, self.sample_rate_inv);
        osc_sample = audio_utils.tptProcess(&self.brightness_state, osc_sample, self.brightness_coef);

        // Apply filter
        osc_sample = if (self.par.filter.four_pole)
            self.filter.apply4Pole(osc_sample, cutoffcalc)
        else
            self.filter.apply2Pole(osc_sample, cutoffcalc);

        // LFO volume modulation
        osc_sample *= 1.0 - (self.par.lfo1.volume * self.lfo1_in * 0.5 + self.par.lfo1.abs_volume * 0.5) *
            (self.par.lfo1.amt2 * 1.4285714285714286);
        osc_sample *= 1.0 - (self.par.lfo2.volume * lfo2_in * 0.5 + self.par.lfo2.abs_volume * 0.5) *
            (self.par.lfo2.amt2 * 1.4285714285714286);

        // Amp envelope
        const amp_env_val = self.amp_env_delayed.feedReturn(
            self.amp_env.processSample() * (1 - (1 - self.velocity) * self.par.extmod.vel_to_amp),
        );
        osc_sample *= amp_env_val;
        self.amp_env_level = amp_env_val;

        return osc_sample;
    }
};
