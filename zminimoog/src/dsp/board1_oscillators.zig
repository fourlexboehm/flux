// Board 1: Oscillator Board
// Minimoog Model D - Three Voltage Controlled Oscillators
//
// Schematic page 2 of Minimoog-schematics.pdf
//
// VCO 1, 2, 3: Sawtooth core oscillators
//   - Exponential converter (CA3046 transistor array) for 1V/octave tracking
//   - Integrating capacitor (0.01uF) for sawtooth generation
//   - Waveform outputs: Sawtooth, Triangle, Square (via shapers)

const std = @import("std");

// ============================================================================
// Component Values from Schematic
// ============================================================================

pub const OscillatorComponents = struct {
    // Core capacitor value
    pub const core_cap: comptime_float = 0.01e-6; // 0.01uF integrating capacitor

    // Exponential converter thermal voltage
    pub const vt: comptime_float = 25.85e-3; // 25.85mV at 25°C

    // Reference current for exponential converter
    pub const i_ref: comptime_float = 1.0e-6; // ~1µA reference

    // Default base frequency (A4 = 440Hz at 0V CV)
    pub const base_frequency: comptime_float = 440.0;

    // Octave range (Minimoog has -2 to +2 octaves from base)
    pub const octave_range_low: comptime_float = -2.0;
    pub const octave_range_high: comptime_float = 2.0;
};

// ============================================================================
// Waveform Types
// ============================================================================

pub const Waveform = enum {
    sawtooth,
    triangle,
    square,
    pulse, // Variable pulse width
};

// ============================================================================
// Band-Limited Oscillator (PolyBLEP)
// ============================================================================

/// Minimoog-style VCO with band-limited waveforms
/// Uses PolyBLEP for anti-aliasing
pub fn VCO(comptime T: type) type {
    return struct {
        phase: T = 0.0,
        phase_increment: T = 0.0,
        frequency: T = OscillatorComponents.base_frequency,
        sample_rate: T,
        waveform: Waveform = .sawtooth,
        pulse_width: T = 0.5, // For pulse wave (0.0 to 1.0)

        // Detune in cents (-100 to +100 typical)
        detune_cents: T = 0.0,

        // Octave offset (-2 to +2)
        octave_offset: i8 = 0,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            var self = Self{
                .sample_rate = sample_rate,
            };
            self.updatePhaseIncrement();
            return self;
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.updatePhaseIncrement();
        }

        pub fn reset(self: *Self) void {
            self.phase = 0.0;
        }

        /// Set frequency directly in Hz
        pub fn setFrequency(self: *Self, freq_hz: T) void {
            self.frequency = @max(0.1, @min(freq_hz, self.sample_rate * 0.45)); // Nyquist limit
            self.updatePhaseIncrement();
        }

        /// Set frequency via MIDI note number (69 = A4 = 440Hz)
        pub fn setMidiNote(self: *Self, note: T) void {
            const freq = 440.0 * std.math.pow(T, 2.0, (note - 69.0) / 12.0);
            self.setFrequency(freq);
        }

        /// Set frequency via 1V/octave CV (0V = base frequency)
        pub fn setCV(self: *Self, cv_volts: T) void {
            const octave_shift = cv_volts + @as(T, @floatFromInt(self.octave_offset));
            const freq = OscillatorComponents.base_frequency * std.math.pow(T, 2.0, octave_shift);
            self.setFrequency(freq);
        }

        /// Set detune in cents
        pub fn setDetune(self: *Self, cents: T) void {
            self.detune_cents = cents;
            self.updatePhaseIncrement();
        }

        /// Set octave offset (-2 to +2)
        pub fn setOctave(self: *Self, octave: i8) void {
            self.octave_offset = std.math.clamp(octave, -2, 2);
        }

        /// Set waveform type
        pub fn setWaveform(self: *Self, wf: Waveform) void {
            self.waveform = wf;
        }

        /// Set pulse width (0.0 to 1.0, only affects pulse waveform)
        pub fn setPulseWidth(self: *Self, pw: T) void {
            self.pulse_width = @max(0.01, @min(0.99, pw));
        }

        fn updatePhaseIncrement(self: *Self) void {
            // Apply detune
            const detune_factor = std.math.pow(T, 2.0, self.detune_cents / 1200.0);
            const final_freq = self.frequency * detune_factor;
            self.phase_increment = final_freq / self.sample_rate;
        }

        /// Generate one sample
        pub inline fn processSample(self: *Self) T {
            const output = switch (self.waveform) {
                .sawtooth => self.generateSaw(),
                .triangle => self.generateTriangle(),
                .square => self.generateSquare(),
                .pulse => self.generatePulse(),
            };

            // Advance phase
            self.phase += self.phase_increment;
            if (self.phase >= 1.0) {
                self.phase -= 1.0;
            }

            return output;
        }

        // PolyBLEP correction for discontinuities
        fn polyBlep(self: *Self, t: T) T {
            const dt = self.phase_increment;
            if (t < dt) {
                // t is in [0, dt)
                const t_norm = t / dt;
                return t_norm + t_norm - t_norm * t_norm - 1.0;
            } else if (t > 1.0 - dt) {
                // t is in (1-dt, 1]
                const t_norm = (t - 1.0) / dt;
                return t_norm * t_norm + t_norm + t_norm + 1.0;
            }
            return 0.0;
        }

        fn generateSaw(self: *Self) T {
            // Naive sawtooth: 2*phase - 1 (range -1 to 1)
            var output = 2.0 * self.phase - 1.0;
            // Apply PolyBLEP at discontinuity (phase = 0/1)
            output -= self.polyBlep(self.phase);
            return output;
        }

        fn generateSquare(self: *Self) T {
            return self.generatePulseInternal(0.5);
        }

        fn generatePulse(self: *Self) T {
            return self.generatePulseInternal(self.pulse_width);
        }

        fn generatePulseInternal(self: *Self, pw: T) T {
            // Naive pulse
            var output: T = if (self.phase < pw) 1.0 else -1.0;
            // Apply PolyBLEP at both edges
            output += self.polyBlep(self.phase);
            output -= self.polyBlep(@mod(self.phase + (1.0 - pw), 1.0));
            return output;
        }

        fn generateTriangle(self: *Self) T {
            // Triangle from integrated square wave
            // Using phase directly for a triangle
            if (self.phase < 0.5) {
                return 4.0 * self.phase - 1.0;
            } else {
                return 3.0 - 4.0 * self.phase;
            }
        }
    };
}

// ============================================================================
// Complete Oscillator Bank (3 VCOs)
// ============================================================================

/// Minimoog 3-oscillator bank
pub fn OscillatorBank(comptime T: type) type {
    return struct {
        osc1: VCO(T),
        osc2: VCO(T),
        osc3: VCO(T),

        // Individual mix levels (0.0 to 1.0)
        osc1_level: T = 1.0,
        osc2_level: T = 1.0,
        osc3_level: T = 1.0,

        // Osc 3 as LFO mode
        osc3_lfo_mode: bool = false,

        sample_rate: T,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            return .{
                .osc1 = VCO(T).init(sample_rate),
                .osc2 = VCO(T).init(sample_rate),
                .osc3 = VCO(T).init(sample_rate),
                .sample_rate = sample_rate,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.osc1.prepare(sample_rate);
            self.osc2.prepare(sample_rate);
            self.osc3.prepare(sample_rate);
        }

        pub fn reset(self: *Self) void {
            self.osc1.reset();
            self.osc2.reset();
            self.osc3.reset();
        }

        /// Set all oscillators to same base frequency (1V/oct CV)
        pub fn setCV(self: *Self, cv_volts: T) void {
            self.osc1.setCV(cv_volts);
            self.osc2.setCV(cv_volts);
            if (!self.osc3_lfo_mode) {
                self.osc3.setCV(cv_volts);
            }
        }

        /// Set Osc 3 frequency directly (for LFO mode)
        pub fn setOsc3Frequency(self: *Self, freq_hz: T) void {
            self.osc3.setFrequency(freq_hz);
        }

        /// Set mix levels
        pub fn setMix(self: *Self, osc1: T, osc2: T, osc3: T) void {
            self.osc1_level = @max(0.0, @min(1.0, osc1));
            self.osc2_level = @max(0.0, @min(1.0, osc2));
            self.osc3_level = @max(0.0, @min(1.0, osc3));
        }

        /// Generate mixed output from all oscillators
        pub inline fn processSample(self: *Self) T {
            const s1 = self.osc1.processSample() * self.osc1_level;
            const s2 = self.osc2.processSample() * self.osc2_level;
            const s3 = self.osc3.processSample() * self.osc3_level;

            // Mix with scaling to prevent clipping
            const mix = (s1 + s2 + s3) * 0.33;
            return mix;
        }

        /// Generate individual outputs (for external mixing)
        pub fn processSampleIndividual(self: *Self) OscOutputs(T) {
            return .{
                .osc1 = self.osc1.processSample(),
                .osc2 = self.osc2.processSample(),
                .osc3 = self.osc3.processSample(),
            };
        }

        /// Get Osc 3 output for modulation (LFO usage)
        pub fn getModulation(self: *Self) T {
            // Return Osc 3 value without advancing (peek)
            // For modulation, call processSample on osc3 separately
            return self.osc3.processSample();
        }
    };
}

pub fn OscOutputs(comptime T: type) type {
    return struct {
        osc1: T,
        osc2: T,
        osc3: T,
    };
}

// ============================================================================
// Tests
// ============================================================================

fn expectApproxEq(actual: f64, expected: f64, tolerance: f64) !void {
    if (@abs(actual - expected) >= tolerance) {
        std.debug.print("Expected: {d}, Actual: {d}, Diff: {d}\n", .{ expected, actual, actual - expected });
        return error.TestExpectedApproxEq;
    }
}

test "vco generates output" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var vco = VCO(T).init(sample_rate);
    vco.setFrequency(440.0);

    // Generate some samples
    var has_positive = false;
    var has_negative = false;
    for (0..1000) |_| {
        const sample = vco.processSample();
        if (sample > 0.1) has_positive = true;
        if (sample < -0.1) has_negative = true;
    }

    // Should oscillate between positive and negative
    try std.testing.expect(has_positive);
    try std.testing.expect(has_negative);
}

test "vco frequency scaling" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var vco = VCO(T).init(sample_rate);

    // Test 1V/octave: +1V should double frequency
    vco.setCV(0.0);
    const freq_0v = vco.frequency;

    vco.setCV(1.0);
    const freq_1v = vco.frequency;

    // Should be approximately double
    try expectApproxEq(freq_1v / freq_0v, 2.0, 0.01);
}

test "vco waveforms produce different outputs" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var vco = VCO(T).init(sample_rate);
    vco.setFrequency(100.0);

    // Collect samples for each waveform
    var sum_saw: T = 0.0;
    var sum_square: T = 0.0;

    vco.setWaveform(.sawtooth);
    for (0..1000) |_| {
        sum_saw += @abs(vco.processSample());
    }

    vco.reset();
    vco.setWaveform(.square);
    for (0..1000) |_| {
        sum_square += @abs(vco.processSample());
    }

    // Square wave should have higher average absolute value than sawtooth
    try std.testing.expect(sum_square > sum_saw);
}

test "oscillator bank mixes three oscillators" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var bank = OscillatorBank(T).init(sample_rate);
    bank.setCV(0.0);
    bank.setMix(1.0, 1.0, 1.0);

    // Should produce output
    var max_output: T = 0.0;
    for (0..1000) |_| {
        const sample = @abs(bank.processSample());
        max_output = @max(max_output, sample);
    }

    try std.testing.expect(max_output > 0.1);
}
