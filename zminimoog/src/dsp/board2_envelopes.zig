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

// ============================================================================
// Component Values from Schematic
// ============================================================================

pub const EnvelopeComponents = struct {
    // Main timing capacitor
    pub const timing_cap: comptime_float = 10.0e-6; // 10µF

    // Timing resistor ranges (determines attack/decay times)
    pub const min_time_ms: comptime_float = 1.0; // Minimum attack/decay time
    pub const max_time_ms: comptime_float = 10000.0; // Maximum attack/decay time (10 seconds)

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
// ADSD Envelope Generator
// ============================================================================

/// Minimoog-style ADSD (Attack, Decay, Sustain, Decay) envelope
/// Note: Release is actually "Decay to zero" in the Minimoog
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

        // Per-note velocity scaling (1.0 for full level)
        velocity_scale: T = 1.0,

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
            self.velocity_scale = 1.0;
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
            self.gate = true;
            self.stage = .attack;
            self.velocity_scale = 1.0;
            self.target = 1.0;
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
            self.gate = true;
            self.stage = .attack;
            self.velocity_scale = @max(0.0, @min(1.0, velocity));
            self.target = self.velocity_scale;
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
                        if (self.output - self.target <= self.attack_rate) {
                            self.output = self.target;
                        }
                        self.stage = .decay;
                    }
                },
                .decay => {
                    // Exponential-ish decay towards sustain level
                    const sustain_target = self.sustain_level * self.velocity_scale;
                    const diff = self.output - sustain_target;
                    if (@abs(diff) > 0.0001) {
                        self.output -= diff * self.decay_rate * 6.0; // Multiply for faster response
                        if ((diff > 0.0 and self.output <= sustain_target) or
                            (diff < 0.0 and self.output >= sustain_target))
                        {
                            self.output = sustain_target;
                            self.stage = .sustain;
                        }
                    } else {
                        self.output = sustain_target;
                        self.stage = .sustain;
                    }
                },
                .sustain => {
                    // Hold at sustain level while gate is held
                    self.output = self.sustain_level * self.velocity_scale;
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
pub fn Board2Contours(comptime T: type) type {
    return struct {
        filter_env: ADSDEnvelope(T),
        loudness_env: ADSDEnvelope(T),
        glide: Glide(T),
        sample_rate: T,

        // Envelope amounts (scaling factors)
        filter_env_amount: T = 1.0, // How much filter env affects cutoff
        loudness_env_amount: T = 1.0, // Usually 1.0 for VCA

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            return .{
                .filter_env = ADSDEnvelope(T).init(sample_rate),
                .loudness_env = ADSDEnvelope(T).init(sample_rate),
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
    var prev_pitch: T = 0.0;
    var all_increasing = true;
    const steps: usize = 1000;
    for (0..steps) |_| {
        const pitch = glide.processSample();
        if (pitch < prev_pitch - 0.0001) {
            all_increasing = false;
        }
        prev_pitch = pitch;
    }

    try std.testing.expect(all_increasing);
    // Should be near exponential expectation after N steps
    const samples = glide.glide_time * sample_rate;
    const expected = 1.0 - @exp(-@as(T, @floatFromInt(steps)) / samples);
    try std.testing.expect(@abs(prev_pitch - expected) < 0.02);
}

test "board2 contours complete cycle" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var board2 = Board2Contours(T).init(sample_rate);

    // Set up envelopes
    board2.filter_env.setADSD(0.01, 0.05, 0.5, 0.1);
    board2.loudness_env.setADSD(0.01, 0.05, 0.8, 0.1);
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

    // Process release
    for (0..10000) |_| {
        _ = board2.processSample();
    }

    // Should be finished
    try std.testing.expect(board2.isFinished());
}
