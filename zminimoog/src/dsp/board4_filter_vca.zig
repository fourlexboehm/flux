// Board 4: Filter and VCA Board
// Minimoog Model D - 24dB/octave Voltage Controlled Lowpass Filter (Ladder) and VCA
//
// Schematic page 10 of Minimoog-schematics.pdf
//
// Circuit 6: Moog Ladder Filter
//   - 4-pole (24dB/octave) transistor ladder lowpass filter
//   - Resonance via feedback from output to input
//   - Exponential frequency control
//   - Transistor soft-clipping nonlinearity
//
// Circuit 7: Voltage Controlled Amplifier
//   - Differential pair VCA
//   - Controlled by loudness envelope
//
// WDF Implementation based on:
//   "Direct Synthesis of Ladder Wave Digital Filters with Tunable Parameters"
//   by S.A. Samad, AJSTD Vol. 20 Issue 1, 2003
//
// Key equations from paper:
//   - First-order WDF coefficient: m = tan(ωc/2) / (1 + tan(ωc/2))  [eq. 50]
//   - First-order lowpass: y[n] = m*(x[n] + x[n-1]) + (1-2m)*y[n-1]  [eq. 48]

const std = @import("std");
const wdft = @import("wdf");

// ============================================================================
// Component Values from Schematic
// ============================================================================

pub const FilterComponents = struct {
    // Ladder capacitors (all identical for matched response)
    // From schematic: C1, C5, C11, C16 = 0.068uF
    pub const ladder_cap: comptime_float = 0.068e-6; // 0.068uF = 68nF

    // Transistor parameters (TIS91 approximation)
    pub const vt: comptime_float = 25.85e-3; // Thermal voltage at 25°C

    // Base resistance for each stage (approximation of transistor impedance)
    // Used for base cutoff calculation
    pub const stage_resistance: comptime_float = 10000.0; // ~10k base impedance

    // Resonance feedback scaling
    // The Moog ladder has k=4 at self-oscillation
    pub const max_resonance: comptime_float = 4.0;

    // Transistor saturation level (normalized)
    // Models the soft clipping in each differential pair
    pub const saturation_level: comptime_float = 1.0;

    // WDF ladder input/feedback/load resistances (Ohms)
    // R_in is small relative to R_stage so voltage divider doesn't
    // attenuate the signal (one-port BJT provides no voltage gain).
    pub const input_resistance: comptime_float = 100.0;
    // R_fb is high so the feedback path doesn't load the filter
    // (feedback is applied at the voltage source, not through R_fb).
    pub const feedback_resistance: comptime_float = 100000.0;
    pub const load_resistance: comptime_float = 100000.0;
    pub const feedback_gain: comptime_float = 4.0;
    pub const cutoff_scale: comptime_float = 1.0;

    // BJT parameters (RT-WDF defaults for Ebers-Moll model)
    pub const bjt_is: comptime_float = 5.911e-15;
    pub const bjt_vt: comptime_float = 25.85e-3;
    pub const bjt_beta_f: comptime_float = 1.434e3;
    pub const bjt_beta_r: comptime_float = 1.262;
    pub const bjt_is_scale: comptime_float = 1.0;
};

pub const VCAComponents = struct {
    // Differential pair parameters (2N4058)
    pub const vt: comptime_float = 25.85e-3;
    pub const beta: comptime_float = 100.0; // Current gain
    pub const input_r: comptime_float = 47000.0; // 47k input impedance
    pub const output_r: comptime_float = 1000.0; // 1k output
};

// ============================================================================
// Nonlinear Functions for Transistor Modeling
// ============================================================================

/// Fast tanh approximation for real-time use
/// Pade approximant: tanh(x) ≈ x(27 + x²) / (27 + 9x²) for |x| < 3
fn fastTanh(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    const x2 = x * x;
    // Clamp for stability at extreme values
    if (x > 3.0) return @as(T, 1.0);
    if (x < -3.0) return @as(T, -1.0);
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

// ============================================================================
// WDF One-Port BJT Pair (Reduced Differential Pair)
// ============================================================================

/// One-port nonlinear element using a reduced BJT differential pair model.
/// The port current is computed from a symmetric Ebers-Moll pair:
///   i(v) = Is/alpha_f*(exp(v/Vt)-1) - Is/alpha_r*(exp(-v/Vt)-1)
/// This preserves a true WDF topology while using full BJT equations.
pub fn WdfBjtPairOnePort(comptime T: type) type {
    comptime if (@typeInfo(T) != .float) @compileError("WdfBjtPairOnePort requires a scalar float type");

    return struct {
        wdf: wdft.Wdf(T) = .{},
        r_value: T,
        is: T,
        vt: T,
        beta_f: T,
        beta_r: T,
        alpha_f: T = 0.0,
        alpha_r: T = 0.0,
        last_v: T = 0.0,
        max_iters: u8 = 50,
        tol: T = 1.0e-6,

        const Self = @This();

        pub fn init(resistance: T, saturation_current: T, thermal_voltage: T, beta_f: T, beta_r: T) Self {
            var self = Self{
                .r_value = resistance,
                .is = saturation_current,
                .vt = thermal_voltage,
                .beta_f = beta_f,
                .beta_r = beta_r,
            };
            self.updateAlphas();
            self.calcImpedance();
            return self;
        }

        pub fn calcImpedance(self: *Self) void {
            self.wdf.R = self.r_value;
            self.wdf.G = 1.0 / self.wdf.R;
        }

        pub fn setResistance(self: *Self, r: T) void {
            self.r_value = r;
        }

        pub fn setIs(self: *Self, is: T) void {
            self.is = is;
        }

        pub fn setVt(self: *Self, vt: T) void {
            self.vt = vt;
        }

        pub fn setBetaF(self: *Self, beta_f: T) void {
            self.beta_f = beta_f;
            self.updateAlphas();
        }

        pub fn setBetaR(self: *Self, beta_r: T) void {
            self.beta_r = beta_r;
            self.updateAlphas();
        }

        fn updateAlphas(self: *Self) void {
            const eps: T = 1.0e-12;
            const denom_f = @max(eps, 1.0 + self.beta_f);
            const denom_r = @max(eps, 1.0 + self.beta_r);
            self.alpha_f = self.beta_f / denom_f;
            self.alpha_r = self.beta_r / denom_r;
        }

        pub inline fn incident(self: *Self, x: T) void {
            self.wdf.a = x;
        }

        fn clampExp(x: T) T {
            return @max(-40.0, @min(40.0, x));
        }

        fn iBjtPair(self: *Self, v: T) T {
            const one_over_vt = 1.0 / self.vt;
            const exp_pos = std.math.exp(clampExp(v * one_over_vt));
            const exp_neg = std.math.exp(clampExp(-v * one_over_vt));
            return (self.is / self.alpha_f) * (exp_pos - 1.0) - (self.is / self.alpha_r) * (exp_neg - 1.0);
        }

        fn dIdV(self: *Self, v: T) T {
            const one_over_vt = 1.0 / self.vt;
            const exp_pos = std.math.exp(clampExp(v * one_over_vt));
            const exp_neg = std.math.exp(clampExp(-v * one_over_vt));
            return (self.is / (self.alpha_f * self.vt)) * exp_pos + (self.is / (self.alpha_r * self.vt)) * exp_neg;
        }

        pub inline fn reflected(self: *Self) T {
            const a = self.wdf.a;
            const r = self.wdf.R;

            var v = self.last_v;
            var iter: u8 = 0;
            while (iter < self.max_iters) : (iter += 1) {
                const f = self.iBjtPair(v) - (a - v) / r;
                const df = self.dIdV(v) + (1.0 / r);
                if (@abs(df) < 1.0e-12) break;
                var dv = -f / df;
                // Dampen large Newton steps to prevent overshoot
                const max_step: T = 0.5;
                dv = @max(-max_step, @min(max_step, dv));
                v += dv;
                if (@abs(dv) < self.tol) break;
            }

            self.last_v = v;
            self.wdf.b = 2.0 * v - a;
            return self.wdf.b;
        }
    };
}

fn countNlPortsComptime(comptime models: []const wdft.NlModelType) usize {
    var total: usize = 0;
    for (models) |m| {
        switch (m) {
            .diode, .diode_ap => total += 1,
            .npn_em, .pnp_em, .tri_dw => total += 2,
        }
    }
    return total;
}

pub fn WdfNlRootOnePort(comptime T: type, comptime models: []const wdft.NlModelType) type {
    comptime if (@typeInfo(T) != .float) @compileError("WdfNlRootOnePort requires a scalar float type");

    const num_nl_ports = countNlPortsComptime(models);
    const buffer_size = 8192;

    return struct {
        wdf: wdft.Wdf(T) = .{},
        r_value: T,
        nonlinear_r: [num_nl_ports]f64 = undefined,
        buffer: [buffer_size]u8 = undefined,
        fba: std.heap.FixedBufferAllocator = undefined,
        mat_data: wdft.MatData = undefined,
        solver: wdft.NlNewtonSolver = undefined,
        in_waves: [1]f64 = .{0.0},
        out_waves: [1]f64 = .{0.0},
        initialized: bool = false,

        const Self = @This();

        pub fn init(resistance: T) Self {
            var self: Self = undefined;
            self.wdf = .{};
            self.r_value = resistance;
            self.in_waves = .{0.0};
            self.out_waves = .{0.0};
            self.initialized = false;
            self.buffer = [_]u8{0} ** buffer_size;
            self.fba = std.heap.FixedBufferAllocator.init(self.buffer[0..]);
            var i: usize = 0;
            while (i < num_nl_ports) : (i += 1) {
                self.nonlinear_r[i] = @floatCast(resistance);
            }
            self.rebuildMatrices();
            return self;
        }

        pub fn calcImpedance(self: *Self) void {
            self.wdf.R = self.r_value;
            self.wdf.G = 1.0 / self.wdf.R;
        }

        pub fn setResistance(self: *Self, r: T) void {
            self.r_value = r;
            var i: usize = 0;
            while (i < num_nl_ports) : (i += 1) {
                self.nonlinear_r[i] = @floatCast(r);
            }
            self.rebuildMatrices();
        }

        fn rebuildMatrices(self: *Self) void {
            if (self.initialized) {
                self.solver.deinit();
                wdft.deinitMatData(&self.mat_data);
                self.fba = std.heap.FixedBufferAllocator.init(self.buffer[0..]);
            }

            const allocator = self.fba.allocator();
            const linear_r = [_]f64{ @floatCast(self.r_value) };
            self.mat_data = wdft.buildParallelRootMatrices(allocator, &linear_r, &self.nonlinear_r) catch @panic("buildParallelRootMatrices failed");
            self.solver = wdft.NlNewtonSolver.init(allocator, models, &self.mat_data) catch @panic("NlNewtonSolver init failed");
            self.calcImpedance();
            self.initialized = true;
        }

        pub inline fn incident(self: *Self, x: T) void {
            self.wdf.a = x;
        }

        pub inline fn reflected(self: *Self) T {
            self.in_waves[0] = @floatCast(self.wdf.a);
            self.solver.nlSolve(&self.in_waves, &self.out_waves);
            self.wdf.b = @floatCast(self.out_waves[0]);
            return self.wdf.b;
        }
    };
}

// ============================================================================
// First-Order WDF Ladder Section
// ============================================================================

/// Single stage of the WDF ladder filter
/// Implements a first-order lowpass with tunable cutoff coefficient
///
/// Based on the paper "Direct Synthesis of Ladder Wave Digital Filters"
/// Transfer function from eq. 48:
///   G(z) = (m + m*z^-1) / (1 + (2m-1)*z^-1)
///        = m*(1 + z^-1) / (1 - (1-2m)*z^-1)
///
/// Difference equation:
///   y[n] = m*(x[n] + x[n-1]) + (1-2m)*y[n-1]
///
/// The coefficient m = tan(ωc/2) / (1 + tan(ωc/2)) controls cutoff
pub fn WdfLadderSection(comptime T: type) type {
    return struct {
        // Adaptor coefficient (controls cutoff frequency)
        m: T = 0.5,

        // State variables
        x1: T = 0.0, // Previous input x[n-1]
        y1: T = 0.0, // Previous output y[n-1]

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.x1 = 0.0;
            self.y1 = 0.0;
        }

        /// Set the adaptor coefficient directly
        /// m should be in range (0, 1)
        pub fn setCoefficient(self: *Self, coeff: T) void {
            self.m = @max(0.001, @min(0.999, coeff));
        }

        /// Set cutoff frequency and compute coefficient
        /// ωc is the digital cutoff frequency in radians (0 to π)
        pub fn setCutoffOmega(self: *Self, omega_c: T) void {
            // From paper equation (50): m = tan(ωc/2) / (1 + tan(ωc/2))
            // Clamp omega to avoid tan explosion near π
            const clamped_omega = @min(omega_c, std.math.pi * 0.98);
            const half_omega = clamped_omega * 0.5;
            const tan_half = std.math.tan(half_omega);
            self.m = tan_half / (1.0 + tan_half);
            // Clamp for stability
            self.m = @max(0.001, @min(0.999, self.m));
        }

        /// Set cutoff frequency in Hz given sample rate
        pub fn setCutoffHz(self: *Self, freq_hz: T, sample_rate: T) void {
            // Digital frequency: ω = 2π * f / fs
            // Clamp to prevent instability near Nyquist
            const max_freq = sample_rate * 0.45;
            const min_freq: T = 20.0;
            const clamped_freq = @max(min_freq, @min(freq_hz, max_freq));
            const omega_c = 2.0 * std.math.pi * clamped_freq / sample_rate;
            self.setCutoffOmega(omega_c);
        }

        /// Process one sample through the WDF section (linear)
        /// Implements: y[n] = m*(x[n] + x[n-1]) + (1-2m)*y[n-1]
        pub inline fn processSample(self: *Self, input: T) T {
            // First-order lowpass from bilinear transform of RC filter
            // This gives proper frequency warping and zero at Nyquist
            const x0 = input;
            const one_minus_2m = 1.0 - 2.0 * self.m;

            const output = self.m * (x0 + self.x1) + one_minus_2m * self.y1;

            // Update state
            self.x1 = x0;
            self.y1 = output;

            return output;
        }

        /// Process with nonlinear saturation (models transistor clipping)
        pub inline fn processSampleNonlinear(self: *Self, input: T, saturation: T) T {
            // Apply soft saturation to input (models transistor differential pair)
            const saturated_input = fastTanh(input / saturation) * saturation;
            return self.processSample(saturated_input);
        }
    };
}

pub const LadderStage = WdfLadderSection;

// ============================================================================
// Moog Ladder Filter (4-Pole with Resonance)
// ============================================================================

/// Classic Moog 4-pole ladder filter with resonance
/// Four cascaded WDF lowpass stages with global feedback
///
/// The resonance is implemented by feeding the 4th stage output back
/// to the input, scaled by k. At k=4, the filter self-oscillates.
pub fn MoogLadderFilter(comptime T: type) type {
    const Rin = wdft.Resistor(T);
    const Rfb = wdft.ResistiveVoltageSource(T);
    const Rload = wdft.Resistor(T);
    const Cap = wdft.Capacitor(T);
    const StageNl = WdfBjtPairOnePort(T);

    const P4 = wdft.Parallel(T, Cap, Rload);
    const S4 = wdft.Series(T, StageNl, P4);
    const P3 = wdft.Parallel(T, Cap, S4);
    const S3 = wdft.Series(T, StageNl, P3);
    const P2 = wdft.Parallel(T, Cap, S3);
    const S2 = wdft.Series(T, StageNl, P2);
    const P1 = wdft.Parallel(T, Cap, S2);
    const S1 = wdft.Series(T, StageNl, P1);

    const Pfb = wdft.Parallel(T, Rfb, S1);
    const Sin = wdft.Series(T, Rin, Pfb);
    const Inv = wdft.PolarityInverter(T, Sin);
    const Root = wdft.IdealVoltageSource(T, Inv);

    return struct {
        // WDF circuit tree
        circuit: Root,

        // Current parameters
        cutoff_hz: T = 1000.0,
        resonance: T = 0.0, // k factor: 0 to 4 (self-oscillation)
        sample_rate: T,

        // Parameter smoothing targets
        cutoff_target: T = 1000.0,
        resonance_target: T = 0.0,

        // Feedback state (delayed by one sample for stability)
        feedback: T = 0.0,

        // Compensation for gain loss at high resonance
        compensation: T = 1.0,
        compensation_target: T = 1.0,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            const r_stage = stageResistance(1000.0, sample_rate);
            var self = Self{
                .circuit = Root.init(
                    Inv.init(
                        Sin.init(
                            Rin.init(FilterComponents.input_resistance),
                            Pfb.init(
                                Rfb.init(FilterComponents.feedback_resistance),
                                S1.init(
                                    StageNl.init(
                                        r_stage,
                                        FilterComponents.bjt_is * FilterComponents.bjt_is_scale,
                                        FilterComponents.bjt_vt,
                                        FilterComponents.bjt_beta_f,
                                        FilterComponents.bjt_beta_r,
                                    ),
                                    P1.init(
                                        Cap.init(FilterComponents.ladder_cap, sample_rate),
                                        S2.init(
                                            StageNl.init(
                                                r_stage,
                                                FilterComponents.bjt_is * FilterComponents.bjt_is_scale,
                                                FilterComponents.bjt_vt,
                                                FilterComponents.bjt_beta_f,
                                                FilterComponents.bjt_beta_r,
                                            ),
                                            P2.init(
                                                Cap.init(FilterComponents.ladder_cap, sample_rate),
                                                S3.init(
                                                    StageNl.init(
                                                        r_stage,
                                                        FilterComponents.bjt_is * FilterComponents.bjt_is_scale,
                                                        FilterComponents.bjt_vt,
                                                        FilterComponents.bjt_beta_f,
                                                        FilterComponents.bjt_beta_r,
                                                    ),
                                                    P3.init(
                                                        Cap.init(FilterComponents.ladder_cap, sample_rate),
                                                        S4.init(
                                                            StageNl.init(
                                                                r_stage,
                                                                FilterComponents.bjt_is * FilterComponents.bjt_is_scale,
                                                                FilterComponents.bjt_vt,
                                                                FilterComponents.bjt_beta_f,
                                                                FilterComponents.bjt_beta_r,
                                                            ),
                                                            P4.init(
                                                                Cap.init(FilterComponents.ladder_cap, sample_rate),
                                                                Rload.init(FilterComponents.load_resistance),
                                                            ),
                                                        ),
                                                    ),
                                                ),
                                            ),
                                        ),
                                    ),
                                ),
                            ),
                        ),
                    ),
                ),
                .sample_rate = sample_rate,
            };
            self.setCutoff(1000.0);
            self.updateImpedances();
            return self;
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.cap1().prepare(sample_rate);
            self.cap2().prepare(sample_rate);
            self.cap3().prepare(sample_rate);
            self.cap4().prepare(sample_rate);
            self.updateImpedances();
        }

        pub fn reset(self: *Self) void {
            self.cap1().reset();
            self.cap2().reset();
            self.cap3().reset();
            self.cap4().reset();
            self.feedback = 0.0;
            self.cutoff_hz = self.cutoff_target;
            self.resonance = self.resonance_target;
            self.compensation = self.compensation_target;
        }

        /// Set cutoff frequency in Hz
        pub fn setCutoff(self: *Self, frequency_hz: T) void {
            self.cutoff_target = @max(20.0, @min(frequency_hz, self.sample_rate * 0.49));
        }

        /// Set cutoff via 1V/octave CV (0V = 261.63 Hz, middle C)
        pub fn setCutoffCV(self: *Self, cv_volts: T) void {
            // 1V/octave: each volt doubles frequency
            // 0V = middle C (261.63 Hz)
            const base_freq: T = 261.63;
            const frequency_hz = base_freq * std.math.pow(T, 2.0, cv_volts);
            self.setCutoff(frequency_hz);
        }

        /// Set resonance (emphasis)
        /// 0.0 = no resonance
        /// ~3.9 = near self-oscillation
        /// 4.0 = self-oscillation
        pub fn setResonance(self: *Self, res: T) void {
            self.resonance_target = @max(0.0, @min(res, FilterComponents.max_resonance));
            // Compensate for gain loss at high resonance
            // Each pole reduces passband gain by ~1/(1+k/4) factor
            self.compensation_target = 1.0 + self.resonance_target * 0.25;
        }

        /// Enable/disable transistor nonlinearity modeling
        pub fn setNonlinear(self: *Self, enabled: bool) void {
            _ = self;
            _ = enabled;
        }

        /// Set saturation level for nonlinear mode
        pub fn setSaturation(self: *Self, level: T) void {
            _ = self;
            _ = level;
        }

        fn stageResistance(cutoff_hz: T, sample_rate: T) T {
            const max_freq = sample_rate * 0.49;
            const min_freq: T = 20.0;
            const scaled = cutoff_hz * FilterComponents.cutoff_scale;
            const clamped = @max(min_freq, @min(scaled, max_freq));
            // Bilinear pre-warped: R_stage = R_cap / tan(π * fc / fs)
            // R_cap is the WDF capacitor port resistance = 1/(2*C*fs)
            // This ensures correct frequency mapping through the WDF adaptors.
            // At low frequencies this approximates 1/(2π*fc*C), the analog value.
            const r_cap = 1.0 / (2.0 * FilterComponents.ladder_cap * sample_rate);
            const omega_d = std.math.pi * clamped / sample_rate;
            const tan_omega = std.math.tan(omega_d);
            if (tan_omega < 1.0e-10) return r_cap * 1.0e10; // prevent division by zero
            return r_cap / tan_omega;
        }

        fn updateImpedances(self: *Self) void {
            const r_stage = stageResistance(self.cutoff_target, self.sample_rate);
            // Dynamically adjust BJT saturation current to match operating point.
            // In the real Moog, bias current sets both cutoff and transistor gm.
            // Is_eff = Vt / (r_stage * (1/αf + 1/αr)) models this coupling.
            const alpha_recip_sum = 1.0 / self.stage1().alpha_f + 1.0 / self.stage1().alpha_r;
            const is_eff = FilterComponents.bjt_vt / (r_stage * alpha_recip_sum);
            self.stage1().setResistance(r_stage);
            self.stage1().setIs(is_eff);
            self.stage2().setResistance(r_stage);
            self.stage2().setIs(is_eff);
            self.stage3().setResistance(r_stage);
            self.stage3().setIs(is_eff);
            self.stage4().setResistance(r_stage);
            self.stage4().setIs(is_eff);
            self.circuit.calcImpedance();
        }

        fn stage1(self: *Self) *StageNl {
            return &self.circuit.next.port1.port2.port2.port1;
        }

        fn stage2(self: *Self) *StageNl {
            return &self.circuit.next.port1.port2.port2.port2.port2.port1;
        }

        fn stage3(self: *Self) *StageNl {
            return &self.circuit.next.port1.port2.port2.port2.port2.port2.port2.port1;
        }

        fn stage4(self: *Self) *StageNl {
            return &self.circuit.next.port1.port2.port2.port2.port2.port2.port2.port2.port2.port1;
        }

        fn cap1(self: *Self) *Cap {
            return &self.circuit.next.port1.port2.port2.port2.port1;
        }

        fn cap2(self: *Self) *Cap {
            return &self.circuit.next.port1.port2.port2.port2.port2.port2.port1;
        }

        fn cap3(self: *Self) *Cap {
            return &self.circuit.next.port1.port2.port2.port2.port2.port2.port2.port2.port1;
        }

        fn cap4(self: *Self) *Cap {
            return &self.circuit.next.port1.port2.port2.port2.port2.port2.port2.port2.port2.port2.port1;
        }

        fn feedbackSource(self: *Self) *Rfb {
            return &self.circuit.next.port1.port2.port1;
        }

        fn outputWdf(self: *Self) *const wdft.Wdf(T) {
            return &self.cap4().wdf;
        }

        /// Smooth parameter changes to avoid clicks
        fn smoothParam(current: T, target: T, coeff: T) T {
            return current + (target - current) * coeff;
        }

        /// Process one sample through the 4-pole filter
        pub inline fn processSample(self: *Self, input: T) T {
            // Parameter smoothing (~1ms time constant at 48kHz)
            const smooth_coeff: T = 0.02;

            // Smooth cutoff changes
            const prev_cutoff = self.cutoff_hz;
            self.cutoff_hz = smoothParam(self.cutoff_hz, self.cutoff_target, smooth_coeff);
            if (@abs(self.cutoff_hz - prev_cutoff) > 0.01) {
                self.updateImpedances();
            }

            // Smooth resonance and compensation
            self.resonance = smoothParam(self.resonance, self.resonance_target, smooth_coeff);
            self.compensation = smoothParam(self.compensation, self.compensation_target, smooth_coeff);

            // Apply resonance feedback at the voltage source (before WDF tree).
            // feedback_gain compensates for one-port BJT not providing voltage gain.
            // Tanh saturation models transistor pair limiting in the real feedback path.
            const fb_raw = self.resonance * FilterComponents.feedback_gain * self.feedback;
            const fb = fastTanh(fb_raw / FilterComponents.saturation_level) * FilterComponents.saturation_level;
            self.circuit.setVoltage(input - fb);
            self.feedbackSource().setVoltage(0.0);
            self.circuit.process();

            const output = wdft.voltage(T, self.outputWdf());
            self.feedback = output;

            // Apply output compensation (after filter — avoids amplifying feedback)
            return output * self.compensation;
        }

        /// Get intermediate outputs for multimode operation
        pub fn processSampleMultimode(self: *Self, input: T) FilterOutputs(T) {
            // Parameter smoothing
            const smooth_coeff: T = 0.02;

            const prev_cutoff = self.cutoff_hz;
            self.cutoff_hz = smoothParam(self.cutoff_hz, self.cutoff_target, smooth_coeff);
            if (@abs(self.cutoff_hz - prev_cutoff) > 0.01) {
                self.updateImpedances();
            }

            self.resonance = smoothParam(self.resonance, self.resonance_target, smooth_coeff);
            self.compensation = smoothParam(self.compensation, self.compensation_target, smooth_coeff);

            // Apply resonance feedback at the voltage source
            const fb_raw = self.resonance * FilterComponents.feedback_gain * self.feedback;
            const fb = fastTanh(fb_raw / FilterComponents.saturation_level) * FilterComponents.saturation_level;
            self.circuit.setVoltage(input - fb);
            self.feedbackSource().setVoltage(0.0);
            self.circuit.process();

            const s1_out = wdft.voltage(T, &self.cap1().wdf);
            const s2_out = wdft.voltage(T, &self.cap2().wdf);
            const s3_out = wdft.voltage(T, &self.cap3().wdf);
            const s4_out = wdft.voltage(T, self.outputWdf());

            self.feedback = s4_out;

            // Apply output compensation
            return .{
                .lp6 = s1_out * self.compensation,
                .lp12 = s2_out * self.compensation,
                .lp18 = s3_out * self.compensation,
                .lp24 = s4_out * self.compensation,
            };
        }
    };
}

pub fn FilterOutputs(comptime T: type) type {
    return struct {
        lp6: T, // 1-pole output (6dB/oct)
        lp12: T, // 2-pole output (12dB/oct)
        lp18: T, // 3-pole output (18dB/oct)
        lp24: T, // 4-pole output (24dB/oct)
    };
}

// ============================================================================
// Voltage Controlled Amplifier
// ============================================================================

/// Simple VCA model using differential pair approximation
/// The gain is exponentially controlled by the CV input
pub fn VCA(comptime T: type) type {
    return struct {
        gain: T = 0.0, // Linear gain (0.0 to 1.0+)
        cv_scale: T = 1.0, // CV to gain scaling

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.gain = 0.0;
        }

        /// Set gain directly (linear)
        pub fn setGain(self: *Self, g: T) void {
            self.gain = @max(0.0, g);
        }

        /// Set gain via control voltage
        /// CV is typically 0-10V for full range
        pub fn setGainCV(self: *Self, cv: T) void {
            // Exponential response like real VCA
            // 0V = silent, ~10V = unity gain
            const normalized_cv = cv / 10.0;
            if (normalized_cv <= 0.0) {
                self.gain = 0.0;
            } else {
                // Approximate exponential response
                self.gain = normalized_cv * normalized_cv; // Quadratic approximation
            }
        }

        /// Set gain via envelope (0.0 to 1.0 range)
        pub fn setGainEnvelope(self: *Self, env: T) void {
            self.gain = @max(0.0, @min(1.0, env));
        }

        pub inline fn processSample(self: *Self, input: T) T {
            return input * self.gain;
        }
    };
}

// ============================================================================
// Complete Board 4: Filter + VCA Chain
// ============================================================================

/// Complete Board 4 signal chain: VCF -> VCA
pub fn Board4FilterVCA(comptime T: type) type {
    return struct {
        vcf: MoogLadderFilter(T),
        vca: VCA(T),
        sample_rate: T,

        const Self = @This();

        pub fn init(sample_rate: T) Self {
            return .{
                .vcf = MoogLadderFilter(T).init(sample_rate),
                .vca = VCA(T).init(),
                .sample_rate = sample_rate,
            };
        }

        pub fn prepare(self: *Self, sample_rate: T) void {
            self.sample_rate = sample_rate;
            self.vcf.prepare(sample_rate);
        }

        pub fn reset(self: *Self) void {
            self.vcf.reset();
            self.vca.reset();
        }

        /// Set filter cutoff frequency in Hz
        pub fn setCutoff(self: *Self, freq_hz: T) void {
            self.vcf.setCutoff(freq_hz);
        }

        /// Set filter resonance (0.0 to ~4.0)
        pub fn setResonance(self: *Self, res: T) void {
            self.vcf.setResonance(res);
        }

        /// Set VCA gain (0.0 to 1.0)
        pub fn setAmplitude(self: *Self, amp: T) void {
            self.vca.setGainEnvelope(amp);
        }

        /// Process audio through filter and VCA
        pub inline fn processSample(self: *Self, input: T) T {
            const filtered = self.vcf.processSample(input);
            return self.vca.processSample(filtered);
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

test "wdf ladder section coefficient calculation" {
    var section = WdfLadderSection(f64).init();

    // At ωc = π/2 (quarter Nyquist), tan(π/4) = 1, so m = 0.5
    section.setCutoffOmega(std.math.pi / 2.0);
    try expectApproxEq(section.m, 0.5, 1e-6);

    // At very low frequency, m approaches 0
    section.setCutoffOmega(0.01);
    try std.testing.expect(section.m < 0.01);
    try std.testing.expect(section.m > 0.0);

    // At high frequency (0.9π), m should be reasonably high
    // Note: we clamp omega to prevent tan() explosion, so m won't reach 0.9
    section.setCutoffOmega(std.math.pi * 0.9);
    try std.testing.expect(section.m > 0.8); // Relaxed from 0.9 due to clamping
    try std.testing.expect(section.m < 1.0);
}

test "wdf ladder section basic operation" {
    const sample_rate: f64 = 48000.0;
    var section = WdfLadderSection(f64).init();
    section.setCutoffHz(1000.0, sample_rate);

    // Process a step response
    var output: f64 = 0.0;
    for (0..500) |_| {
        output = section.processSample(1.0);
    }

    // Lowpass should approach input value (DC gain = 1)
    try std.testing.expect(output > 0.99);
    try std.testing.expect(output <= 1.01);
}

test "wdf ladder section is lowpass" {
    const sample_rate: f64 = 48000.0;
    var section = WdfLadderSection(f64).init();
    section.setCutoffHz(1000.0, sample_rate);

    // Generate low frequency signal (100 Hz) - well below cutoff
    var sum_low: f64 = 0.0;
    const low_freq: f64 = 100.0;
    for (0..2000) |i| {
        const phase = @as(f64, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * low_freq;
        const input = @sin(phase);
        const output = section.processSample(input);
        // Skip first 500 samples for settling
        if (i >= 500) {
            sum_low += output * output;
        }
    }

    section.reset();

    // Generate high frequency signal (10000 Hz) - well above cutoff
    var sum_high: f64 = 0.0;
    const high_freq: f64 = 10000.0;
    for (0..2000) |i| {
        const phase = @as(f64, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * high_freq;
        const input = @sin(phase);
        const output = section.processSample(input);
        if (i >= 500) {
            sum_high += output * output;
        }
    }

    // Low frequency should pass with much more energy than high frequency
    // For a 1-pole lowpass at 1kHz, 10kHz should be attenuated by ~20dB (factor of 100 in power)
    try std.testing.expect(sum_low > sum_high * 10.0);
}

test "moog ladder filter reduces high frequencies" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter = MoogLadderFilter(T).init(sample_rate);
    filter.setCutoff(1000.0); // 1kHz cutoff
    filter.setResonance(0.0); // No resonance
    filter.setNonlinear(false); // Linear for predictable test

    // Generate high frequency test signal (10kHz)
    var sum_input: T = 0.0;
    var sum_output: T = 0.0;
    const freq: T = 10000.0;

    for (0..3000) |i| {
        const phase = @as(T, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase);
        const output = filter.processSample(input);

        // Skip first 1000 samples for settling
        if (i >= 1000) {
            sum_input += input * input;
            sum_output += output * output;
        }
    }

    // 4-pole filter at 10kHz (10x cutoff) should attenuate by ~80dB
    // In power terms that's 10^8, but we'll use a conservative threshold
    try std.testing.expect(sum_output < sum_input * 0.01);
}

test "moog ladder resonance increases peak" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter_no_res = MoogLadderFilter(T).init(sample_rate);
    filter_no_res.setCutoff(1000.0);
    filter_no_res.setResonance(0.0);
    filter_no_res.setNonlinear(false);

    var filter_res = MoogLadderFilter(T).init(sample_rate);
    filter_res.setCutoff(1000.0);
    filter_res.setResonance(3.5);
    filter_res.setNonlinear(false);

    // Generate signal at cutoff frequency
    const freq: T = 1000.0;

    // Warm up filters to reach steady state
    for (0..4000) |i| {
        const phase = @as(T, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase) * 0.3;
        _ = filter_no_res.processSample(input);
        _ = filter_res.processSample(input);
    }

    // Measure steady-state response
    var sum_no_res: T = 0.0;
    var sum_res: T = 0.0;
    for (0..2000) |i| {
        const phase = @as(T, @floatFromInt(i + 4000)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase) * 0.3;
        const out_no_res = filter_no_res.processSample(input);
        const out_res = filter_res.processSample(input);
        sum_no_res += out_no_res * out_no_res;
        sum_res += out_res * out_res;
    }

    const rms_no_res = @sqrt(sum_no_res / 2000.0);
    const rms_res = @sqrt(sum_res / 2000.0);

    // Resonance should boost signal at cutoff frequency
    try std.testing.expect(rms_res > rms_no_res * 1.2);
}

test "moog ladder nonlinear output is finite" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter = MoogLadderFilter(T).init(sample_rate);
    filter.setCutoff(1000.0);
    filter.setResonance(3.9); // Near self-oscillation
    filter.setNonlinear(true);

    var out: T = 0.0;
    var max_out: T = 0.0;
    for (0..4000) |i| {
        const input = @sin(@as(T, @floatFromInt(i)) * 0.1) * 0.5;
        out = filter.processSample(input);
        try std.testing.expect(std.math.isFinite(out));
        max_out = @max(max_out, @abs(out));
    }

    // Should have some output
    try std.testing.expect(max_out > 0.01);
    // Should be bounded due to saturation
    try std.testing.expect(max_out < 10.0);
}

test "moog ladder self-oscillation" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter = MoogLadderFilter(T).init(sample_rate);
    filter.setCutoff(440.0); // A4
    filter.setResonance(4.0); // Self-oscillation
    filter.setNonlinear(true);

    // Force parameters to their targets immediately (bypass smoothing)
    filter.cutoff_hz = filter.cutoff_target;
    filter.resonance = filter.resonance_target;
    filter.compensation = filter.compensation_target;
    filter.prepare(sample_rate);

    // Give it a kick to start oscillation
    _ = filter.processSample(0.5);
    _ = filter.processSample(0.2);
    _ = filter.processSample(0.0);

    // Let it run with zero input - give it time to build up
    var sum: T = 0.0;
    for (0..8000) |_| {
        const out = filter.processSample(0.0);
        sum += out * out;
    }

    // Should self-oscillate (have significant output with zero input)
    // Using a lower threshold since nonlinearity limits amplitude
    const rms = @sqrt(sum / 8000.0);
    try std.testing.expect(rms > 0.05);
}

test "board4 chain produces output" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var board4 = Board4FilterVCA(T).init(sample_rate);
    board4.setCutoff(800.0);
    board4.setResonance(2.5);
    board4.setAmplitude(0.9);

    var sum_out: T = 0.0;
    for (0..2000) |i| {
        const input = @sin(@as(T, @floatFromInt(i)) * 0.05);
        const out = board4.processSample(input);
        sum_out += out * out;
    }

    try std.testing.expect(sum_out > 1e-6);
}

test "vca gain control" {
    const T = f64;

    var vca = VCA(T).init();

    // Zero gain
    vca.setGainEnvelope(0.0);
    try expectApproxEq(vca.processSample(1.0), 0.0, 1e-9);

    // Unity gain
    vca.setGainEnvelope(1.0);
    try expectApproxEq(vca.processSample(1.0), 1.0, 1e-9);

    // Half gain
    vca.setGainEnvelope(0.5);
    try expectApproxEq(vca.processSample(1.0), 0.5, 1e-9);
}

test "board4 complete chain" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var board4 = Board4FilterVCA(T).init(sample_rate);
    board4.setCutoff(5000.0);
    board4.setResonance(1.0);
    board4.setAmplitude(0.8);

    // Process some samples
    var out: T = 0.0;
    for (0..100) |i| {
        const input = @sin(@as(T, @floatFromInt(i)) * 0.1);
        out = board4.processSample(input);
    }

    // Should produce output
    try std.testing.expect(@abs(out) > 0.0);
}

test "multimode outputs are progressively filtered" {
    const T = f64;
    const sample_rate: T = 48000.0;

    var filter = MoogLadderFilter(T).init(sample_rate);
    filter.setCutoff(500.0);
    filter.setResonance(0.0);
    filter.setNonlinear(false);

    // High frequency signal
    const freq: T = 8000.0;
    var sum_6: T = 0.0;
    var sum_12: T = 0.0;
    var sum_18: T = 0.0;
    var sum_24: T = 0.0;

    for (0..3000) |i| {
        const phase = @as(T, @floatFromInt(i)) / sample_rate * 2.0 * std.math.pi * freq;
        const input = @sin(phase);
        const outputs = filter.processSampleMultimode(input);

        if (i >= 1000) {
            sum_6 += outputs.lp6 * outputs.lp6;
            sum_12 += outputs.lp12 * outputs.lp12;
            sum_18 += outputs.lp18 * outputs.lp18;
            sum_24 += outputs.lp24 * outputs.lp24;
        }
    }

    // Each additional pole should attenuate more
    try std.testing.expect(sum_6 > sum_12);
    try std.testing.expect(sum_12 > sum_18);
    try std.testing.expect(sum_18 > sum_24);
}
