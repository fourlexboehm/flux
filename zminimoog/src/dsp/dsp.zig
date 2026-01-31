// Minimoog Model D DSP Modules
// Wave Digital Filter implementations of Minimoog circuits
//
// Based on schematic analysis from Minimoog-schematics.pdf
//
// Board Layout:
//   Board 1: Oscillator Board (3 VCOs)
//   Board 2: Contour Generator and Keyboard Board (Envelopes, Glide)
//   Board 3: Power Supply and Noise Board (Voltage Regulators, Noise)
//   Board 4: Filter and VCA Board (Moog Ladder Filter, VCA)
//   Board 5: Rectifier Board (Power Supply)
//   Board 6: Octave Buffer Board (CV Buffers)
//   Front Panel: Wheels, Switches, Pots

const std = @import("std");

// ============================================================================
// Board 1: Oscillators
// ============================================================================
pub const board1_oscillators = @import("board1_oscillators.zig");

pub const VCO = board1_oscillators.VCO;
pub const OscillatorBank = board1_oscillators.OscillatorBank;
pub const OscillatorComponents = board1_oscillators.OscillatorComponents;
pub const Waveform = board1_oscillators.Waveform;
pub const OscOutputs = board1_oscillators.OscOutputs;

// ============================================================================
// Board 2: Envelope Generators and Glide
// ============================================================================
pub const board2_envelopes = @import("board2_envelopes.zig");

pub const ADSDEnvelope = board2_envelopes.ADSDEnvelope;
pub const Glide = board2_envelopes.Glide;
pub const Board2Contours = board2_envelopes.Board2Contours;
pub const EnvelopeComponents = board2_envelopes.EnvelopeComponents;
pub const EnvelopeStage = board2_envelopes.EnvelopeStage;
pub const ContourOutputs = board2_envelopes.ContourOutputs;

// ============================================================================
// Board 3: Noise Generator
// ============================================================================
pub const board3_noise = @import("board3_noise.zig");

pub const WhiteNoiseGenerator = board3_noise.WhiteNoiseGenerator;
pub const PinkNoiseFilter = board3_noise.PinkNoiseFilter;
pub const NoiseSource = board3_noise.NoiseSource;
pub const NoiseComponents = board3_noise.NoiseComponents;
pub const NoiseOutputs = board3_noise.NoiseOutputs;

// ============================================================================
// Board 4: Filter and VCA
// ============================================================================
pub const board4_filter_vca = @import("board4_filter_vca.zig");

pub const MoogLadderFilter = board4_filter_vca.MoogLadderFilter;
pub const VCA = board4_filter_vca.VCA;
pub const Board4FilterVCA = board4_filter_vca.Board4FilterVCA;
pub const FilterComponents = board4_filter_vca.FilterComponents;
pub const FilterOutputs = board4_filter_vca.FilterOutputs;

// ============================================================================
// Global Oversampler (for entire voice)
// ============================================================================
pub const oversampler = @import("oversampler.zig");

pub const GlobalOversampler = oversampler.GlobalOversampler;
pub const OversampleFactor = oversampler.OversampleFactor;

// ============================================================================
// Board 5: Rectifier/Power Supply
// ============================================================================
pub const board5_rectifier = @import("board5_rectifier.zig");

pub const Board5Rectifier = board5_rectifier.Board5Rectifier;
pub const HalfWaveRectifier = board5_rectifier.HalfWaveRectifier;
pub const FullWaveRailRectifier = board5_rectifier.FullWaveRailRectifier;
pub const RectifierComponents = board5_rectifier.ComponentValues;
pub const RailVoltages = board5_rectifier.RailVoltages;

// ============================================================================
// Front Panel: Wheels and Switches
// ============================================================================
pub const front_panel = @import("front_panel.zig");

pub const PitchWheel = front_panel.PitchWheel;
pub const ModWheel = front_panel.ModWheel;
pub const PanelSwitches = front_panel.PanelSwitches;
pub const FrontPanel = front_panel.FrontPanel;
pub const WheelOutputs = front_panel.WheelOutputs;
pub const GlideMode = front_panel.GlideMode;
pub const DecayMode = front_panel.DecayMode;
pub const OscRange = front_panel.OscRange;
pub const OscWaveformSwitch = front_panel.OscWaveformSwitch;
pub const NoiseType = front_panel.NoiseType;
pub const FilterKeyboardTracking = front_panel.FilterKeyboardTracking;

// ============================================================================
// Complete Minimoog Synthesizer
// ============================================================================

/// Complete Minimoog Model D synthesizer
/// Connects all boards together with proper signal routing
pub fn Minimoog(comptime T: type) type {
    return struct {
        // Boards
        oscillators: OscillatorBank(T), // Board 1
        contours: Board2Contours(T), // Board 2
        noise: NoiseSource(T), // Board 3
        board4: Board4FilterVCA(T), // Board 4 - Unified Filter + VCA

        // Front Panel
        panel: FrontPanel(T),

        // Sample rate
        sample_rate: T,

        // Mixer levels (from front panel pots)
        osc1_level: T = 1.0,
        osc2_level: T = 1.0,
        osc3_level: T = 1.0,
        noise_level: T = 0.0,
        external_level: T = 0.0,

        // Filter parameters (from front panel)
        filter_cutoff: T = 5000.0, // Hz
        filter_emphasis: T = 0.0, // Resonance (0 to ~4)
        filter_contour_amount: T = 0.5, // Envelope amount
        filter_mod_amount: T = 0.0, // Mod wheel to filter

        // Oscillator modulation
        osc_mod_amount: T = 0.0, // Mod wheel to oscillators (vibrato)

        // Current note state
        current_note_cv: T = 0.0,
        gate: bool = false,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            var self = Self{
                .oscillators = OscillatorBank(T).init(sample_rate),
                .contours = Board2Contours(T).init(sample_rate),
                .noise = NoiseSource(T).initWithSampleRate(sample_rate),
                .board4 = Board4FilterVCA(T).init(sample_rate),
                .panel = FrontPanel(T).init(),
                .sample_rate = sample_rate,
            };

            // Set up default Minimoog-style envelopes
            self.contours.filter_env.setADSD(0.001, 0.3, 0.0, 0.3);
            self.contours.loudness_env.setADSD(0.001, 0.1, 1.0, 0.3);

            return self;
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.oscillators.prepare(sample_rate);
            self.contours.prepare(sample_rate);
            self.noise.prepare(sample_rate);
            self.board4.prepare(sample_rate);
        }

        pub fn reset(self: *Self) void {
            self.oscillators.reset();
            self.contours.reset();
            self.noise.reset();
            self.board4.reset();
            self.panel.reset();
            self.gate = false;
        }

        /// Set digital anti-aliasing mode for oscillators
        /// - true: Use PolyBLEP/PolyBLAMP (for 1x, no oversampling)
        /// - false: Raw WDF output (for 2x/4x, oversampling handles aliasing)
        pub fn setDigitalAntialiasing(self: *Self, enabled: bool) void {
            self.oscillators.setDigitalAntialiasing(enabled);
        }

        // ====================================================================
        // Note Control
        // ====================================================================

        /// Note on with MIDI note number
        pub fn noteOn(self: *Self, midi_note: u8, velocity: T) void {
            // Convert MIDI note to 1V/octave CV (note 69 = A4 = 0V)
            self.current_note_cv = (@as(T, @floatFromInt(midi_note)) - 69.0) / 12.0;

            // Trigger envelopes
            self.contours.filter_env.noteOnVelocity(velocity);
            self.contours.loudness_env.noteOnVelocity(velocity);

            // Set glide target
            if (self.panel.switches.glide_mode == .on) {
                self.contours.glide.setTargetPitch(self.current_note_cv);
            } else {
                self.contours.glide.setPitchImmediate(self.current_note_cv);
            }

            self.gate = true;
        }

        /// Note off
        pub fn noteOff(self: *Self) void {
            self.contours.filter_env.noteOff();
            self.contours.loudness_env.noteOff();
            self.gate = false;
        }

        /// Check if voice is finished (for voice stealing)
        pub fn isFinished(self: *Self) bool {
            return self.contours.isFinished();
        }

        // ====================================================================
        // Parameter Control
        // ====================================================================

        /// Set filter cutoff frequency
        pub fn setFilterCutoff(self: *Self, freq_hz: T) void {
            self.filter_cutoff = std.math.clamp(freq_hz, 20.0, 20000.0);
        }

        /// Set filter emphasis (resonance)
        pub fn setFilterEmphasis(self: *Self, emphasis: T) void {
            self.filter_emphasis = std.math.clamp(emphasis, 0.0, 4.5);
            self.board4.setResonance(self.filter_emphasis);
        }

        /// Set filter contour (envelope) amount
        pub fn setFilterContourAmount(self: *Self, amount: T) void {
            self.filter_contour_amount = std.math.clamp(amount, 0.0, 1.0);
        }

        /// Set attack time for both envelopes
        pub fn setAttack(self: *Self, time_seconds: T) void {
            self.contours.filter_env.setAttack(time_seconds);
            self.contours.loudness_env.setAttack(time_seconds);
        }

        /// Set decay time
        pub fn setDecay(self: *Self, time_seconds: T) void {
            self.contours.filter_env.setDecay(time_seconds);
            self.contours.loudness_env.setDecay(time_seconds);
        }

        /// Set sustain level
        pub fn setSustain(self: *Self, level: T) void {
            self.contours.filter_env.setSustain(level);
            self.contours.loudness_env.setSustain(level);
        }

        /// Set release time
        pub fn setRelease(self: *Self, time_seconds: T) void {
            self.contours.filter_env.setRelease(time_seconds);
            self.contours.loudness_env.setRelease(time_seconds);
        }

        /// Set glide time
        pub fn setGlideTime(self: *Self, time_seconds: T) void {
            self.contours.glide.setGlideTime(time_seconds);
            self.panel.switches.glide_time = time_seconds;
        }

        /// Set oscillator mix levels
        pub fn setOscMix(self: *Self, osc1: T, osc2: T, osc3: T) void {
            self.osc1_level = std.math.clamp(osc1, 0.0, 1.0);
            self.osc2_level = std.math.clamp(osc2, 0.0, 1.0);
            self.osc3_level = std.math.clamp(osc3, 0.0, 1.0);
        }

        /// Set noise level
        pub fn setNoiseLevel(self: *Self, level: T) void {
            self.noise_level = std.math.clamp(level, 0.0, 1.0);
        }

        /// Set oscillator waveforms
        pub fn setOscWaveforms(self: *Self, osc1: Waveform, osc2: Waveform, osc3: Waveform) void {
            self.oscillators.osc1.setWaveform(osc1);
            self.oscillators.osc2.setWaveform(osc2);
            self.oscillators.osc3.setWaveform(osc3);
        }

        /// Set oscillator detune (osc2 and osc3 relative to osc1)
        pub fn setDetune(self: *Self, osc2_cents: T, osc3_cents: T) void {
            self.oscillators.osc2.setDetune(osc2_cents);
            self.oscillators.osc3.setDetune(osc3_cents);
        }

        // ====================================================================
        // Wheel Control
        // ====================================================================

        /// Set pitch wheel position (-1.0 to 1.0)
        pub fn setPitchWheel(self: *Self, position: T) void {
            self.panel.pitch_wheel.setPosition(position);
        }

        /// Set mod wheel position (0.0 to 1.0)
        pub fn setModWheel(self: *Self, position: T) void {
            self.panel.mod_wheel.setPosition(position);
        }

        // ====================================================================
        // Audio Processing
        // ====================================================================

        /// Process one sample
        pub inline fn processSample(self: *Self) T {
            // Process front panel wheels
            const wheels = self.panel.process();

            // Get envelope outputs
            const filter_env = self.contours.filter_env.processSample();
            const loudness_env = self.contours.loudness_env.processSample();

            // Get pitch with glide
            const glide_pitch = self.contours.glide.processSample();

            // Calculate final pitch CV (base + pitch wheel + vibrato)
            const mod_amount = wheels.mod_amount;
            const vibrato = if (self.osc_mod_amount > 0)
                self.getOsc3Mod() * mod_amount * self.osc_mod_amount
            else
                0.0;

            const final_pitch_cv = glide_pitch + wheels.pitch_bend_cv + vibrato;

            // Set oscillator frequencies
            self.oscillators.osc1.setCV(final_pitch_cv + @as(T, @floatFromInt(self.panel.switches.osc1_range.getOctaveOffset())));
            self.oscillators.osc2.setCV(final_pitch_cv + @as(T, @floatFromInt(self.panel.switches.osc2_range.getOctaveOffset())));

            // Osc 3: either keyboard controlled or free-running
            if (self.panel.switches.osc3_keyboard_control) {
                self.oscillators.osc3.setCV(final_pitch_cv + @as(T, @floatFromInt(self.panel.switches.osc3_range.getOctaveOffset())));
            }

            // Generate oscillator outputs
            const osc_outputs = self.oscillators.processSampleIndividual();

            // Mix oscillators
            var audio: T = 0.0;
            if (self.panel.switches.osc1_on) {
                audio += osc_outputs.osc1 * self.osc1_level;
            }
            if (self.panel.switches.osc2_on) {
                audio += osc_outputs.osc2 * self.osc2_level;
            }
            if (self.panel.switches.osc3_on and !self.panel.switches.osc3_to_filter and !self.panel.switches.osc3_to_osc) {
                audio += osc_outputs.osc3 * self.osc3_level;
            }

            // Add noise
            if (self.panel.switches.noise_on and self.noise_level > 0.0) {
                const noise_sample = switch (self.panel.switches.noise_type) {
                    .white => self.noise.processWhite(),
                    .pink => self.noise.processPink(),
                };
                audio += noise_sample * self.noise_level;
            }

            // Calculate filter cutoff with modulation
            var cutoff = self.filter_cutoff;

            // Filter envelope modulation
            cutoff += filter_env * self.filter_contour_amount * 10000.0;

            // Keyboard tracking
            const tracking = self.panel.switches.filter_keyboard_tracking.getAmount(T);
            cutoff += glide_pitch * tracking * 1000.0;

            // Mod wheel to filter
            if (self.filter_mod_amount > 0.0) {
                cutoff += self.getOsc3Mod() * mod_amount * self.filter_mod_amount * 5000.0;
            }

            // Osc 3 to filter (when switch enabled)
            if (self.panel.switches.osc3_to_filter) {
                cutoff += osc_outputs.osc3 * 2000.0;
            }

            // Set Board 4 parameters
            self.board4.setCutoff(std.math.clamp(cutoff, 20.0, 20000.0));
            self.board4.setAmplitude(loudness_env);

            // Process through unified Board 4 (Filter -> VCA as one circuit)
            const output = self.board4.processSample(audio);

            // Apply master volume
            return output * self.panel.master_volume;
        }

        /// Get Osc 3 output for modulation (normalized)
        fn getOsc3Mod(self: *Self) T {
            // Use the last osc3 sample value for modulation
            // This gives LFO-like behavior when osc3 is set to low range
            return self.oscillators.osc3.processSample();
        }
    };
}

// ============================================================================
// Legacy Voice Type (Simpler interface)
// ============================================================================

/// Simple Minimoog voice (legacy interface)
pub fn MinimoogVoice(comptime T: type) type {
    return struct {
        synth: Minimoog(T),

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            return .{
                .synth = Minimoog(T).init(sample_rate),
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.synth.prepare(sample_rate);
        }

        pub fn reset(self: *Self) void {
            self.synth.reset();
        }

        pub fn noteOn(self: *Self, pitch_cv: T) void {
            // Convert CV to MIDI note (0V = note 69 = A4)
            const midi_note: u8 = @intFromFloat(std.math.clamp(pitch_cv * 12.0 + 69.0, 0.0, 127.0));
            self.synth.noteOn(midi_note, 1.0);
        }

        pub fn noteOff(self: *Self) void {
            self.synth.noteOff();
        }

        pub fn isFinished(self: *Self) bool {
            return self.synth.isFinished();
        }

        pub fn setCutoff(self: *Self, freq_hz: T) void {
            self.synth.setFilterCutoff(freq_hz);
        }

        pub fn setResonance(self: *Self, res: T) void {
            self.synth.setFilterEmphasis(res);
        }

        pub inline fn processSample(self: *Self) T {
            return self.synth.processSample();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "minimoog produces output" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var synth = Minimoog(T).init(sample_rate);

    // Play a note
    synth.noteOn(69, 1.0); // A4

    // Process some samples
    var max_output: T = 0.0;
    for (0..1000) |_| {
        const sample = @abs(synth.processSample());
        max_output = @max(max_output, sample);
    }

    // Should produce audio
    try std.testing.expect(max_output > 0.01);
}

test "minimoog responds to note off" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var synth = Minimoog(T).init(sample_rate);
    synth.setRelease(0.01); // Fast release

    synth.noteOn(69, 1.0);

    // Let attack/decay happen
    for (0..2000) |_| {
        _ = synth.processSample();
    }

    synth.noteOff();

    // Process release
    for (0..5000) |_| {
        _ = synth.processSample();
    }

    // Should be finished
    try std.testing.expect(synth.isFinished());
}

test "minimoog pitch wheel affects pitch" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var synth = Minimoog(T).init(sample_rate);
    synth.noteOn(69, 1.0);

    // Warm up
    for (0..100) |_| {
        _ = synth.processSample();
    }

    // Get baseline frequency (by counting zero crossings)
    var crossings_baseline: usize = 0;
    var prev: T = 0.0;
    for (0..1000) |_| {
        const sample = synth.processSample();
        if (prev < 0 and sample >= 0) crossings_baseline += 1;
        prev = sample;
    }

    // Apply pitch bend up
    synth.setPitchWheel(1.0);

    // Let it settle
    for (0..100) |_| {
        _ = synth.processSample();
    }

    // Count crossings with pitch bend
    var crossings_bent: usize = 0;
    prev = 0.0;
    for (0..1000) |_| {
        const sample = synth.processSample();
        if (prev < 0 and sample >= 0) crossings_bent += 1;
        prev = sample;
    }

    // Bent pitch should be higher (more crossings)
    try std.testing.expect(crossings_bent > crossings_baseline);
}
