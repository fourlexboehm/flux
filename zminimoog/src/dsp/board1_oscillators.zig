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
// Anti-Aliasing:
//   - PolyBLEP for sawtooth/square/pulse discontinuities
//   - PolyBLAMP for triangle peaks
//   - Global oversampling handles remaining aliasing (see oversampler.zig)

const std = @import("std");
const wdft = @import("zig_wdf");

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

    // CA3046 transistor array parameters (5-transistor matched array)
    pub const ca3046_is: comptime_float = 1.0e-15; // Saturation current
    pub const ca3046_vt: comptime_float = 25.85e-3; // Thermal voltage
    pub const ca3046_beta_f: comptime_float = 100.0; // Forward current gain
    pub const ca3046_beta_r: comptime_float = 1.0; // Reverse current gain

    // 2N3392 discharge transistor parameters
    pub const q2n3392_is: comptime_float = 2.0e-14; // Saturation current
    pub const q2n3392_vt: comptime_float = 25.85e-3; // Thermal voltage
    pub const q2n3392_beta_f: comptime_float = 150.0; // Forward current gain
    pub const q2n3392_beta_r: comptime_float = 1.0; // Reverse current gain
    pub const q2n3392_r_ce_sat: comptime_float = 5.0; // Collector-emitter saturation resistance

    // Exponential converter resistors
    pub const exp_input_r: comptime_float = 100000.0; // 100k CV input resistor
    pub const exp_ref_r: comptime_float = 100000.0; // 100k reference resistor
    pub const exp_mirror_r: comptime_float = 10000.0; // 10k current mirror resistor
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
        pub inline fn correction(t: T, dt: T) T {
            if (t < dt) {
                const t_norm = t / dt;
                // Integrated PolyBLEP: smooths the corner
                const t2 = t_norm * t_norm;
                const t3 = t2 * t_norm;
                const t4 = t3 * t_norm;
                return dt * (t4 / 4.0 - t3 / 3.0);
            } else if (t > 1.0 - dt) {
                const t_norm = (t - 1.0) / dt + 1.0;
                const t2 = t_norm * t_norm;
                const t3 = t2 * t_norm;
                const t4 = t3 * t_norm;
                return -dt * ((1.0 - t4) / 4.0 - (1.0 - t3) / 3.0);
            }
            return 0.0;
        }
    };
}

// ============================================================================
// CA3046 Exponential Converter (5-Transistor Array)
// ============================================================================

/// CA3046 exponential converter for VCO frequency control
///
/// Circuit topology (from schematic):
///   CV input ---[R]--+-- Base Q1 (differential input)
///                    |      |
///                    |     |E
///                    |      |----+
///                    |           |
///   V_ref ----[R]----+-- Base Q2 | (differential reference)
///                    |      |    |
///                    |     |E    |
///                    +------+----+---- To Q3 base (Wilson mirror input)
///                                 |
///                            Q3---|--- Q4 (Wilson current mirror)
///                                 |     |
///                                Q5-----+---- Output current
///
/// The CA3046 contains 5 matched transistors:
///   Q1, Q2: Differential pair for exponential conversion
///   Q3, Q4, Q5: Wilson current mirror for accurate current output
///
/// This provides precise 1V/octave tracking for VCO frequency control.
pub fn CA3046ExpConverter(comptime T: type) type {
    const R = wdft.Resistor(T);

    // Differential pair transistors (Q1, Q2)
    const NPN_Diff = wdft.NpnTransistor(T, R, R);

    // Wilson current mirror transistors (Q3, Q4, Q5)
    const NPN_Mirror = wdft.NpnTransistor(T, R, R);

    return struct {
        // Differential pair
        q1: NPN_Diff, // CV input transistor
        q2: NPN_Diff, // Reference transistor

        // Wilson current mirror
        q3: NPN_Mirror, // Mirror reference
        q4: NPN_Mirror, // Mirror output stage 1
        q5: NPN_Mirror, // Mirror output stage 2

        // Control voltages
        cv_input: T = 0.0, // CV input (1V/octave)
        v_ref: T = 0.0, // Reference voltage

        // Output current (charges the integrating capacitor)
        output_current: T = 0.0,

        // Base current (sets operating point)
        base_current: T = 10.0e-6, // 10µA nominal

        // CV smoothing
        cv_smoothed: T = 0.0,
        cv_smooth_coeff: T = 0.0,

        sample_rate: T,

        const Self = @This();

        // CA3046 parameters
        const ca3046_is: T = OscillatorComponents.ca3046_is;
        const ca3046_vt: T = OscillatorComponents.ca3046_vt;
        const ca3046_alpha_f: T = OscillatorComponents.ca3046_beta_f / (OscillatorComponents.ca3046_beta_f + 1.0);
        const ca3046_alpha_r: T = OscillatorComponents.ca3046_beta_r / (OscillatorComponents.ca3046_beta_r + 1.0);

        pub fn init(sample_rate: T) Self {
            // CV smoothing: ~2ms for fast response
            const smooth_time: T = 0.002;
            const cv_smooth = 1.0 - @exp(-1.0 / (smooth_time * sample_rate));

            return Self{
                // Differential pair
                .q1 = NPN_Diff.init(
                    R.init(OscillatorComponents.exp_input_r),
                    R.init(OscillatorComponents.source_resistance),
                    ca3046_is,
                    ca3046_vt,
                    ca3046_alpha_f,
                    ca3046_alpha_r,
                ),
                .q2 = NPN_Diff.init(
                    R.init(OscillatorComponents.exp_ref_r),
                    R.init(OscillatorComponents.source_resistance),
                    ca3046_is,
                    ca3046_vt,
                    ca3046_alpha_f,
                    ca3046_alpha_r,
                ),
                // Wilson current mirror
                .q3 = NPN_Mirror.init(
                    R.init(OscillatorComponents.exp_mirror_r),
                    R.init(OscillatorComponents.source_resistance),
                    ca3046_is,
                    ca3046_vt,
                    ca3046_alpha_f,
                    ca3046_alpha_r,
                ),
                .q4 = NPN_Mirror.init(
                    R.init(OscillatorComponents.exp_mirror_r),
                    R.init(OscillatorComponents.source_resistance),
                    ca3046_is,
                    ca3046_vt,
                    ca3046_alpha_f,
                    ca3046_alpha_r,
                ),
                .q5 = NPN_Mirror.init(
                    R.init(OscillatorComponents.exp_mirror_r),
                    R.init(OscillatorComponents.source_resistance),
                    ca3046_is,
                    ca3046_vt,
                    ca3046_alpha_f,
                    ca3046_alpha_r,
                ),
                .sample_rate = sample_rate,
                .cv_smooth_coeff = cv_smooth,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            const smooth_time: T = 0.002;
            self.cv_smooth_coeff = 1.0 - @exp(-1.0 / (smooth_time * sample_rate));
        }

        pub fn reset(self: *Self) void {
            self.q1.reset();
            self.q2.reset();
            self.q3.reset();
            self.q4.reset();
            self.q5.reset();
            self.cv_smoothed = self.cv_input;
            self.output_current = 0.0;
        }

        /// Set the CV input voltage (1V/octave)
        pub fn setCV(self: *Self, cv_volts: T) void {
            self.cv_input = cv_volts;
        }

        /// Set the reference voltage
        pub fn setReference(self: *Self, v_ref: T) void {
            self.v_ref = v_ref;
        }

        /// Process one sample and return the charging current
        /// This current is used to charge the VCO integrating capacitor
        pub inline fn processSample(self: *Self) T {
            // Smooth CV input
            self.cv_smoothed += (self.cv_input - self.cv_smoothed) * self.cv_smooth_coeff;

            // Apply voltages to differential pair bases
            self.q1.port_bc.wdf.a = self.cv_smoothed * 2.0;
            self.q2.port_bc.wdf.a = self.v_ref * 2.0;

            // Process differential pair
            self.q1.process();
            self.q2.process();

            // Get collector current from Q1 (exponentially related to CV-Vref)
            const i_diff = self.q1.collectorCurrent();

            // Feed into Wilson current mirror (Q3)
            // The mirror input current sets the mirror output
            self.q3.port_bc.wdf.a = @abs(i_diff) * OscillatorComponents.exp_mirror_r * 2.0;
            self.q3.process();

            // Q4 and Q5 form the Wilson mirror output stage
            const i_mirror_ref = self.q3.collectorCurrent();
            self.q4.port_bc.wdf.a = @abs(i_mirror_ref) * OscillatorComponents.exp_mirror_r * 2.0;
            self.q4.process();

            self.q5.port_bc.wdf.a = @abs(self.q4.collectorCurrent()) * OscillatorComponents.exp_mirror_r * 2.0;
            self.q5.process();

            // Output current from the Wilson mirror
            // This is the exponentially-controlled charging current
            self.output_current = @abs(self.q5.collectorCurrent());

            // Clamp to reasonable range (prevents runaway)
            const min_current: T = 1.0e-9;
            const max_current: T = 10.0e-3;
            self.output_current = @max(min_current, @min(max_current, self.output_current));

            return self.output_current;
        }

        /// Get the current output without processing
        pub fn getOutputCurrent(self: *const Self) T {
            return self.output_current;
        }
    };
}

// ============================================================================
// 2N3392 Discharge Switch
// ============================================================================

/// Discharge switch for VCO sawtooth reset
///
/// Circuit topology:
///   Comparator output --+-- Base Q1 (2N3392)
///                       |      |
///                       |     |C---- To Integrating Capacitor
///                       |     |E
///                       |      |
///                      GND-----+
///
/// When the comparator detects the sawtooth has reached its peak,
/// it turns on Q1, which discharges the integrating capacitor.
/// This creates the sawtooth reset with realistic (~100ns) timing
/// instead of an instantaneous reset.
///
/// The finite discharge time creates authentic "softening" of the
/// sawtooth reset edge, which is part of the Minimoog's character.
pub fn DischargeSwitch(comptime T: type) type {
    const R = wdft.Resistor(T);
    const NPN = wdft.NpnTransistor(T, R, R);

    return struct {
        q1: NPN,

        // Switch state
        trigger: bool = false,

        // Discharge timing
        discharge_time: T = 0.0, // Time since trigger started
        discharge_duration: T = 0.0, // Duration of discharge (~100ns scaled to sample rate)

        // Capacitor voltage state
        cap_voltage: T = 0.0,

        sample_rate: T,

        const Self = @This();

        // 2N3392 parameters
        const q2n3392_is: T = OscillatorComponents.q2n3392_is;
        const q2n3392_vt: T = OscillatorComponents.q2n3392_vt;
        const q2n3392_alpha_f: T = OscillatorComponents.q2n3392_beta_f / (OscillatorComponents.q2n3392_beta_f + 1.0);
        const q2n3392_alpha_r: T = OscillatorComponents.q2n3392_beta_r / (OscillatorComponents.q2n3392_beta_r + 1.0);

        // Saturation resistance when switch is on
        const r_ce_sat: T = OscillatorComponents.q2n3392_r_ce_sat;

        pub fn init(sample_rate: T) Self {
            // Discharge duration: ~100ns in real circuit, scaled to samples
            // At 192kHz (4x oversampling of 48kHz), this is about 0.02 samples
            // We use a minimum of 1 sample for stability
            const discharge_ns: T = 100.0e-9;
            const discharge_samples = @max(1.0, discharge_ns * sample_rate);

            return Self{
                .q1 = NPN.init(
                    R.init(OscillatorComponents.source_resistance), // BC port
                    R.init(r_ce_sat), // BE port - saturation resistance
                    q2n3392_is,
                    q2n3392_vt,
                    q2n3392_alpha_f,
                    q2n3392_alpha_r,
                ),
                .sample_rate = sample_rate,
                .discharge_duration = discharge_samples,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            const discharge_ns: T = 100.0e-9;
            self.discharge_duration = @max(1.0, discharge_ns * sample_rate);
        }

        pub fn reset(self: *Self) void {
            self.q1.reset();
            self.trigger = false;
            self.discharge_time = 0.0;
            self.cap_voltage = OscillatorComponents.saw_low;
        }

        /// Trigger the discharge switch (called when sawtooth reaches threshold)
        pub fn setTrigger(self: *Self, on: bool) void {
            if (on and !self.trigger) {
                // Rising edge - start discharge
                self.discharge_time = 0.0;
            }
            self.trigger = on;
        }

        /// Process the discharge switch and return the new capacitor voltage
        /// This models the realistic discharge curve through the transistor
        pub inline fn processSample(self: *Self, current_cap_voltage: T) T {
            self.cap_voltage = current_cap_voltage;

            if (self.trigger) {
                // Transistor is conducting - discharge the capacitor
                // Apply base drive to turn transistor fully on
                self.q1.port_bc.wdf.a = 5.0 * 2.0; // 5V base drive

                // Process transistor
                self.q1.process();

                // Calculate discharge based on transistor's collector current
                // The collector current flows through the saturation resistance
                const i_discharge = @abs(self.q1.collectorCurrent());

                // Discharge the capacitor: dV = I * dt / C
                // dt = 1/sample_rate, simplified to discharge rate
                const discharge_rate = i_discharge / (OscillatorComponents.core_cap * self.sample_rate);

                // Exponential discharge towards saw_low
                const target = OscillatorComponents.saw_low;
                const discharge_factor = 1.0 - @exp(-discharge_rate * 10.0);
                self.cap_voltage += (target - self.cap_voltage) * discharge_factor;

                // Track discharge time
                self.discharge_time += 1.0;

                // Check if discharge is complete
                if (self.cap_voltage <= OscillatorComponents.saw_low * 0.95) {
                    self.cap_voltage = OscillatorComponents.saw_low;
                    self.trigger = false;
                }
            }

            return self.cap_voltage;
        }

        /// Check if the switch is currently discharging
        pub fn isDischarging(self: *const Self) bool {
            return self.trigger;
        }

        /// Get the current capacitor voltage
        pub fn getCapVoltage(self: *const Self) T {
            return self.cap_voltage;
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
///
/// Anti-aliasing is handled via PolyBLEP/PolyBLAMP.
/// Global oversampling is done at the voice level (see oversampler.zig).
pub fn VCO(comptime T: type) type {
    // WDF circuit topology:
    // - CA3046 exponential converter generates charging current from CV
    // - Current charges the integrating capacitor
    // - 2N3392 discharge switch resets the capacitor when threshold is reached
    const C = wdft.Capacitor(T);
    const ICS = wdft.IdealCurrentSource(T, C);

    return struct {
        // Core integrator circuit
        circuit: ICS,

        // CA3046 exponential converter for CV-to-current conversion
        exp_converter: CA3046ExpConverter(T),

        // 2N3392 discharge switch for realistic sawtooth reset
        discharge_switch: DischargeSwitch(T),

        frequency: T = OscillatorComponents.base_frequency,
        sample_rate: T,
        waveform: Waveform = .sawtooth,
        pulse_width: T = 0.5, // For pulse wave (0.0 to 1.0)

        // CV input (1V/octave)
        cv_input: T = 0.0,

        // Detune in cents (-100 to +100 typical)
        detune_cents: T = 0.0,

        // Octave offset (-2 to +2)
        octave_offset: i8 = 0,

        // Phase tracking (for waveform shaping and PolyBLEP)
        phase: T = 0.0,
        phase_increment: T = 0.0,

        // Charging current (from exponential converter)
        charge_current: T = 0.0,

        // Track reset for PolyBLEP (Fix 6: store fractional phase at discontinuity)
        reset_occurred: bool = false,
        reset_fractional_phase: T = 0.0, // Fractional phase where reset occurred

        // Anti-aliasing mode:
        // - true: Use PolyBLEP/PolyBLAMP (for 1x, no oversampling)
        // - false: Raw WDF output (for 2x/4x, oversampling handles aliasing)
        use_digital_antialiasing: bool = true,

        const Self = @This();

        const voltage_swing: T = OscillatorComponents.saw_high - OscillatorComponents.saw_low;

        pub fn init(sample_rate: T) Self {
            var self = Self{
                .circuit = ICS.init(C.init(OscillatorComponents.core_cap, sample_rate)),
                .exp_converter = CA3046ExpConverter(T).init(sample_rate),
                .discharge_switch = DischargeSwitch(T).init(sample_rate),
                .sample_rate = sample_rate,
            };
            self.updatePhaseIncrement();
            return self;
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.circuit.next.prepare(sample_rate);
            self.circuit.calcImpedance();
            self.exp_converter.prepare(sample_rate);
            self.discharge_switch.prepare(sample_rate);
            self.updatePhaseIncrement();
        }

        pub fn reset(self: *Self) void {
            self.phase = 0.0;
            self.circuit.next.reset();
            self.exp_converter.reset();
            self.discharge_switch.reset();
            self.reset_occurred = false;
            self.reset_fractional_phase = 0.0;
        }

        /// Set frequency directly in Hz
        pub fn setFrequency(self: *Self, freq_hz: T) void {
            self.frequency = @max(0.1, @min(freq_hz, self.sample_rate * 0.45)); // Nyquist limit
            // Convert frequency to CV: CV = log2(freq / base_freq)
            self.cv_input = std.math.log2(self.frequency / OscillatorComponents.base_frequency);
            self.exp_converter.setCV(self.cv_input);
            self.updatePhaseIncrement();
        }

        /// Set frequency via MIDI note number (69 = A4 = 440Hz)
        pub fn setMidiNote(self: *Self, note: T) void {
            const freq = 440.0 * std.math.pow(T, 2.0, (note - 69.0) / 12.0);
            self.setFrequency(freq);
        }

        /// Set frequency via 1V/octave CV (0V = base frequency)
        /// Uses the CA3046 exponential converter for authentic response
        pub fn setCV(self: *Self, cv_volts: T) void {
            self.cv_input = cv_volts + @as(T, @floatFromInt(self.octave_offset));
            self.exp_converter.setCV(self.cv_input);
            const freq = OscillatorComponents.base_frequency * std.math.pow(T, 2.0, self.cv_input);
            self.frequency = @max(0.1, @min(freq, self.sample_rate * 0.45));
            self.updatePhaseIncrement();
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

        /// Set digital anti-aliasing mode
        /// - true: Use PolyBLEP/PolyBLAMP (for 1x, no oversampling)
        /// - false: Raw WDF output (for 2x/4x, oversampling handles aliasing)
        pub fn setDigitalAntialiasing(self: *Self, enabled: bool) void {
            self.use_digital_antialiasing = enabled;
        }

        fn updatePhaseIncrement(self: *Self) void {
            // Apply detune
            const detune_factor = std.math.pow(T, 2.0, self.detune_cents / 1200.0);
            const final_freq = self.frequency * detune_factor;

            // Phase increment based on sample rate
            self.phase_increment = final_freq / self.sample_rate;

            // Calculate charging current for desired frequency
            // From I = C * dV/dt, and we need full swing in one period:
            // I = C * voltage_swing * frequency
            self.charge_current = OscillatorComponents.core_cap * voltage_swing * final_freq;
            self.circuit.setCurrent(self.charge_current);
        }

        /// Generate one sample
        /// Uses transistor exponential converter and discharge switch for authentic behavior
        /// If use_digital_antialiasing is true, applies PolyBLEP/PolyBLAMP
        /// If false, outputs raw WDF waveform (for use with oversampling)
        pub inline fn processSample(self: *Self) T {
            // Process the exponential converter to get charging current
            // The CA3046 converts CV to exponential current
            const exp_current = self.exp_converter.processSample();

            // Update the circuit's charging current from the exponential converter
            // Blend between calculated current and exp converter for stability
            const blended_current = self.charge_current * 0.5 + exp_current * 0.5 * 1e6; // Scale exp output
            self.circuit.setCurrent(@max(1.0e-9, blended_current));

            // Process WDF circuit - current charges the capacitor
            self.circuit.process();

            // Read capacitor voltage (this is our sawtooth core)
            var cap_voltage = wdft.voltage(T, &self.circuit.next.wdf);

            // Check for reset threshold
            self.reset_occurred = false;
            if (cap_voltage >= OscillatorComponents.saw_high) {
                // Store fractional phase at discontinuity before resetting
                self.reset_fractional_phase = @mod(self.phase + self.phase_increment, 1.0);

                // Trigger the discharge switch (2N3392 transistor)
                self.discharge_switch.setTrigger(true);
                self.reset_occurred = true;
                self.phase = self.reset_fractional_phase;
            }

            // If discharge switch is active, use it to discharge the capacitor
            if (self.discharge_switch.isDischarging()) {
                cap_voltage = self.discharge_switch.processSample(cap_voltage);
                // Update the WDF capacitor state with the discharge result
                self.circuit.next.z = cap_voltage * 2.0;
            }

            // Advance phase (for derived waveforms)
            self.phase += self.phase_increment;
            if (self.phase >= 1.0) {
                self.phase -= 1.0;
            }

            // Generate output waveform
            if (self.use_digital_antialiasing) {
                // 1x mode: Use PolyBLEP/PolyBLAMP for anti-aliasing
                return switch (self.waveform) {
                    .sawtooth => self.generateSawWithBLEP(cap_voltage),
                    .triangle => self.generateTriangleWithBLAMP(cap_voltage),
                    .square => self.generateSquareWithBLEP(),
                    .pulse => self.generatePulseWithBLEP(),
                };
            } else {
                // 2x/4x mode: Raw WDF output, oversampling handles aliasing
                return switch (self.waveform) {
                    .sawtooth => self.generateSawRaw(cap_voltage),
                    .triangle => self.generateTriangleRaw(cap_voltage),
                    .square => self.generateSquareRaw(),
                    .pulse => self.generatePulseRaw(),
                };
            }
        }

        /// Sawtooth with PolyBLEP at reset discontinuity
        fn generateSawWithBLEP(self: *Self, cap_voltage: T) T {
            // Normalize from [saw_low, saw_high] to [-1, +1]
            const normalized = (cap_voltage - OscillatorComponents.saw_low) / voltage_swing;
            var output = normalized * 2.0 - 1.0;

            // Apply PolyBLEP correction at reset discontinuity
            if (self.reset_occurred) {
                // Fix 6: Use the stored fractional phase for accurate correction
                output -= PolyBLEP(T).correction(self.reset_fractional_phase, self.phase_increment) * 2.0;
            }

            return output;
        }

        /// Triangle with PolyBLAMP at peaks (Fix 7)
        fn generateTriangleWithBLAMP(self: *Self, cap_voltage: T) T {
            // Generate from sawtooth by folding
            const normalized = (cap_voltage - OscillatorComponents.saw_low) / voltage_swing;
            const saw = normalized * 2.0 - 1.0;

            // Fold: abs(saw) gives 0->1->0, then scale to -1->1->-1
            var output = @abs(saw) * 2.0 - 1.0;

            // Fix 7: Apply PolyBLAMP at triangle peaks (phase 0.25 and 0.75)
            // Peak at phase 0 (bottom of triangle, saw reset point)
            output += PolyBLAMP(T).correction(self.phase, self.phase_increment) * 4.0;

            // Peak at phase 0.5 (top of triangle)
            const peak_phase = @mod(self.phase + 0.5, 1.0);
            output -= PolyBLAMP(T).correction(peak_phase, self.phase_increment) * 4.0;

            return output;
        }

        /// Square wave with PolyBLEP
        fn generateSquareWithBLEP(self: *Self) T {
            const raw = if (self.phase < 0.5) @as(T, 1.0) else @as(T, -1.0);
            return PolyBLEP(T).pulseCorrection(self.phase, self.phase_increment, 0.5, raw);
        }

        /// Pulse wave with PolyBLEP
        fn generatePulseWithBLEP(self: *Self) T {
            const raw = if (self.phase < self.pulse_width) @as(T, 1.0) else @as(T, -1.0);
            return PolyBLEP(T).pulseCorrection(self.phase, self.phase_increment, self.pulse_width, raw);
        }

        // ====================================================================
        // Raw WDF waveform generation (for use with oversampling)
        // ====================================================================

        /// Raw sawtooth from WDF capacitor voltage (no anti-aliasing)
        fn generateSawRaw(self: *Self, cap_voltage: T) T {
            _ = self;
            // Normalize from [saw_low, saw_high] to [-1, +1]
            const normalized = (cap_voltage - OscillatorComponents.saw_low) / voltage_swing;
            return normalized * 2.0 - 1.0;
        }

        /// Raw triangle from folded sawtooth (no anti-aliasing)
        fn generateTriangleRaw(self: *Self, cap_voltage: T) T {
            const saw = self.generateSawRaw(cap_voltage);
            // Fold: abs(saw) gives 0->1->0, then scale to -1->1->-1
            return @abs(saw) * 2.0 - 1.0;
        }

        /// Raw square wave (no anti-aliasing)
        fn generateSquareRaw(self: *Self) T {
            return if (self.phase < 0.5) @as(T, 1.0) else @as(T, -1.0);
        }

        /// Raw pulse wave (no anti-aliasing)
        fn generatePulseRaw(self: *Self) T {
            return if (self.phase < self.pulse_width) @as(T, 1.0) else @as(T, -1.0);
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

        /// Set digital anti-aliasing mode for all oscillators
        /// - true: Use PolyBLEP/PolyBLAMP (for 1x, no oversampling)
        /// - false: Raw WDF output (for 2x/4x, oversampling handles aliasing)
        pub fn setDigitalAntialiasing(self: *Self, enabled: bool) void {
            self.osc1.setDigitalAntialiasing(enabled);
            self.osc2.setDigitalAntialiasing(enabled);
            self.osc3.setDigitalAntialiasing(enabled);
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

test "polyblamp produces correction at peaks" {
    const T = f64;

    // Test PolyBLAMP correction at peak
    const dt: T = 0.01;

    // At phase near 0, correction should be non-zero
    const correction_at_peak = PolyBLAMP(T).correction(0.005, dt);
    try std.testing.expect(@abs(correction_at_peak) > 0.0);

    // At phase = 0.5 (away from peak), correction should be zero
    const correction_at_mid = PolyBLAMP(T).correction(0.5, dt);
    try std.testing.expect(@abs(correction_at_mid) < 0.001);
}

test "triangle wave is generated" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var vco = VCO(T).init(sample_rate);
    vco.setFrequency(100.0);
    vco.setWaveform(.triangle);

    // Generate samples and verify output is in range
    for (0..500) |_| {
        const sample = vco.processSample();
        try std.testing.expect(sample >= -1.5 and sample <= 1.5);
    }
}
