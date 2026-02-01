// Board 1: Oscillator Board
// Minimoog Model D - Three Voltage Controlled Oscillators
//
// Schematic page 2 of Minimoog-schematics.pdf
//
// VCO 1, 2, 3: Sawtooth core oscillators
//   - Exponential converter (CA3046 transistor array) for 1V/octave tracking
//   - Integrating capacitor (0.01µF) for sawtooth generation
//   - Comparator/transistor switch (Q1: 2N3392) for capacitor reset
//
// WDF Model:
//   The sawtooth core is modeled as a current source charging a capacitor.
//   The current magnitude determines frequency (I = C * dV/dt).
//   Reset is handled by detecting threshold crossing and resetting capacitor state.
//
// Anti-Aliasing Options:
//   - None: Raw WDF output (will alias)
//   - PolyBLEP: Polynomial bandlimited step correction (efficient, good quality)
//   - Oversampling: Process at higher rate, lowpass filter, decimate (pure, CPU intensive)

const std = @import("std");
const wdft = @import("wdf");

// ============================================================================
// Component Values from Schematic
// ============================================================================

pub const OscillatorComponents = struct {
    // Core integrating capacitor (C2 on schematic)
    pub const core_cap: comptime_float = 0.01e-6; // 0.01µF precision capacitor

    // Exponential converter thermal voltage (CA3046 at 25°C)
    pub const vt: comptime_float = 25.85e-3; // 25.85mV

    // Source resistance for WDF model (affects circuit impedance)
    pub const source_resistance: comptime_float = 1000.0; // 1k

    // Sawtooth voltage swing (typical Minimoog levels)
    pub const saw_high: comptime_float = 5.0; // +5V peak
    pub const saw_low: comptime_float = -5.0; // -5V peak

    // Default base frequency (A4 = 440Hz at 0V CV)
    pub const base_frequency: comptime_float = 440.0;

    // Octave range (Minimoog has -2 to +2 octaves from base)
    pub const octave_range_low: comptime_float = -2.0;
    pub const octave_range_high: comptime_float = 2.0;
};

// ============================================================================
// Anti-Aliasing Configuration
// ============================================================================

pub const AntiAliasMode = enum {
    polyBlep, // PolyBLEP correction (efficient, applied to WDF output)
    oversample2x, // 2x oversampling
    oversample4x, // 4x oversampling (best quality, default)
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
// Oversampler (Generic)
// ============================================================================

/// Generic oversampler with half-band lowpass filter for decimation
/// Can be used to wrap oscillators or entire signal chains
pub fn Oversampler(comptime T: type, comptime factor: comptime_int) type {
    comptime if (factor != 2 and factor != 4) @compileError("Oversampling factor must be 2 or 4");

    return struct {
        // Half-band filter coefficients (optimized for oversampling)
        // Using a simple but effective 7-tap half-band filter
        filter_state: [7]T = [_]T{0.0} ** 7,
        output_accumulator: T = 0.0,

        const Self = @This();

        // Half-band filter coefficients (symmetric, every other coef is 0 except center)
        // This allows efficient implementation
        const coeffs = if (factor == 2)
            [_]T{ 0.0625, 0.25, 0.375, 0.25, 0.0625, 0.0, 0.0 }
        else
            // For 4x, we use a steeper filter
            [_]T{ 0.03125, 0.125, 0.21875, 0.25, 0.21875, 0.125, 0.03125 };

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.filter_state = [_]T{0.0} ** 7;
            self.output_accumulator = 0.0;
        }

        /// Process multiple oversampled inputs and return decimated output
        pub fn processAndDecimate(self: *Self, samples: [factor]T) T {
            var result: T = 0.0;

            // Process each oversampled sample through the filter
            for (samples) |sample| {
                // Shift filter state
                var i: usize = 6;
                while (i > 0) : (i -= 1) {
                    self.filter_state[i] = self.filter_state[i - 1];
                }
                self.filter_state[0] = sample;

                // Apply filter (only compute output for last sample in group)
            }

            // Compute filtered output
            for (coeffs, 0..) |coef, i| {
                result += coef * self.filter_state[i];
            }

            return result;
        }
    };
}

// ============================================================================
// PolyBLEP Anti-Aliasing
// ============================================================================

/// PolyBLEP (Polynomial Bandlimited Step) correction
/// Smooths discontinuities in waveforms to reduce aliasing
pub fn PolyBLEP(comptime T: type) type {
    return struct {
        /// Calculate PolyBLEP correction for a discontinuity
        /// t: normalized position within the current sample (0 to 1)
        /// dt: phase increment (frequency / sample_rate)
        pub inline fn correction(t: T, dt: T) T {
            if (t < dt) {
                // Discontinuity is in current sample
                const t_norm = t / dt;
                return t_norm + t_norm - t_norm * t_norm - 1.0;
            } else if (t > 1.0 - dt) {
                // Discontinuity is in previous sample
                const t_norm = (t - 1.0) / dt;
                return t_norm * t_norm + t_norm + t_norm + 1.0;
            }
            return 0.0;
        }

        /// Apply PolyBLEP to a sawtooth wave
        /// phase: current phase (0 to 1)
        /// dt: phase increment
        /// raw_saw: naive sawtooth value (-1 to 1)
        pub inline fn sawtoothCorrection(phase: T, dt: T, raw_saw: T) T {
            return raw_saw - correction(phase, dt);
        }

        /// Apply PolyBLEP to a square/pulse wave
        /// phase: current phase (0 to 1)
        /// dt: phase increment
        /// pw: pulse width (0 to 1)
        /// raw_pulse: naive pulse value (-1 or 1)
        pub inline fn pulseCorrection(phase: T, dt: T, pw: T, raw_pulse: T) T {
            var output = raw_pulse;
            // Correction at rising edge (phase = 0)
            output += correction(phase, dt);
            // Correction at falling edge (phase = pw)
            output -= correction(@mod(phase + (1.0 - pw), 1.0), dt);
            return output;
        }
    };
}

// ============================================================================
// PolyBLAMP Anti-Aliasing for Triangle Waves
// ============================================================================

/// PolyBLAMP (Polynomial Bandlimited Ramp) correction
/// Smooths slope discontinuities (corners) in triangle waves
pub fn PolyBLAMP(comptime T: type) type {
    return struct {
        /// Calculate PolyBLAMP correction for a slope discontinuity (corner)
        /// t: normalized position within the current sample (0 to 1)
        /// dt: phase increment (frequency / sample_rate)
        /// scale: slope change magnitude (typically 4.0 for triangle going from +2 to -2)
        pub inline fn correction(t: T, dt: T, scale: T) T {
            // PolyBLAMP is the integral of PolyBLEP
            if (t < dt) {
                const t_norm = t / dt;
                const t2 = t_norm * t_norm;
                const t3 = t2 * t_norm;
                const t4 = t3 * t_norm;
                return scale * dt * (t4 / 4.0 - t3 / 3.0);
            } else if (t > 1.0 - dt) {
                const t_norm = (t - 1.0) / dt + 1.0;
                const t2 = t_norm * t_norm;
                const t3 = t2 * t_norm;
                const t4 = t3 * t_norm;
                return scale * dt * (t4 / 4.0 + t3 / 3.0 - t_norm);
            }
            return 0.0;
        }

        /// Apply PolyBLAMP to a triangle wave
        /// phase: current phase (0 to 1)
        /// dt: phase increment
        /// raw_tri: naive triangle value (-1 to 1)
        pub inline fn triangleCorrection(phase: T, dt: T, raw_tri: T) T {
            var output = raw_tri;
            // Triangle has corners at phase 0 (bottom) and 0.5 (top)
            // Slope changes from +4 to -4 at phase 0.5, and -4 to +4 at phase 0/1
            const slope_change: T = 4.0; // Going from slope +2 to -2 (or vice versa)

            // Corner at phase 0.5 (peak)
            const phase_from_peak = @mod(phase + 0.5, 1.0);
            output -= correction(phase_from_peak, dt, slope_change);

            // Corner at phase 0/1 (trough)
            output += correction(phase, dt, slope_change);

            return output;
        }
    };
}

// ============================================================================
// WDF-Based VCO (Sawtooth Core)
// ============================================================================

/// Minimoog-style VCO using Wave Digital Filter circuit modeling
///
/// Circuit model:
///   Current Source --+-- Capacitor --+-- GND
///                    |               |
///                    +-- (output)    |
///                                    |
///   Reset switch closes when V_cap reaches threshold
///
/// The charging current is set to achieve the desired frequency:
///   I = C * (V_high - V_low) * f
pub fn VCO(comptime T: type) type {
    // WDF circuit topology: IdealCurrentSource driving a Capacitor
    // The current source models the exponential converter output
    // IdealCurrentSource is the root that drives wave scattering
    const C = wdft.Capacitor(T);
    const ICS = wdft.IdealCurrentSource(T, C);

    return struct {
        circuit: ICS,

        frequency: T = OscillatorComponents.base_frequency,
        sample_rate: T,
        internal_sample_rate: T, // May differ from sample_rate when oversampling
        waveform: Waveform = .sawtooth,
        pulse_width: T = 0.5, // For pulse wave (0.0 to 1.0)

        // Anti-aliasing mode
        anti_alias: AntiAliasMode = .polyBlep,

        // Detune in cents (-100 to +100 typical)
        detune_cents: T = 0.0,

        // Octave offset (-2 to +2)
        octave_offset: i8 = 0,

        // Phase tracking (for waveform shaping and PolyBLEP)
        phase: T = 0.0,
        phase_increment: T = 0.0,

        // Charging current (determines frequency)
        charge_current: T = 0.0,

        // Track reset for PolyBLEP
        reset_occurred: bool = false,
        reset_phase: T = 0.0, // Phase at which reset occurred

        // Oversamplers
        oversampler_2x: Oversampler(T, 2) = Oversampler(T, 2).init(),
        oversampler_4x: Oversampler(T, 4) = Oversampler(T, 4).init(),

        const Self = @This();

        const voltage_swing: T = OscillatorComponents.saw_high - OscillatorComponents.saw_low;

        pub fn init(sample_rate: T) Self {
            var self = Self{
                .circuit = ICS.init(C.init(OscillatorComponents.core_cap, sample_rate)),
                .sample_rate = sample_rate,
                .internal_sample_rate = sample_rate,
            };
            self.updatePhaseIncrement();
            return self;
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.updateInternalSampleRate();
            self.circuit.next.prepare(self.internal_sample_rate);
            self.circuit.calcImpedance();
            self.updatePhaseIncrement();
        }

        pub fn reset(self: *Self) void {
            self.phase = 0.0;
            self.circuit.next.reset();
            self.oversampler_2x.reset();
            self.oversampler_4x.reset();
            self.reset_occurred = false;
        }

        /// Set anti-aliasing mode
        pub fn setAntiAliasMode(self: *Self, mode: AntiAliasMode) void {
            self.anti_alias = mode;
            self.updateInternalSampleRate();
            self.circuit.next.prepare(self.internal_sample_rate);
            self.circuit.calcImpedance();
            self.updatePhaseIncrement();
        }

        fn updateInternalSampleRate(self: *Self) void {
            self.internal_sample_rate = switch (self.anti_alias) {
                .polyBlep => self.sample_rate,
                .oversample2x => self.sample_rate * 2.0,
                .oversample4x => self.sample_rate * 4.0,
            };
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

            // Phase increment based on internal (possibly oversampled) rate
            self.phase_increment = final_freq / self.internal_sample_rate;

            // Calculate charging current for desired frequency
            // From I = C * dV/dt, and we need full swing in one period:
            // I = C * voltage_swing * frequency
            self.charge_current = OscillatorComponents.core_cap * voltage_swing * final_freq;
            self.circuit.setCurrent(self.charge_current);
        }

        /// Generate one sample (handles anti-aliasing internally)
        pub inline fn processSample(self: *Self) T {
            return switch (self.anti_alias) {
                .polyBlep => self.processSampleWithPolyBLEP(),
                .oversample2x => self.processSampleOversampled2x(),
                .oversample4x => self.processSampleOversampled4x(),
            };
        }

        /// Raw WDF processing (no anti-aliasing)
        fn processSampleInternal(self: *Self) T {
            // Process WDF circuit - IdealCurrentSource drives the wave scattering
            self.circuit.process();

            // Read capacitor voltage (this is our sawtooth core)
            const cap_voltage = wdft.voltage(T, &self.circuit.next.wdf);

            // Check for reset threshold (models comparator + discharge transistor)
            self.reset_occurred = false;
            if (cap_voltage >= OscillatorComponents.saw_high) {
                // Reset capacitor state - models the fast discharge through Q1
                self.circuit.next.z = OscillatorComponents.saw_low * 2.0; // WDF state
                self.reset_occurred = true;
                self.reset_phase = self.phase;
                self.phase = 0.0;
            }

            // Advance phase (for derived waveforms)
            self.phase += self.phase_increment;
            if (self.phase >= 1.0) {
                self.phase -= 1.0;
            }

            // Generate output waveform
            const output = switch (self.waveform) {
                .sawtooth => self.generateSaw(cap_voltage),
                .triangle => self.generateTriangle(cap_voltage),
                .square => self.generateSquare(),
                .pulse => self.generatePulse(),
            };

            return output;
        }

        /// WDF processing with PolyBLEP anti-aliasing
        fn processSampleWithPolyBLEP(self: *Self) T {
            const raw = self.processSampleInternal();

            // Apply PolyBLEP correction based on waveform
            return switch (self.waveform) {
                .sawtooth => blk: {
                    var output = raw;
                    // Apply correction at reset discontinuity
                    if (self.reset_occurred) {
                        output -= PolyBLEP(T).correction(self.phase, self.phase_increment) * 2.0;
                    }
                    break :blk output;
                },
                .triangle => PolyBLAMP(T).triangleCorrection(self.phase, self.phase_increment, raw),
                .square => PolyBLEP(T).pulseCorrection(self.phase, self.phase_increment, 0.5, raw),
                .pulse => PolyBLEP(T).pulseCorrection(self.phase, self.phase_increment, self.pulse_width, raw),
            };
        }

        /// 2x oversampled processing
        fn processSampleOversampled2x(self: *Self) T {
            var samples: [2]T = undefined;
            for (&samples) |*s| {
                s.* = self.processSampleInternal();
            }
            return self.oversampler_2x.processAndDecimate(samples);
        }

        /// 4x oversampled processing
        fn processSampleOversampled4x(self: *Self) T {
            var samples: [4]T = undefined;
            for (&samples) |*s| {
                s.* = self.processSampleInternal();
            }
            return self.oversampler_4x.processAndDecimate(samples);
        }

        /// Sawtooth: normalized capacitor voltage
        fn generateSaw(self: *Self, cap_voltage: T) T {
            _ = self;
            // Normalize from [saw_low, saw_high] to [-1, +1]
            const normalized = (cap_voltage - OscillatorComponents.saw_low) / voltage_swing;
            return normalized * 2.0 - 1.0;
        }

        /// Triangle: fold the sawtooth
        fn generateTriangle(self: *Self, cap_voltage: T) T {
            const saw = self.generateSaw(cap_voltage);
            // Fold: abs(saw) gives 0->1->0, then scale to -1->1->-1
            return @abs(saw) * 2.0 - 1.0;
        }

        /// Square: comparator on phase
        fn generateSquare(self: *Self) T {
            return self.generatePulseInternal(0.5);
        }

        /// Pulse: variable duty cycle
        fn generatePulse(self: *Self) T {
            return self.generatePulseInternal(self.pulse_width);
        }

        fn generatePulseInternal(self: *Self, pw: T) T {
            return if (self.phase < pw) @as(T, 1.0) else @as(T, -1.0);
        }
    };
}

// ============================================================================
// Complete Oscillator Bank (3 VCOs) with Analog Summing
// ============================================================================

/// Minimoog 3-oscillator bank with WDF-based analog summing
pub fn OscillatorBank(comptime T: type) type {
    // Analog summing circuit: three resistors meeting at a virtual ground
    // Each oscillator output goes through a mixing resistor
    const Rmix = wdft.Resistor(T);
    const S12 = wdft.Series(T, Rmix, Rmix);
    const S123 = wdft.Series(T, S12, Rmix);

    return struct {
        osc1: VCO(T),
        osc2: VCO(T),
        osc3: VCO(T),

        // Mixing circuit (resistor summing network)
        mix_circuit: S123,

        // Individual mix levels (0.0 to 1.0)
        osc1_level: T = 1.0,
        osc2_level: T = 1.0,
        osc3_level: T = 1.0,

        // Osc 3 as LFO mode
        osc3_lfo_mode: bool = false,

        // Analog summing characteristics
        drive: T = 1.0, // Input drive (affects saturation)

        sample_rate: T,

        const Self = @This();

        // Mixing resistor value (10k typical for Minimoog mixer)
        const mix_resistance: T = 10000.0;

        pub fn init(sample_rate: T) Self {
            return .{
                .osc1 = VCO(T).init(sample_rate),
                .osc2 = VCO(T).init(sample_rate),
                .osc3 = VCO(T).init(sample_rate),
                .mix_circuit = S123.init(
                    S12.init(
                        Rmix.init(mix_resistance),
                        Rmix.init(mix_resistance),
                    ),
                    Rmix.init(mix_resistance),
                ),
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

        /// Set anti-aliasing mode for all oscillators
        pub fn setAntiAliasMode(self: *Self, mode: AntiAliasMode) void {
            self.osc1.setAntiAliasMode(mode);
            self.osc2.setAntiAliasMode(mode);
            self.osc3.setAntiAliasMode(mode);
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

        /// Set drive amount (affects analog saturation character)
        pub fn setDrive(self: *Self, d: T) void {
            self.drive = @max(0.1, @min(4.0, d));
        }

        /// Generate mixed output with analog summing emulation
        pub inline fn processSample(self: *Self) T {
            const s1 = self.osc1.processSample() * self.osc1_level;
            const s2 = self.osc2.processSample() * self.osc2_level;
            const s3 = self.osc3.processSample() * self.osc3_level;

            // Apply drive before summing
            const driven_sum = (s1 + s2 + s3) * self.drive;

            // Analog summing with soft saturation (tanh-like op-amp behavior)
            // This models the summing amplifier's nonlinear headroom
            const mix = analogSaturate(driven_sum * 0.33);

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
            return self.osc3.processSample();
        }

        /// Analog saturation curve (models op-amp soft clipping)
        pub fn analogSaturate(x: T) T {
            // Soft saturation using tanh approximation
            // More efficient than std.math.tanh for real-time use
            const x2 = x * x;
            const x3 = x2 * x;
            const x5 = x3 * x2;
            // Pade approximation of tanh
            return x * (1.0 + x2 * 0.0833333) / (1.0 + x2 * 0.416667 + x5 * 0.0083333);
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
// Synth-Wide Oversampler (for entire signal chain)
// ============================================================================

/// Wrapper for oversampling an entire signal processing chain
/// Use this when you want to oversample filter + mixer saturation too
pub fn SynthOversampler(comptime T: type, comptime factor: comptime_int) type {
    comptime if (factor != 2 and factor != 4) @compileError("Factor must be 2 or 4");

    return struct {
        oversampler: Oversampler(T, factor),
        internal_sample_rate: T,
        output_sample_rate: T,

        const Self = @This();

        pub fn init(output_sample_rate: T) Self {
            return .{
                .oversampler = Oversampler(T, factor).init(),
                .internal_sample_rate = output_sample_rate * @as(T, @floatFromInt(factor)),
                .output_sample_rate = output_sample_rate,
            };
        }

        pub fn reset(self: *Self) void {
            self.oversampler.reset();
        }

        /// Get the sample rate that internal processing should use
        pub fn getInternalSampleRate(self: *Self) T {
            return self.internal_sample_rate;
        }

        /// Call this once per output sample with `factor` internal samples
        pub fn processAndDecimate(self: *Self, samples: [factor]T) T {
            return self.oversampler.processAndDecimate(samples);
        }
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
    vco.setAntiAliasMode(.polyBlep); // Use lightweight mode for consistent comparison

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

test "vco anti-alias modes work" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var vco = VCO(T).init(sample_rate);
    vco.setFrequency(1000.0);

    // Test each mode produces output
    const modes = [_]AntiAliasMode{ .polyBlep, .oversample2x, .oversample4x };
    for (modes) |mode| {
        vco.setAntiAliasMode(mode);
        vco.reset();

        var has_output = false;
        for (0..500) |_| {
            const sample = vco.processSample();
            if (@abs(sample) > 0.1) has_output = true;
        }
        try std.testing.expect(has_output);
    }
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

test "analog saturation soft clips" {
    const T = f64;

    // Test that saturation function limits output
    const saturated = OscillatorBank(T).analogSaturate(10.0);

    // Should be less than input (soft clipped)
    try std.testing.expect(saturated < 10.0);
    // Should be positive
    try std.testing.expect(saturated > 0.0);
    // tanh(10) ≈ 1.0, our approximation should be close
    try std.testing.expect(saturated > 0.9);
    try std.testing.expect(saturated < 1.1);
}

test "polyblep reduces discontinuity" {
    const T = f64;

    // Test PolyBLEP correction at discontinuity
    const dt: T = 0.01; // 1% of phase per sample

    // At phase = 0 (just after reset), correction should be significant
    const correction_at_reset = PolyBLEP(T).correction(0.005, dt);
    try std.testing.expect(@abs(correction_at_reset) > 0.1);

    // At phase = 0.5 (middle of cycle), correction should be zero
    const correction_at_mid = PolyBLEP(T).correction(0.5, dt);
    try std.testing.expect(@abs(correction_at_mid) < 0.001);
}

test "oversampler decimates correctly" {
    const T = f64;

    var os = Oversampler(T, 2).init();

    // DC signal should pass through unchanged (approximately)
    const dc_samples = [_]T{ 0.5, 0.5 };
    const dc_out = os.processAndDecimate(dc_samples);
    try std.testing.expect(@abs(dc_out - 0.5) < 0.1);
}
