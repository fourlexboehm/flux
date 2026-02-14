const builtin = @import("builtin");
const std = @import("std");
const zaudio = @import("zaudio");

const audio_constants = @import("audio/audio_constants.zig");
const audio_device = @import("audio/audio_device.zig");
const audio_engine = @import("audio/audio_engine.zig");
const audio_graph = @import("audio/audio_graph.zig");
const host_mod = @import("host.zig");
const plugin_runtime = @import("plugin/plugin_runtime.zig");
const session_constants = @import("ui/session_view/constants.zig");
const time_utils = @import("time_utils.zig");
const ui_state = @import("ui/state.zig");

const track_count = session_constants.max_tracks;
const TrackPlugin = plugin_runtime.TrackPlugin;
const simd_lanes = 4;
const F32xN = @Vector(simd_lanes, f32);

pub fn envBool(name: [:0]const u8) bool {
    const v = std.c.getenv(name.ptr) orelse return false;
    const s = std.mem.span(v);
    if (s.len == 0) return false;
    return s[0] == '1' or s[0] == 'y' or s[0] == 'Y' or s[0] == 't' or s[0] == 'T';
}

fn envU32(name: [:0]const u8, default_value: u32) u32 {
    const v = std.c.getenv(name.ptr) orelse return default_value;
    return std.fmt.parseInt(u32, std.mem.span(v), 10) catch default_value;
}

fn envU64(name: [:0]const u8, default_value: u64) u64 {
    const v = std.c.getenv(name.ptr) orelse return default_value;
    return std.fmt.parseInt(u64, std.mem.span(v), 10) catch default_value;
}

fn envUsize(name: [:0]const u8, default_value: usize) usize {
    const v = std.c.getenv(name.ptr) orelse return default_value;
    return std.fmt.parseInt(usize, std.mem.span(v), 10) catch default_value;
}

fn envF32(name: [:0]const u8, default_value: f32) f32 {
    const v = std.c.getenv(name.ptr) orelse return default_value;
    return std.fmt.parseFloat(f32, std.mem.span(v)) catch default_value;
}

inline fn nsSince(from: std.Io.Timestamp, to: std.Io.Timestamp) u64 {
    const ns = from.durationTo(to).toNanoseconds();
    return if (ns > 0) @intCast(ns) else 0;
}

pub fn configureRuntimeTuning(host: *host_mod.Host, cpu_count: usize) void {
    const is_arm = switch (builtin.cpu.arch) {
        .arm, .armeb, .thumb, .thumbeb, .aarch64, .aarch64_be => true,
        else => false,
    };
    const arm_default_scale: f32 = if (is_arm) 0.75 else 1.0;
    const fanout_scale = envF32("FLUX_AUDIO_ARM_FANOUT_SCALE", arm_default_scale);
    const base_fanout: usize = if (cpu_count > 1) @min(cpu_count - 1, 16) else 0;
    const clamped_scale = std.math.clamp(fanout_scale, 0.0, 1.0);
    const scaled_fanout = @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(base_fanout)) * clamped_scale)));
    host.jobs_fanout = @intCast(@min(base_fanout, scaled_fanout));

    const min_sleep_ns = envU64("FLUX_AUDIO_WORKER_MIN_SLEEP_NS", 10_000);
    const max_sleep_ns = envU64("FLUX_AUDIO_WORKER_MAX_SLEEP_NS", 2_000_000);
    audio_device.setWorkerSleepBounds(min_sleep_ns, max_sleep_ns);

    const parallel_threshold = envU32("FLUX_AUDIO_PARALLEL_THRESHOLD", 3);
    audio_graph.setParallelThreshold(parallel_threshold);
    audio_device.setAudioThreadQos(.user_interactive);
}

const BenchConfig = struct {
    enabled: bool = false,
    scenario: []const u8 = "idle_play_lowbuf",
    duration_s: u32 = 180,
    log_json_path: ?[]const u8 = null,
};

fn benchConfigFromEnv() BenchConfig {
    var cfg: BenchConfig = .{};
    cfg.enabled = envBool("FLUX_HEADLESS_BENCH");
    if (std.c.getenv("FLUX_BENCH_SCENARIO")) |v| {
        cfg.scenario = std.mem.span(v);
    }
    cfg.duration_s = @max(envU32("FLUX_BENCH_DURATION_S", 180), 10);
    if (std.c.getenv("FLUX_BENCH_LOG_JSON")) |v| {
        const path = std.mem.span(v);
        if (path.len > 0) cfg.log_json_path = path;
    }
    return cfg;
}

inline fn benchAddMulUnroll1(
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

inline fn benchAddMulUnroll4(
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

inline fn benchAddMulUnroll16(
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

pub fn runKernelBench(allocator: std.mem.Allocator, io: std.Io) !void {
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

    std.log.info("Kernel bench: tracks={d} frames={d} blocks={d}", .{ tracks, frames, blocks });

    @memcpy(out_l, base_l);
    @memcpy(out_r, base_r);
    var start = std.Io.Clock.awake.now(io);
    var b: usize = 0;
    while (b < blocks) : (b += 1) {
        const gain = 0.95 + @as(f32, @floatFromInt(b % 7)) * 0.005;
        var t: usize = 0;
        while (t < tracks) : (t += 1) {
            const off = t * frames;
            benchAddMulUnroll1(
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
    const ns_u1 = nsSince(start, end_u1);
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
            benchAddMulUnroll4(
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
    const ns_u4 = nsSince(start, end_u4);
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
            benchAddMulUnroll16(
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
    const ns_u16 = nsSince(start, end_u16);
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

pub fn runHeadlessBench(
    _: std.mem.Allocator,
    io: std.Io,
    host: *host_mod.Host,
    state: *ui_state.State,
    track_plugins: *[track_count]TrackPlugin,
    track_fx: *[track_count][ui_state.max_fx_slots]TrackPlugin,
    engine: *audio_engine.AudioEngine,
    device: **zaudio.Device,
    device_config: *zaudio.Device.Config,
    buffer_frames: *u32,
) !bool {
    const bench = benchConfigFromEnv();
    if (!bench.enabled) return false;

    std.log.info("Headless benchmark mode: scenario={s} duration={d}s", .{ bench.scenario, bench.duration_s });

    var last = std.Io.Clock.awake.now(io);
    const start = last;
    while (true) {
        host.pumpMainThreadCallbacks();
        const now = std.Io.Clock.awake.now(io);
        const elapsed_ns = nsSince(start, now);
        if (elapsed_ns >= @as(u64, bench.duration_s) * std.time.ns_per_s) break;

        const elapsed_s: u32 = @intCast(elapsed_ns / std.time.ns_per_s);
        const phase = (elapsed_s * 5) / bench.duration_s;

        var desired_playing = false;
        var desired_frames: u32 = buffer_frames.*;
        switch (phase) {
            0 => {
                desired_playing = false;
            },
            1 => {
                desired_playing = true;
            },
            2 => {
                desired_playing = true;
                desired_frames = 128;
            },
            3 => {
                desired_playing = true;
                desired_frames = 64;
            },
            else => {
                desired_playing = false;
                desired_frames = 64;
            },
        }

        if (desired_frames != buffer_frames.*) {
            audio_device.applyBufferFramesChange(
                io,
                device,
                device_config,
                engine,
                &engine.shared,
                track_plugins,
                track_fx,
                desired_frames,
            ) catch |err| {
                std.log.warn("Headless bench: failed buffer size {d}: {}", .{ desired_frames, err });
            };
            buffer_frames.* = desired_frames;
        }

        const delta_ns = nsSince(last, now);
        last = now;
        if (desired_playing != state.playing and desired_playing) {
            state.playhead_beat = 0;
        }
        state.playing = desired_playing;
        if (state.playing and delta_ns > 0) {
            const dt = @as(f64, @floatFromInt(delta_ns)) / std.time.ns_per_s;
            state.playhead_beat += @floatCast((@as(f64, state.bpm) / 60.0) * dt);
        }
        engine.updateFromUi(state);

        time_utils.sleepNs(io, 5 * std.time.ns_per_ms);
    }

    state.playing = false;
    engine.updateFromUi(state);

    std.log.info("Headless bench complete: scenario={s} duration={d}s", .{ bench.scenario, bench.duration_s });
    return true;
}
