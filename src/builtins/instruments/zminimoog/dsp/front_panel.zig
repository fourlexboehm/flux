// Front Panel Controls
// Minimoog Model D - Wheels, Switches, and Panel Controls
//
// Components not on the main boards but essential for performance control:
//   - Pitch Wheel (R1403) - 25K linear pot with center deadband
//   - Modulation Wheel (R1402) - 50K audio taper pot
//   - Glide Switch
//   - Decay Switch (controls release behavior)
//   - Oscillator switches and range selectors

const std = @import("std");

// ============================================================================
// Component Values from Schematic
// ============================================================================

pub const WheelComponents = struct {
    // Pitch Wheel (R1403)
    pub const pitch_wheel_resistance: comptime_float = 25000.0; // 25K
    pub const pitch_wheel_deadband: comptime_float = 0.05; // 5% center deadband
    pub const pitch_wheel_ground_r: comptime_float = 15000.0; // 15K to ground at detent

    // Modulation Wheel (R1402)
    pub const mod_wheel_resistance: comptime_float = 50000.0; // 50K audio taper
};

// ============================================================================
// Pitch Wheel
// ============================================================================

/// Pitch wheel with center deadband
/// Range: -1.0 to +1.0 (typically ±2 semitones, configurable)
pub fn PitchWheel(comptime T: type) type {
    return struct {
        position: T = 0.0, // -1.0 to 1.0, 0.0 = center
        bend_range: T = 2.0, // Semitones (±2 default, like original Minimoog)
        deadband: T = WheelComponents.pitch_wheel_deadband,

        // Smoothing for physical wheel simulation
        smoothed_position: T = 0.0,
        smoothing_coeff: T = 0.1,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.position = 0.0;
            self.smoothed_position = 0.0;
        }

        /// Set wheel position (-1.0 to 1.0)
        pub fn setPosition(self: *Self, pos: T) void {
            self.position = std.math.clamp(pos, -1.0, 1.0);
        }

        /// Set bend range in semitones
        pub fn setBendRange(self: *Self, semitones: T) void {
            self.bend_range = @max(0.0, semitones);
        }

        /// Get pitch bend in semitones (with deadband applied)
        pub fn getBendSemitones(self: *Self) T {
            // Apply deadband around center
            var effective_pos = self.position;
            if (@abs(effective_pos) < self.deadband) {
                effective_pos = 0.0;
            } else {
                // Scale remaining range to full output
                if (effective_pos > 0) {
                    effective_pos = (effective_pos - self.deadband) / (1.0 - self.deadband);
                } else {
                    effective_pos = (effective_pos + self.deadband) / (1.0 - self.deadband);
                }
            }

            return effective_pos * self.bend_range;
        }

        /// Get pitch bend as frequency ratio
        pub fn getBendRatio(self: *Self) T {
            const semitones = self.getBendSemitones();
            return std.math.pow(T, 2.0, semitones / 12.0);
        }

        /// Get pitch bend as 1V/octave CV offset
        pub fn getBendCV(self: *Self) T {
            const semitones = self.getBendSemitones();
            return semitones / 12.0; // 1V per octave = 1/12 V per semitone
        }

        /// Process with smoothing (call once per sample for smooth wheel movement)
        pub fn process(self: *Self) T {
            self.smoothed_position += (self.position - self.smoothed_position) * self.smoothing_coeff;

            var effective_pos = self.smoothed_position;
            if (@abs(effective_pos) < self.deadband) {
                effective_pos = 0.0;
            } else {
                if (effective_pos > 0) {
                    effective_pos = (effective_pos - self.deadband) / (1.0 - self.deadband);
                } else {
                    effective_pos = (effective_pos + self.deadband) / (1.0 - self.deadband);
                }
            }

            return effective_pos * self.bend_range / 12.0; // Return as CV
        }
    };
}

// ============================================================================
// Modulation Wheel
// ============================================================================

/// Modulation wheel with audio taper response
/// Range: 0.0 to 1.0 (CCW to CW)
pub fn ModWheel(comptime T: type) type {
    return struct {
        position: T = 0.0, // 0.0 to 1.0
        smoothed_position: T = 0.0,
        smoothing_coeff: T = 0.05,

        // Modulation destinations
        filter_mod_amount: T = 0.0, // How much mod wheel affects filter
        osc_mod_amount: T = 0.0, // How much mod wheel affects oscillator pitch (vibrato)

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.position = 0.0;
            self.smoothed_position = 0.0;
        }

        /// Set wheel position (0.0 to 1.0)
        pub fn setPosition(self: *Self, pos: T) void {
            self.position = std.math.clamp(pos, 0.0, 1.0);
        }

        /// Apply audio taper curve (attempt to simulate 50K audio pot)
        fn audioTaper(self: *Self, linear: T) T {
            _ = self;
            // Audio taper approximation: logarithmic response
            // At 50% rotation, output is ~10% of max
            if (linear <= 0.0) return 0.0;
            if (linear >= 1.0) return 1.0;

            // Simple audio taper approximation
            return linear * linear; // Quadratic gives similar feel
        }

        /// Get modulation amount (0.0 to 1.0 with audio taper)
        pub fn getModAmount(self: *Self) T {
            return self.audioTaper(self.smoothed_position);
        }

        /// Get filter modulation CV
        pub fn getFilterMod(self: *Self) T {
            return self.getModAmount() * self.filter_mod_amount;
        }

        /// Get oscillator modulation CV (for vibrato)
        pub fn getOscMod(self: *Self) T {
            return self.getModAmount() * self.osc_mod_amount;
        }

        /// Process with smoothing
        pub fn process(self: *Self) T {
            self.smoothed_position += (self.position - self.smoothed_position) * self.smoothing_coeff;
            return self.getModAmount();
        }
    };
}

// ============================================================================
// Panel Switches
// ============================================================================

pub const GlideMode = enum {
    off,
    on,
};

pub const DecayMode = enum {
    decay, // Normal ADSD behavior
    release, // Use decay as release (for held notes)
};

pub const OscRange = enum {
    lo, // LO (for LFO use, Osc 3 only)
    @"32", // 32' (lowest)
    @"16", // 16'
    @"8", // 8' (middle)
    @"4", // 4'
    @"2", // 2' (highest)

    pub fn getOctaveOffset(self: OscRange) i8 {
        return switch (self) {
            .lo => -4, // Very low for LFO
            .@"32" => -2,
            .@"16" => -1,
            .@"8" => 0, // Reference
            .@"4" => 1,
            .@"2" => 2,
        };
    }
};

pub const OscWaveformSwitch = enum {
    triangle,
    shark_tooth, // Minimoog's "triangle-saw" hybrid
    sawtooth,
    square,
    wide_pulse,
    narrow_pulse,
};

/// Panel switches state
pub fn PanelSwitches(comptime T: type) type {
    return struct {
        // Glide
        glide_mode: GlideMode = .off,
        glide_time: T = 0.1, // Glide pot setting (seconds)

        // Decay/Release
        decay_mode: DecayMode = .decay,

        // Oscillator ranges
        osc1_range: OscRange = .@"8",
        osc2_range: OscRange = .@"8",
        osc3_range: OscRange = .@"8",

        // Oscillator waveforms
        osc1_waveform: OscWaveformSwitch = .sawtooth,
        osc2_waveform: OscWaveformSwitch = .sawtooth,
        osc3_waveform: OscWaveformSwitch = .sawtooth,

        // Oscillator on/off
        osc1_on: bool = true,
        osc2_on: bool = true,
        osc3_on: bool = true,

        // Osc 3 control
        osc3_keyboard_control: bool = true, // When off, Osc 3 runs free (for LFO)

        // Noise
        noise_on: bool = false,
        noise_type: NoiseType = .white,

        // External input
        external_on: bool = false,

        // Filter
        filter_keyboard_tracking: FilterKeyboardTracking = .half,

        // Modulation
        osc3_to_filter: bool = false, // Osc 3 modulates filter
        osc3_to_osc: bool = false, // Osc 3 modulates other oscillators
        noise_to_filter: bool = false, // Noise modulates filter

        const Self = @This();

        pub fn init() Self {
            return .{};
        }
    };
}

pub const NoiseType = enum {
    white,
    pink,
};

pub const FilterKeyboardTracking = enum {
    off,
    half, // 1/2 keyboard tracking
    full, // Full keyboard tracking

    pub fn getAmount(self: FilterKeyboardTracking, comptime T: type) T {
        return switch (self) {
            .off => 0.0,
            .half => 0.5,
            .full => 1.0,
        };
    }
};

// ============================================================================
// Complete Front Panel
// ============================================================================

/// Complete front panel controls
pub fn FrontPanel(comptime T: type) type {
    return struct {
        pitch_wheel: PitchWheel(T),
        mod_wheel: ModWheel(T),
        switches: PanelSwitches(T),

        // Main output volume
        master_volume: T = 0.7,

        // A-440 tuning reference
        a440_on: bool = false,

        const Self = @This();

        pub fn init() Self {
            return .{
                .pitch_wheel = PitchWheel(T).init(),
                .mod_wheel = ModWheel(T).init(),
                .switches = PanelSwitches(T).init(),
            };
        }

        pub fn reset(self: *Self) void {
            self.pitch_wheel.reset();
            self.mod_wheel.reset();
        }

        /// Process wheels (call once per sample)
        pub fn process(self: *Self) WheelOutputs(T) {
            return .{
                .pitch_bend_cv = self.pitch_wheel.process(),
                .mod_amount = self.mod_wheel.process(),
            };
        }
    };
}

pub fn WheelOutputs(comptime T: type) type {
    return struct {
        pitch_bend_cv: T, // Add to oscillator CV
        mod_amount: T, // 0.0 to 1.0 mod depth
    };
}

// ============================================================================
// Tests
// ============================================================================

test "pitch wheel deadband" {
    const T = f64;

    var wheel = PitchWheel(T).init();

    // Center position should give zero bend
    wheel.setPosition(0.0);
    const bend_center = wheel.getBendSemitones();
    try std.testing.expect(@abs(bend_center) < 0.001);

    // Small movements within deadband should still be zero
    wheel.setPosition(0.03);
    const bend_small = wheel.getBendSemitones();
    try std.testing.expect(@abs(bend_small) < 0.001);

    // Full bend should give bend_range semitones
    wheel.setPosition(1.0);
    const bend_full = wheel.getBendSemitones();
    try std.testing.expect(@abs(bend_full - 2.0) < 0.1); // Default ±2 semitones
}

test "mod wheel audio taper" {
    const T = f64;

    var wheel = ModWheel(T).init();

    // Zero position
    wheel.setPosition(0.0);
    wheel.smoothed_position = 0.0;
    try std.testing.expect(wheel.getModAmount() < 0.001);

    // Full position
    wheel.setPosition(1.0);
    wheel.smoothed_position = 1.0;
    try std.testing.expect(@abs(wheel.getModAmount() - 1.0) < 0.001);

    // Half position should be less than 0.5 (audio taper)
    wheel.setPosition(0.5);
    wheel.smoothed_position = 0.5;
    const half_amount = wheel.getModAmount();
    try std.testing.expect(half_amount < 0.5);
}

test "oscillator range offsets" {
    try std.testing.expect(OscRange.@"32".getOctaveOffset() == -2);
    try std.testing.expect(OscRange.@"8".getOctaveOffset() == 0);
    try std.testing.expect(OscRange.@"2".getOctaveOffset() == 2);
}
