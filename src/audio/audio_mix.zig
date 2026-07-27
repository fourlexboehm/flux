const std = @import("std");

/// Target-preferred f32 vector width (NEON 4, AVX 8, AVX-512 16, …).
pub const lanes: comptime_int = std.simd.suggestVectorLength(f32) orelse 4;
pub const F32xN = @Vector(lanes, f32);
const unroll = 2;

inline fn load(buf: []const f32, i: usize) F32xN {
    return @as(F32xN, buf[i..][0..lanes].*);
}

inline fn store(buf: []f32, i: usize, v: F32xN) void {
    buf[i..][0..lanes].* = @as([lanes]f32, v);
}

pub inline fn mulStereo(out_left: []f32, out_right: []f32, frame_count: usize, gain: f32) void {
    if (gain == 1.0) return;
    var i: usize = 0;
    const unroll_width = lanes * unroll;
    const vec_unroll_end = frame_count - (frame_count % unroll_width);
    const gain_vec: F32xN = @splat(gain);
    while (i < vec_unroll_end) : (i += unroll_width) {
        store(out_left, i, load(out_left, i) * gain_vec);
        store(out_right, i, load(out_right, i) * gain_vec);
        const j = i + lanes;
        store(out_left, j, load(out_left, j) * gain_vec);
        store(out_right, j, load(out_right, j) * gain_vec);
    }
    const vec_end = frame_count - (frame_count % lanes);
    while (i < vec_end) : (i += lanes) {
        store(out_left, i, load(out_left, i) * gain_vec);
        store(out_right, i, load(out_right, i) * gain_vec);
    }
    while (i < frame_count) : (i += 1) {
        out_left[i] *= gain;
        out_right[i] *= gain;
    }
}

pub inline fn applyStereoGainsAndPeak(left: []f32, right: []f32, frame_count: usize, left_gain: f32, right_gain: f32) [2]f32 {
    var left_peak: f32 = 0;
    var right_peak: f32 = 0;
    var i: usize = 0;
    const left_gain_vec: F32xN = @splat(left_gain);
    const right_gain_vec: F32xN = @splat(right_gain);
    const vec_end = frame_count - (frame_count % lanes);
    while (i < vec_end) : (i += lanes) {
        const left_vec = load(left, i) * left_gain_vec;
        const right_vec = load(right, i) * right_gain_vec;
        store(left, i, left_vec);
        store(right, i, right_vec);
        left_peak = @max(left_peak, @reduce(.Max, @abs(left_vec)));
        right_peak = @max(right_peak, @reduce(.Max, @abs(right_vec)));
    }
    while (i < frame_count) : (i += 1) {
        left[i] *= left_gain;
        right[i] *= right_gain;
        left_peak = @max(left_peak, @abs(left[i]));
        right_peak = @max(right_peak, @abs(right[i]));
    }
    return .{ left_peak, right_peak };
}

/// A planar stereo input to the fused mixer: two same-length channel slices.
pub const StereoSpan = struct {
    left: []const f32,
    right: []const f32,
};

/// Fused multi-input stereo mix: `out = (Σ spans) * gain`, computed in ONE pass
/// over the output (samples outer, inputs inner, running sum kept in a register)
/// so the output is written once instead of once per input. Callers pass at
/// least one span.
pub fn sumSpans(
    out_left: []f32,
    out_right: []f32,
    spans: []const StereoSpan,
    frame_count: usize,
    gain: f32,
) void {
    const gain_vec: F32xN = @splat(gain);
    var i: usize = 0;
    const vec_end = frame_count - (frame_count % lanes);
    while (i < vec_end) : (i += lanes) {
        var acc_l: F32xN = @splat(0);
        var acc_r: F32xN = @splat(0);
        for (spans) |s| {
            acc_l += load(s.left, i);
            acc_r += load(s.right, i);
        }
        store(out_left, i, acc_l * gain_vec);
        store(out_right, i, acc_r * gain_vec);
    }
    while (i < frame_count) : (i += 1) {
        var sl: f32 = 0;
        var sr: f32 = 0;
        for (spans) |s| {
            sl += s.left[i];
            sr += s.right[i];
        }
        out_left[i] = sl * gain;
        out_right[i] = sr * gain;
    }
}

/// Interleave planar L/R into device stereo. Uses `@shuffle` at target lane width.
pub inline fn interleaveStereo(
    out: [*]align(1) f32,
    frame_offset: usize,
    left: []const f32,
    right: []const f32,
    frame_count: usize,
) void {
    const Interleaved = @Vector(lanes * 2, f32);
    const mask = comptime blk: {
        var m: [lanes * 2]i32 = undefined;
        for (0..lanes) |k| {
            m[k * 2] = @intCast(k);
            m[k * 2 + 1] = ~@as(i32, @intCast(k));
        }
        break :blk m;
    };

    var i: usize = 0;
    const vec_end = frame_count - (frame_count % lanes);
    while (i < vec_end) : (i += lanes) {
        const interleaved: Interleaved = @shuffle(f32, load(left, i), load(right, i), mask);
        const base = (frame_offset + i) * 2;
        // Device buffer may be unaligned; copy avoids a strict vector store.
        const packed_arr: [lanes * 2]f32 = interleaved;
        @memcpy(out[base..][0 .. lanes * 2], &packed_arr);
    }
    while (i < frame_count) : (i += 1) {
        const base = (frame_offset + i) * 2;
        out[base] = left[i];
        out[base + 1] = right[i];
    }
}

test "stereo gains and peak are calculated in one pass" {
    var left = [_]f32{ 1, -0.5, 0.25, 0 };
    var right = [_]f32{ 0.75, 1, -1, 0.5 };
    const peak = applyStereoGainsAndPeak(&left, &right, left.len, 0.25, 1.0);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, -0.125, 0.0625, 0 }, &left);
    try std.testing.expectEqualSlices(f32, &.{ 0.75, 1, -1, 0.5 }, &right);
    try std.testing.expectEqual([2]f32{ 0.25, 1.0 }, peak);
}

test "sumSpans fused mix matches naive sum with gain" {
    const frames = 37; // deliberately not a multiple of `lanes`, to hit the tail
    const n_inputs = 9;

    var prng = std.Random.DefaultPrng.init(0x5150);
    const rnd = prng.random();

    var lefts: [n_inputs][frames]f32 = undefined;
    var rights: [n_inputs][frames]f32 = undefined;
    var spans: [n_inputs]StereoSpan = undefined;
    for (0..n_inputs) |k| {
        for (0..frames) |f| {
            lefts[k][f] = rnd.float(f32) * 2 - 1;
            rights[k][f] = rnd.float(f32) * 2 - 1;
        }
        spans[k] = .{ .left = &lefts[k], .right = &rights[k] };
    }

    const gain: f32 = 0.75;

    // Naive reference: Σ inputs, then scale.
    var expect_l: [frames]f32 = @splat(0);
    var expect_r: [frames]f32 = @splat(0);
    for (0..frames) |f| {
        var sl: f32 = 0;
        var sr: f32 = 0;
        for (0..n_inputs) |k| {
            sl += lefts[k][f];
            sr += rights[k][f];
        }
        expect_l[f] = sl * gain;
        expect_r[f] = sr * gain;
    }

    var out_l: [frames]f32 = @splat(0);
    var out_r: [frames]f32 = @splat(0);
    sumSpans(&out_l, &out_r, &spans, frames, gain);

    for (0..frames) |f| {
        try std.testing.expectApproxEqAbs(expect_l[f], out_l[f], 1e-5);
        try std.testing.expectApproxEqAbs(expect_r[f], out_r[f], 1e-5);
    }
}

test "interleaveStereo planar to interleaved" {
    const left = [_]f32{ 1, 2, 3, 4, 5 };
    const right = [_]f32{ 10, 20, 30, 40, 50 };
    var out: [10]f32 = undefined;
    interleaveStereo(&out, 0, &left, &right, 5);
    try std.testing.expectEqualSlices(f32, &.{ 1, 10, 2, 20, 3, 30, 4, 40, 5, 50 }, &out);
}
