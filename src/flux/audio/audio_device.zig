const std = @import("std");
const zaudio = @import("zaudio");

const audio_constants = @import("audio_constants.zig");
const audio_engine = @import("audio_engine.zig");
const plugin_runtime = @import("../plugin/plugin_runtime.zig");
const session_constants = @import("../ui/session_view/constants.zig");
const thread_context = @import("../thread_context.zig");
const ui_state = @import("../ui/state.zig");

const track_count = session_constants.max_tracks;
const TrackPlugin = plugin_runtime.TrackPlugin;

var perf_total_us: u64 = 0;
var perf_max_us: u64 = 0;
var perf_count: u64 = 0;
var perf_last_print: ?std.time.Instant = null;

pub fn dataCallback(
    device: *zaudio.Device,
    output: ?*anyopaque,
    _: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    const start = std.time.Instant.now() catch null;
    thread_context.is_audio_thread = true;
    defer thread_context.is_audio_thread = false;

    const user_data = zaudio.Device.getUserData(device) orelse return;
    const engine: *audio_engine.AudioEngine = @ptrCast(@alignCast(user_data));
    const max_frames = engine.max_frames;
    if (frame_count > max_frames) {
        std.log.warn("Audio callback frame_count={} (requested {})", .{ frame_count, max_frames });
    }
    engine.render(device, output, frame_count);

    // Perf timing and adaptive sleep
    if (start) |s| {
        const end = std.time.Instant.now() catch return;
        const elapsed_us = end.since(s) / 1000;
        perf_total_us += elapsed_us;
        perf_max_us = @max(perf_max_us, elapsed_us);
        perf_count += 1;

        const budget_us = @as(u64, frame_count) * 1_000_000 / audio_constants.sample_rate;
        const budget_ns = budget_us * 1000;

        // Adaptive sleep - update every callback for responsiveness
        if (engine.jobs) |jobs| {
            const usage_pct = elapsed_us * 100 / budget_us;
            const usage_pct_clamped: u32 = @intCast(@min(usage_pct, 999));
            engine.dsp_load_pct.store(usage_pct_clamped, .release);
            const current_sleep = jobs.dynamic_sleep_ns.load(.monotonic);
            const is_playing = engine.shared.snapshot().playing;

            // Sleep targets as fraction of buffer period
            const max_sleep = budget_ns / 2; // 50% of buffer - idle
            const mid_sleep = budget_ns / 10; // 10% of buffer - moderate
            const min_sleep = budget_ns / 100; // 1% of buffer - high load
            const mid_threshold: u64 = if (is_playing) 5 else 20;

            const sleep_ns: u64 = if (usage_pct >= 40)
                min_sleep
            else if (usage_pct >= mid_threshold)
                mid_sleep
            else if (usage_pct < 5 and current_sleep < max_sleep)
                @min(current_sleep * 2, max_sleep) // ramp up slowly
            else
                current_sleep; // stay in current state

            jobs.setSleepNs(sleep_ns);
        }
    }
}

pub fn applyBufferFramesChange(
    io: std.Io,
    device: **zaudio.Device,
    device_config: *zaudio.Device.Config,
    engine: *audio_engine.AudioEngine,
    shared: *audio_engine.SharedState,
    track_plugins: *[track_count]TrackPlugin,
    track_fx: *[track_count][ui_state.max_fx_slots]TrackPlugin,
    new_frames: u32,
) !void {
    if (new_frames == engine.max_frames) return;

    if (device.*.isStarted()) {
        device.*.stop() catch |err| {
            std.log.warn("Failed to stop audio device: {}", .{err});
        };
    }
    shared.waitForIdle(io);

    const was_audio = thread_context.is_audio_thread;
    thread_context.is_audio_thread = true;
    defer thread_context.is_audio_thread = was_audio;

    const plugins_for_tracks = plugin_runtime.collectPlugins(track_plugins, track_fx);
    for (0..track_count) |t| {
        if (shared.isPluginStarted(t)) {
            if (plugins_for_tracks.instruments[t]) |plugin| {
                plugin.stopProcessing(plugin);
            }
            shared.clearPluginStarted(t);
        }
        for (0..ui_state.max_fx_slots) |fx_index| {
            if (shared.isFxPluginStarted(t, fx_index)) {
                if (plugins_for_tracks.fx[t][fx_index]) |plugin| {
                    plugin.stopProcessing(plugin);
                }
                shared.clearFxPluginStarted(t, fx_index);
            }
        }
    }

    for (0..track_count) |t| {
        if (plugins_for_tracks.instruments[t]) |plugin| {
            plugin.deactivate(plugin);
            if (!plugin.activate(plugin, audio_constants.sample_rate, 1, new_frames)) {
                std.log.warn("Failed to activate plugin for track {d}", .{t});
            } else {
                shared.requestStartProcessing(t);
            }
        }
        for (0..ui_state.max_fx_slots) |fx_index| {
            if (plugins_for_tracks.fx[t][fx_index]) |plugin| {
                plugin.deactivate(plugin);
                if (!plugin.activate(plugin, audio_constants.sample_rate, 1, new_frames)) {
                    std.log.warn("Failed to activate fx for track {d} slot {d}", .{ t, fx_index });
                } else {
                    shared.requestStartProcessingFx(t, fx_index);
                }
            }
        }
    }

    try engine.setMaxFrames(new_frames);
    device_config.period_size_in_frames = new_frames;
    device.*.destroy();
    device.* = try zaudio.Device.create(null, device_config.*);
    try device.*.start();
}
