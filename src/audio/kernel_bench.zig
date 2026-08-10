//! SIMD add-mul kernel microbench (pre-DVUI `FLUX_KERNEL_BENCH`).
//!
//! Compares vectorized `(out + src) * gain` unroll factors — pure CPU, no device
//! or plugins. Used by `rt-bench` and the `FLUX_KERNEL_BENCH=1` flux early exit.

const std = @import("std");
const audio_mix = @import("audio_mix.zig");
const time_utils = @import("../util/time_utils.zig");

const simd_lanes = audio_mix.lanes;
const F32xN = audio_mix.F32xN;

fn envUsize(name: [:0]const u8, default_value: usize) usize {
    const v = std.c.getenv(name.ptr) orelse return default_value;
    return std.fmt.parseInt(usize, std.mem.span(v), 10) catch default_value;
}

inline fn addMulUnroll1(
    out_left: []f32,
    out_right: []f32,
    src_left: []const f32,
    src_right: []const f32,
    frame_count: usize,
    gain: f32,
) void {
    var i: usize = 0;
    const vec_end = frame_count - (frame_count % simd_lanes);
    const gain_vec: F32xN = @splat(gain);
    while (i < vec_end) : (i += simd_lanes) {
        const dst_l = @as(F32xN, out_left[i..][0..simd_lanes].*);
        const dst_r = @as(F32xN, out_right[i..][0..simd_lanes].*);
        const src_l = @as(F32xN, src_left[i..][0..simd_lanes].*);
        const src_r = @as(F32xN, src_right[i..][0..simd_lanes].*);
        const sum_l = dst_l + src_l;
        const sum_r = dst_r + src_r;
        out_left[i..][0..simd_lanes].* = @as([simd_lanes]f32, sum_l * gain_vec);
        out_right[i..][0..simd_lanes].* = @as([simd_lanes]f32, sum_r * gain_vec);
    }
    while (i < frame_count) : (i += 1) {
        out_left[i] = (out_left[i] + src_left[i]) * gain;
        out_right[i] = (out_right[i] + src_right[i]) * gain;
    }
}

inline fn addMulUnroll4(
    out_left: []f32,
    out_right: []f32,
    src_left: []const f32,
    src_right: []const f32,
    frame_count: usize,
    gain: f32,
) void {
    const unroll = simd_lanes * 4;
    var i: usize = 0;
    const vec_unroll_end = frame_count - (frame_count % unroll);
    const gain_vec: F32xN = @splat(gain);

    while (i < vec_unroll_end) : (i += unroll) {
        inline for (0..4) |k| {
            const base = i + k * simd_lanes;
            const dst_l = @as(F32xN, out_left[base..][0..simd_lanes].*);
            const dst_r = @as(F32xN, out_right[base..][0..simd_lanes].*);
            const src_l = @as(F32xN, src_left[base..][0..simd_lanes].*);
            const src_r = @as(F32xN, src_right[base..][0..simd_lanes].*);
            const sum_l = dst_l + src_l;
            const sum_r = dst_r + src_r;
            out_left[base..][0..simd_lanes].* = @as([simd_lanes]f32, sum_l * gain_vec);
            out_right[base..][0..simd_lanes].* = @as([simd_lanes]f32, sum_r * gain_vec);
        }
    }

    const vec_end = frame_count - (frame_count % simd_lanes);
    while (i < vec_end) : (i += simd_lanes) {
        const dst_l = @as(F32xN, out_left[i..][0..simd_lanes].*);
        const dst_r = @as(F32xN, out_right[i..][0..simd_lanes].*);
        const src_l = @as(F32xN, src_left[i..][0..simd_lanes].*);
        const src_r = @as(F32xN, src_right[i..][0..simd_lanes].*);
        const sum_l = dst_l + src_l;
        const sum_r = dst_r + src_r;
        out_left[i..][0..simd_lanes].* = @as([simd_lanes]f32, sum_l * gain_vec);
        out_right[i..][0..simd_lanes].* = @as([simd_lanes]f32, sum_r * gain_vec);
    }
    while (i < frame_count) : (i += 1) {
        out_left[i] = (out_left[i] + src_left[i]) * gain;
        out_right[i] = (out_right[i] + src_right[i]) * gain;
    }
}

inline fn addMulUnroll16(
    out_left: []f32,
    out_right: []f32,
    src_left: []const f32,
    src_right: []const f32,
    frame_count: usize,
    gain: f32,
) void {
    const unroll = simd_lanes * 16;
    var i: usize = 0;
    const vec_unroll_end = frame_count - (frame_count % unroll);
    const gain_vec: F32xN = @splat(gain);

    while (i < vec_unroll_end) : (i += unroll) {
        inline for (0..16) |k| {
            const base = i + k * simd_lanes;
            const dst_l = @as(F32xN, out_left[base..][0..simd_lanes].*);
            const dst_r = @as(F32xN, out_right[base..][0..simd_lanes].*);
            const src_l = @as(F32xN, src_left[base..][0..simd_lanes].*);
            const src_r = @as(F32xN, src_right[base..][0..simd_lanes].*);
            const sum_l = dst_l + src_l;
            const sum_r = dst_r + src_r;
            out_left[base..][0..simd_lanes].* = @as([simd_lanes]f32, sum_l * gain_vec);
            out_right[base..][0..simd_lanes].* = @as([simd_lanes]f32, sum_r * gain_vec);
        }
    }

    const vec_end = frame_count - (frame_count % simd_lanes);
    while (i < vec_end) : (i += simd_lanes) {
        const dst_l = @as(F32xN, out_left[i..][0..simd_lanes].*);
        const dst_r = @as(F32xN, out_right[i..][0..simd_lanes].*);
        const src_l = @as(F32xN, src_left[i..][0..simd_lanes].*);
        const src_r = @as(F32xN, src_right[i..][0..simd_lanes].*);
        const sum_l = dst_l + src_l;
        const sum_r = dst_r + src_r;
        out_left[i..][0..simd_lanes].* = @as([simd_lanes]f32, sum_l * gain_vec);
        out_right[i..][0..simd_lanes].* = @as([simd_lanes]f32, sum_r * gain_vec);
    }
    while (i < frame_count) : (i += 1) {
        out_left[i] = (out_left[i] + src_left[i]) * gain;
        out_right[i] = (out_right[i] + src_right[i]) * gain;
    }
}

/// Run the kernel microbench. Env: `FLUX_KERNEL_BENCH_TRACKS` (default 64),
/// `FLUX_KERNEL_BENCH_FRAMES` (64), `FLUX_KERNEL_BENCH_BLOCKS` (20000).
pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    const tracks = @max(envUsize("FLUX_KERNEL_BENCH_TRACKS", 64), 1);
    const frames = @max(envUsize("FLUX_KERNEL_BENCH_FRAMES", 64), 4);
    const blocks = @max(envUsize("FLUX_KERNEL_BENCH_BLOCKS", 20_000), 1);
    const total = tracks * frames;

    var prng = std.Random.DefaultPrng.init(0x6f72616e);
    const random = prng.random();

    const src_l = try allocator.alloc(f32, total);
    defer allocator.free(src_l);
    const src_r = try allocator.alloc(f32, total);
    defer allocator.free(src_r);
    const base_l = try allocator.alloc(f32, total);
    defer allocator.free(base_l);
    const base_r = try allocator.alloc(f32, total);
    defer allocator.free(base_r);
    const out_l = try allocator.alloc(f32, total);
    defer allocator.free(out_l);
    const out_r = try allocator.alloc(f32, total);
    defer allocator.free(out_r);

    for (0..total) |i| {
        src_l[i] = random.float(f32) * 0.1;
        src_r[i] = random.float(f32) * 0.1;
        base_l[i] = random.float(f32) * 0.1;
        base_r[i] = random.float(f32) * 0.1;
    }

    std.log.info("Kernel bench: tracks={d} frames={d} blocks={d} simd_lanes={d}", .{
        tracks,
        frames,
        blocks,
        simd_lanes,
    });

    @memcpy(out_l, base_l);
    @memcpy(out_r, base_r);
    var start = std.Io.Clock.awake.now(io);
    var b: usize = 0;
    while (b < blocks) : (b += 1) {
        const gain = 0.95 + @as(f32, @floatFromInt(b % 7)) * 0.005;
        var t: usize = 0;
        while (t < tracks) : (t += 1) {
            const off = t * frames;
            addMulUnroll1(
                out_l[off .. off + frames],
                out_r[off .. off + frames],
                src_l[off .. off + frames],
                src_r[off .. off + frames],
                frames,
                gain,
            );
        }
    }
    const end_u1 = std.Io.Clock.awake.now(io);
    const ns_u1 = time_utils.nsSince(start, end_u1);
    var checksum_u1: f64 = 0;
    for (0..tracks) |t| {
        checksum_u1 += out_l[t * frames];
    }

    @memcpy(out_l, base_l);
    @memcpy(out_r, base_r);
    start = std.Io.Clock.awake.now(io);
    b = 0;
    while (b < blocks) : (b += 1) {
        const gain = 0.95 + @as(f32, @floatFromInt(b % 7)) * 0.005;
        var t: usize = 0;
        while (t < tracks) : (t += 1) {
            const off = t * frames;
            addMulUnroll4(
                out_l[off .. off + frames],
                out_r[off .. off + frames],
                src_l[off .. off + frames],
                src_r[off .. off + frames],
                frames,
                gain,
            );
        }
    }
    const end_u4 = std.Io.Clock.awake.now(io);
    const ns_u4 = time_utils.nsSince(start, end_u4);
    var checksum_u4: f64 = 0;
    for (0..tracks) |t| {
        checksum_u4 += out_l[t * frames];
    }

    @memcpy(out_l, base_l);
    @memcpy(out_r, base_r);
    start = std.Io.Clock.awake.now(io);
    b = 0;
    while (b < blocks) : (b += 1) {
        const gain = 0.95 + @as(f32, @floatFromInt(b % 7)) * 0.005;
        var t: usize = 0;
        while (t < tracks) : (t += 1) {
            const off = t * frames;
            addMulUnroll16(
                out_l[off .. off + frames],
                out_r[off .. off + frames],
                src_l[off .. off + frames],
                src_r[off .. off + frames],
                frames,
                gain,
            );
        }
    }
    const end_u16 = std.Io.Clock.awake.now(io);
    const ns_u16 = time_utils.nsSince(start, end_u16);
    var checksum_u16: f64 = 0;
    for (0..tracks) |t| {
        checksum_u16 += out_l[t * frames];
    }

    const work_items = @as(f64, @floatFromInt(blocks * tracks * frames));
    const ns_per_frame_u1 = @as(f64, @floatFromInt(ns_u1)) / work_items;
    const ns_per_frame_u4 = @as(f64, @floatFromInt(ns_u4)) / work_items;
    const ns_per_frame_u16 = @as(f64, @floatFromInt(ns_u16)) / work_items;
    const speedup = @as(f64, @floatFromInt(ns_u1)) / @max(@as(f64, @floatFromInt(ns_u4)), 1.0);
    const speedup_16 = @as(f64, @floatFromInt(ns_u1)) / @max(@as(f64, @floatFromInt(ns_u16)), 1.0);

    std.log.info(
        "Kernel bench unroll1: total_ns={d} ns_per_frame={d:.4} checksum={d:.6}",
        .{ ns_u1, ns_per_frame_u1, checksum_u1 },
    );
    std.log.info(
        "Kernel bench unroll4: total_ns={d} ns_per_frame={d:.4} checksum={d:.6}",
        .{ ns_u4, ns_per_frame_u4, checksum_u4 },
    );
    std.log.info(
        "Kernel bench unroll16: total_ns={d} ns_per_frame={d:.4} checksum={d:.6}",
        .{ ns_u16, ns_per_frame_u16, checksum_u16 },
    );
    std.log.info("Kernel bench speedup x{d:.3}", .{speedup});
    std.log.info("Kernel bench speedup16 x{d:.3}", .{speedup_16});
}
