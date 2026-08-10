//! Headless audio-engine microbench for RT budget analysis.
//!
//! Build: `zig build rt-bench -Doptimize=ReleaseFast`
//! Run:   `zig-out/bin/rt-bench` (optional: FLUX_BENCH_FRAMES=128 FLUX_BENCH_ITERS=20000)
//!
//! Reports ns/callback and % of the 44.1 kHz buffer budget for the idle graph
//! (no plugins) — the floor that every quantum must pay before any DSP.

const std = @import("std");
const audio_engine = @import("audio/audio_engine.zig");
const audio_graph = @import("audio/audio_graph.zig");
const audio_mix = @import("audio/audio_mix.zig");
const latency_compensation = @import("audio/latency_compensation.zig");
const note_source = @import("audio/note_source.zig");
const session_constants = @import("session/constants.zig");
const audio_constants = @import("audio/audio_constants.zig");
const engine_ui = @import("audio/engine_ui.zig");
const time_utils = @import("util/time_utils.zig");
const kernel_bench = @import("audio/kernel_bench.zig");

const max_tracks = session_constants.max_tracks;
const max_fx_slots = engine_ui.max_fx_slots;
const sample_rate = audio_constants.sample_rate;
const clock_io: std.Io = std.Io.Threaded.global_single_threaded.io();

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(clock_io);
}

fn envU32(name: [:0]const u8, default_value: u32) u32 {
    const v = std.c.getenv(name.ptr) orelse return default_value;
    return std.fmt.parseInt(u32, std.mem.span(v), 10) catch default_value;
}

fn budgetUs(frames: u32) f64 {
    return @as(f64, @floatFromInt(frames)) * 1_000_000.0 / @as(f64, @floatFromInt(sample_rate));
}

fn printLine(label: []const u8, total_ns: u64, iters: u32, frames: u32) void {
    const ns_per = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iters));
    const us_per = ns_per / 1000.0;
    const budget = budgetUs(frames);
    const pct = us_per / budget * 100.0;
    std.debug.print(
        "  {s:28}  {d:8.2} us/cb  ({d:6.1}% of {d:.0} us budget)  {d:.1} ns/frame\n",
        .{ label, us_per, pct, budget, ns_per / @as(f64, @floatFromInt(frames)) },
    );
}

fn initEmptySnapshot(snap: *audio_graph.StateSnapshot) void {
    const bytes: [*]u8 = @ptrCast(snap);
    @memset(bytes[0..@sizeOf(audio_graph.StateSnapshot)], 0);
    snap.bpm = 120;
    snap.time_signature_numerator = 4;
    snap.time_signature_denominator = 4;
    snap.track_count = max_tracks;
    snap.scene_count = session_constants.max_scenes;
    snap.playing = false;
    for (0..max_tracks) |t| {
        snap.active_scene_by_track[t] = -1;
        snap.playing_audio[t].clear();
        snap.track_instrument_enabled[t] = true;
        for (0..max_fx_slots) |fx| snap.track_fx_enabled[t][fx] = true;
        snap.tracks[t] = .{};
        snap.tracks[t].volume = 1.0;
    }
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    const frames = envU32("FLUX_BENCH_FRAMES", 128);
    const iters = envU32("FLUX_BENCH_ITERS", 20_000);
    const frames_list = [_]u32{ 64, 128, 256, 512, frames };

    std.debug.print(
        "Flux RT microbench  sr={d} tracks={d} fx_slots={d} StateSnapshot={d} KB  PDC ring/track={d} KB\n",
        .{
            sample_rate,
            max_tracks,
            max_fx_slots,
            @sizeOf(audio_graph.StateSnapshot) / 1024,
            (latency_compensation.max_frames * 2 * @sizeOf(f32)) / 1024,
        },
    );
    std.debug.print("  note_sources per graph: {d}  (tracks * (1 instrument + {d} fx))\n\n", .{
        max_tracks * (1 + max_fx_slots),
        max_fx_slots,
    });

    // ── Isolated kernel benches ──────────────────────────────────────────────
    // SIMD add-mul unroll (same as FLUX_KERNEL_BENCH on the flux binary).
    std.debug.print("SIMD add-mul kernel (FLUX_KERNEL_BENCH_* env):\n", .{});
    try kernel_bench.run(gpa, clock_io);
    std.debug.print("\n", .{});

    try benchPdc(gpa, frames, iters);
    benchLiveKeyEql(iters);
    benchSumSpans(frames, iters);
    try benchNoteSourcesIdle(frames, iters);
    std.debug.print("\n", .{});

    // ── Serial stage breakdown (4-track graph matches default session) ───────
    std.debug.print("Serial stage breakdown (jobs=null, quantum={d}):\n", .{frames});
    try benchStages(gpa, frames, iters, 4, false);
    try benchStages(gpa, frames, @max(iters / 4, 500), 4, true);
    try benchStages(gpa, frames, iters, 16, false);
    std.debug.print("\n", .{});

    // ── Full graph idle process at several quanta ────────────────────────────
    std.debug.print("Full idle Graph.process (no plugins, transport stopped):\n", .{});
    var seen: [8]u32 = @splat(0);
    var seen_n: usize = 0;
    for (frames_list) |f| {
        var skip = false;
        for (seen[0..seen_n]) |prev| {
            if (prev == f) skip = true;
        }
        if (skip) continue;
        if (seen_n < seen.len) {
            seen[seen_n] = f;
            seen_n += 1;
        }
        try benchFullGraph(gpa, f, iters);
    }
    std.debug.print("\n", .{});

    // ── Playing transport, still no clips/plugins ────────────────────────────
    std.debug.print("Full Graph.process playing=true, no active scenes/plugins:\n", .{});
    try benchFullGraphPlaying(gpa, frames, iters);

    // ── Full AudioEngine.render path (includes interleave + metronome) ───────
    std.debug.print("\nAudioEngine.render idle (interleave + metronome path):\n", .{});
    try benchEngineRender(gpa, frames, iters);

    // ── With built-in instruments (serial vs parallel) ───────────────────────
    std.debug.print("\nWith built-in plugins (quantum={d}):\n", .{frames});
    try benchWithPlugins(gpa, frames, @max(iters / 4, 500), 1, "com.juge.zsynth", false);
    try benchWithPlugins(gpa, frames, @max(iters / 4, 500), 4, "com.juge.zsynth", false);
    try benchWithPlugins(gpa, frames, @max(iters / 4, 500), 4, "com.juge.zsynth", true);
    try benchWithPlugins(gpa, frames, @max(iters / 10, 200), 1, "com.fourlex.zminimoog", false);
    try benchWithPlugins(gpa, frames, @max(iters / 10, 200), 2, "com.fourlex.zminimoog", false);
    try benchWithPlugins(gpa, frames, @max(iters / 10, 200), 2, "com.fourlex.zminimoog", true);

    // ── Snapshot publish cost (UI-thread, not RT, but freezes/xruns adjacent) ─
    std.debug.print("\nSnapshot assign cost (UI double-buffer publish):\n", .{});
    try benchSnapshotAssign(iters);
}

fn benchPdc(gpa: std.mem.Allocator, frames: u32, iters: u32) !void {
    var delays: [max_tracks]latency_compensation.StereoDelay = undefined;
    for (&delays) |*d| d.* = try .init(gpa);
    defer for (&delays) |*d| d.deinit(gpa);

    var left: [1024]f32 = @splat(0);
    var right: [1024]f32 = @splat(0);
    const n = @min(frames, 1024);

    // Warm
    for (0..100) |_| {
        for (&delays) |*d| d.process(left[0..n], right[0..n], 0);
    }

    var t0 = now();
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        for (&delays) |*d| d.process(left[0..n], right[0..n], 0);
    }
    printLine("PDC delay0 x16 tracks", time_utils.nsSince(t0, now()), iters, frames);

    // Warm delay != 0 path
    for (&delays) |*d| {
        d.history = latency_compensation.max_frames;
        d.delay = 512;
    }
    for (0..100) |_| {
        for (&delays) |*d| d.process(left[0..n], right[0..n], 512);
    }
    t0 = now();
    i = 0;
    while (i < iters) : (i += 1) {
        for (&delays) |*d| d.process(left[0..n], right[0..n], 512);
    }
    printLine("PDC delay512 x16 tracks", time_utils.nsSince(t0, now()), iters, frames);
}

fn benchLiveKeyEql(iters: u32) void {
    var a: [128]bool = @splat(false);
    var b: [128]bool = @splat(false);
    a[64] = true;
    b[64] = true;

    // 16 instrument note sources do mem.eql every callback when emit_notes
    const t0 = now();
    var i: u32 = 0;
    var checksum: usize = 0;
    while (i < iters) : (i += 1) {
        var t: usize = 0;
        while (t < max_tracks) : (t += 1) {
            if (!std.mem.eql(bool, a[0..], b[0..])) checksum +%= 1;
            @memcpy(a[0..], b[0..]);
        }
    }
    // Fake frames=128 for % budget context
    printLine("live-key eql+memcpy x16", time_utils.nsSince(t0, now()), iters, 128);
    std.mem.doNotOptimizeAway(checksum);
}

fn benchSumSpans(frames: u32, iters: u32) void {
    var lefts: [16][1024]f32 = @splat(@splat(0.1));
    var rights: [16][1024]f32 = @splat(@splat(0.1));
    var spans: [16]audio_mix.StereoSpan = undefined;
    const n = @min(frames, 1024);
    for (0..16) |k| {
        spans[k] = .{ .left = lefts[k][0..n], .right = rights[k][0..n] };
    }
    var out_l: [1024]f32 = undefined;
    var out_r: [1024]f32 = undefined;

    const t0 = now();
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        audio_mix.sumSpans(&out_l, &out_r, spans[0..16], n, 1.0);
    }
    printLine("sumSpans 16-in mixer", time_utils.nsSince(t0, now()), iters, frames);
    std.mem.doNotOptimizeAway(out_l[0]);
}

fn benchNoteSourcesIdle(frames: u32, iters: u32) !void {
    // One note source per instrument + fx slot, matching buildGraph
    const count = max_tracks * (1 + max_fx_slots);
    var sources = try std.heap.page_allocator.alloc(note_source.NoteSource, count);
    defer std.heap.page_allocator.free(sources);

    var idx: usize = 0;
    for (0..max_tracks) |t| {
        sources[idx] = .init(t, true, -1);
        idx += 1;
        for (0..max_fx_slots) |fx| {
            sources[idx] = .init(t, false, @intCast(fx));
            idx += 1;
        }
    }

    var snap: audio_graph.StateSnapshot = undefined;
    initEmptySnapshot(&snap);

    // Warm
    for (0..50) |_| {
        for (sources) |*s| _ = s.process(&snap, @floatFromInt(sample_rate), frames);
    }

    var t0 = now();
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        for (sources) |*s| _ = s.process(&snap, @floatFromInt(sample_rate), frames);
    }
    printLine("NoteSource.process x80 idle", time_utils.nsSince(t0, now()), iters, frames);

    snap.playing = true;
    t0 = now();
    i = 0;
    while (i < iters) : (i += 1) {
        for (sources) |*s| _ = s.process(&snap, @floatFromInt(sample_rate), frames);
    }
    printLine("NoteSource x80 playing/empty", time_utils.nsSince(t0, now()), iters, frames);
}

fn benchStages(gpa: std.mem.Allocator, frames: u32, iters: u32, tracks: usize, with_note: bool) !void {
    // Build a graph with exactly `tracks` instrument lanes (serial path only).
    var eng = try audio_engine.AudioEngine.init(gpa, @floatFromInt(sample_rate), frames);
    defer eng.deinit();
    try eng.rebuildTracks(tracks);

    var plugin_slot: ?@import("plugin/handle.zig").LoadedPlugin = null;
    defer {
        if (plugin_slot) |*s| {
            if (s.builtin) |*bh| {
                if (eng.shared.isPluginStarted(0)) {
                    if (s.getPlugin()) |p| p.stopProcessing(p);
                }
                bh.deinit();
            }
        }
    }

    if (with_note) {
        const builtin_load = @import("plugin/builtin_load.zig");
        const clap = @import("clap-bindings");
        const Host = struct {
            clap_host: clap.Host = .{
                .clap_version = clap.version,
                .host_data = undefined,
                .name = "rt-bench",
                .vendor = "flux",
                .url = null,
                .version = "0.1",
                .getExtension = struct {
                    fn f(_: *const clap.Host, _: [*:0]const u8) callconv(.c) ?*const anyopaque {
                        return null;
                    }
                }.f,
                .requestRestart = struct {
                    fn f(_: *const clap.Host) callconv(.c) void {}
                }.f,
                .requestProcess = struct {
                    fn f(_: *const clap.Host) callconv(.c) void {}
                }.f,
                .requestCallback = struct {
                    fn f(_: *const clap.Host) callconv(.c) void {}
                }.f,
            },
        };
        var host = Host{};
        plugin_slot = .{};
        try builtin_load.loadStaticInstrument(&plugin_slot.?, gpa, &host.clap_host, "com.fourlex.zminimoog", frames);
        eng.shared.setTrackPlugin(0, plugin_slot.?.getPlugin().?);
        eng.shared.requestStartProcessing(0);
        const idx = eng.shared.active_index.load(.acquire);
        eng.shared.snapshots[idx].live_key_states[0][60] = true;
        eng.shared.snapshots[idx].live_key_velocities[0][60] = 0.8;
    }

    const snap = eng.shared.snapshot();
    var acc: audio_graph.Graph.StageNs = .{};
    var stages: audio_graph.Graph.StageNs = .{};

    for (0..100) |_| {
        for (eng.graph.synths.items) |*s| s.sleeping = false;
        eng.graph.processProfiled(snap, &eng.shared, null, frames, 0, null);
    }

    var i: u32 = 0;
    var steady: u64 = 0;
    while (i < iters) : (i += 1) {
        for (eng.graph.synths.items) |*s| s.sleeping = false;
        stages = .{};
        eng.graph.processProfiled(snap, &eng.shared, null, frames, steady, &stages);
        acc.clear_active += stages.clear_active;
        acc.notes += stages.notes;
        acc.clips += stages.clips;
        acc.synths += stages.synths;
        acc.fx += stages.fx;
        acc.gains += stages.gains;
        acc.mixers += stages.mixers;
        acc.master += stages.master;
        acc.total += stages.total;
        steady +%= frames;
    }

    const label = if (with_note) "zminimoog+note" else "idle";
    std.debug.print(
        "  tracks≈{d} {s}: total={d:.2}us  notes={d:.2} clips={d:.2} synths={d:.2} fx={d:.2} gains={d:.2} mix={d:.2} master={d:.2} clear={d:.2}\n",
        .{
            eng.track_count,
            label,
            usAvg(acc.total, iters),
            usAvg(acc.notes, iters),
            usAvg(acc.clips, iters),
            usAvg(acc.synths, iters),
            usAvg(acc.fx, iters),
            usAvg(acc.gains, iters),
            usAvg(acc.mixers, iters),
            usAvg(acc.master, iters),
            usAvg(acc.clear_active, iters),
        },
    );
}

fn usAvg(total_ns: u64, iters: u32) f64 {
    return @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iters)) / 1000.0;
}

fn benchFullGraph(gpa: std.mem.Allocator, frames: u32, iters: u32) !void {
    var eng = try audio_engine.AudioEngine.init(gpa, @floatFromInt(sample_rate), frames);
    defer eng.deinit();

    const snap = eng.shared.snapshot();

    // Warm
    for (0..200) |_| {
        eng.graph.process(snap, &eng.shared, null, frames, 0);
    }

    const t0 = now();
    var i: u32 = 0;
    var steady: u64 = 0;
    while (i < iters) : (i += 1) {
        eng.graph.process(snap, &eng.shared, null, frames, steady);
        steady +%= frames;
    }
    var label_buf: [64]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buf, "graph idle frames={d}", .{frames});
    printLine(label, time_utils.nsSince(t0, now()), iters, frames);
}

fn benchFullGraphPlaying(gpa: std.mem.Allocator, frames: u32, iters: u32) !void {
    var eng = try audio_engine.AudioEngine.init(gpa, @floatFromInt(sample_rate), frames);
    defer eng.deinit();

    // Flip playing on the active snapshot in-place (bench-only).
    const idx = eng.shared.active_index.load(.acquire);
    eng.shared.snapshots[idx].playing = true;
    eng.shared.snapshots[idx].bpm = 120;
    const snap = eng.shared.snapshot();

    for (0..200) |_| {
        eng.graph.process(snap, &eng.shared, null, frames, 0);
    }

    const t0 = now();
    var i: u32 = 0;
    var steady: u64 = 0;
    while (i < iters) : (i += 1) {
        eng.graph.process(snap, &eng.shared, null, frames, steady);
        steady +%= frames;
    }
    printLine("graph playing empty", time_utils.nsSince(t0, now()), iters, frames);
}

fn benchEngineRender(gpa: std.mem.Allocator, frames: u32, iters: u32) !void {
    // Mirrors AudioEngine.render without a real zaudio.Device: graph.process +
    // stereo interleave into a device-shaped buffer.
    var eng = try audio_engine.AudioEngine.init(gpa, @floatFromInt(sample_rate), frames);
    defer eng.deinit();

    const sample_count = @as(usize, frames) * 2;
    const out = try gpa.alloc(f32, sample_count);
    defer gpa.free(out);
    const snap = eng.shared.snapshot();

    for (0..200) |_| {
        eng.shared.beginProcess();
        eng.graph.process(snap, &eng.shared, null, frames, 0);
        if (eng.graph.getMasterOutput()) |outputs| {
            audio_mix.interleaveStereo(out.ptr, 0, outputs.left, outputs.right, frames);
        }
        eng.shared.endProcess();
    }

    const t0 = now();
    var i: u32 = 0;
    var steady: u64 = 0;
    while (i < iters) : (i += 1) {
        eng.shared.beginProcess();
        defer eng.shared.endProcess();
        @memset(out, 0);
        eng.graph.process(snap, &eng.shared, null, frames, steady);
        if (eng.graph.getMasterOutput()) |outputs| {
            audio_mix.interleaveStereo(out.ptr, 0, outputs.left, outputs.right, frames);
        }
        steady +%= frames;
    }
    printLine("process+interleave idle", time_utils.nsSince(t0, now()), iters, frames);
    std.mem.doNotOptimizeAway(out[0]);
}

fn benchSnapshotAssign(iters: u32) !void {
    // Mimics double-buffer publish: `snapshots[current] = snapshots[next]`
    // Heap-allocate so ReleaseFast cannot elide the multi-MB memcpy.
    const a = try std.heap.page_allocator.create(audio_graph.StateSnapshot);
    defer std.heap.page_allocator.destroy(a);
    const b = try std.heap.page_allocator.create(audio_graph.StateSnapshot);
    defer std.heap.page_allocator.destroy(b);
    initEmptySnapshot(a);
    initEmptySnapshot(b);
    a.playing = true;
    a.playhead_beat = 1.5;
    a.piano_clips[0][0].notes[0].pitch = 60;
    a.piano_clips[max_tracks - 1][session_constants.max_scenes - 1].count = 1;

    for (0..5) |_| {
        b.* = a.*;
        a.* = b.*;
    }

    const t0 = now();
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        b.* = a.*;
        std.mem.doNotOptimizeAway(b.piano_clips[0][0].notes[0].pitch);
        std.mem.doNotOptimizeAway(b.playhead_beat);
    }
    const total = time_utils.nsSince(t0, now());
    const ns_per = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(iters));
    std.debug.print(
        "  {s:28}  {d:8.2} us/assign  ({d} KB struct)\n",
        .{ "StateSnapshot assign", ns_per / 1000.0, @sizeOf(audio_graph.StateSnapshot) / 1024 },
    );
}

fn benchWithPlugins(
    gpa: std.mem.Allocator,
    frames: u32,
    iters: u32,
    plugin_count: usize,
    plugin_id: []const u8,
    use_jobs: bool,
) !void {
    const builtin_load = @import("plugin/builtin_load.zig");
    const plugin_handle = @import("plugin/handle.zig");
    const clap = @import("clap-bindings");

    const Host = struct {
        clap_host: clap.Host = .{
            .clap_version = clap.version,
            .host_data = undefined,
            .name = "rt-bench",
            .vendor = "flux",
            .url = null,
            .version = "0.1",
            .getExtension = struct {
                fn f(_: *const clap.Host, _: [*:0]const u8) callconv(.c) ?*const anyopaque {
                    return null;
                }
            }.f,
            .requestRestart = struct {
                fn f(_: *const clap.Host) callconv(.c) void {}
            }.f,
            .requestProcess = struct {
                fn f(_: *const clap.Host) callconv(.c) void {}
            }.f,
            .requestCallback = struct {
                fn f(_: *const clap.Host) callconv(.c) void {}
            }.f,
        },
    };

    var host = Host{};
    var eng = try audio_engine.AudioEngine.init(gpa, @floatFromInt(sample_rate), frames);
    defer eng.deinit();

    var jobs_storage: ?audio_graph.JobQueue = null;
    defer {
        if (jobs_storage) |*j| {
            eng.jobs = null;
            j.stop();
            j.join();
            j.deinit();
        }
    }
    if (use_jobs) {
        jobs_storage = try audio_graph.JobQueue.init(gpa, clock_io);
        try jobs_storage.?.start();
        eng.jobs = &jobs_storage.?;
    }

    var slots: [max_tracks]plugin_handle.LoadedPlugin = @splat(.{});
    defer {
        for (0..plugin_count) |t| {
            if (slots[t].builtin) |*bh| {
                if (eng.shared.isPluginStarted(t)) {
                    if (slots[t].getPlugin()) |p| p.stopProcessing(p);
                }
                bh.deinit();
            }
        }
    }

    const n = @min(plugin_count, max_tracks);
    for (0..n) |t| {
        try builtin_load.loadStaticInstrument(&slots[t], gpa, &host.clap_host, plugin_id, frames);
        const plugin = slots[t].getPlugin().?;
        eng.shared.setTrackPlugin(t, plugin);
        eng.shared.requestStartProcessing(t);
        // Force non-sleeping so process always runs (worst-case continuous voices).
        eng.shared.process_requested.store(true, .release);
    }

    // Hold a live note on each instrument track so plugins cannot sleep.
    const idx = eng.shared.active_index.load(.acquire);
    for (0..n) |t| {
        eng.shared.snapshots[idx].live_key_states[t][60] = true;
        eng.shared.snapshots[idx].live_key_velocities[t][60] = 0.8;
    }
    const snap = eng.shared.snapshot();

    for (0..50) |_| {
        // Prevent sleep: plugins return .sleep with silent input after note-off.
        for (eng.graph.synths.items) |*s| s.sleeping = false;
        eng.graph.process(snap, &eng.shared, eng.jobs, frames, 0);
    }

    const t0 = now();
    var i: u32 = 0;
    var steady: u64 = 0;
    while (i < iters) : (i += 1) {
        for (eng.graph.synths.items) |*s| s.sleeping = false;
        eng.graph.process(snap, &eng.shared, eng.jobs, frames, steady);
        steady +%= frames;
    }
    const total = time_utils.nsSince(t0, now());

    var label_buf: [96]u8 = undefined;
    const mode: []const u8 = if (use_jobs) "parallel" else "serial";
    const short_id = if (std.mem.lastIndexOfScalar(u8, plugin_id, '.')) |dot|
        plugin_id[dot + 1 ..]
    else
        plugin_id;
    const label = try std.fmt.bufPrint(&label_buf, "{s} x{d} {s}", .{ short_id, n, mode });
    printLine(label, total, iters, frames);
}
