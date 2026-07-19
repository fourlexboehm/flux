const simd_lanes = 4;
const simd_unroll = 2;
const F32xN = @Vector(simd_lanes, f32);

pub inline fn addStereo(
    out_left: []f32,
    out_right: []f32,
    src_left: []const f32,
    src_right: []const f32,
    frame_count: usize,
) void {
    var i: usize = 0;
    const unroll_width = simd_lanes * simd_unroll;
    const vec_unroll_end = frame_count - (frame_count % unroll_width);
    while (i < vec_unroll_end) : (i += unroll_width) {
        const dst_l = @as(F32xN, out_left[i..][0..simd_lanes].*);
        const dst_r = @as(F32xN, out_right[i..][0..simd_lanes].*);
        const src_l = @as(F32xN, src_left[i..][0..simd_lanes].*);
        const src_r = @as(F32xN, src_right[i..][0..simd_lanes].*);
        out_left[i..][0..simd_lanes].* = @as([simd_lanes]f32, dst_l + src_l);
        out_right[i..][0..simd_lanes].* = @as([simd_lanes]f32, dst_r + src_r);

        const i_next = i + simd_lanes;
        const dst2_l = @as(F32xN, out_left[i_next..][0..simd_lanes].*);
        const dst2_r = @as(F32xN, out_right[i_next..][0..simd_lanes].*);
        const src2_l = @as(F32xN, src_left[i_next..][0..simd_lanes].*);
        const src2_r = @as(F32xN, src_right[i_next..][0..simd_lanes].*);
        out_left[i_next..][0..simd_lanes].* = @as([simd_lanes]f32, dst2_l + src2_l);
        out_right[i_next..][0..simd_lanes].* = @as([simd_lanes]f32, dst2_r + src2_r);
    }

    const vec_end = frame_count - (frame_count % simd_lanes);
    while (i < vec_end) : (i += simd_lanes) {
        const dst_l = @as(F32xN, out_left[i..][0..simd_lanes].*);
        const dst_r = @as(F32xN, out_right[i..][0..simd_lanes].*);
        const src_l = @as(F32xN, src_left[i..][0..simd_lanes].*);
        const src_r = @as(F32xN, src_right[i..][0..simd_lanes].*);
        out_left[i..][0..simd_lanes].* = @as([simd_lanes]f32, dst_l + src_l);
        out_right[i..][0..simd_lanes].* = @as([simd_lanes]f32, dst_r + src_r);
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
    var i: usize = 0;
    const unroll_width = simd_lanes * simd_unroll;
    const vec_unroll_end = frame_count - (frame_count % unroll_width);
    const gain_vec: F32xN = @splat(gain);
    while (i < vec_unroll_end) : (i += unroll_width) {
        const dst_l = @as(F32xN, out_left[i..][0..simd_lanes].*);
        const dst_r = @as(F32xN, out_right[i..][0..simd_lanes].*);
        out_left[i..][0..simd_lanes].* = @as([simd_lanes]f32, dst_l * gain_vec);
        out_right[i..][0..simd_lanes].* = @as([simd_lanes]f32, dst_r * gain_vec);

        const i_next = i + simd_lanes;
        const dst2_l = @as(F32xN, out_left[i_next..][0..simd_lanes].*);
        const dst2_r = @as(F32xN, out_right[i_next..][0..simd_lanes].*);
        out_left[i_next..][0..simd_lanes].* = @as([simd_lanes]f32, dst2_l * gain_vec);
        out_right[i_next..][0..simd_lanes].* = @as([simd_lanes]f32, dst2_r * gain_vec);
    }

    const vec_end = frame_count - (frame_count % simd_lanes);
    while (i < vec_end) : (i += simd_lanes) {
        const dst_l = @as(F32xN, out_left[i..][0..simd_lanes].*);
        const dst_r = @as(F32xN, out_right[i..][0..simd_lanes].*);
        out_left[i..][0..simd_lanes].* = @as([simd_lanes]f32, dst_l * gain_vec);
        out_right[i..][0..simd_lanes].* = @as([simd_lanes]f32, dst_r * gain_vec);
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
    const vec_end = frame_count - (frame_count % simd_lanes);
    while (i < vec_end) : (i += simd_lanes) {
        const left_vec = @as(F32xN, left[i..][0..simd_lanes].*) * left_gain_vec;
        const right_vec = @as(F32xN, right[i..][0..simd_lanes].*) * right_gain_vec;
        left[i..][0..simd_lanes].* = @as([simd_lanes]f32, left_vec);
        right[i..][0..simd_lanes].* = @as([simd_lanes]f32, right_vec);
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
    const vec_end = frame_count - (frame_count % simd_lanes);
    while (i < vec_end) : (i += simd_lanes) {
        const src_l = @as(F32xN, src_left[i..][0..simd_lanes].*);
        const src_r = @as(F32xN, src_right[i..][0..simd_lanes].*);
        out_left[i..][0..simd_lanes].* = @as([simd_lanes]f32, src_l * gain_vec);
        out_right[i..][0..simd_lanes].* = @as([simd_lanes]f32, src_r * gain_vec);
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
    const vec_end = frame_count - (frame_count % simd_lanes);
    while (i < vec_end) : (i += simd_lanes) {
        const dst_l = @as(F32xN, out_left[i..][0..simd_lanes].*);
        const dst_r = @as(F32xN, out_right[i..][0..simd_lanes].*);
        const src_l = @as(F32xN, src_left[i..][0..simd_lanes].*);
        const src_r = @as(F32xN, src_right[i..][0..simd_lanes].*);
        out_left[i..][0..simd_lanes].* = @as([simd_lanes]f32, dst_l + (src_l * gain_vec));
        out_right[i..][0..simd_lanes].* = @as([simd_lanes]f32, dst_r + (src_r * gain_vec));
    }
    while (i < frame_count) : (i += 1) {
        out_left[i] += src_left[i] * gain;
        out_right[i] += src_right[i] * gain;
    }
}

test "stereo gains and peak are calculated in one pass" {
    var left = [_]f32{ 1, -0.5, 0.25, 0 };
    var right = [_]f32{ 0.75, 1, -1, 0.5 };
    const peak = applyStereoGainsAndPeak(&left, &right, left.len, 0.25, 1.0);
    try @import("std").testing.expectEqualSlices(f32, &.{ 0.25, -0.125, 0.0625, 0 }, &left);
    try @import("std").testing.expectEqualSlices(f32, &.{ 0.75, 1, -1, 0.5 }, &right);
    try @import("std").testing.expectEqual([2]f32{ 0.25, 1.0 }, peak);
}
