//! Full `AudioEngine` for the DVUI host: zaudio device, graph render, metronome,
//! DSP %, track peak meters, live plugin pointers from `ui/plugin_host`.
//!
//! Chrome adapter: each frame projects `ui/host` document + chrome transport into
//! `audio/engine_ui.EngineUiView`.
//!
//! Hardware MIDI + computer-keyboard live keys come from `plugin_host`.
//! DAWproject load/save is adapted by `ui/project_runtime.zig`.
//!
//! Runtime tuning (`FLUX_AUDIO_*`) and JobQueue ownership live here; the CLAP
//! host `thread_pool` extension shares the same queue via `plugin_host`.

const builtin = @import("builtin");
const std = @import("std");
const zaudio = @import("zaudio");
const chrome = @import("state.zig");
const host_mod = @import("host.zig");
const document_model = @import("../document/model.zig");
const plugin_host_mod = @import("plugin_host.zig");
const audio_engine_mod = @import("../audio/audio_engine.zig");
const audio_constants = @import("../audio/audio_constants.zig");
const engine_ui = @import("../audio/engine_ui.zig");
const thread_context = @import("../util/thread_context.zig");
const time_utils = @import("../util/time_utils.zig");

const audio_graph = @import("../audio/audio_graph.zig");

const AudioEngine = audio_engine_mod.AudioEngine;
const EngineUiView = engine_ui.EngineUiView;
const max_tracks = engine_ui.max_tracks;
const max_fx_slots = engine_ui.max_fx_slots;

pub const sample_rate: u32 = audio_constants.sample_rate;
pub const channels: u32 = audio_constants.channels;
const dsp_meter_interval: u8 = audio_engine_mod.dsp_meter_interval;
const clock_io: std.Io = std.Io.Threaded.global_single_threaded.io();

/// Adaptive worker idle sleep bounds (copied from pre-DVUI audio_device).
var worker_min_sleep_ns: std.atomic.Value(u64) = .init(10_000);
var worker_max_sleep_ns: std.atomic.Value(u64) = .init(2_000_000);

pub fn setWorkerSleepBounds(min_sleep_ns: u64, max_sleep_ns: u64) void {
    const min_ns = @max(min_sleep_ns, 1_000);
    const max_ns = @max(max_sleep_ns, min_ns);
    worker_min_sleep_ns.store(min_ns, .release);
    worker_max_sleep_ns.store(max_ns, .release);
}

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

fn envF32(name: [:0]const u8, default_value: f32) f32 {
    const v = std.c.getenv(name.ptr) orelse return default_value;
    return std.fmt.parseFloat(f32, std.mem.span(v)) catch default_value;
}

/// Apply `FLUX_AUDIO_*` tuning: worker sleep bounds, parallel threshold, and
/// CLAP thread_pool fan-out on `plugin_host` (pre-DVUI `bench.configureRuntimeTuning`).
pub fn configureRuntimeTuning() void {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const is_arm = switch (builtin.cpu.arch) {
        .arm, .armeb, .thumb, .thumbeb, .aarch64, .aarch64_be => true,
        else => false,
    };
    const arm_default_scale: f32 = if (is_arm) 0.75 else 1.0;
    const fanout_scale = envF32("FLUX_AUDIO_ARM_FANOUT_SCALE", arm_default_scale);
    const base_fanout: usize = if (cpu_count > 1) @min(cpu_count - 1, 16) else 0;
    const clamped_scale = std.math.clamp(fanout_scale, 0.0, 1.0);
    const scaled_fanout = @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(base_fanout)) * clamped_scale)));
    const jobs_fanout: u32 = @intCast(@min(base_fanout, scaled_fanout));

    if (plugin_host_mod.ready()) {
        plugin_host_mod.g.jobs_fanout = jobs_fanout;
    }

    const min_sleep_ns = envU64("FLUX_AUDIO_WORKER_MIN_SLEEP_NS", 10_000);
    const max_sleep_ns = envU64("FLUX_AUDIO_WORKER_MAX_SLEEP_NS", 2_000_000);
    setWorkerSleepBounds(min_sleep_ns, max_sleep_ns);

    const parallel_threshold = envU32("FLUX_AUDIO_PARALLEL_THRESHOLD", 3);
    audio_graph.setParallelThreshold(parallel_threshold);

    std.log.info("audio tuning: fanout={d} sleep=[{d},{d}]ns parallel_threshold={d}", .{
        jobs_fanout,
        min_sleep_ns,
        max_sleep_ns,
        parallel_threshold,
    });
}

pub const AudioRuntime = struct {
    allocator: std.mem.Allocator,
    engine: ?AudioEngine = null,
    device: ?*zaudio.Device = null,
    device_config: zaudio.Device.Config = undefined,
    buffer_frames: u32 = chrome.default_buffer_frames,

    /// Work-stealing queue for parallel synth process (null if FLUX_SINGLE_THREAD=1).
    jobs_storage: ?audio_graph.JobQueue = null,

    /// Bypass flags fed to the engine (host instrument/fx enable).
    instrument_enabled: [max_tracks]bool = @splat(true),
    fx_enabled: [max_tracks][max_fx_slots]bool = @splat(@splat(true)),
    /// Fallback when plugin_host is not ready (tests).
    live_key_states: [max_tracks][128]bool = @splat(@splat(false)),
    live_key_velocities: [max_tracks][128]f32 = @splat(@splat(0)),
    /// Host param chrome + (future) controller mapping → RT param events.
    controller_writes: [engine_ui.max_controller_param_writes]engine_ui.ControllerParamWrite = undefined,
    controller_write_count: usize = 0,

    /// True after successful zaudio.init (even if device open failed).
    zaudio_ready: bool = false,
    /// Engine constructed.
    engine_ready: bool = false,
    /// Device is open and started.
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator, buffer_frames: u32) AudioRuntime {
        return .{
            .allocator = allocator,
            .buffer_frames = if (buffer_frames == 0) chrome.default_buffer_frames else buffer_frames,
        };
    }

    /// Queue a main-thread parameter write for the next engine publish.
    /// Dedupes by track/fx/param_id (last value wins).
    pub fn pushControllerParamWrite(self: *AudioRuntime, write: engine_ui.ControllerParamWrite) void {
        var i: usize = 0;
        while (i < self.controller_write_count) : (i += 1) {
            const existing = &self.controller_writes[i];
            if (existing.track_index == write.track_index and
                existing.target_fx_index == write.target_fx_index and
                existing.param_id == write.param_id)
            {
                existing.value = write.value;
                return;
            }
        }
        if (self.controller_write_count >= self.controller_writes.len) return;
        self.controller_writes[self.controller_write_count] = write;
        self.controller_write_count += 1;
    }

    pub fn deinit(self: *AudioRuntime) void {
        self.stopDevice();
        self.stopJobs();
        if (self.engine) |*eng| {
            eng.jobs = null;
            eng.deinit();
            self.engine = null;
        }
        self.engine_ready = false;
        if (self.zaudio_ready) {
            zaudio.deinit();
            self.zaudio_ready = false;
        }
        self.* = undefined;
    }

    fn stopJobs(self: *AudioRuntime) void {
        if (self.jobs_storage) |*jobs| {
            if (self.engine) |*eng| eng.jobs = null;
            if (plugin_host_mod.ready()) plugin_host_mod.g.jobs = null;
            jobs.stop();
            jobs.join();
            jobs.deinit();
            self.jobs_storage = null;
        }
    }

    fn wireJobsToPluginHost(self: *AudioRuntime) void {
        if (!plugin_host_mod.ready()) return;
        if (self.jobs_storage) |*jobs| {
            plugin_host_mod.g.jobs = jobs;
        } else {
            plugin_host_mod.g.jobs = null;
        }
        if (self.engine) |*eng| {
            plugin_host_mod.g.shared_state = &eng.shared;
        } else {
            plugin_host_mod.g.shared_state = null;
        }
    }

    fn startJobs(self: *AudioRuntime) void {
        if (self.jobs_storage != null) return;
        if (envBool("FLUX_SINGLE_THREAD")) {
            std.log.info("audio jobs: single-threaded (FLUX_SINGLE_THREAD=1)", .{});
            self.wireJobsToPluginHost();
            return;
        }
        const jobs = audio_graph.JobQueue.init(self.allocator, clock_io) catch |err| {
            std.log.warn("audio JobQueue init failed: {} (serial synth process)", .{err});
            self.wireJobsToPluginHost();
            return;
        };
        self.jobs_storage = jobs;
        self.jobs_storage.?.start() catch |err| {
            std.log.warn("audio JobQueue start failed: {} (serial synth process)", .{err});
            self.jobs_storage.?.deinit();
            self.jobs_storage = null;
            self.wireJobsToPluginHost();
            return;
        };
        if (self.engine) |*eng| eng.jobs = &self.jobs_storage.?;
        self.wireJobsToPluginHost();
        std.log.info("audio jobs: work-stealing queue started", .{});
    }

    /// Open playback device + construct engine (best-effort). Host chrome still
    /// works if audio fails.
    pub fn start(self: *AudioRuntime) void {
        if (self.running) return;

        if (!self.zaudio_ready) {
            zaudio.init(self.allocator);
            self.zaudio_ready = true;
        }

        if (!self.engine_ready) {
            self.engine = AudioEngine.init(
                self.allocator,
                @floatFromInt(sample_rate),
                self.buffer_frames,
            ) catch |err| {
                std.log.warn("audio engine init failed: {} (UI continues without engine)", .{err});
                return;
            };
            self.engine_ready = true;
            self.startJobs();
            if (self.jobs_storage) |*jobs| {
                if (self.engine) |*eng| eng.jobs = jobs;
            }
        }

        self.openDevice() catch |err| {
            std.log.warn("audio device unavailable: {} (UI continues without output)", .{err});
            return;
        };
    }

    pub fn stopDevice(self: *AudioRuntime) void {
        if (self.device) |dev| {
            if (dev.isStarted()) {
                dev.stop() catch |err| {
                    std.log.warn("failed to stop audio device: {}", .{err});
                };
            }
            dev.destroy();
            self.device = null;
        }
        self.running = false;
    }

    fn openDevice(self: *AudioRuntime) !void {
        self.stopDevice();
        const eng = if (self.engine) |*e| e else return error.EngineNotReady;

        var config = zaudio.Device.Config.init(.playback);
        config.playback.format = .float32;
        config.playback.channels = channels;
        config.sample_rate = sample_rate;
        config.period_size_in_frames = self.buffer_frames;
        config.performance_profile = .low_latency;
        config.periods = 2;
        config.data_callback = dataCallback;
        config.user_data = eng;

        const device = try zaudio.Device.create(null, config);
        errdefer device.destroy();
        try device.start();

        self.device_config = config;
        self.device = device;
        self.running = true;
        std.log.info("audio engine device started (sr={d} buf={d})", .{ sample_rate, self.buffer_frames });
    }

    /// Publish a UI-neutral document plus runtime controls into the RT snapshot.
    pub fn publishDocument(
        self: *AudioRuntime,
        document: document_model.Model,
        instrument_enabled: *const [chrome.max_tracks]bool,
        fx_enabled: *const [chrome.max_tracks][chrome.max_fx_slots]bool,
        state: *const chrome.State,
    ) void {
        if (self.engine == null) return;
        const eng = &self.engine.?;

        // Sync bypass flags (chrome max_fx may exceed engine depth).
        for (0..max_tracks) |t| {
            self.instrument_enabled[t] = if (t < chrome.max_tracks) instrument_enabled[t] else true;
            for (0..max_fx_slots) |fx| {
                if (t < chrome.max_tracks and fx < chrome.max_fx_slots) {
                    self.fx_enabled[t][fx] = fx_enabled[t][fx];
                } else {
                    self.fx_enabled[t][fx] = true;
                }
            }
        }

        const live_keys: *const [max_tracks][128]bool = if (plugin_host_mod.ready())
            &plugin_host_mod.g.live_key_states
        else
            &self.live_key_states;
        const live_vels: *const [max_tracks][128]f32 = if (plugin_host_mod.ready())
            &plugin_host_mod.g.live_key_velocities
        else
            &self.live_key_velocities;

        var view = EngineUiView{
            .document_revision = document.revision,
            .playing = state.playing,
            .metronome_enabled = state.metronome_enabled,
            .bpm = state.bpm,
            .time_signature_numerator = state.time_signature_numerator,
            .time_signature_denominator = state.time_signature_denominator,
            .playhead_beat = state.playhead_beat,
            .session = document.session,
            .sample_store = document.sample_store,
            .track_instrument_enabled = &self.instrument_enabled,
            .track_fx_enabled = &self.fx_enabled,
            .live_key_states = live_keys,
            .live_key_velocities = live_vels,
            .controller_param_writes = self.controller_writes[0..self.controller_write_count],
        };
        eng.updateFromUi(&view);
        self.controller_write_count = 0;
    }

    /// Pull RT meters into chrome (DSP % + track peaks with decay).
    pub fn pullToChrome(self: *AudioRuntime, state: *chrome.State) void {
        if (self.engine == null) return;
        const eng = &self.engine.?;

        const pct = eng.dsp_load_pct.load(.acquire);
        state.dsp_load_pct = @intCast(@min(pct, 100));

        const tc = @min(state.track_count, max_tracks);
        for (0..tc) |track| {
            const peak = eng.shared.getTrackPeak(track);
            state.track_levels[track][0] = @max(peak[0], state.track_levels[track][0] * 0.72);
            state.track_levels[track][1] = @max(peak[1], state.track_levels[track][1] * 0.72);
        }
        for (tc..chrome.max_tracks) |track| {
            state.track_levels[track] = .{ 0, 0 };
        }
    }

    /// Recreate the device if chrome buffer size changed.
    /// Pre-DVUI parity: stop device → wait idle → deactivate/activate plugins
    /// at the new max frames → resize engine → reopen device.
    pub fn applyBufferFramesIfNeeded(self: *AudioRuntime, state: *chrome.State) void {
        if (state.buffer_frames == 0) return;
        if (state.buffer_frames == self.buffer_frames) return;
        if (!self.engine_ready or self.engine == null) {
            self.buffer_frames = state.buffer_frames;
            return;
        }

        const requested = state.buffer_frames;
        const eng = &self.engine.?;

        self.stopDevice();
        eng.shared.waitForIdle(clock_io);

        if (plugin_host_mod.ready()) {
            plugin_host_mod.g.reconfigureMaxFrames(&eng.shared, requested);
        }

        eng.setMaxFrames(requested) catch |err| {
            std.log.warn("failed to set engine max frames {d}: {}", .{ requested, err });
            state.buffer_frames = self.buffer_frames;
            // Roll plugins back to the previous size if possible.
            if (plugin_host_mod.ready()) {
                plugin_host_mod.g.reconfigureMaxFrames(&eng.shared, self.buffer_frames);
            }
            self.openDevice() catch {};
            return;
        };
        self.buffer_frames = requested;
        self.openDevice() catch |err| {
            std.log.warn("failed to apply buffer size {d}: {}", .{ requested, err });
            if (self.device == null) {
                state.buffer_frames = self.buffer_frames;
            }
        };
    }

    /// Full per-frame tick: buffer size, MIDI, plugin sync, publish, meters.
    pub fn tick(self: *AudioRuntime, host: *host_mod.Host, state: *chrome.State) void {
        self.applyBufferFramesIfNeeded(state);

        // Load/unload CLAPs to match device-chain choices; feed engine plugin ptrs.
        if (plugin_host_mod.ready()) {
            // Armed track owns live MIDI (zgui keyboard_midi parity).
            const midi_track = state.armed_track orelse state.selected_track;
            plugin_host_mod.g.tickLiveMidi(midi_track, state.piano_preview_pitch);
            const eng: ?*AudioEngine = if (self.engine != null) &self.engine.? else null;
            plugin_host_mod.g.tick(eng, self.buffer_frames);
            plugin_host_mod.g.projectToDocumentHost(host);
        }

        self.publishDocument(host.document(), &host.instrument_enabled, &host.fx_enabled, state);
        self.pullToChrome(state);
    }
};

fn dataCallback(
    device: *zaudio.Device,
    output: ?*anyopaque,
    _: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    thread_context.is_audio_thread = true;
    defer thread_context.is_audio_thread = false;

    const user_data = zaudio.Device.getUserData(device) orelse return;
    const engine: *AudioEngine = @ptrCast(@alignCast(user_data));

    const measure = engine.dsp_meter_count == 0;
    engine.dsp_meter_count = (engine.dsp_meter_count + 1) % dsp_meter_interval;
    const start = if (measure) std.Io.Clock.awake.now(clock_io) else undefined;

    engine.render(device, output, frame_count);

    if (!measure) return;

    const end = std.Io.Clock.awake.now(clock_io);
    const elapsed_us = time_utils.nsSince(start, end) / 1000;
    const budget_us = @as(u64, frame_count) * 1_000_000 / sample_rate;
    if (budget_us == 0) return;
    const usage_pct = elapsed_us * 100 / budget_us;
    engine.dsp_load_pct.store(@intCast(@min(usage_pct, 999)), .release);

    // Keep worker idle sleep short under load so parallel synth jobs wake in time
    // for the next quantum (critical at 64/128 frames).
    if (engine.jobs) |jobs| {
        const current_sleep = jobs.dynamic_sleep_ns.load(.monotonic);
        const is_playing = engine.shared.snapshot().playing;
        const configured_min = worker_min_sleep_ns.load(.acquire);
        const configured_max = worker_max_sleep_ns.load(.acquire);
        const budget_ns = budget_us * 1000;
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
        jobs.setSleepNs(@max(min_sleep, @min(next, max_sleep)));
    }
}

// ── Process-wide runtime for the DVUI app binary ─────────────────────────────

pub var g: AudioRuntime = undefined;
pub var g_ready: bool = false;

pub fn initGlobal(allocator: std.mem.Allocator, buffer_frames: u32) void {
    g = AudioRuntime.init(allocator, buffer_frames);
    g.start();
    g_ready = true;
    // Plugin host must already be up so fan-out / shared_state wire correctly.
    configureRuntimeTuning();
    g.wireJobsToPluginHost();
}

pub fn deinitGlobal() void {
    if (!g_ready) return;
    if (plugin_host_mod.ready()) {
        plugin_host_mod.g.jobs = null;
        plugin_host_mod.g.shared_state = null;
    }
    g.deinit();
    g_ready = false;
}

pub fn ready() bool {
    return g_ready;
}

// ── Unit tests (no device) ───────────────────────────────────────────────────

test "engine ui view builds from host fields" {
    var store = document_model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    var h = host_mod.Host.init(&store);
    defer h.deinit();
    h.wireInternalRefs();

    var rt = AudioRuntime.init(std.testing.allocator, 128);
    defer rt.deinit(); // no zaudio started

    var s: chrome.State = .{};
    s.playing = true;
    s.metronome_enabled = true;
    s.bpm = 140;

    // publish without engine should no-op
    rt.publishDocument(h.document(), &h.instrument_enabled, &h.fx_enabled, &s);
    try std.testing.expect(!rt.engine_ready);
}

test "audio runtime init defaults buffer frames" {
    var rt = AudioRuntime.init(std.testing.allocator, 0);
    defer rt.deinit();
    try std.testing.expectEqual(chrome.default_buffer_frames, rt.buffer_frames);
}
