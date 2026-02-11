const std = @import("std");
const Voice = @import("voice.zig").Voice;
const Lfo = @import("lfo.zig").Lfo;
const Smoother = @import("smoother.zig").Smoother;
const Decimator17 = @import("decimator.zig").Decimator17;
const audio_utils = @import("audio_utils.zig");

pub const MAX_VOICES: usize = 32;
pub const MAX_PANNINGS: usize = 8;
pub const MAX_BEND_RANGE: f32 = 48;

pub const SynthEngine = struct {
    voices: [MAX_VOICES]Voice = [_]Voice{.{}} ** MAX_VOICES,
    global_lfo: Lfo = .{},
    vibrato_lfo: Lfo = .{},

    left_decimator: Decimator17 = .{},
    right_decimator: Decimator17 = .{},

    cutoff_smoother: Smoother = .{},
    res_smoother: Smoother = .{},
    filter_mode_smoother: Smoother = .{},
    pitch_bend_smoother: Smoother = .{},
    mod_wheel_smoother: Smoother = .{},

    sample_rate: f32 = 44100,
    sample_rate_inv: f32 = 1.0 / 44100.0,

    total_voice_count: usize = MAX_VOICES,
    unison_voice_count: usize = MAX_PANNINGS,

    vibrato_amount: f32 = 0,
    volume: f32 = 0,
    pannings: [MAX_PANNINGS]f32 = [_]f32{0.5} ** MAX_PANNINGS,
    unison: bool = false,
    oversample: bool = false,

    // Voice priority
    voice_priority: VoicePriority = .latest,
    voice_age: [129]i32 = [_]i32{0} ** 129,
    stolen_voices: [129]i32 = [_]i32{0} ** 129,
    as_played_counter: i32 = 0,

    pub const VoicePriority = enum { latest, lowest, highest };

    pub fn init() SynthEngine {
        var engine: SynthEngine = .{};
        // Initialize vibrato LFO as pure sine
        engine.vibrato_lfo.par.wave1blend = -1.0; // pure sine
        engine.vibrato_lfo.par.unipolar_pulse = 1.0;
        // Initialize random slop for each voice
        for (&engine.voices) |*v| {
            v.initRandom();
        }
        return engine;
    }

    pub fn setSampleRate(self: *SynthEngine, sr: f32) void {
        self.sample_rate = sr;
        self.sample_rate_inv = 1.0 / sr;

        self.cutoff_smoother.setSampleRate(sr);
        self.res_smoother.setSampleRate(sr);
        self.filter_mode_smoother.setSampleRate(sr);
        self.pitch_bend_smoother.setSampleRate(sr);
        self.mod_wheel_smoother.setSampleRate(sr);

        self.global_lfo.setSampleRate(sr);
        self.vibrato_lfo.setSampleRate(sr);

        for (&self.voices) |*v| {
            v.setSampleRate(sr);
        }

        self.setHQMode(self.oversample, true);
    }

    pub fn setHQMode(self: *SynthEngine, over: bool, force: bool) void {
        if (!force and over == self.oversample) return;

        const factor: f32 = if (over) 2.0 else 1.0;

        self.global_lfo.setSampleRate(self.sample_rate * factor);
        self.vibrato_lfo.setSampleRate(self.sample_rate * factor);

        for (&self.voices) |*v| {
            v.setSampleRate(self.sample_rate * factor);
            v.setHqMode(over);
        }

        self.oversample = over;
        self.left_decimator.reset();
        self.right_decimator.reset();
    }

    // Note On - voice allocation
    pub fn noteOn(self: *SynthEngine, note: i32, velocity: f32) void {
        self.voice_age[@intCast(@min(@max(note, 0), 128))] = self.as_played_counter;
        self.as_played_counter += 1;

        // Check if a voice is already playing this note
        for (self.voices[0..self.total_voice_count]) |*v| {
            if (v.midi_note == note and v.isGated()) {
                v.noteOn(note, velocity);
                return;
            }
        }

        // Find a free voice
        for (self.voices[0..self.total_voice_count]) |*v| {
            if (!v.isGated()) {
                v.noteOn(note, velocity);
                return;
            }
        }

        // Voice stealing - steal oldest
        var oldest_idx: usize = 0;
        var oldest_age: i32 = std.math.maxInt(i32);
        for (self.voices[0..self.total_voice_count], 0..) |*v, i| {
            const age = self.voice_age[@intCast(@min(@max(v.midi_note, 0), 128))];
            if (age < oldest_age) {
                oldest_age = age;
                oldest_idx = i;
            }
        }
        self.voices[oldest_idx].noteOn(note, velocity);
    }

    // Note Off
    pub fn noteOff(self: *SynthEngine, note: i32) void {
        for (self.voices[0..self.total_voice_count]) |*v| {
            if (v.midi_note == note) {
                v.noteOff();
            }
        }
    }

    pub fn allNotesOff(self: *SynthEngine) void {
        for (&self.voices) |*v| {
            v.noteOff();
        }
    }

    pub fn allSoundOff(self: *SynthEngine) void {
        self.allNotesOff();
        for (&self.voices) |*v| {
            v.resetEnvelope();
        }
    }

    pub fn sustainOn(self: *SynthEngine) void {
        for (self.voices[0..self.total_voice_count]) |*v| {
            v.sustOn();
        }
    }

    pub fn sustainOff(self: *SynthEngine) void {
        for (self.voices[0..self.total_voice_count]) |*v| {
            v.sustOff();
        }
    }

    // Process one output sample (stereo)
    pub fn processSample(self: *SynthEngine, left: *f32, right: *f32) void {
        // Check if any voice is sounding
        var any_sounding = false;
        for (self.voices[0..self.total_voice_count]) |*v| {
            if (v.isSounding()) {
                any_sounding = true;
                break;
            }
        }

        if (!any_sounding) {
            self.global_lfo.update(true);
            self.vibrato_lfo.update(true);
            if (self.oversample) {
                self.global_lfo.update(true);
                self.vibrato_lfo.update(true);
            }
            left.* = 0;
            right.* = 0;
            return;
        }

        // Smooth parameters
        const co = self.cutoff_smoother.smoothStep();
        const re = self.res_smoother.smoothStep();
        const fm = self.filter_mode_smoother.smoothStep();
        const pb = self.pitch_bend_smoother.smoothStep();
        const mw = self.mod_wheel_smoother.smoothStep();
        self.vibrato_amount = mw;

        // Apply smoothed params to sounding voices
        for (self.voices[0..self.total_voice_count]) |*v| {
            if (v.isSounding()) {
                v.par.filter.cutoff = co;
                v.filter.setResonance(re);
                v.filter.setMultimode(fm);
                v.pitch_bend = pb;
            }
        }

        // Update LFOs
        self.global_lfo.update(false);
        self.vibrato_lfo.update(false);

        var vl: f32 = 0;
        var vr: f32 = 0;
        var vlo: f32 = 0;
        var vro: f32 = 0;

        const lfo_value = self.global_lfo.getVal();
        const vib_lfo = self.vibrato_lfo.getVal() * self.vibrato_amount * self.vibrato_amount * 4.0;

        var lfo_value2: f32 = 0;
        var vib_lfo2: f32 = 0;

        if (self.oversample) {
            self.global_lfo.update(false);
            self.vibrato_lfo.update(false);
            lfo_value2 = self.global_lfo.getVal();
            vib_lfo2 = self.vibrato_lfo.getVal() * self.vibrato_amount * self.vibrato_amount * 4.0;
        }

        // Process each voice
        for (0..self.total_voice_count) |i| {
            var v = &self.voices[i];
            _ = v.updateSoundingState();

            if (v.isSounding()) {
                v.lfo1_in = lfo_value;
                v.vibrato_lfo_in = vib_lfo;
                const x1 = v.processSample();

                const pan = self.pannings[i % MAX_PANNINGS];

                if (self.oversample) {
                    v.lfo1_in = lfo_value2;
                    v.vibrato_lfo_in = vib_lfo2;
                    const x2 = v.processSample();
                    vlo += x2 * (1 - pan);
                    vro += x2 * pan;
                }

                vl += x1 * (1 - pan);
                vr += x1 * pan;
            }
        }

        if (self.oversample) {
            vl = self.left_decimator.decimate(vl, vlo);
            vr = self.right_decimator.decimate(vr, vro);
        }

        left.* = vl * self.volume;
        right.* = vr * self.volume;
    }

    // Parameter processing methods (maps normalized 0-1 to DSP values)
    pub fn processPitchWheel(self: *SynthEngine, val: f32) void {
        self.pitch_bend_smoother.setStep(val);
    }

    pub fn processModWheel(self: *SynthEngine, val: f32) void {
        self.mod_wheel_smoother.setStep(val);
    }

    pub fn processFilterCutoff(self: *SynthEngine, val: f32) void {
        self.cutoff_smoother.setStep(audio_utils.linsc(val, 0, 120));
    }

    pub fn processFilterResonance(self: *SynthEngine, val: f32) void {
        self.res_smoother.setStep(0.991 - audio_utils.logsc(1.0 - val, 0, 0.991, 40));
    }

    pub fn processFilterMode(self: *SynthEngine, val: f32) void {
        self.filter_mode_smoother.setStep(val);
    }

    pub fn processVolume(self: *SynthEngine, val: f32) void {
        self.volume = audio_utils.linsc(val, 0, 0.30);
    }

    // ForEachVoice helper
    fn forEachVoice(self: *SynthEngine, comptime setter: fn (*Voice) void) void {
        for (&self.voices) |*v| {
            setter(v);
        }
    }
};
