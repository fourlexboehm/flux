const std = @import("std");
const zaudio = @import("zaudio");

const audio_constants = @import("audio_constants.zig");
const audio_engine = @import("audio_engine.zig");
const plugin_runtime = @import("../plugin/plugin_runtime.zig");
const session_constants = @import("../ui/session_view/constants.zig");
const thread_context = @import("../thread_context.zig");
const time_utils = @import("../time_utils.zig");
const ui_state = @import("../ui/state.zig");
const clock_io: std.Io = std.Io.Threaded.global_single_threaded.io();

const track_count = session_constants.max_tracks;
const TrackPlugin = plugin_runtime.TrackPlugin;

var worker_min_sleep_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(10_000);
var worker_max_sleep_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(2_000_000);

pub fn setWorkerSleepBounds(min_sleep_ns: u64, max_sleep_ns: u64) void {
    const min_ns = @max(min_sleep_ns, 1_000);
    const max_ns = @max(max_sleep_ns, min_ns);
    worker_min_sleep_ns.store(min_ns, .release);
    worker_max_sleep_ns.store(max_ns, .release);
}

pub fn dataCallback(
    device: *zaudio.Device,
    output: ?*anyopaque,
    _: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    thread_context.is_audio_thread = true;
    defer thread_context.is_audio_thread = false;

    const user_data = zaudio.Device.getUserData(device) orelse return;
    const engine: *audio_engine.AudioEngine = @ptrCast(@alignCast(user_data));
    const measure_dsp_load = engine.dsp_meter_count == 0;
    engine.dsp_meter_count = (engine.dsp_meter_count + 1) % audio_engine.dsp_meter_interval;
    const start = if (measure_dsp_load) std.Io.Clock.awake.now(clock_io) else undefined;

    engine.render(device, output, frame_count);

    if (!measure_dsp_load) return;

    const end = std.Io.Clock.awake.now(clock_io);
    const elapsed_us = time_utils.nsSince(start, end) / 1000;
    const budget_us = @as(u64, frame_count) * 1_000_000 / audio_constants.sample_rate;
    const budget_ns = budget_us * 1000;
    const usage_pct = elapsed_us * 100 / budget_us;
    const usage_pct_clamped: u32 = @intCast(@min(usage_pct, 999));
    engine.dsp_load_pct.store(usage_pct_clamped, .release);

    if (engine.jobs) |jobs| {
        const current_sleep = jobs.dynamic_sleep_ns.load(.monotonic);
        const is_playing = engine.shared.snapshot().playing;
        const configured_min = worker_min_sleep_ns.load(.acquire);
        const configured_max = worker_max_sleep_ns.load(.acquire);
        const max_sleep = @min(configured_max, budget_ns / 2);
        const min_sleep = @max(configured_min, @max(@as(u64, 1_000), budget_ns / 200));
        const mid_sleep = @min(max_sleep, @max(min_sleep, budget_ns / 10));
        const mid_threshold: u64 = if (is_playing) 5 else 20;
        const next: u64 = if (usage_pct >= 40)
            min_sleep
        else if (usage_pct >= mid_threshold)
            mid_sleep
        else if (usage_pct < 5 and current_sleep < max_sleep)
            @min(current_sleep * 2, max_sleep)
        else
            current_sleep;
        const sleep_ns: u64 = @max(min_sleep, @min(next, max_sleep));
        jobs.setSleepNs(sleep_ns);
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
