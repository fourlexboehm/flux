const builtin = @import("builtin");
const std = @import("std");

const zaudio = @import("zaudio");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const shared_mod = @import("shared");
const objc = if (builtin.os.tag == .macos) @import("objc") else struct {};

const app_window = @import("app_window.zig");
const audio_constants = @import("audio/audio_constants.zig");
const audio_device = @import("audio/audio_device.zig");
const audio_engine = @import("audio/audio_engine.zig");
const audio_graph = @import("audio/audio_graph.zig");
const dawproject_runtime = @import("dawproject/runtime.zig");
const device_state = @import("device_state.zig");
const host_mod = @import("host.zig");
const midi_input = @import("midi_input.zig");
const options = @import("options");
const static_data = @import("static_data");
const plugin_runtime = @import("plugin/plugin_runtime.zig");
const plugins = @import("plugin/plugins.zig");
const presets = @import("plugin/presets.zig");
const session_constants = @import("ui/session_view/constants.zig");
const theme = @import("theme.zig");
const time_utils = @import("time_utils.zig");
const ui_draw = @import("ui/draw.zig");
const ui_filters = @import("ui/filters.zig");
const ui_keyboard = @import("ui/keyboard_midi.zig");
const ui_recording = @import("ui/recording.zig");
const ui_state = @import("ui/state.zig");
const colors = @import("ui/colors.zig");

const track_count = session_constants.max_tracks;

fn nsSince(from: std.Io.Timestamp, to: std.Io.Timestamp) u64 {
    return @intCast(from.durationTo(to).toNanoseconds());
}

pub const std_options: std.Options = .{
    .enable_segfault_handler = options.enable_segfault_handler,
};

const TrackPlugin = plugin_runtime.TrackPlugin;
const simd_lanes = 4;
const F32xN = @Vector(simd_lanes, f32);

const BenchConfig = struct {
    enabled: bool = false,
    scenario: []const u8 = "idle_play_lowbuf",
    duration_s: u32 = 180,
    log_json_path: ?[]const u8 = null,
};

fn envBool(name: [:0]const u8) bool {
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

fn configureRuntimeTuning(host: *host_mod.Host, cpu_count: usize) void {
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
    // Bias the CoreAudio callback thread toward P-cores where possible.
    audio_device.setAudioThreadQos(.user_interactive);
}

fn writeBenchReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    counters: audio_device.PerfCounters,
    midi_counters: audio_graph.MidiPerfCounters,
    duration_s: u32,
    scenario: []const u8,
) !void {
    const avg_us: u64 = if (counters.callbacks > 0) counters.total_us / counters.callbacks else 0;
    const over_budget_pct: u64 = if (counters.callbacks > 0)
        (counters.over_budget * 10_000) / counters.callbacks
    else
        0;
    const midi_avg_us: u64 = if (midi_counters.callbacks > 0) midi_counters.total_us / midi_counters.callbacks else 0;
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\n  \"scenario\": \"{s}\",\n  \"duration_s\": {d},\n  \"callbacks\": {d},\n  \"avg_callback_us\": {d},\n  \"max_callback_us\": {d},\n  \"budget_total_us\": {d},\n  \"over_budget_callbacks\": {d},\n  \"over_budget_pct_basis_points\": {d},\n  \"midi\": {{\n    \"callbacks\": {d},\n    \"avg_process_us\": {d},\n    \"total_process_us\": {d},\n    \"notes_scanned\": {d},\n    \"points_scanned\": {d},\n    \"scene_slots_scanned\": {d},\n    \"events_emitted\": {d}\n  }}\n}}\n",
        .{
            scenario,
            duration_s,
            counters.callbacks,
            avg_us,
            counters.max_us,
            counters.budget_total_us,
            counters.over_budget,
            over_budget_pct,
            midi_counters.callbacks,
            midi_avg_us,
            midi_counters.total_us,
            midi_counters.notes_scanned,
            midi_counters.points_scanned,
            midi_counters.scene_slots_scanned,
            midi_counters.events_emitted,
        },
    );
    defer allocator.free(json);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, json);
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

fn runKernelBench(allocator: std.mem.Allocator, io: std.Io) !void {
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

fn runHeadlessBench(
    allocator: std.mem.Allocator,
    io: std.Io,
    bench: BenchConfig,
    host: *host_mod.Host,
    state: *ui_state.State,
    track_plugins: *[track_count]TrackPlugin,
    track_fx: *[track_count][ui_state.max_fx_slots]TrackPlugin,
    engine: *audio_engine.AudioEngine,
    device: **zaudio.Device,
    device_config: *zaudio.Device.Config,
    buffer_frames: *u32,
) !void {
    std.log.info("Headless benchmark mode: scenario={s} duration={d}s", .{ bench.scenario, bench.duration_s });
    audio_device.resetPerfCounters();
    audio_graph.resetMidiPerfCounters();

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

    const counters = audio_device.snapshotPerfCounters();
    const midi_counters = audio_graph.snapshotMidiPerfCounters();
    const midi_avg_us: u64 = if (midi_counters.callbacks > 0) midi_counters.total_us / midi_counters.callbacks else 0;
    std.log.info("Headless bench results: callbacks={d} max_us={d} over_budget={d}", .{
        counters.callbacks,
        counters.max_us,
        counters.over_budget,
    });
    std.log.info(
        "Headless MIDI: callbacks={d} avg_us={d} notes_scanned={d} points_scanned={d} scene_scans={d} events={d}",
        .{
            midi_counters.callbacks,
            midi_avg_us,
            midi_counters.notes_scanned,
            midi_counters.points_scanned,
            midi_counters.scene_slots_scanned,
            midi_counters.events_emitted,
        },
    );
    if (bench.log_json_path) |path| {
        try writeBenchReport(allocator, io, path, counters, midi_counters, bench.duration_s, bench.scenario);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var host = host_mod.Host.init();
    host.clap_host.host_data = &host;

    const cpu_count = std.Thread.getCpuCount() catch 4;
    configureRuntimeTuning(&host, cpu_count);

    if (envBool("FLUX_KERNEL_BENCH")) {
        try runKernelBench(allocator, io);
        return;
    }

    var track_plugins: [track_count]TrackPlugin = undefined;
    for (&track_plugins) |*track| {
        track.* = .{};
    }
    var track_fx: [track_count][ui_state.max_fx_slots]TrackPlugin = undefined;
    for (&track_fx) |*track_slots| {
        for (track_slots) |*slot| {
            slot.* = .{};
        }
    }

    zaudio.init(allocator);
    defer zaudio.deinit();

    var catalog = try plugins.discover(allocator, io);
    defer catalog.deinit();

    var preset_catalog = try presets.build(allocator, io, &catalog, init.environ_map);
    defer preset_catalog.deinit();

    var state = ui_state.State.init(allocator);
    defer state.deinit();
    state.plugin_items = catalog.items_z;
    state.plugin_fx_items = catalog.fx_items_z;
    state.plugin_fx_indices = catalog.fx_indices;
    state.plugin_instrument_items = catalog.instrument_items_z;
    state.plugin_instrument_indices = catalog.instrument_indices;
    state.plugin_divider_index = catalog.divider_index;
    state.preset_catalog = &preset_catalog;
    ui_filters.rebuildInstrumentFilter(&state);
    var buffer_frames: u32 = state.buffer_frames;

    // Set up host references for undo support
    host.ui_state = &state;
    host.allocator = allocator;
    host.track_plugins_ptr = &track_plugins;
    host.track_fx_ptr = &track_fx;
    host.catalog_ptr = &catalog;

    var engine = try audio_engine.AudioEngine.init(allocator, audio_constants.sample_rate, buffer_frames);
    defer engine.deinit();
    host.shared_state = &engine.shared;

    // Initialize libz_jobs work-stealing queue (FLUX_SINGLE_THREAD=1 to disable)
    const single_thread = if (std.c.getenv("FLUX_SINGLE_THREAD")) |v| v[0] == '1' else false;
    var jobs_storage: audio_graph.JobQueue = undefined;
    if (!single_thread) {
        jobs_storage = try audio_graph.JobQueue.init(allocator, io);
        try jobs_storage.start();
        engine.jobs = &jobs_storage;
        host.jobs = &jobs_storage;
    } else {
        std.log.info("Single-threaded mode (FLUX_SINGLE_THREAD=1)", .{});
    }
    defer if (!single_thread) {
        jobs_storage.stop();
        jobs_storage.join();
        jobs_storage.deinit();
    };

    engine.updateFromUi(&state);
    // Initial plugin sync will happen on first frame - plugins are loaded lazily

    var device_config = zaudio.Device.Config.init(.playback);
    device_config.playback.format = zaudio.Format.float32;
    device_config.playback.channels = audio_constants.channels;
    device_config.sample_rate = audio_constants.sample_rate;
    device_config.period_size_in_frames = buffer_frames;
    device_config.performance_profile = .low_latency;
    device_config.periods = 2;
    device_config.data_callback = audio_device.dataCallback;
    device_config.user_data = &engine;

    var device = try zaudio.Device.create(null, device_config);
    defer device.destroy();
    try device.start();

    const bench = benchConfigFromEnv();
    if (bench.enabled) {
        try runHeadlessBench(
            allocator,
            io,
            bench,
            &host,
            &state,
            &track_plugins,
            &track_fx,
            &engine,
            &device,
            &device_config,
            &buffer_frames,
        );
        if (device.isStarted()) {
            device.stop() catch |err| {
                std.log.warn("Failed to stop audio device: {}", .{err});
            };
        }
        for (&track_plugins, 0..) |*track, t| {
            plugin_runtime.unloadPlugin(track, allocator, &engine.shared, t);
        }
        return;
    }

    zgui.init(allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    zgui.plot.init();
    defer zgui.plot.deinit();
    ui_filters.rebuildPresetFilter(&state);

    colors.Colors.setTheme(theme.resolveTheme());

    var midi = midi_input.MidiInput{};
    midi.init(allocator) catch |err| {
        std.log.warn("MIDI input disabled: {}", .{err});
        midi.disable();
    };
    defer midi.deinit();

    var last_time = std.Io.Clock.awake.now(io);
    var dsp_last_update = last_time;
    var last_interaction_time = last_time;
    var window_was_focused = true;

    std.log.info("flux running (Ctrl+C to quit)", .{});
    switch (builtin.os.tag) {
        .macos => {
            var app = try app_window.AppWindow.init("flux", 1280, 720);
            defer app.deinit();

            shared_mod.imgui_style.applyScaleFromMemory(static_data.font, app.scale_factor);
            zgui.backend.init(app.view, app.device);
            defer zgui.backend.deinit();

            while (app.window.isVisible()) {
                const frame_start = std.Io.Clock.awake.now(io);
                host.pumpMainThreadCallbacks();

                const now = std.Io.Clock.awake.now(io);
                const delta_ns = nsSince(last_time, now);
                last_time = now;
                if (delta_ns > 0) {
                    const dt = @as(f64, @floatFromInt(delta_ns)) / std.time.ns_per_s;
                    ui_recording.tick(&state, dt);
                }
                device_state.updateDeviceState(&state, &catalog, &track_plugins, &track_fx);
                midi.poll();
                state.midi_note_states = midi.note_states;
                state.midi_note_velocities = midi.note_velocities;
                if (nsSince(dsp_last_update, now) >= 250 * std.time.ns_per_ms) {
                    state.dsp_load_pct = engine.dsp_load_pct.load(.acquire);
                    dsp_last_update = now;
                }
                const wants_keyboard = zgui.io.getWantCaptureKeyboard();
                const item_active = zgui.isAnyItemActive();
                if ((!wants_keyboard or !item_active) and zgui.isKeyPressed(.space, false)) {
                    // Avoid macOS "bonk" when handling space outside ImGui widgets.
                    zgui.setNextFrameWantCaptureKeyboard(true);
                    state.playing = !state.playing;
                    state.playhead_beat = 0;
                }

                while (app.app.nextEventMatchingMask(
                    objc.app_kit.EventMaskAny,
                    objc.app_kit.Date.distantPast(),
                    objc.app_kit.NSDefaultRunLoopMode,
                    true,
                )) |event| {
                    app.app.sendEvent(event);
                }
                const window_focused = objc.objc.msgSend(app.window, "isKeyWindow", bool, .{});
                if (window_focused and !window_was_focused) {
                    last_interaction_time = now;
                }
                window_was_focused = window_focused;

                const frame = app.window.frame();
                const content = app.window.contentRectForFrameRect(frame);
                const scale: f32 = @floatCast(app.window.backingScaleFactor());
                if (scale != app.scale_factor) {
                    app.scale_factor = scale;
                }
                app.view.setFrameSize(content.size);
                app.view.setBoundsOrigin(.{ .x = 0, .y = 0 });
                app.view.setBoundsSize(.{
                    .width = content.size.width * @as(f64, @floatCast(scale)),
                    .height = content.size.height * @as(f64, @floatCast(scale)),
                });
                app.layer.setDrawableSize(.{
                    .width = content.size.width * @as(f64, @floatCast(scale)),
                    .height = content.size.height * @as(f64, @floatCast(scale)),
                });

                const fb_width: u32 = @intFromFloat(@max(content.size.width * @as(f64, @floatCast(scale)), 1));
                const fb_height: u32 = @intFromFloat(@max(content.size.height * @as(f64, @floatCast(scale)), 1));

                const descriptor = objc.metal.RenderPassDescriptor.renderPassDescriptor();
                const color_attachment = descriptor.colorAttachments().objectAtIndexedSubscript(0);
                const clear_color = objc.metal.ClearColor.init(0.08, 0.08, 0.1, 1.0);
                color_attachment.setClearColor(clear_color);
                const attachment_descriptor = color_attachment.as(objc.metal.RenderPassAttachmentDescriptor);
                const drawable_opt = app.layer.nextDrawable();
                if (drawable_opt == null) {
                    time_utils.sleepNs(io, 5 * std.time.ns_per_ms);
                    continue;
                }
                const drawable = drawable_opt.?;
                attachment_descriptor.setTexture(drawable.texture());
                attachment_descriptor.setLoadAction(objc.metal.LoadActionClear);
                attachment_descriptor.setStoreAction(objc.metal.StoreActionStore);

                const command_buffer = app.command_queue.commandBuffer().?;
                const command_encoder = command_buffer.renderCommandEncoderWithDescriptor(descriptor).?;

                zgui.backend.newFrame(fb_width, fb_height, app.view, descriptor);
                zgui.setNextFrameWantCaptureKeyboard(true);
                ui_keyboard.updateKeyboardMidi(&state);
                plugin_runtime.updateUiPluginPointers(&state, &track_plugins, &track_fx);
                ui_draw.draw(&state, 1.0);
                if (state.buffer_frames_requested) {
                    const requested_frames = state.buffer_frames;
                    state.buffer_frames_requested = false;
                    if (requested_frames != buffer_frames) {
                        audio_device.applyBufferFramesChange(
                            io,
                            &device,
                            &device_config,
                            &engine,
                            &engine.shared,
                            &track_plugins,
                            &track_fx,
                            requested_frames,
                        ) catch |err| {
                            std.log.warn("Failed to apply buffer size {d}: {}", .{ requested_frames, err });
                            state.buffer_frames = buffer_frames;
                        };
                        if (state.buffer_frames == requested_frames) {
                            buffer_frames = requested_frames;
                        }
                    }
                }
                dawproject_runtime.handleFileRequests(
                    allocator,
                    io,
                    &state,
                    &catalog,
                    &track_plugins,
                    &track_fx,
                    &host.clap_host,
                    &engine.shared,
                );
                engine.updateFromUi(&state);
                try plugin_runtime.syncTrackPlugins(allocator, &host.clap_host, &track_plugins, &track_fx, &state, &catalog, &engine.shared, io, buffer_frames, true);
                try plugin_runtime.syncFxPlugins(allocator, &host.clap_host, &track_plugins, &track_fx, &state, &catalog, &engine.shared, io, buffer_frames, true);
                dawproject_runtime.applyPresetLoadRequests(&state, &catalog, &track_plugins);
                const frame_plugins = plugin_runtime.collectPlugins(&track_plugins, &track_fx);
                engine.updatePlugins(frame_plugins.instruments, frame_plugins.fx);
                zgui.backend.draw(command_buffer, command_encoder);
                command_encoder.as(objc.metal.CommandEncoder).endEncoding();
                command_buffer.presentDrawable(drawable.as(objc.metal.Drawable));
                command_buffer.commit();
                command_buffer.waitUntilCompleted();

                // Update plugin GUIs outside the host ImGui frame to avoid context collisions.
                for (&track_plugins) |*track| {
                    if (track.gui_open and track.handle != null) {
                        track.handle.?.plugin.onMainThread(track.handle.?.plugin);
                    }
                }

                const any_plugin_gui_open = blk: {
                    for (track_plugins) |track| {
                        if (track.gui_open) break :blk true;
                    }
                    break :blk false;
                };
                const interactive = zgui.isAnyItemActive() or zgui.isAnyItemHovered() or zgui.io.getWantCaptureMouse() or wants_keyboard;
                const active = state.playing or interactive or any_plugin_gui_open;
                if (active) {
                    last_interaction_time = now;
                }
                const idle_ns = nsSince(last_interaction_time, now);
                const target_fps: u32 = if (active)
                    60
                else if (idle_ns >= std.time.ns_per_s)
                    1
                else
                    20;
                const target_frame_ns: u64 = std.time.ns_per_s / @as(u64, target_fps);
                const frame_end = std.Io.Clock.awake.now(io);
                const frame_elapsed_ns = nsSince(frame_start, frame_end);
                if (frame_elapsed_ns < target_frame_ns) {
                    time_utils.sleepNs(io, target_frame_ns - frame_elapsed_ns);
                }
            }
        },
        .linux => {
            const gl_major = 4;
            const gl_minor = 0;

            try zglfw.init();
            defer zglfw.terminate();

            zglfw.windowHint(.context_version_major, gl_major);
            zglfw.windowHint(.context_version_minor, gl_minor);
            zglfw.windowHint(.opengl_profile, .opengl_core_profile);
            zglfw.windowHint(.opengl_forward_compat, true);
            zglfw.windowHint(.client_api, .opengl_api);
            zglfw.windowHint(.doublebuffer, true);

            const window = try zglfw.Window.create(1280, 720, "flux", null);
            defer window.destroy();
            window.setSizeLimits(320, 240, -1, -1);

            zglfw.makeContextCurrent(window);
            zglfw.swapInterval(1);
            try zopengl.loadCoreProfile(zglfw.getProcAddress, gl_major, gl_minor);

            // Font/UI scale: Wayland typically already provides logical sizes, so default to 1.0.
            // Override via `FLUX_UI_SCALE` (e.g. "1.25") if desired.
            const ui_scale: f32 = blk: {
                const env = std.c.getenv("FLUX_UI_SCALE") orelse break :blk 1.0;
                const parsed = std.fmt.parseFloat(f32, std.mem.span(env)) catch break :blk 1.0;
                break :blk if (parsed > 0) parsed else 1.0;
            };
            shared_mod.imgui_style.applyScaleFromMemory(static_data.font, ui_scale);

            zgui.backend.init(window);
            defer zgui.backend.deinit();

            const gl = zopengl.bindings;

            while (!window.shouldClose()) {
                const frame_start = std.Io.Clock.awake.now(io);
                host.pumpMainThreadCallbacks();

                const now = std.Io.Clock.awake.now(io);
                const delta_ns = nsSince(last_time, now);
                last_time = now;
                if (delta_ns > 0) {
                    const dt = @as(f64, @floatFromInt(delta_ns)) / std.time.ns_per_s;
                    ui_recording.tick(&state, dt);
                }
                device_state.updateDeviceState(&state, &catalog, &track_plugins, &track_fx);
                midi.poll();
                state.midi_note_states = midi.note_states;
                state.midi_note_velocities = midi.note_velocities;
                if (nsSince(dsp_last_update, now) >= 250 * std.time.ns_per_ms) {
                    state.dsp_load_pct = engine.dsp_load_pct.load(.acquire);
                    dsp_last_update = now;
                }
                const wants_keyboard = zgui.io.getWantCaptureKeyboard();
                const item_active = zgui.isAnyItemActive();
                if ((!wants_keyboard or !item_active) and zgui.isKeyPressed(.space, false)) {
                    zgui.setNextFrameWantCaptureKeyboard(true);
                    state.playing = !state.playing;
                    state.playhead_beat = 0;
                }

                zglfw.pollEvents();
                if (window.getKey(.escape) == .press) {
                    zglfw.setWindowShouldClose(window, true);
                    continue;
                }
                const window_focused = window.getAttribute(.focused);
                if (window_focused and !window_was_focused) {
                    last_interaction_time = now;
                }
                window_was_focused = window_focused;

                gl.clearBufferfv(gl.COLOR, 0, &colors.Colors.current.bg_dark);
                const fb_size = window.getFramebufferSize();
                const fb_width: u32 = @intCast(@max(fb_size[0], 1));
                const fb_height: u32 = @intCast(@max(fb_size[1], 1));

                // Wayland reports cursor positions in logical units while the framebuffer
                // is in physical pixels. Feed ImGui the logical size and the framebuffer
                // scale so mouse clicks/key focus line up.
                const win_size = window.getSize();
                const win_width_i: c_int = @max(win_size[0], 1);
                const win_height_i: c_int = @max(win_size[1], 1);
                const win_width: u32 = @intCast(win_width_i);
                const win_height: u32 = @intCast(win_height_i);
                const scale_x: f32 = @as(f32, @floatFromInt(fb_width)) / @as(f32, @floatFromInt(win_width));
                const scale_y: f32 = @as(f32, @floatFromInt(fb_height)) / @as(f32, @floatFromInt(win_height));

                zgui.backend.newFrame(win_width, win_height);
                zgui.io.setDisplayFramebufferScale(scale_x, scale_y);
                zgui.setNextFrameWantCaptureKeyboard(true);
                ui_keyboard.updateKeyboardMidi(&state);
                plugin_runtime.updateUiPluginPointers(&state, &track_plugins, &track_fx);
                ui_draw.draw(&state, 1.0);
                if (state.buffer_frames_requested) {
                    const requested_frames = state.buffer_frames;
                    state.buffer_frames_requested = false;
                    if (requested_frames != buffer_frames) {
                        audio_device.applyBufferFramesChange(
                            io,
                            &device,
                            &device_config,
                            &engine,
                            &engine.shared,
                            &track_plugins,
                            &track_fx,
                            requested_frames,
                        ) catch |err| {
                            std.log.warn("Failed to apply buffer size {d}: {}", .{ requested_frames, err });
                            state.buffer_frames = buffer_frames;
                        };
                        if (state.buffer_frames == requested_frames) {
                            buffer_frames = requested_frames;
                        }
                    }
                }
                dawproject_runtime.handleFileRequests(
                    allocator,
                    io,
                    &state,
                    &catalog,
                    &track_plugins,
                    &track_fx,
                    &host.clap_host,
                    &engine.shared,
                );
                engine.updateFromUi(&state);
                try plugin_runtime.syncTrackPlugins(allocator, &host.clap_host, &track_plugins, &track_fx, &state, &catalog, &engine.shared, io, buffer_frames, true);
                try plugin_runtime.syncFxPlugins(allocator, &host.clap_host, &track_plugins, &track_fx, &state, &catalog, &engine.shared, io, buffer_frames, true);
                dawproject_runtime.applyPresetLoadRequests(&state, &catalog, &track_plugins);
                const frame_plugins = plugin_runtime.collectPlugins(&track_plugins, &track_fx);
                engine.updatePlugins(frame_plugins.instruments, frame_plugins.fx);
                zgui.backend.draw();

                window.swapBuffers();

                for (&track_plugins) |*track| {
                    if (track.gui_open and track.handle != null) {
                        track.handle.?.plugin.onMainThread(track.handle.?.plugin);
                    }
                }

                const any_plugin_gui_open = blk: {
                    for (track_plugins) |track| {
                        if (track.gui_open) break :blk true;
                    }
                    break :blk false;
                };
                const interactive = zgui.isAnyItemActive() or zgui.isAnyItemHovered() or zgui.io.getWantCaptureMouse() or wants_keyboard;
                const active = state.playing or interactive or any_plugin_gui_open;
                if (active) {
                    last_interaction_time = now;
                }
                const idle_ns = nsSince(last_interaction_time, now);
                const target_fps: u32 = if (active)
                    60
                else if (idle_ns >= std.time.ns_per_s)
                    1
                else
                    20;
                const target_frame_ns: u64 = std.time.ns_per_s / @as(u64, target_fps);
                const frame_end = std.Io.Clock.awake.now(io);
                const frame_elapsed_ns = nsSince(frame_start, frame_end);
                if (frame_elapsed_ns < target_frame_ns) {
                    time_utils.sleepNs(io, target_frame_ns - frame_elapsed_ns);
                }
            }
        },
        else => return error.UnsupportedOs,
    }

    if (device.isStarted()) {
        device.stop() catch |err| {
            std.log.warn("Failed to stop audio device: {}", .{err});
        };
    }
    for (&track_plugins) |*track| {
        plugin_runtime.closePluginGui(track);
    }
    for (&track_plugins, 0..) |*track, t| {
        plugin_runtime.unloadPlugin(track, allocator, &engine.shared, t);
    }
}
