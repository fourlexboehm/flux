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

pub inline fn addStereo(
    out_left: []f32,
    out_right: []f32,
    src_left: []const f32,
    src_right: []const f32,
    frame_count: usize,
) void {
    var i: usize = 0;
    const unroll_width = lanes * unroll;
    const vec_unroll_end = frame_count - (frame_count % unroll_width);
    while (i < vec_unroll_end) : (i += unroll_width) {
        store(out_left, i, load(out_left, i) + load(src_left, i));
        store(out_right, i, load(out_right, i) + load(src_right, i));
        const j = i + lanes;
        store(out_left, j, load(out_left, j) + load(src_left, j));
        store(out_right, j, load(out_right, j) + load(src_right, j));
    }
    const vec_end = frame_count - (frame_count % lanes);
    while (i < vec_end) : (i += lanes) {
        store(out_left, i, load(out_left, i) + load(src_left, i));
        store(out_right, i, load(out_right, i) + load(src_right, i));
    }
    while (i < frame_count) : (i += 1) {
        out_left[i] += src_left[i];
        out_right[i] += src_right[i];
    }
}

pub inline fn copyStereo(
    out_left: []f32,
    out_right: []f32,
    src_left: []const f32,
    src_right: []const f32,
    frame_count: usize,
) void {
    @memcpy(out_left[0..frame_count], src_left[0..frame_count]);
    @memcpy(out_right[0..frame_count], src_right[0..frame_count]);
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

pub inline fn copyScaledStereo(
    out_left: []f32,
    out_right: []f32,
    src_left: []const f32,
    src_right: []const f32,
    frame_count: usize,
    gain: f32,
) void {
    var i: usize = 0;
    const gain_vec: F32xN = @splat(gain);
    const vec_end = frame_count - (frame_count % lanes);
    while (i < vec_end) : (i += lanes) {
        store(out_left, i, load(src_left, i) * gain_vec);
        store(out_right, i, load(src_right, i) * gain_vec);
    }
    while (i < frame_count) : (i += 1) {
        out_left[i] = src_left[i] * gain;
        out_right[i] = src_right[i] * gain;
    }
}

pub inline fn addScaledStereo(
    out_left: []f32,
    out_right: []f32,
    src_left: []const f32,
    src_right: []const f32,
    frame_count: usize,
    gain: f32,
) void {
    var i: usize = 0;
    const gain_vec: F32xN = @splat(gain);
    const vec_end = frame_count - (frame_count % lanes);
    while (i < vec_end) : (i += lanes) {
        store(out_left, i, load(out_left, i) + (load(src_left, i) * gain_vec));
        store(out_right, i, load(out_right, i) + (load(src_right, i) * gain_vec));
    }
    while (i < frame_count) : (i += 1) {
        out_left[i] += src_left[i] * gain;
        out_right[i] += src_right[i] * gain;
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

test "interleaveStereo planar to interleaved" {
    const left = [_]f32{ 1, 2, 3, 4, 5 };
    const right = [_]f32{ 10, 20, 30, 40, 50 };
    var out: [10]f32 = undefined;
    interleaveStereo(&out, 0, &left, &right, 5);
    try std.testing.expectEqualSlices(f32, &.{ 1, 10, 2, 20, 3, 30, 4, 40, 5, 50 }, &out);
}
