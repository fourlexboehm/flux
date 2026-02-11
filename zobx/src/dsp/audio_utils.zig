// Audio utility functions and DSP constants
// Ported from OB-Xf AudioUtils.h and Constants.h
//
// Contains:
//   - TPT (topology-preserving transform) one-pole lowpass filters
//   - Pitch/frequency conversion
//   - Linear and logarithmic parameter scaling

const std = @import("std");

// ============================================================================
// Constants (from OB-Xf Constants.h)
// ============================================================================

/// DC offset to prevent denormal numbers
pub const dc: f32 = 1e-18;

/// Natural logarithm of 2
pub const ln2: f32 = 0.69314718056;

/// Semitone-to-frequency multiplier: ln(2) / 12
pub const mult: f32 = ln2 / 12.0;

/// Maximum pitch bend range in semitones
pub const max_bend_range: f32 = 48.0;

// ============================================================================
// TPT (Topology-Preserving Transform) Lowpass Filters
// ============================================================================

/// One-pole TPT lowpass filter without frequency warping.
///
/// Uses the linear (un-warped) cutoff approximation: cutoff_g = cutoff * srInv * pi.
/// Faster but less accurate at high frequencies than the warped version.
///
/// `state` is the filter state (modified in place).
/// `input` is the input sample.
/// `cutoff` is the cutoff frequency in Hz.
/// `sr_inv` is 1.0 / sample_rate.
///
/// Returns the lowpass output.
pub inline fn tptLpUnwarped(state: *f32, input: f32, cutoff: f32, sr_inv: f32) f32 {
    const g: f64 = @as(f64, cutoff * sr_inv) * std.math.pi;
    const v: f64 = (@as(f64, input) - @as(f64, state.*)) * g / (1.0 + g);
    const res: f64 = v + @as(f64, state.*);
    state.* = @floatCast(res + v);
    return @floatCast(res);
}

/// One-pole TPT lowpass filter with frequency warping (tan prewarping).
///
/// Uses the bilinear transform's frequency warping: cutoff_g = tan(cutoff * srInv * pi).
/// More accurate frequency response at all frequencies.
///
/// `state` is the filter state (modified in place).
/// `input` is the input sample.
/// `cutoff` is the cutoff frequency in Hz.
/// `sr_inv` is 1.0 / sample_rate.
///
/// Returns the lowpass output.
pub inline fn tptLp(state: *f32, input: f32, cutoff: f32, sr_inv: f32) f32 {
    const g: f64 = @tan(@as(f64, cutoff * sr_inv) * std.math.pi);
    const v: f64 = (@as(f64, input) - @as(f64, state.*)) * g / (1.0 + g);
    const res: f64 = v + @as(f64, state.*);
    state.* = @floatCast(res + v);
    return @floatCast(res);
}

/// One-pole TPT lowpass filter with a pre-computed cutoff coefficient.
///
/// The `cutoff` parameter should already be the filter's g coefficient
/// (e.g. from a tan() prewarping step). Use this when the cutoff does not
/// change per-sample to avoid redundant tan() calls.
///
/// `state` is the filter state (modified in place).
/// `input` is the input sample.
/// `cutoff` is the pre-computed g coefficient.
///
/// Returns the lowpass output.
pub inline fn tptProcess(state: *f32, input: f32, cutoff: f32) f32 {
    const g: f64 = @as(f64, cutoff);
    const v: f64 = (@as(f64, input) - @as(f64, state.*)) * g / (1.0 + g);
    const res: f64 = v + @as(f64, state.*);
    state.* = @floatCast(res + v);
    return @floatCast(res);
}

/// One-pole TPT lowpass filter with a pre-scaled cutoff.
///
/// The `cutoff_over_one_plus_cutoff` parameter is cutoff / (1 + cutoff),
/// precomputed to avoid the division per sample.
///
/// `state` is the filter state (modified in place).
/// `input` is the input sample.
/// `cutoff_over_one_plus_cutoff` is the pre-scaled coefficient.
///
/// Returns the lowpass output.
pub inline fn tptProcessScaledCutoff(state: *f32, input: f32, cutoff_over_one_plus_cutoff: f32) f32 {
    const c: f64 = @as(f64, cutoff_over_one_plus_cutoff);
    const v: f64 = (@as(f64, input) - @as(f64, state.*)) * c;
    const res: f64 = v + @as(f64, state.*);
    state.* = @floatCast(res + v);
    return @floatCast(res);
}

// ============================================================================
// Pitch / Frequency Conversion
// ============================================================================

/// Convert a semitone index (relative to A4 = 440 Hz) to frequency in Hz.
///
/// getPitch(0) = 440 Hz, getPitch(12) = 880 Hz, getPitch(-12) = 220 Hz.
pub inline fn getPitch(index: f32) f32 {
    return 440.0 * @exp(@as(f32, mult) * index);
}

// ============================================================================
// Parameter Scaling
// ============================================================================

/// Linear scaling of a normalised parameter (0..1) to an arbitrary range.
pub inline fn linsc(param: f32, min: f32, max: f32) f32 {
    return param * (max - min) + min;
}

/// Logarithmic scaling of a normalised parameter (0..1) to an arbitrary range.
///
/// `rolloff` controls the curvature of the mapping (default 19.0 in OB-Xf).
/// Higher rolloff values produce a more pronounced logarithmic curve.
pub inline fn logsc(param: f32, min: f32, max: f32, rolloff: f32) f32 {
    return ((@exp(param * @log(rolloff + 1.0)) - 1.0) / rolloff) * (max - min) + min;
}

/// Logarithmic scaling with the OB-Xf default rolloff of 19.0.
pub inline fn logscDefault(param: f32, min: f32, max: f32) f32 {
    return logsc(param, min, max, 19.0);
}

// ============================================================================
// Tests
// ============================================================================

test "getPitch returns 440 at index 0" {
    const freq = getPitch(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), freq, 0.01);
}

test "getPitch returns ~880 at index 12" {
    const freq = getPitch(12.0);
    try std.testing.expectApproxEqAbs(@as(f32, 880.0), freq, 0.5);
}

test "getPitch returns ~220 at index -12" {
    const freq = getPitch(-12.0);
    try std.testing.expectApproxEqAbs(@as(f32, 220.0), freq, 0.5);
}

test "linsc maps 0..1 to min..max" {
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), linsc(0.0, 100.0, 200.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), linsc(0.5, 100.0, 200.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), linsc(1.0, 100.0, 200.0), 1e-6);
}

test "logsc maps endpoints correctly" {
    // At param=0, logsc should return min
    const at_zero = logsc(0.0, 100.0, 200.0, 19.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), at_zero, 0.01);

    // At param=1, logsc should return max
    const at_one = logsc(1.0, 100.0, 200.0, 19.0);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), at_one, 0.01);
}

test "logsc is concave (lower than linear at midpoint)" {
    const log_mid = logsc(0.5, 0.0, 1.0, 19.0);
    const lin_mid = linsc(0.5, 0.0, 1.0);

    // Logarithmic scaling at 0.5 should be below linear scaling at 0.5
    try std.testing.expect(log_mid < lin_mid);
}

test "tptLpUnwarped filters signal" {
    var state: f32 = 0.0;
    const sr_inv: f32 = 1.0 / 44100.0;

    // Step response: feed 1.0 into the filter
    var out: f32 = 0.0;
    for (0..44100) |_| {
        out = tptLpUnwarped(&state, 1.0, 100.0, sr_inv);
    }

    // After one second at 100 Hz cutoff, should be very close to 1.0 (DC passthrough)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out, 0.01);
}

test "tptLp filters signal" {
    var state: f32 = 0.0;
    const sr_inv: f32 = 1.0 / 44100.0;

    var out: f32 = 0.0;
    for (0..44100) |_| {
        out = tptLp(&state, 1.0, 100.0, sr_inv);
    }

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out, 0.01);
}

test "tptProcess with zero cutoff passes nothing" {
    var state: f32 = 0.0;
    const out = tptProcess(&state, 1.0, 0.0);

    // With zero cutoff, filter output should be zero
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out, 1e-10);
}

test "tptProcessScaledCutoff matches tptProcess" {
    var state1: f32 = 0.0;
    var state2: f32 = 0.0;

    const g: f32 = 0.1; // arbitrary cutoff coefficient
    const g_scaled: f32 = g / (1.0 + g);

    for (0..100) |i| {
        const input: f32 = @as(f32, @floatFromInt(i)) / 100.0;
        const out1 = tptProcess(&state1, input, g);
        const out2 = tptProcessScaledCutoff(&state2, input, g_scaled);
        try std.testing.expectApproxEqAbs(out1, out2, 1e-6);
    }
}

test "dc constant is very small" {
    try std.testing.expect(dc > 0.0);
    try std.testing.expect(dc < 1e-15);
}
