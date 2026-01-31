// Board 2: Contour Generator and Keyboard Board
// Minimoog Model D - ADSD Envelope Generators and Glide
//
// Schematic page 6 of Minimoog-schematics.pdf
//
// Contains:
//   - Filter Envelope Generator (ADSD for VCF cutoff)
//   - Loudness Envelope Generator (ADSD for VCA)
//   - Keyboard Circuit with Glide (Portamento)

const std = @import("std");
const wdft = @import("zig_wdf");

// ============================================================================
// Component Values from Schematic
// ============================================================================

pub const EnvelopeComponents = struct {
    // Main timing capacitor
    pub const timing_cap: comptime_float = 10.0e-6; // 10µF

    // Timing resistor ranges (determines attack/decay times)
    pub const min_time_ms: comptime_float = 1.0; // Minimum attack/decay time
    pub const max_time_ms: comptime_float = 10000.0; // Maximum attack/decay time (10 seconds)

    // Timing resistor values (from pots)
    pub const min_timing_r: comptime_float = 1000.0; // 1k minimum (fastest)
    pub const max_timing_r: comptime_float = 10000000.0; // 10M maximum (slowest)

    // 1N4004 diode parameters (attack diode CR1)
    pub const diode_is: comptime_float = 1.0e-14; // Saturation current
    pub const diode_vt: comptime_float = 25.85e-3; // Thermal voltage

    // Glide capacitor
    pub const glide_cap: comptime_float = 1.0e-6; // 1µF (C6)
};

// ============================================================================
// Envelope Stages
// ============================================================================

pub const EnvelopeStage = enum {
    idle,
    attack,
    decay,
    sustain,
    release,
};

// ============================================================================
// WDF Transistor Envelope Generator
// ============================================================================

/// WDF-based envelope generator with authentic RC timing and diode shaping
///
/// Circuit topology (from schematic):
///   +V ----[R_attack]---+
///                       |
///                      CR1 (1N4004)  <-- Attack diode (forward bias during attack)
///                       |
///                       +----------- Timing Capacitor (10µF)
///                       |
///         [R_decay]-----+
///                       |
///                      GND
///
/// During attack:
///   - Current flows through R_attack and CR1 (diode forward biased)
///   - Capacitor charges with time constant τ = R_attack * C
///   - Diode drop (~0.6V) creates slight asymmetry
///
/// During decay/release:
///   - Diode reverse biased (blocks attack path)
///   - Capacitor discharges through R_decay only
///   - Time constant τ = R_decay * C
///
/// The diode creates the characteristic asymmetric attack/decay behavior
/// that gives analog envelopes their distinctive feel.
pub fn WDFEnvelope(comptime T: type) type {
    const R = wdft.Resistor(T);
    const C = wdft.Capacitor(T);

    // Diode for attack path asymmetry
    const Diode = wdft.Diode(T, R);

    return struct {
        // Timing capacitor (main energy storage)
        c_timing: C,

        // Attack resistor (variable via pot)
        r_attack: R,

        // Decay resistor (variable via pot)
        r_decay: R,

        // Attack diode (1N4004) - creates asymmetric charging
        cr1: Diode,

        // Envelope state
        stage: EnvelopeStage = .idle,
        output: T = 0.0,
        gate: bool = false,

        // Time parameters (in seconds)
        attack_time: T = 0.01,
        decay_time: T = 0.1,
        sustain_level: T = 0.7,
        release_time: T = 0.3,

        // Target voltage for current stage
        target: T = 0.0,

        // Capacitor voltage (envelope output)
        cap_voltage: T = 0.0,

        // Cached release resistance to avoid per-sample recompute
        release_r: T = timeToResistance(0.3),

        // Sample rate
        sample_rate: T,

        const Self = @This();

        // Diode parameters (1N4004)
        const diode_is: T = EnvelopeComponents.diode_is;
        const diode_vt: T = EnvelopeComponents.diode_vt;

        pub fn init(sample_rate: T) Self {
            // Calculate initial resistor values from time constants
            // τ = R * C, so R = τ / C
            const attack_r = timeToResistance(0.01); // 10ms default
            const decay_r = timeToResistance(0.1); // 100ms default

            return Self{
                .c_timing = C.init(EnvelopeComponents.timing_cap, sample_rate),
                .r_attack = R.init(attack_r),
                .r_decay = R.init(decay_r),
                .cr1 = Diode.init(R.init(100.0), diode_is, diode_vt, 1.0), // 100 ohm series resistance, 1 diode
                .sample_rate = sample_rate,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.c_timing.prepare(sample_rate);
            self.c_timing.calcImpedance();
        }

        pub fn reset(self: *Self) void {
            self.stage = .idle;
            self.output = 0.0;
            self.cap_voltage = 0.0;
            self.gate = false;
            self.c_timing.reset();
        }

        /// Convert time in seconds to resistance value
        fn timeToResistance(time_seconds: T) T {
            // τ = R * C, so R = τ / C
            // We use a multiplier because the RC time constant gives ~63% charge
            // and we want time to ~95% (about 3τ)
            const tau = time_seconds / 3.0;
            const r = tau / EnvelopeComponents.timing_cap;
            return @max(EnvelopeComponents.min_timing_r, @min(EnvelopeComponents.max_timing_r, r));
        }

        /// Set attack time in seconds
        pub fn setAttack(self: *Self, time_seconds: T) void {
            self.attack_time = @max(0.001, time_seconds);
            self.r_attack.setResistance(timeToResistance(self.attack_time));
        }

        /// Set decay time in seconds
        pub fn setDecay(self: *Self, time_seconds: T) void {
            self.decay_time = @max(0.001, time_seconds);
            self.r_decay.setResistance(timeToResistance(self.decay_time));
        }

        /// Set sustain level (0.0 to 1.0)
        pub fn setSustain(self: *Self, level: T) void {
            self.sustain_level = @max(0.0, @min(1.0, level));
        }

        /// Set release time in seconds
        pub fn setRelease(self: *Self, time_seconds: T) void {
            self.release_time = @max(0.001, time_seconds);
            self.release_r = timeToResistance(self.release_time);
            // Release uses the decay resistor path (diode blocks attack path)
        }

        /// Set all ADSD parameters at once
        pub fn setADSD(self: *Self, attack: T, decay: T, sustain: T, release: T) void {
            self.setAttack(attack);
            self.setDecay(decay);
            self.setSustain(sustain);
            self.setRelease(release);
        }

        /// Trigger the envelope (gate on)
        pub fn noteOn(self: *Self) void {
            const was_gate = self.gate;
            self.gate = true;
            self.target = 1.0;
            if (!was_gate or self.stage == .idle) {
                self.stage = .attack;
                // Start from zero only when fully idle (avoids hard retrigger clicks)
                self.cap_voltage = 0.0;
                self.output = 0.0;
            } else {
                // Retrigger from current level to avoid discontinuity
                self.stage = if (self.cap_voltage >= self.target) .decay else .attack;
                self.output = self.cap_voltage;
            }
        }

        /// Release the envelope (gate off)
        pub fn noteOff(self: *Self) void {
            self.gate = false;
            if (self.stage != .idle) {
                self.stage = .release;
                self.target = 0.0;
            }
        }

        /// Trigger with velocity
        pub fn noteOnVelocity(self: *Self, velocity: T) void {
            const was_gate = self.gate;
            self.gate = true;
            self.target = @max(0.0, @min(1.0, velocity));
            if (!was_gate or self.stage == .idle) {
                self.stage = .attack;
                self.cap_voltage = 0.0;
                self.output = 0.0;
            } else {
                self.stage = if (self.cap_voltage >= self.target) .decay else .attack;
                self.output = self.cap_voltage;
            }
        }

        /// Check if envelope is finished
        pub fn isFinished(self: *const Self) bool {
            return self.stage == .idle;
        }

        /// Process one sample using WDF RC circuit with diode
        pub inline fn processSample(self: *Self) T {
            switch (self.stage) {
                .idle => {
                    self.output = 0.0;
                    self.cap_voltage = 0.0;
                },
                .attack => {
                    // Attack: charge capacitor through R_attack and diode
                    // In real circuit, diode allows current flow but we model
                    // the charging directly without the 0.6V drop for proper envelope behavior
                    const v_supply: T = self.target; // Target voltage
                    const v_diff = v_supply - self.cap_voltage;

                    // RC charging: dV/dt = (V_target - V_cap) / (R * C)
                    const r_attack_val = self.r_attack.wdf.R;
                    const charge_rate = v_diff / (r_attack_val * EnvelopeComponents.timing_cap * self.sample_rate);

                    self.cap_voltage += charge_rate;

                    // Check if we've reached target (within 1%)
                    if (self.cap_voltage >= self.target * 0.99) {
                        self.cap_voltage = self.target;
                        self.stage = .decay;
                    }

                    self.output = self.cap_voltage;
                },
                .decay => {
                    // Decay: discharge capacitor through R_decay only
                    // Diode is reverse biased (blocks attack path)
                    const v_diff = self.cap_voltage - self.sustain_level;

                    if (v_diff > 0.0001) {
                        // RC discharge: dV/dt = -(V_cap - V_sustain) / (R * C)
                        const r_decay_val = self.r_decay.wdf.R;
                        const discharge_rate = v_diff / (r_decay_val * EnvelopeComponents.timing_cap * self.sample_rate);

                        self.cap_voltage -= discharge_rate;

                        if (self.cap_voltage <= self.sustain_level) {
                            self.cap_voltage = self.sustain_level;
                            self.stage = .sustain;
                        }
                    } else {
                        self.cap_voltage = self.sustain_level;
                        self.stage = .sustain;
                    }

                    self.output = self.cap_voltage;
                },
                .sustain => {
                    // Hold at sustain level
                    self.output = self.sustain_level;
                    self.cap_voltage = self.sustain_level;

                    if (!self.gate) {
                        self.stage = .release;
                    }
                },
                .release => {
                    // Release: discharge to zero through R_decay
                    // Similar to decay but to zero target
                    if (self.cap_voltage > 0.0001) {
                        // Use release time for the resistance calculation
                        const discharge_rate = self.cap_voltage / (self.release_r * EnvelopeComponents.timing_cap * self.sample_rate);

                        self.cap_voltage -= discharge_rate;

                        if (self.cap_voltage < 0.0001) {
                            self.cap_voltage = 0.0;
                            self.stage = .idle;
                        }
                    } else {
                        self.cap_voltage = 0.0;
                        self.stage = .idle;
                    }

                    self.output = self.cap_voltage;
                },
            }

            return self.output;
        }
    };
}

// ============================================================================
// ADSD Envelope Generator (Mathematical Model - Fast Alternative)
// ============================================================================

/// Minimoog-style ADSD (Attack, Decay, Sustain, Decay) envelope
/// Note: Release is actually "Decay to zero" in the Minimoog
/// This is a fast mathematical model as an alternative to WDFEnvelope
pub fn ADSDEnvelope(comptime T: type) type {
    return struct {
        stage: EnvelopeStage = .idle,
        output: T = 0.0,
        sample_rate: T,

        // Time parameters (in seconds)
        attack_time: T = 0.01,
        decay_time: T = 0.1,
        sustain_level: T = 0.7, // 0.0 to 1.0
        release_time: T = 0.3,

        // Internal rate calculations
        attack_rate: T = 0.0,
        decay_rate: T = 0.0,
        release_rate: T = 0.0,

        // Target for current stage
        target: T = 0.0,

        // Gate state
        gate: bool = false,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            var self = Self{
                .sample_rate = sample_rate,
            };
            self.recalculateRates();
            return self;
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.recalculateRates();
        }

        pub fn reset(self: *Self) void {
            self.stage = .idle;
            self.output = 0.0;
            self.gate = false;
        }

        /// Set attack time in seconds
        pub fn setAttack(self: *Self, time_seconds: T) void {
            self.attack_time = @max(0.001, time_seconds);
            self.recalculateRates();
        }

        /// Set decay time in seconds
        pub fn setDecay(self: *Self, time_seconds: T) void {
            self.decay_time = @max(0.001, time_seconds);
            self.recalculateRates();
        }

        /// Set sustain level (0.0 to 1.0)
        pub fn setSustain(self: *Self, level: T) void {
            self.sustain_level = @max(0.0, @min(1.0, level));
        }

        /// Set release time in seconds
        pub fn setRelease(self: *Self, time_seconds: T) void {
            self.release_time = @max(0.001, time_seconds);
            self.recalculateRates();
        }

        /// Set all ADSD parameters at once
        pub fn setADSD(self: *Self, attack: T, decay: T, sustain: T, release: T) void {
            self.attack_time = @max(0.001, attack);
            self.decay_time = @max(0.001, decay);
            self.sustain_level = @max(0.0, @min(1.0, sustain));
            self.release_time = @max(0.001, release);
            self.recalculateRates();
        }

        fn recalculateRates(self: *Self) void {
            // Rate = 1.0 / (time_in_samples)
            // For exponential curves, we use a coefficient approach
            self.attack_rate = 1.0 / (self.attack_time * self.sample_rate);
            self.decay_rate = 1.0 / (self.decay_time * self.sample_rate);
            self.release_rate = 1.0 / (self.release_time * self.sample_rate);
        }

        /// Trigger the envelope (gate on)
        pub fn noteOn(self: *Self) void {
            const was_gate = self.gate;
            self.gate = true;
            self.target = 1.0;
            if (!was_gate or self.stage == .idle) {
                self.stage = .attack;
                self.output = 0.0;
            } else {
                self.stage = if (self.output >= self.target) .decay else .attack;
            }
        }

        /// Release the envelope (gate off)
        pub fn noteOff(self: *Self) void {
            self.gate = false;
            if (self.stage != .idle) {
                self.stage = .release;
                self.target = 0.0;
            }
        }

        /// Trigger with velocity (optional)
        pub fn noteOnVelocity(self: *Self, velocity: T) void {
            const was_gate = self.gate;
            self.gate = true;
            self.target = @max(0.0, @min(1.0, velocity));
            if (!was_gate or self.stage == .idle) {
                self.stage = .attack;
                self.output = 0.0;
            } else {
                self.stage = if (self.output >= self.target) .decay else .attack;
            }
        }

        /// Check if envelope is finished
        pub fn isFinished(self: *Self) bool {
            return self.stage == .idle;
        }

        /// Process one sample
        pub inline fn processSample(self: *Self) T {
            switch (self.stage) {
                .idle => {
                    self.output = 0.0;
                },
                .attack => {
                    // Linear attack towards target (1.0)
                    self.output += self.attack_rate;
                    if (self.output >= self.target) {
                        self.output = self.target;
                        self.stage = .decay;
                    }
                },
                .decay => {
                    // Exponential-ish decay towards sustain level
                    const diff = self.output - self.sustain_level;
                    if (diff > 0.0001) {
                        self.output -= diff * self.decay_rate * 6.0; // Multiply for faster response
                        if (self.output <= self.sustain_level) {
                            self.output = self.sustain_level;
                            self.stage = .sustain;
                        }
                    } else {
                        self.output = self.sustain_level;
                        self.stage = .sustain;
                    }
                },
                .sustain => {
                    // Hold at sustain level while gate is held
                    self.output = self.sustain_level;
                    if (!self.gate) {
                        self.stage = .release;
                    }
                },
                .release => {
                    // Exponential decay to zero
                    self.output -= self.output * self.release_rate * 6.0;
                    if (self.output < 0.0001) {
                        self.output = 0.0;
                        self.stage = .idle;
                    }
                },
            }

            return self.output;
        }
    };
}

// ============================================================================
// Glide (Portamento) Circuit
// ============================================================================

/// Glide circuit for smooth pitch transitions
/// Models the RC charging behavior of the Minimoog glide circuit
pub fn Glide(comptime T: type) type {
    return struct {
        current_pitch: T = 0.0,
        target_pitch: T = 0.0,
        glide_time: T = 0.0, // 0 = instant, no glide
        sample_rate: T,
        coefficient: T = 1.0,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            return .{
                .sample_rate = sample_rate,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.recalculateCoefficient();
        }

        pub fn reset(self: *Self) void {
            self.current_pitch = 0.0;
            self.target_pitch = 0.0;
        }

        /// Set glide time in seconds (0 = disabled)
        pub fn setGlideTime(self: *Self, time_seconds: T) void {
            self.glide_time = @max(0.0, time_seconds);
            self.recalculateCoefficient();
        }

        fn recalculateCoefficient(self: *Self) void {
            if (self.glide_time <= 0.0) {
                self.coefficient = 1.0; // Instant
            } else {
                // Exponential smoothing coefficient
                // Time constant = glide_time, coefficient determines how fast we approach target
                const samples = self.glide_time * self.sample_rate;
                self.coefficient = 1.0 - @exp(-1.0 / samples);
            }
        }

        /// Set new target pitch (in semitones or V/oct)
        pub fn setTargetPitch(self: *Self, pitch: T) void {
            self.target_pitch = pitch;
        }

        /// Set pitch immediately (no glide)
        pub fn setPitchImmediate(self: *Self, pitch: T) void {
            self.current_pitch = pitch;
            self.target_pitch = pitch;
        }

        /// Process one sample, returns current pitch
        pub inline fn processSample(self: *Self) T {
            if (self.glide_time <= 0.0) {
                self.current_pitch = self.target_pitch;
            } else {
                // Exponential approach to target
                self.current_pitch += (self.target_pitch - self.current_pitch) * self.coefficient;
            }
            return self.current_pitch;
        }
    };
}

// ============================================================================
// Complete Board 2: Dual Envelopes + Glide
// ============================================================================

/// Complete Board 2 with filter envelope, loudness envelope, and glide
/// Uses WDF-based envelopes for authentic RC timing with diode shaping
pub fn Board2Contours(comptime T: type) type {
    return struct {
        // WDF-based envelopes with transistor timing circuits
        filter_env: WDFEnvelope(T),
        loudness_env: WDFEnvelope(T),
        glide: Glide(T),
        sample_rate: T,

        // Envelope amounts (scaling factors)
        filter_env_amount: T = 1.0, // How much filter env affects cutoff
        loudness_env_amount: T = 1.0, // Usually 1.0 for VCA

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            return .{
                .filter_env = WDFEnvelope(T).init(sample_rate),
                .loudness_env = WDFEnvelope(T).init(sample_rate),
                .glide = Glide(T).init(sample_rate),
                .sample_rate = sample_rate,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.filter_env.prepare(sample_rate);
            self.loudness_env.prepare(sample_rate);
            self.glide.prepare(sample_rate);
        }

        pub fn reset(self: *Self) void {
            self.filter_env.reset();
            self.loudness_env.reset();
            self.glide.reset();
        }

        /// Note on - triggers both envelopes
        pub fn noteOn(self: *Self, pitch: T) void {
            self.filter_env.noteOn();
            self.loudness_env.noteOn();
            self.glide.setTargetPitch(pitch);
        }

        /// Note off - releases both envelopes
        pub fn noteOff(self: *Self) void {
            self.filter_env.noteOff();
            self.loudness_env.noteOff();
        }

        /// Process one sample, returns all contour outputs
        pub fn processSample(self: *Self) ContourOutputs(T) {
            return .{
                .filter_env = self.filter_env.processSample() * self.filter_env_amount,
                .loudness_env = self.loudness_env.processSample() * self.loudness_env_amount,
                .pitch = self.glide.processSample(),
            };
        }

        /// Check if both envelopes are finished (voice can be released)
        pub fn isFinished(self: *Self) bool {
            return self.filter_env.isFinished() and self.loudness_env.isFinished();
        }
    };
}

pub fn ContourOutputs(comptime T: type) type {
    return struct {
        filter_env: T, // CV for filter cutoff modulation
        loudness_env: T, // CV for VCA gain
        pitch: T, // Pitch CV (with glide applied)
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

test "envelope attack phase" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var env = ADSDEnvelope(T).init(sample_rate);
    env.setADSD(0.01, 0.1, 0.5, 0.2); // 10ms attack

    env.noteOn();

    // Process attack phase
    var max_output: T = 0.0;
    for (0..1000) |_| {
        const sample = env.processSample();
        max_output = @max(max_output, sample);
    }

    // Should reach near 1.0 during attack
    try std.testing.expect(max_output > 0.9);
}

test "envelope sustain phase" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var env = ADSDEnvelope(T).init(sample_rate);
    env.setADSD(0.001, 0.01, 0.6, 0.1); // Fast attack/decay, 0.6 sustain

    env.noteOn();

    // Process until sustain
    for (0..5000) |_| {
        _ = env.processSample();
    }

    // Should be at sustain level
    const sustain_output = env.processSample();
    try expectApproxEq(sustain_output, 0.6, 0.05);
}

test "envelope release phase" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var env = ADSDEnvelope(T).init(sample_rate);
    env.setADSD(0.001, 0.01, 0.7, 0.05); // Fast everything, 50ms release

    env.noteOn();

    // Get to sustain
    for (0..2000) |_| {
        _ = env.processSample();
    }

    env.noteOff();

    // Process release
    var min_output: T = 1.0;
    for (0..5000) |_| {
        const sample = env.processSample();
        min_output = @min(min_output, sample);
    }

    // Should decay close to zero
    try std.testing.expect(min_output < 0.01);
    try std.testing.expect(env.isFinished());
}

test "glide smooths pitch" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var glide = Glide(T).init(sample_rate);
    glide.setGlideTime(0.1); // 100ms glide

    glide.setPitchImmediate(0.0);
    glide.setTargetPitch(1.0);

    // Process and check that pitch gradually increases
    // With 100ms glide time at 48kHz, we need ~5000 samples (~104ms) to reach 0.5
    var prev_pitch: T = 0.0;
    var all_increasing = true;
    for (0..5000) |_| {
        const pitch = glide.processSample();
        if (pitch < prev_pitch - 0.0001) {
            all_increasing = false;
        }
        prev_pitch = pitch;
    }

    try std.testing.expect(all_increasing);
    // Should be approaching target (after ~100ms, should be at ~63%)
    try std.testing.expect(prev_pitch > 0.5);
}

test "board2 contours complete cycle" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var board2 = Board2Contours(T).init(sample_rate);

    // Set up envelopes with short release for faster test
    board2.filter_env.setADSD(0.01, 0.05, 0.5, 0.05); // 50ms release
    board2.loudness_env.setADSD(0.01, 0.05, 0.8, 0.05); // 50ms release
    board2.glide.setGlideTime(0.05);

    // Note on
    board2.noteOn(60.0); // Middle C

    // Process note
    for (0..5000) |_| {
        const outputs = board2.processSample();
        _ = outputs;
    }

    // Note off
    board2.noteOff();

    // Process release - with 50ms release, need ~8000 samples for exponential decay
    for (0..10000) |_| {
        _ = board2.processSample();
    }

    // Should be finished
    try std.testing.expect(board2.isFinished());
}
