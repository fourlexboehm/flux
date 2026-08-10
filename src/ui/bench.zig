//! Headless / kernel bench entrypoints for the DVUI host binary.
//!
//! Pre-DVUI these lived in `app/bench.zig` and were gated from `main_zgui` via
//! `FLUX_KERNEL_BENCH` / `FLUX_HEADLESS_BENCH`. Kernel work is shared with
//! `rt-bench` (`audio/kernel_bench.zig`); headless stresses the real device path
//! (`audio_runtime` + `plugin_host` pumps) without opening a window.

const std = @import("std");
const chrome = @import("state.zig");
const host_mod = @import("host.zig");
const plugin_host = @import("plugin_host.zig");
const audio_runtime = @import("audio_runtime.zig");
const document_model = @import("../document/model.zig");
const kernel_bench = @import("../audio/kernel_bench.zig");
const time_utils = @import("../util/time_utils.zig");
const gui_float = @import("../plugin/gui_float.zig");

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

const HeadlessConfig = struct {
    enabled: bool = false,
    scenario: []const u8 = "idle_play_lowbuf",
    duration_s: u32 = 180,
};

fn headlessConfigFromEnv() HeadlessConfig {
    var cfg: HeadlessConfig = .{};
    cfg.enabled = envBool("FLUX_HEADLESS_BENCH");
    if (std.c.getenv("FLUX_BENCH_SCENARIO")) |v| {
        cfg.scenario = std.mem.span(v);
    }
    cfg.duration_s = @max(envU32("FLUX_BENCH_DURATION_S", 180), 10);
    return cfg;
}

/// If a bench env var is set, run that mode and return true (caller should exit).
/// Order: kernel first (no device), then headless device stress.
pub fn maybeRunFromEnv(allocator: std.mem.Allocator, io: std.Io) !bool {
    if (envBool("FLUX_KERNEL_BENCH")) {
        try kernel_bench.run(allocator, io);
        return true;
    }
    if (try runHeadlessBench(allocator, io)) return true;
    return false;
}

/// Full host + audio device stress without a GUI window.
/// Phases cycle transport + buffer size; pumps plugin host main-thread services.
pub fn runHeadlessBench(allocator: std.mem.Allocator, io: std.Io) !bool {
    const cfg = headlessConfigFromEnv();
    if (!cfg.enabled) return false;

    std.log.info("Headless benchmark mode: scenario={s} duration={d}s", .{ cfg.scenario, cfg.duration_s });

    // XInitThreads before any CLAP may open an X11 parent (Linux only).
    gui_float.initPlatform();

    document_model.initGlobal(allocator);
    defer document_model.deinitGlobal();

    host_mod.initGlobal(allocator);
    defer host_mod.deinitGlobal();

    // Chrome state (transport / buffer size) — not the DVUI process global.
    var state: chrome.State = .{};
    host_mod.g.projectChrome(&state);

    plugin_host.initGlobal(allocator);
    defer {
        if (audio_runtime.ready()) {
            const eng = if (audio_runtime.g.engine != null) &audio_runtime.g.engine.? else null;
            plugin_host.g.unloadAll(eng);
        }
        plugin_host.deinitGlobal();
    }

    audio_runtime.initGlobal(allocator, state.buffer_frames);
    defer audio_runtime.deinitGlobal();

    if (!audio_runtime.g.running) {
        std.log.warn("Headless bench: audio device did not start; continuing pump-only", .{});
    }

    var last = std.Io.Clock.awake.now(io);
    const start = last;
    while (true) {
        const now = std.Io.Clock.awake.now(io);
        const elapsed_ns = time_utils.nsSince(start, now);
        if (elapsed_ns >= @as(u64, cfg.duration_s) * std.time.ns_per_s) break;

        const elapsed_s: u32 = @intCast(elapsed_ns / std.time.ns_per_s);
        const phase = (elapsed_s * 5) / cfg.duration_s;

        var desired_playing = false;
        var desired_frames: u32 = state.buffer_frames;
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

        if (desired_frames != state.buffer_frames) {
            state.buffer_frames = desired_frames;
        }

        const delta_ns = time_utils.nsSince(last, now);
        last = now;
        if (desired_playing != state.playing and desired_playing) {
            state.playhead_beat = 0;
        }
        state.playing = desired_playing;
        if (state.playing and delta_ns > 0) {
            const dt = @as(f64, @floatFromInt(delta_ns)) / std.time.ns_per_s;
            state.playhead_beat += @floatCast((@as(f64, state.bpm) / 60.0) * dt);
        }

        // Same per-frame path as the DVUI host (buffer resize, host pumps, publish).
        audio_runtime.g.tick(&host_mod.g, &state);

        time_utils.sleepNs(io, 5 * std.time.ns_per_ms);
    }

    state.playing = false;
    audio_runtime.g.tick(&host_mod.g, &state);

    std.log.info(
        "Headless bench complete: scenario={s} duration={d}s final_dsp={d}% buf={d}",
        .{ cfg.scenario, cfg.duration_s, state.dsp_load_pct, state.buffer_frames },
    );
    return true;
}
