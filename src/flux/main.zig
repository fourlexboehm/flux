const builtin = @import("builtin");
const std = @import("std");

const clap = @import("clap-bindings");
const zaudio = @import("zaudio");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const objc = if (builtin.os.tag == .macos) @import("objc") else struct {};

const options = @import("options");
const ui = @import("ui.zig");
const audio_engine = @import("audio_engine.zig");
const audio_graph = @import("audio_graph.zig");
const zsynth = @import("zsynth-core");
const zminimoog = @import("zminimoog-core");
const plugins = @import("plugins.zig");
const dawproject = @import("dawproject.zig");
const file_dialog = @import("file_dialog.zig");
const midi_input = @import("midi_input.zig");

pub const std_options: std.Options = .{
    .enable_segfault_handler = options.enable_segfault_handler,
};

const SampleRate = 44_100;
const Channels = 2;

const Theme = ui.Colors.Theme;

fn containsInsensitive(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn resolveTheme() Theme {
    if (std.c.getenv("FLUX_THEME")) |env| {
        const value = std.mem.span(env);
        if (std.ascii.eqlIgnoreCase(value, "light")) return .light;
        if (std.ascii.eqlIgnoreCase(value, "dark")) return .dark;
        if (std.ascii.eqlIgnoreCase(value, "system")) return detectSystemTheme();
    }
    return detectSystemTheme();
}

fn detectSystemTheme() Theme {
    return switch (builtin.os.tag) {
        .macos => detectMacTheme(),
        .linux => detectLinuxTheme(),
        else => .light,
    };
}

fn detectMacTheme() Theme {
    if (builtin.os.tag == .macos) {
        const app = objc.app_kit.Application.sharedApplication();
        const appearance = objc.objc.msgSend(app, "effectiveAppearance", ?*objc.app_kit.Appearance, .{});
        if (appearance) |ap| {
            const name = objc.objc.msgSend(ap, "name", *objc.foundation.String, .{});
            const dark_name = objc.foundation.String.stringWithUTF8String("NSAppearanceNameDarkAqua");
            if (name.isEqualToString(dark_name)) {
                return .dark;
            }
        }
    }
    return .light;
}

fn detectLinuxTheme() Theme {
    if (builtin.os.tag == .linux) {
        if (std.c.getenv("GTK_THEME")) |env| {
            if (containsInsensitive(std.mem.span(env), "dark")) return .dark;
        }
    }
    return .light;
}

/// Thread-local flag set when we're in an audio processing context
pub threadlocal var is_audio_thread: bool = false;
/// Thread-local flag set when running inside libz_jobs worker/help loop.
/// Used as a reentrancy guard for CLAP thread-pool requests.
pub threadlocal var in_jobs_worker: bool = false;
/// Nesting depth for CLAP `thread_pool` requests on this thread.
pub threadlocal var clap_threadpool_depth: u32 = 0;

const Host = struct {
    clap_host: clap.Host,
    jobs: ?*audio_graph.JobQueue = null,
    jobs_fanout: u32 = 0,
    shared_state: ?*audio_engine.SharedState = null,
    main_thread_id: std.Thread.Id = undefined,
    callback_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Undo state
    ui_state: ?*ui.State = null,
    allocator: ?std.mem.Allocator = null,
    track_plugins_ptr: ?*[ui.track_count]TrackPlugin = null,
    track_fx_ptr: ?*[ui.track_count][ui.max_fx_slots]TrackPlugin = null,
    catalog_ptr: ?*const plugins.PluginCatalog = null,
    undo_change_in_progress: bool = false,
    undo_track_index: ?usize = null, // Track that started the change
    undo_pre_state: ?[]u8 = null, // State captured at begin_change

    const thread_pool_ext = clap.ext.thread_pool.Host{
        .requestExec = _requestExec,
    };

    const thread_check_ext = clap.ext.thread_check.Host{
        .isMainThread = _isMainThread,
        .isAudioThread = _isAudioThread,
    };

    const undo_ext = clap.ext.undo.Host{
        .begin_change = _undoBeginChange,
        .cancel_change = _undoCancelChange,
        .change_made = _undoChangeMade,
        .request_undo = _undoRequestUndo,
        .request_redo = _undoRequestRedo,
        .set_wants_context_updates = _undoSetWantsContextUpdates,
    };

    const params_ext = clap.ext.params.Host{
        .rescan = _paramsRescan,
        .clear = _paramsClear,
        .requestFlush = _paramsRequestFlush,
    };

    pub fn init() Host {
        return .{
            .clap_host = .{
                .clap_version = clap.version,
                .host_data = undefined,
                .name = "flux",
                .vendor = "gearmulator",
                .url = null,
                .version = "0.1",
                .getExtension = _getExtension,
                .requestRestart = _requestRestart,
                .requestProcess = _requestProcess,
                .requestCallback = _requestCallback,
            },
            .main_thread_id = std.Thread.getCurrentId(),
        };
    }

    fn _getExtension(_: *const clap.Host, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.thread_pool.id)) {
            return &thread_pool_ext;
        }
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.thread_check.id)) {
            return &thread_check_ext;
        }
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.undo.id)) {
            return &undo_ext;
        }
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.params.id)) {
            return &params_ext;
        }
        return null;
    }

    fn _isMainThread(host: *const clap.Host) callconv(.c) bool {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        return std.Thread.getCurrentId() == self.main_thread_id;
    }

    fn _isAudioThread(_: *const clap.Host) callconv(.c) bool {
        return is_audio_thread;
    }

    fn _requestExec(host: *const clap.Host, task_count: u32) callconv(.c) bool {
        if (task_count == 0) return true;

        const self: *Host = @ptrCast(@alignCast(host.host_data));

        const plugin = audio_graph.current_processing_plugin orelse return false;

        const ext_raw = plugin.getExtension(plugin, clap.ext.thread_pool.id) orelse return false;
        const ext: *const clap.ext.thread_pool.Plugin = @ptrCast(@alignCast(ext_raw));

        // Allow nesting, but cap recursion to avoid pathological behavior.
        // If we hit the cap, fall back to synchronous execution on this thread.
        const max_depth: u32 = 4;
        if (clap_threadpool_depth >= max_depth) {
            for (0..task_count) |i| ext.exec(plugin, @intCast(i));
            return true;
        }

        if (self.jobs) |job_queue| {
            clap_threadpool_depth += 1;
            defer clap_threadpool_depth -= 1;

            const base_fanout: u32 = if (self.jobs_fanout > 0) self.jobs_fanout else 1;
            // When called from within a worker/help loop, keep some headroom to reduce oversubscription.
            const desired_fanout: u32 = if (in_jobs_worker) @max(1, base_fanout / 2) else base_fanout;
            const job_count: u32 = @min(task_count, desired_fanout);

            const Shared = struct {
                plugin: *const clap.Plugin,
                exec_fn: *const fn (*const clap.Plugin, u32) callconv(.c) void,
                task_count: u32,
                next_task: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
            };

            var shared = Shared{
                .plugin = plugin,
                .exec_fn = ext.exec,
                .task_count = task_count,
                .next_task = std.atomic.Value(u32).init(0),
            };

            const RootJob = struct {
                pub fn exec(_: *@This()) void {}
            };
            const root = job_queue.allocate(RootJob{});

            const WorkerJob = struct {
                shared: *Shared,
                pub fn exec(job: *@This()) void {
                    is_audio_thread = true;
                    in_jobs_worker = true;
                    defer in_jobs_worker = false;

                    while (true) {
                        const idx = job.shared.next_task.fetchAdd(1, .acq_rel);
                        if (idx >= job.shared.task_count) break;
                        job.shared.exec_fn(job.shared.plugin, idx);
                    }
                }
            };

            for (0..job_count) |_| {
                const worker = job_queue.allocate(WorkerJob{ .shared = &shared });
                job_queue.finishWith(worker, root);
                job_queue.schedule(worker);
            }

            job_queue.schedule(root);
            job_queue.wait(root);
            return true;
        }
        return false;
    }

    fn _requestRestart(_: *const clap.Host) callconv(.c) void {}
    fn _requestProcess(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        if (self.shared_state) |shared| {
            shared.process_requested.store(true, .release);
        }
    }

    fn _requestCallback(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        self.callback_requested.store(true, .release);
    }

    fn pumpMainThreadCallbacks(self: *Host) void {
        if (!self.callback_requested.swap(false, .acq_rel)) return;
        const shared = self.shared_state orelse return;
        const snapshot = shared.snapshot();
        for (snapshot.track_plugins) |plugin| {
            if (plugin) |p| {
                p.onMainThread(p);
            }
        }
        for (snapshot.track_fx_plugins) |track_fx| {
            for (track_fx) |plugin| {
                if (plugin) |p| {
                    p.onMainThread(p);
                }
            }
        }
    }

    // --- Undo extension callbacks ---

    /// Find which track a plugin belongs to
    fn findTrackForPlugin(self: *Host, caller_plugin: *const clap.Plugin) ?usize {
        const track_plugins = self.track_plugins_ptr orelse return null;
        for (track_plugins, 0..) |track, idx| {
            if (track.handle) |handle| {
                if (handle.plugin == caller_plugin) {
                    return idx;
                }
            }
        }
        if (self.track_fx_ptr) |track_fx| {
            for (track_fx, 0..) |track_slots, idx| {
                for (track_slots) |slot| {
                    if (slot.handle) |handle| {
                        if (handle.plugin == caller_plugin) {
                            return idx;
                        }
                    }
                }
            }
        }
        return null;
    }

    /// Get the CLAP plugin for a given track (external or builtin)
    fn getPluginForTrack(self: *Host, state: *ui.State, track_idx: usize) ?*const clap.Plugin {
        _ = state;
        if (track_idx >= ui.track_count) return null;

        // All plugins (builtin and external) are now in TrackPlugin
        if (self.track_plugins_ptr) |track_plugins| {
            return track_plugins[track_idx].getPlugin();
        }
        return null;
    }

    fn _undoBeginChange(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        if (self.undo_change_in_progress) {
            std.log.warn("Plugin called begin_change while change already in progress", .{});
            return;
        }

        // Determine which track is making this call (use selected track with open GUI)
        const state = self.ui_state orelse return;
        const track_idx = state.selectedTrack();
        const allocator = self.allocator orelse return;

        // Get the plugin for this track (external or builtin)
        const plugin = self.getPluginForTrack(state, track_idx) orelse return;

        // Capture the current state before the change
        if (capturePluginStateForUndo(allocator, plugin)) |pre_state| {
            self.undo_pre_state = pre_state;
            self.undo_track_index = track_idx;
            self.undo_change_in_progress = true;
        }
    }

    fn _undoCancelChange(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        const allocator = self.allocator orelse return;

        // Discard captured state
        if (self.undo_pre_state) |pre_state| {
            allocator.free(pre_state);
        }
        self.undo_pre_state = null;
        self.undo_track_index = null;
        self.undo_change_in_progress = false;
    }

    fn _undoChangeMade(
        host: *const clap.Host,
        name: [*:0]const u8,
        delta: ?*const anyopaque,
        delta_size: usize,
        delta_can_undo: bool,
    ) callconv(.c) void {
        _ = delta;
        _ = delta_size;
        _ = delta_can_undo;

        const self: *Host = @ptrCast(@alignCast(host.host_data));
        const state = self.ui_state orelse return;
        const allocator = self.allocator orelse return;

        // Determine track index - use tracked one from begin_change or selected track
        const track_idx = self.undo_track_index orelse state.selectedTrack();

        // Get the pre-change state (either from begin_change or capture now)
        const old_state = if (self.undo_pre_state) |pre| pre else blk: {
            // No begin_change was called - this is an instant change
            // We need to capture state, but we're already past the change...
            // For instant changes without begin_change, we can't provide undo
            // because we don't have the old state. Log and skip.
            std.log.debug("Plugin change_made without begin_change: {s}", .{name});
            break :blk null;
        };

        if (old_state == null) {
            // Can't create undo entry without old state
            self.undo_change_in_progress = false;
            self.undo_track_index = null;
            return;
        }

        // Get the plugin for this track (external or builtin)
        const plugin = self.getPluginForTrack(state, track_idx) orelse {
            allocator.free(old_state.?);
            self.undo_change_in_progress = false;
            self.undo_track_index = null;
            return;
        };

        // Capture the new state after the change
        if (capturePluginStateForUndo(allocator, plugin)) |new_state| {
            // Push to undo history
            state.undo_history.push(.{
                .plugin_state = .{
                    .track_index = track_idx,
                    .old_state = old_state.?,
                    .new_state = new_state,
                },
            });
            std.log.debug("Plugin undo entry created: {s}", .{name});
        } else {
            // Failed to capture new state, free old state
            allocator.free(old_state.?);
        }

        // Reset change tracking
        self.undo_pre_state = null;
        self.undo_track_index = null;
        self.undo_change_in_progress = false;
    }

    fn _undoRequestUndo(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        const state = self.ui_state orelse return;
        _ = state.performUndo();
    }

    fn _undoRequestRedo(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        const state = self.ui_state orelse return;
        _ = state.performRedo();
    }

    fn _undoSetWantsContextUpdates(_: *const clap.Host, _: bool) callconv(.c) void {
        // TODO: Implement context updates if plugins request them
        // This would involve calling plugin's set_can_undo/set_can_redo
        // when the undo state changes
    }

    // --- Params extension callbacks ---

    fn _paramsRescan(_: *const clap.Host, _: clap.ext.params.Host.RescanFlags) callconv(.c) void {
        // Plugin is notifying us that parameter values/info changed.
        // For now this is a no-op; the host UI doesn't currently display
        // plugin parameter values. In the future this could trigger UI refresh.
    }

    fn _paramsClear(_: *const clap.Host, _: clap.Id, _: clap.ext.params.Host.ClearFlags) callconv(.c) void {
        // Plugin is requesting we clear automation/modulation for a parameter.
        // Not implemented - flux doesn't have parameter automation yet.
    }

    fn _paramsRequestFlush(_: *const clap.Host) callconv(.c) void {
        // Plugin is requesting a parameter flush outside of process().
        // Not implemented - we always process parameters during process().
    }
};

const PluginHandle = struct {
    lib: std.DynLib,
    entry: *const clap.Entry,
    factory: *const clap.PluginFactory,
    plugin: *const clap.Plugin,
    plugin_path_z: [:0]u8,
    activated: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        host: *const clap.Host,
        plugin_path: []const u8,
        plugin_id: ?[]const u8,
        max_frames: u32,
    ) !PluginHandle {
        const plugin_path_z = try allocator.dupeZ(u8, plugin_path);
        errdefer allocator.free(plugin_path_z);

        var lib = try std.DynLib.open(plugin_path);
        errdefer lib.close();

        const entry = lib.lookup(*const clap.Entry, "clap_entry") orelse return error.MissingClapEntry;
        if (!entry.init(plugin_path_z)) return error.EntryInitFailed;
        errdefer entry.deinit();

        const factory_raw = entry.getFactory(clap.PluginFactory.id) orelse return error.MissingPluginFactory;
        const factory: *const clap.PluginFactory = @ptrCast(@alignCast(factory_raw));
        const plugin = blk: {
            if (plugin_id) |id| {
                const id_z = try allocator.dupeZ(u8, id);
                defer allocator.free(id_z);
                break :blk factory.createPlugin(factory, host, id_z) orelse return error.PluginCreateFailed;
            }

            const plugin_count = factory.getPluginCount(factory);
            if (plugin_count == 0) return error.NoPluginsFound;
            const desc = factory.getPluginDescriptor(factory, 0) orelse return error.MissingPluginDescriptor;
            break :blk factory.createPlugin(factory, host, desc.id) orelse return error.PluginCreateFailed;
        };

        if (!plugin.init(plugin)) return error.PluginInitFailed;

        if (!plugin.activate(plugin, SampleRate, 1, max_frames)) return error.PluginActivateFailed;

        return .{
            .lib = lib,
            .entry = entry,
            .factory = factory,
            .plugin = plugin,
            .plugin_path_z = plugin_path_z,
            .activated = true,
        };
    }

    pub fn deinit(self: *PluginHandle, allocator: std.mem.Allocator) void {
        // Note: stopProcessing is called by unloadPlugin before this, using SharedState tracking
        if (self.activated) {
            self.plugin.deactivate(self.plugin);
        }
        self.plugin.destroy(self.plugin);
        self.entry.deinit();
        self.lib.close();
        allocator.free(self.plugin_path_z);
    }
};

/// Handle for a builtin (statically linked) plugin
const BuiltinHandle = struct {
    plugin: *clap.Plugin,

    pub fn deinit(self: *BuiltinHandle) void {
        self.plugin.deactivate(self.plugin);
        // Note: destroy() calls the CLAP _destroy callback which already calls plugin.deinit()
        self.plugin.destroy(self.plugin);
    }
};

const TrackPlugin = struct {
    /// External CLAP plugin loaded from disk
    handle: ?PluginHandle = null,
    /// Builtin plugin (statically linked)
    builtin: ?BuiltinHandle = null,
    gui_ext: ?*const clap.ext.gui.Plugin = null,
    gui_window: ?*anyopaque = null,
    gui_view: ?*anyopaque = null,
    gui_open: bool = false,
    choice_index: i32 = -1,

    /// Get the CLAP plugin pointer, whether external or builtin
    pub fn getPlugin(self: *const TrackPlugin) ?*const clap.Plugin {
        if (self.handle) |h| return h.plugin;
        if (self.builtin) |b| return b.plugin;
        return null;
    }
};

const AppWindow = if (builtin.os.tag == .macos) struct {
    app: *objc.app_kit.Application,
    window: *objc.app_kit.Window,
    view: *objc.app_kit.View,
    device: *objc.metal.Device,
    layer: *objc.quartz_core.MetalLayer,
    command_queue: *objc.metal.CommandQueue,
    scale_factor: f32,

    pub fn init(title: [:0]const u8, width: f64, height: f64) !AppWindow {
        const app = objc.app_kit.Application.sharedApplication();
        _ = app.setActivationPolicy(objc.app_kit.ApplicationActivationPolicyRegular);
        app.activateIgnoringOtherApps(true);

        const rect = objc.app_kit.Rect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = width, .height = height },
        };
        const style = objc.app_kit.WindowStyleMaskTitled |
            objc.app_kit.WindowStyleMaskClosable |
            objc.app_kit.WindowStyleMaskResizable |
            objc.app_kit.WindowStyleMaskMiniaturizable;
        const window = objc.app_kit.Window.alloc().initWithContentRect_styleMask_backing_defer_screen(
            rect,
            style,
            objc.app_kit.BackingStoreBuffered,
            false,
            null,
        );
        window.setReleasedWhenClosed(false);
        const title_str = objc.foundation.String.stringWithUTF8String(title);
        window.setTitle(title_str);
        window.center();

        const view = objc.app_kit.View.alloc().initWithFrame(rect);
        view.setWantsLayer(true);
        window.setContentView(view);
        window.makeKeyAndOrderFront(null);

        const device = objc.metal.createSystemDefaultDevice().?;
        const layer = objc.quartz_core.MetalLayer.allocInit();
        layer.setDevice(device);
        layer.setPixelFormat(objc.metal.PixelFormatBGRA8Unorm);
        layer.setFramebufferOnly(true);
        view.setLayer(layer.as(objc.quartz_core.Layer));

        const command_queue = device.newCommandQueue().?;
        const scale_factor: f32 = @floatCast(window.backingScaleFactor());

        return .{
            .app = app,
            .window = window,
            .view = view,
            .device = device,
            .layer = layer,
            .command_queue = command_queue,
            .scale_factor = scale_factor,
        };
    }

    pub fn deinit(self: *AppWindow) void {
        self.command_queue.release();
        self.layer.release();
        self.device.release();
        self.view.release();
        self.window.release();
    }
} else struct {};

var perf_total_us: u64 = 0;
var perf_max_us: u64 = 0;
var perf_count: u64 = 0;
var perf_last_print: ?std.time.Instant = null;

fn dataCallback(
    device: *zaudio.Device,
    output: ?*anyopaque,
    _: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    const start = std.time.Instant.now() catch null;
    is_audio_thread = true;
    defer is_audio_thread = false;

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

        const budget_us = @as(u64, frame_count) * 1_000_000 / SampleRate;
        const budget_ns = budget_us * 1000;

        // Adaptive sleep - update every callback for responsiveness
        if (engine.jobs) |jobs| {
            const usage_pct = elapsed_us * 100 / budget_us;
            const usage_pct_clamped: u32 = @intCast(@min(usage_pct, 999));
            engine.dsp_load_pct.store(usage_pct_clamped, .release);
            const current_sleep = jobs.dynamic_sleep_ns.load(.monotonic);

            // Sleep targets as fraction of buffer period
            const max_sleep = budget_ns / 2; // 50% of buffer - idle
            const mid_sleep = budget_ns / 10; // 10% of buffer - moderate
            const min_sleep = budget_ns / 100; // 1% of buffer - high load

            const sleep_ns: u64 = if (usage_pct >= 40)
                min_sleep
            else if (usage_pct >= 20)
                mid_sleep
            else if (usage_pct < 5 and current_sleep < max_sleep)
                @min(current_sleep * 2, max_sleep) // ramp up slowly
            else
                current_sleep; // stay in current state

            jobs.setSleepNs(sleep_ns);
        }
    }
}

fn applyBufferFramesChange(
    io: std.Io,
    device: **zaudio.Device,
    device_config: *zaudio.Device.Config,
    engine: *audio_engine.AudioEngine,
    shared: *audio_engine.SharedState,
    track_plugins: *[ui.track_count]TrackPlugin,
    track_fx: *[ui.track_count][ui.max_fx_slots]TrackPlugin,
    new_frames: u32,
) !void {
    if (new_frames == engine.max_frames) return;

    if (device.*.isStarted()) {
        device.*.stop() catch |err| {
            std.log.warn("Failed to stop audio device: {}", .{err});
        };
    }
    shared.waitForIdle(io);

    const was_audio = is_audio_thread;
    is_audio_thread = true;
    defer is_audio_thread = was_audio;

    const plugins_for_tracks = collectPlugins(track_plugins, track_fx);
    for (0..ui.track_count) |t| {
        if (shared.isPluginStarted(t)) {
            if (plugins_for_tracks.instruments[t]) |plugin| {
                plugin.stopProcessing(plugin);
            }
            shared.clearPluginStarted(t);
        }
        for (0..ui.max_fx_slots) |fx_index| {
            if (shared.isFxPluginStarted(t, fx_index)) {
                if (plugins_for_tracks.fx[t][fx_index]) |plugin| {
                    plugin.stopProcessing(plugin);
                }
                shared.clearFxPluginStarted(t, fx_index);
            }
        }
    }

    for (0..ui.track_count) |t| {
        if (plugins_for_tracks.instruments[t]) |plugin| {
            plugin.deactivate(plugin);
            if (!plugin.activate(plugin, SampleRate, 1, new_frames)) {
                std.log.warn("Failed to activate plugin for track {d}", .{t});
            } else {
                shared.requestStartProcessing(t);
            }
        }
        for (0..ui.max_fx_slots) |fx_index| {
            if (plugins_for_tracks.fx[t][fx_index]) |plugin| {
                plugin.deactivate(plugin);
                if (!plugin.activate(plugin, SampleRate, 1, new_frames)) {
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var host = Host.init();
    host.clap_host.host_data = &host;

    const cpu_count = std.Thread.getCpuCount() catch 4;
    host.jobs_fanout = @intCast(if (cpu_count > 1) @min(cpu_count - 1, 16) else 0);

    var track_plugins: [ui.track_count]TrackPlugin = undefined;
    for (&track_plugins) |*track| {
        track.* = .{};
    }
    var track_fx: [ui.track_count][ui.max_fx_slots]TrackPlugin = undefined;
    for (&track_fx) |*track_slots| {
        for (track_slots) |*slot| {
            slot.* = .{};
        }
    }

    zaudio.init(allocator);
    defer zaudio.deinit();

    var catalog = try plugins.discover(allocator, io);
    defer catalog.deinit();

    var state = ui.State.init(allocator);
    defer state.deinit();
    state.plugin_items = catalog.items_z;
    state.plugin_fx_items = catalog.fx_items_z;
    state.plugin_fx_indices = catalog.fx_indices;
    state.plugin_instrument_items = catalog.instrument_items_z;
    state.plugin_instrument_indices = catalog.instrument_indices;
    state.plugin_divider_index = catalog.divider_index;
    var buffer_frames: u32 = state.buffer_frames;

    // Set up host references for undo support
    host.ui_state = &state;
    host.allocator = allocator;
    host.track_plugins_ptr = &track_plugins;
    host.track_fx_ptr = &track_fx;
    host.catalog_ptr = &catalog;

    var engine = try audio_engine.AudioEngine.init(allocator, SampleRate, buffer_frames);
    defer engine.deinit();
    host.shared_state = &engine.shared;

    // Initialize libz_jobs work-stealing queue
    var jobs = try audio_graph.JobQueue.init(allocator, io);
    defer jobs.deinit();
    try jobs.start();
    defer jobs.join();
    defer jobs.stop();
    engine.jobs = &jobs;
    host.jobs = &jobs;

    engine.updateFromUi(&state);
    // Initial plugin sync will happen on first frame - plugins are loaded lazily

    var device_config = zaudio.Device.Config.init(.playback);
    device_config.playback.format = zaudio.Format.float32;
    device_config.playback.channels = Channels;
    device_config.sample_rate = SampleRate;
    device_config.period_size_in_frames = buffer_frames;
    device_config.performance_profile = .low_latency;
    device_config.periods = 2;
    device_config.data_callback = dataCallback;
    device_config.user_data = &engine;

    var device = try zaudio.Device.create(null, device_config);
    defer device.destroy();
    try device.start();

    zgui.init(allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    zgui.plot.init();
    defer zgui.plot.deinit();

    ui.Colors.setTheme(resolveTheme());

    var midi = midi_input.MidiInput{};
    midi.init(allocator) catch |err| {
        std.log.warn("MIDI input disabled: {}", .{err});
        midi.disable();
    };
    defer midi.deinit();

    var last_time = try std.time.Instant.now();
    var dsp_last_update = last_time;
    var last_interaction_time = last_time;
    var window_was_focused = true;

    std.log.info("flux running (Ctrl+C to quit)", .{});
    switch (builtin.os.tag) {
        .macos => {
            var app_window = try AppWindow.init("flux", 1280, 720);
            defer app_window.deinit();

            _ = zgui.io.addFontFromFile("assets/Roboto-Medium.ttf", std.math.floor(16.0 * app_window.scale_factor));
            zgui.getStyle().scaleAllSizes(app_window.scale_factor);
            zgui.backend.init(app_window.view, app_window.device);
            defer zgui.backend.deinit();

            while (app_window.window.isVisible()) {
                const frame_start = std.time.Instant.now() catch last_time;
                host.pumpMainThreadCallbacks();

                const now = std.time.Instant.now() catch last_time;
                const delta_ns = now.since(last_time);
                last_time = now;
                if (delta_ns > 0) {
                    const dt = @as(f64, @floatFromInt(delta_ns)) / std.time.ns_per_s;
                    ui.tick(&state, dt);
                }
                updateDeviceState(&state, &catalog, &track_plugins, &track_fx);
                midi.poll();
                state.midi_note_states = midi.note_states;
                state.midi_note_velocities = midi.note_velocities;
                if (now.since(dsp_last_update) >= 250 * std.time.ns_per_ms) {
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

                while (app_window.app.nextEventMatchingMask(
                    objc.app_kit.EventMaskAny,
                    objc.app_kit.Date.distantPast(),
                    objc.app_kit.NSDefaultRunLoopMode,
                    true,
                )) |event| {
                    app_window.app.sendEvent(event);
                }
                const window_focused = objc.objc.msgSend(app_window.window, "isKeyWindow", bool, .{});
                if (window_focused and !window_was_focused) {
                    last_interaction_time = now;
                }
                window_was_focused = window_focused;

                const frame = app_window.window.frame();
                const content = app_window.window.contentRectForFrameRect(frame);
                const scale: f32 = @floatCast(app_window.window.backingScaleFactor());
                if (scale != app_window.scale_factor) {
                    app_window.scale_factor = scale;
                }
                app_window.view.setFrameSize(content.size);
                app_window.view.setBoundsOrigin(.{ .x = 0, .y = 0 });
                app_window.view.setBoundsSize(.{
                    .width = content.size.width * @as(f64, @floatCast(scale)),
                    .height = content.size.height * @as(f64, @floatCast(scale)),
                });
                app_window.layer.setDrawableSize(.{
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
                const drawable_opt = app_window.layer.nextDrawable();
                if (drawable_opt == null) {
                    sleepNs(io, 5 * std.time.ns_per_ms);
                    continue;
                }
                const drawable = drawable_opt.?;
                attachment_descriptor.setTexture(drawable.texture());
                attachment_descriptor.setLoadAction(objc.metal.LoadActionClear);
                attachment_descriptor.setStoreAction(objc.metal.StoreActionStore);

                const command_buffer = app_window.command_queue.commandBuffer().?;
                const command_encoder = command_buffer.renderCommandEncoderWithDescriptor(descriptor).?;

                zgui.backend.newFrame(fb_width, fb_height, app_window.view, descriptor);
                zgui.setNextFrameWantCaptureKeyboard(true);
                ui.updateKeyboardMidi(&state);
                updateUiPluginPointers(&state, &track_plugins, &track_fx);
                ui.draw(&state, 1.0);
                if (state.buffer_frames_requested) {
                    const requested_frames = state.buffer_frames;
                    state.buffer_frames_requested = false;
                    if (requested_frames != buffer_frames) {
                        applyBufferFramesChange(
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
                handleFileRequests(allocator, io, &state, &catalog, &track_plugins, &track_fx, &host.clap_host, &engine.shared);
                engine.updateFromUi(&state);
                try syncTrackPlugins(allocator, &host.clap_host, &track_plugins, &track_fx, &state, &catalog, &engine.shared, io, buffer_frames, true);
                try syncFxPlugins(allocator, &host.clap_host, &track_plugins, &track_fx, &state, &catalog, &engine.shared, io, buffer_frames, true);
                const frame_plugins = collectPlugins(&track_plugins, &track_fx);
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
                const idle_ns = now.since(last_interaction_time);
                const target_fps: u32 = if (active)
                    60
                else if (idle_ns >= std.time.ns_per_s)
                    1
                else
                    20;
                const target_frame_ns: u64 = std.time.ns_per_s / @as(u64, target_fps);
                const frame_end = std.time.Instant.now() catch frame_start;
                const frame_elapsed_ns = frame_end.since(frame_start);
                if (frame_elapsed_ns < target_frame_ns) {
                    sleepNs(io, target_frame_ns - frame_elapsed_ns);
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
            _ = zgui.io.addFontFromFile("assets/Roboto-Medium.ttf", std.math.floor(16.0 * ui_scale));
            if (ui_scale != 1.0) zgui.getStyle().scaleAllSizes(ui_scale);

            zgui.backend.init(window);
            defer zgui.backend.deinit();

            const gl = zopengl.bindings;

            while (!window.shouldClose()) {
                const frame_start = std.time.Instant.now() catch last_time;
                host.pumpMainThreadCallbacks();

                const now = std.time.Instant.now() catch last_time;
                const delta_ns = now.since(last_time);
                last_time = now;
                if (delta_ns > 0) {
                    const dt = @as(f64, @floatFromInt(delta_ns)) / std.time.ns_per_s;
                    ui.tick(&state, dt);
                }
                updateDeviceState(&state, &catalog, &track_plugins, &track_fx);
                midi.poll();
                state.midi_note_states = midi.note_states;
                state.midi_note_velocities = midi.note_velocities;
                if (now.since(dsp_last_update) >= 250 * std.time.ns_per_ms) {
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

                gl.clearBufferfv(gl.COLOR, 0, &ui.Colors.current.bg_dark);
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
                ui.updateKeyboardMidi(&state);
                updateUiPluginPointers(&state, &track_plugins, &track_fx);
                ui.draw(&state, 1.0);
                if (state.buffer_frames_requested) {
                    const requested_frames = state.buffer_frames;
                    state.buffer_frames_requested = false;
                    if (requested_frames != buffer_frames) {
                        applyBufferFramesChange(
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
                handleFileRequests(allocator, io, &state, &catalog, &track_plugins, &track_fx, &host.clap_host, &engine.shared);
                engine.updateFromUi(&state);
                try syncTrackPlugins(allocator, &host.clap_host, &track_plugins, &track_fx, &state, &catalog, &engine.shared, io, buffer_frames, true);
                try syncFxPlugins(allocator, &host.clap_host, &track_plugins, &track_fx, &state, &catalog, &engine.shared, io, buffer_frames, true);
                const frame_plugins = collectPlugins(&track_plugins, &track_fx);
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
                const idle_ns = now.since(last_interaction_time);
                const target_fps: u32 = if (active)
                    60
                else if (idle_ns >= std.time.ns_per_s)
                    1
                else
                    20;
                const target_frame_ns: u64 = std.time.ns_per_s / @as(u64, target_fps);
                const frame_end = std.time.Instant.now() catch frame_start;
                const frame_elapsed_ns = frame_end.since(frame_start);
                if (frame_elapsed_ns < target_frame_ns) {
                    sleepNs(io, target_frame_ns - frame_elapsed_ns);
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
        closePluginGui(track);
    }

    for (&track_plugins, 0..) |*track, t| {
        unloadPlugin(track, allocator, &engine.shared, t);
    }
}

fn sleepNs(io: std.Io, ns: u64) void {
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromNanoseconds(@intCast(ns)) }, io) catch {};
}

fn updateDeviceState(
    state: *ui.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [ui.track_count]TrackPlugin,
    track_fx: *const [ui.track_count][ui.max_fx_slots]TrackPlugin,
) void {
    const track_idx = state.selectedTrack();
    const choice = switch (state.device_target_kind) {
        .instrument => state.track_plugins[track_idx].choice_index,
        .fx => state.track_fx[track_idx][state.device_target_fx].choice_index,
    };
    const entry = catalog.entryForIndex(choice);
    if (entry == null or entry.?.kind == .none or entry.?.kind == .divider) {
        state.device_kind = .none;
        state.device_clap_plugin = null;
        state.device_clap_name = "";
        return;
    }

    // Get the plugin from TrackPlugin (works for both builtin and external)
    const track_plugin = switch (state.device_target_kind) {
        .instrument => &track_plugins[track_idx],
        .fx => &track_fx[track_idx][state.device_target_fx],
    };
    const plugin = track_plugin.getPlugin();

    if (plugin != null) {
        state.device_kind = .plugin;
        state.device_clap_plugin = plugin;
        state.device_clap_name = entry.?.name;
    } else {
        // Plugin not yet loaded (will be loaded on next sync)
        state.device_kind = .none;
        state.device_clap_plugin = null;
        state.device_clap_name = entry.?.name;
    }
}

const PluginSnapshot = struct {
    instruments: [ui.track_count]?*const clap.Plugin,
    fx: [ui.track_count][ui.max_fx_slots]?*const clap.Plugin,
};

fn pluginHasAudioInput(plugin: *const clap.Plugin) bool {
    const ext_raw = plugin.getExtension(plugin, clap.ext.audio_ports.id) orelse return false;
    const ports: *const clap.ext.audio_ports.Plugin = @ptrCast(@alignCast(ext_raw));
    return ports.count(plugin, true) > 0;
}

fn collectPlugins(
    track_plugins: *const [ui.track_count]TrackPlugin,
    track_fx: *const [ui.track_count][ui.max_fx_slots]TrackPlugin,
) PluginSnapshot {
    var instruments: [ui.track_count]?*const clap.Plugin = [_]?*const clap.Plugin{null} ** ui.track_count;
    var fx: [ui.track_count][ui.max_fx_slots]?*const clap.Plugin =
        [_][ui.max_fx_slots]?*const clap.Plugin{[_]?*const clap.Plugin{null} ** ui.max_fx_slots} ** ui.track_count;

    for (0..ui.track_count) |t| {
        // All plugins (builtin and external) are now in TrackPlugin
        instruments[t] = track_plugins[t].getPlugin();

        for (0..ui.max_fx_slots) |fx_index| {
            fx[t][fx_index] = track_fx[t][fx_index].getPlugin();
        }
    }

    return .{
        .instruments = instruments,
        .fx = fx,
    };
}

fn updateUiPluginPointers(
    state: *ui.State,
    track_plugins: *const [ui.track_count]TrackPlugin,
    track_fx: *const [ui.track_count][ui.max_fx_slots]TrackPlugin,
) void {
    for (track_plugins, 0..) |track, t| {
        state.track_plugin_ptrs[t] = track.getPlugin();
    }
    for (track_fx, 0..) |track_slots, t| {
        for (track_slots, 0..) |slot, fx_index| {
            state.track_fx_plugin_ptrs[t][fx_index] = slot.getPlugin();
        }
    }
}

fn syncTrackPlugins(
    allocator: std.mem.Allocator,
    host: *const clap.Host,
    track_plugins: *[ui.track_count]TrackPlugin,
    track_fx: *[ui.track_count][ui.max_fx_slots]TrackPlugin,
    state: *ui.State,
    catalog: *const plugins.PluginCatalog,
    shared: ?*audio_engine.SharedState,
    io: std.Io,
    max_frames: u32,
    start_processing: bool,
) !void {
    const prepareUnload = struct {
        fn call(shared_state: ?*audio_engine.SharedState, track_index: usize, io_ctx: std.Io) void {
            if (shared_state) |shared_ref| {
                shared_ref.setTrackPlugin(track_index, null);
                shared_ref.waitForIdle(io_ctx);
            }
        }
    }.call;

    const selected_track = state.selectedTrack();
    for (track_plugins, 0..) |*track, t| {
        const choice = state.track_plugins[t].choice_index;
        // Only show GUI for the selected track (if that track has gui_open enabled)
        const wants_gui = state.track_plugins[t].gui_open and (t == selected_track);

        const entry = catalog.entryForIndex(choice);
        const kind = if (entry) |item| item.kind else .none;

        // Handle none/divider - unload any existing plugin
        if (kind == .none or kind == .divider) {
            if (track.handle != null or track.builtin != null) {
                closePluginGui(track);
                prepareUnload(shared, t, io);
                unloadPlugin(track, allocator, shared, t);
            }
            track.choice_index = choice;
            continue;
        }

        // Plugin choice changed - unload old plugin
        if (track.choice_index != choice) {
            if (track.handle != null or track.builtin != null) {
                closePluginGui(track);
                prepareUnload(shared, t, io);
                unloadPlugin(track, allocator, shared, t);
            }
            track.choice_index = choice;
        }

        // Load new plugin if needed
        if (track.handle == null and track.builtin == null) {
            switch (kind) {
                .builtin => {
                    // Instantiate builtin plugin directly (statically linked)
                    const plugin_id = entry.?.id orelse "";
                    if (std.mem.eql(u8, plugin_id, "com.fourlex.zminimoog")) {
                        const plugin = try zminimoog.Plugin.init(allocator, host);
                        if (!plugin.plugin.init(&plugin.plugin)) return error.PluginInitFailed;
                        if (!plugin.plugin.activate(&plugin.plugin, SampleRate, 1, max_frames)) {
                            return error.PluginActivateFailed;
                        }
                        track.builtin = .{ .plugin = &plugin.plugin };
                    } else {
                        const plugin = try zsynth.Plugin.init(allocator, host);
                        if (!plugin.plugin.init(&plugin.plugin)) return error.PluginInitFailed;
                        if (!plugin.plugin.activate(&plugin.plugin, SampleRate, 1, max_frames)) {
                            return error.PluginActivateFailed;
                        }
                        track.builtin = .{ .plugin = &plugin.plugin };
                    }
                    // Builtins don't have external GUIs - they use embedded zgui views
                    track.gui_ext = null;
                },
                .clap => {
                    const path = entry.?.path orelse return error.PluginMissingPath;
                    track.handle = try PluginHandle.init(allocator, host, path, entry.?.id, max_frames);
                    track.gui_ext = getGuiExt(track.handle.?);
                },
                else => {},
            }
            // Request startProcessing from audio thread (CLAP requires audio thread for this call)
            if (start_processing) {
                if (shared) |s| {
                    s.requestStartProcessing(t);
                }
            }
        }

        // GUI handling for external CLAP plugins only (builtins use embedded views)
        if (kind == .clap) {
            if (wants_gui and !track.gui_open) {
                if (track.gui_ext) |gui_ext| {
                    closeAllPluginGuis(track_plugins, track_fx);
                    openPluginGui(track, gui_ext) catch |err| {
                        std.log.err("Failed to open plugin gui: {}", .{err});
                        state.track_plugins[t].gui_open = false;
                    };
                } else {
                    state.track_plugins[t].gui_open = false;
                }
            } else if (!wants_gui and track.gui_open) {
                closePluginGui(track);
            }
        }
    }
}

fn syncFxPlugins(
    allocator: std.mem.Allocator,
    host: *const clap.Host,
    track_plugins: *[ui.track_count]TrackPlugin,
    track_fx: *[ui.track_count][ui.max_fx_slots]TrackPlugin,
    state: *ui.State,
    catalog: *const plugins.PluginCatalog,
    shared: ?*audio_engine.SharedState,
    io: std.Io,
    max_frames: u32,
    start_processing: bool,
) !void {
    const prepareUnload = struct {
        fn call(shared_state: ?*audio_engine.SharedState, track_index: usize, fx_index: usize, io_ctx: std.Io) void {
            if (shared_state) |shared_ref| {
                shared_ref.setTrackFxPlugin(track_index, fx_index, null);
                shared_ref.waitForIdle(io_ctx);
            }
        }
    }.call;

    const selected_track = state.selectedTrack();
    for (track_fx, 0..) |*track_slots, t| {
        for (track_slots, 0..) |*slot, fx_index| {
            const choice = state.track_fx[t][fx_index].choice_index;
            const entry = catalog.entryForIndex(choice);
            const kind = if (entry) |item| item.kind else .none;
            const wants_gui = state.track_fx[t][fx_index].gui_open and (t == selected_track);

            if (kind != .clap) {
                if (slot.handle != null) {
                    closePluginGui(slot);
                    prepareUnload(shared, t, fx_index, io);
                    unloadFxPlugin(slot, allocator, shared, t, fx_index);
                }
                if (kind == .builtin or kind == .divider) {
                    state.track_fx[t][fx_index].choice_index = 0;
                    state.track_fx[t][fx_index].last_valid_choice = 0;
                }
                slot.choice_index = state.track_fx[t][fx_index].choice_index;
                continue;
            }

            if (slot.choice_index != choice) {
                if (slot.handle != null) {
                    closePluginGui(slot);
                    prepareUnload(shared, t, fx_index, io);
                    unloadFxPlugin(slot, allocator, shared, t, fx_index);
                }
                slot.choice_index = choice;
            }

            if (slot.handle == null) {
                const path = entry.?.path orelse return error.PluginMissingPath;
                slot.handle = try PluginHandle.init(allocator, host, path, entry.?.id, max_frames);
                slot.gui_ext = getGuiExt(slot.handle.?);
                if (start_processing) {
                    if (shared) |s| {
                        s.requestStartProcessingFx(t, fx_index);
                    }
                }
            }

            if (slot.handle != null and !pluginHasAudioInput(slot.handle.?.plugin)) {
                std.log.warn("FX plugin has no audio input: {s}", .{entry.?.name});
                closePluginGui(slot);
                prepareUnload(shared, t, fx_index, io);
                unloadFxPlugin(slot, allocator, shared, t, fx_index);
                state.track_fx[t][fx_index].gui_open = false;
                const fallback = if (state.track_fx[t][fx_index].last_valid_choice != choice)
                    state.track_fx[t][fx_index].last_valid_choice
                else
                    0;
                state.track_fx[t][fx_index].choice_index = fallback;
                slot.choice_index = fallback;
                continue;
            }
            state.track_fx[t][fx_index].last_valid_choice = choice;

            if (wants_gui and !slot.gui_open) {
                if (slot.gui_ext) |gui_ext| {
                    closeAllPluginGuis(track_plugins, track_fx);
                    openPluginGui(slot, gui_ext) catch |err| {
                        std.log.err("Failed to open fx plugin gui: {}", .{err});
                        state.track_fx[t][fx_index].gui_open = false;
                    };
                } else {
                    state.track_fx[t][fx_index].gui_open = false;
                }
            } else if (!wants_gui and slot.gui_open) {
                closePluginGui(slot);
            }
        }
    }
}

fn unloadPlugin(track: *TrackPlugin, allocator: std.mem.Allocator, shared: ?*audio_engine.SharedState, track_index: usize) void {
    // Get the CLAP plugin pointer (works for both handle and builtin)
    const plugin_ptr = track.getPlugin();

    if (plugin_ptr) |plugin| {
        // Check if plugin was started via shared state and call stopProcessing if needed
        if (shared) |s| {
            if (s.isPluginStarted(track_index)) {
                // Set audio thread flag for stopProcessing (per CLAP spec, host controls
                // which thread is "audio thread" and can designate any thread when only
                // one is active. The audio device is already stopped at this point.)
                const was_audio = is_audio_thread;
                is_audio_thread = true;
                defer is_audio_thread = was_audio;
                plugin.stopProcessing(plugin);
                s.clearPluginStarted(track_index);
            }
        }
    }

    // Deinit external plugin handle
    if (track.handle) |*handle| {
        handle.deinit(allocator);
    }
    // Deinit builtin plugin
    if (track.builtin) |*b| {
        b.deinit();
    }

    track.handle = null;
    track.builtin = null;
    track.gui_ext = null;
    track.gui_window = null;
    track.gui_view = null;
    track.gui_open = false;
}

fn unloadFxPlugin(
    track: *TrackPlugin,
    allocator: std.mem.Allocator,
    shared: ?*audio_engine.SharedState,
    track_index: usize,
    fx_index: usize,
) void {
    if (track.handle) |*handle| {
        if (shared) |s| {
            if (s.isFxPluginStarted(track_index, fx_index)) {
                const was_audio = is_audio_thread;
                is_audio_thread = true;
                defer is_audio_thread = was_audio;
                handle.plugin.stopProcessing(handle.plugin);
                s.clearFxPluginStarted(track_index, fx_index);
            }
        }
        handle.deinit(allocator);
    }
    track.handle = null;
    track.gui_ext = null;
    track.gui_window = null;
    track.gui_view = null;
    track.gui_open = false;
}

fn getGuiExt(handle: PluginHandle) ?*const clap.ext.gui.Plugin {
    const ext_raw = handle.plugin.getExtension(handle.plugin, clap.ext.gui.id) orelse return null;
    return @ptrCast(@alignCast(ext_raw));
}

fn openPluginGui(track: *TrackPlugin, gui_ext: *const clap.ext.gui.Plugin) !void {
    if (track.handle == null) return;
    if (track.gui_open) return;

    const plugin = track.handle.?.plugin;
    var is_floating: bool = false;
    var api_ptr: [*:0]const u8 = switch (builtin.os.tag) {
        .linux => clap.ext.gui.window_api.wayland,
        else => clap.ext.gui.window_api.cocoa,
    };
    _ = gui_ext.getPreferredApi(plugin, &api_ptr, &is_floating);

    // CLAP Wayland embedding isn't supported (floating only), so on Linux force floating and
    // pick the best supported API (prefer Wayland).
    if (builtin.os.tag == .linux) {
        is_floating = true;
        if (gui_ext.isApiSupported(plugin, clap.ext.gui.window_api.wayland, true)) {
            api_ptr = clap.ext.gui.window_api.wayland;
        } else if (gui_ext.isApiSupported(plugin, clap.ext.gui.window_api.x11, true)) {
            api_ptr = clap.ext.gui.window_api.x11;
        } else if (gui_ext.isApiSupported(plugin, api_ptr, true)) {
            // keep plugin preference
        } else {
            return error.GuiUnsupported;
        }
    }

    if (!gui_ext.isApiSupported(plugin, api_ptr, is_floating)) {
        return error.GuiUnsupported;
    }

    if (!gui_ext.create(plugin, api_ptr, is_floating)) {
        return error.GuiCreateFailed;
    }

    switch (builtin.os.tag) {
        .macos => {
            if (!is_floating) {
                var width: u32 = 0;
                var height: u32 = 0;
                if (!gui_ext.getSize(plugin, &width, &height)) {
                    width = 800;
                    height = 500;
                }
                const rect = objc.app_kit.Rect{
                    .origin = .{ .x = 0, .y = 0 },
                    .size = .{
                        .width = @floatFromInt(width),
                        .height = @floatFromInt(height),
                    },
                };
                const style = objc.app_kit.WindowStyleMaskTitled |
                    objc.app_kit.WindowStyleMaskClosable |
                    objc.app_kit.WindowStyleMaskResizable |
                    objc.app_kit.WindowStyleMaskMiniaturizable;
                const window = objc.app_kit.Window.alloc().initWithContentRect_styleMask_backing_defer_screen(
                    rect,
                    style,
                    objc.app_kit.BackingStoreBuffered,
                    false,
                    null,
                );
                window.setReleasedWhenClosed(false);
                const title = objc.foundation.String.stringWithUTF8String("Plugin");
                window.setTitle(title);

                // Get main window BEFORE showing plugin window (otherwise plugin becomes mainWindow)
                const main_window: ?*objc.app_kit.Window = objc.objc.msgSend(
                    objc.app_kit.Application.sharedApplication(),
                    "mainWindow",
                    ?*objc.app_kit.Window,
                    .{},
                );

                const view = objc.app_kit.View.alloc().initWithFrame(rect);
                window.setContentView(view);
                window.makeKeyAndOrderFront(null);

                // Add as child window of main app window - stays above main window but not above other apps
                if (main_window) |mw| {
                    const NSWindowAbove: c_long = 1;
                    objc.objc.msgSend(mw, "addChildWindow:ordered:", void, .{ window, NSWindowAbove });
                }
                const window_handle = clap.ext.gui.Window{
                    .api = clap.ext.gui.window_api.cocoa,
                    .data = .{ .cocoa = @ptrCast(view) },
                };
                if (!gui_ext.setParent(plugin, &window_handle)) {
                    view.release();
                    window.release();
                    gui_ext.destroy(plugin);
                    return error.GuiSetParentFailed;
                }
                track.gui_window = @ptrCast(window);
                track.gui_view = @ptrCast(view);
            }
        },
        .linux => {},
        else => {},
    }

    if (!gui_ext.show(plugin)) {
        if (builtin.os.tag == .macos) {
            if (track.gui_window) |window_raw| {
                const window: *objc.app_kit.Window = @ptrCast(@alignCast(window_raw));
                window.setIsVisible(false);
                window.release();
                track.gui_window = null;
            }
            if (track.gui_view) |view_raw| {
                const view: *objc.app_kit.View = @ptrCast(@alignCast(view_raw));
                view.release();
                track.gui_view = null;
            }
        }
        gui_ext.destroy(plugin);
        return error.GuiShowFailed;
    }

    track.gui_open = true;
}

fn closePluginGui(track: *TrackPlugin) void {
    if (track.handle == null) return;
    if (!track.gui_open) return;
    const plugin = track.handle.?.plugin;
    if (track.gui_ext) |gui_ext| {
        _ = gui_ext.hide(plugin);
        gui_ext.destroy(plugin);
    }
    if (builtin.os.tag == .macos) {
        if (track.gui_window) |window_raw| {
            const window: *objc.app_kit.Window = @ptrCast(@alignCast(window_raw));
            // Remove from parent window's child list
            const main_window: ?*objc.app_kit.Window = objc.objc.msgSend(
                objc.app_kit.Application.sharedApplication(),
                "mainWindow",
                ?*objc.app_kit.Window,
                .{},
            );
            if (main_window) |mw| {
                objc.objc.msgSend(mw, "removeChildWindow:", void, .{window});
            }
            window.setIsVisible(false);
            window.release();
            track.gui_window = null;
        }
        if (track.gui_view) |view_raw| {
            const view: *objc.app_kit.View = @ptrCast(@alignCast(view_raw));
            view.release();
            track.gui_view = null;
        }
    } else {
        track.gui_window = null;
        track.gui_view = null;
    }
    track.gui_open = false;
}

fn closeAllPluginGuis(
    track_plugins: *[ui.track_count]TrackPlugin,
    track_fx: *[ui.track_count][ui.max_fx_slots]TrackPlugin,
) void {
    for (track_plugins) |*track| {
        if (track.gui_open) {
            closePluginGui(track);
        }
    }
    for (track_fx) |*track_slots| {
        for (track_slots) |*slot| {
            if (slot.gui_open) {
                closePluginGui(slot);
            }
        }
    }
}

// ============================================================================
// DAWproject File Handling
// ============================================================================

const dawproject_file_types = [_]file_dialog.FileType{
    .{ .name = "DAWproject", .extensions = &.{"dawproject"} },
};

fn handleFileRequests(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *ui.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *[ui.track_count]TrackPlugin,
    track_fx: *[ui.track_count][ui.max_fx_slots]TrackPlugin,
    host: *const clap.Host,
    shared: ?*audio_engine.SharedState,
) void {
    // Handle save request
    if (state.save_project_request) {
        state.save_project_request = false;
        if (state.project_path == null) {
            state.save_project_as_request = true;
        } else {
            handleSaveProject(allocator, io, state, catalog, track_plugins, track_fx) catch |err| {
                std.log.err("Failed to save project: {}", .{err});
            };
        }
    }

    if (state.save_project_as_request) {
        state.save_project_as_request = false;
        handleSaveProjectAs(allocator, io, state, catalog, track_plugins, track_fx) catch |err| {
            std.log.err("Failed to save project as: {}", .{err});
        };
    }

    // Handle load request
    if (state.load_project_request) {
        state.load_project_request = false;
        handleLoadProject(allocator, io, state, catalog, track_plugins, track_fx, host, shared) catch |err| {
            std.log.err("Failed to load project: {}", .{err});
        };
    }

    // Handle plugin state restore request (for undo/redo)
    if (state.plugin_state_restore_request) |req| {
        state.plugin_state_restore_request = null;
        if (req.track_index < ui.track_count) {
            // All plugins (builtin and external) are now in TrackPlugin
            if (track_plugins[req.track_index].getPlugin()) |plugin| {
                loadPluginStateFromData(plugin, req.state_data);
            }
        }
    }
}

fn handleSaveProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *const ui.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [ui.track_count]TrackPlugin,
    track_fx: *const [ui.track_count][ui.max_fx_slots]TrackPlugin,
) !void {
    const path = state.project_path orelse return;
    try saveProjectToPath(allocator, io, path, state, catalog, track_plugins, track_fx);
}

fn handleSaveProjectAs(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *ui.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [ui.track_count]TrackPlugin,
    track_fx: *const [ui.track_count][ui.max_fx_slots]TrackPlugin,
) !void {
    const default_name = if (state.project_path) |path| std.fs.path.basename(path) else "project.dawproject";

    const path = file_dialog.saveFile(
        allocator,
        io,
        "Save DAWproject",
        default_name,
        &dawproject_file_types,
    ) catch |err| {
        std.log.err("File dialog error: {}", .{err});
        return;
    };

    if (path == null) {
        return;
    }
    defer allocator.free(path.?);

    try saveProjectToPath(allocator, io, path.?, state, catalog, track_plugins, track_fx);
    try state.setProjectPath(path.?);
}

fn saveProjectToPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: *const ui.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [ui.track_count]TrackPlugin,
    track_fx: *const [ui.track_count][ui.max_fx_slots]TrackPlugin,
) !void {
    var param_arena = std.heap.ArenaAllocator.init(allocator);
    defer param_arena.deinit();
    const param_alloc = param_arena.allocator();

    // Collect plugin states and plugin info
    var plugin_states: std.ArrayList(dawproject.PluginStateFile) = .empty;
    defer plugin_states.deinit(allocator);

    var track_plugin_info: [ui.track_count]dawproject.TrackPluginInfo = undefined;
    for (&track_plugin_info) |*info| {
        info.* = .{};
    }
    var track_fx_plugin_info: [ui.track_count][ui.max_fx_slots]dawproject.TrackPluginInfo = undefined;
    for (&track_fx_plugin_info) |*track_slots| {
        for (track_slots) |*info| {
            info.* = .{};
        }
    }

    for (track_plugins, 0..) |track, t| {
        if (track.handle) |handle| {
            // Get the plugin ID from the loaded plugin's descriptor
            track_plugin_info[t].plugin_id = std.mem.span(handle.plugin.descriptor.id);
            track_plugin_info[t].params = collectPluginParams(param_alloc, handle.plugin);

            if (capturePluginStateForDawproject(allocator, handle.plugin, t, null)) |ps| {
                track_plugin_info[t].state_path = ps.path;
                plugin_states.append(allocator, ps) catch continue;
            }
        }
    }
    for (track_fx, 0..) |track_slots, t| {
        for (track_slots, 0..) |slot, fx_index| {
            if (slot.handle) |handle| {
                track_fx_plugin_info[t][fx_index].plugin_id = std.mem.span(handle.plugin.descriptor.id);
                track_fx_plugin_info[t][fx_index].params = collectPluginParams(param_alloc, handle.plugin);
                if (capturePluginStateForDawproject(allocator, handle.plugin, t, fx_index)) |ps| {
                    track_fx_plugin_info[t][fx_index].state_path = ps.path;
                    plugin_states.append(allocator, ps) catch continue;
                }
            }
        }
    }

    // Save the project
    dawproject.save(
        allocator,
        io,
        path,
        state,
        catalog,
        plugin_states.items,
        &track_plugin_info,
        &track_fx_plugin_info,
    ) catch |err| {
        std.log.err("Failed to write dawproject: {}", .{err});
        return;
    };

    std.log.info("Saved project to: {s}", .{path});
}

fn collectPluginParams(
    allocator: std.mem.Allocator,
    plugin: *const clap.Plugin,
) []const dawproject.PluginParamInfo {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse return &.{};
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const count = params.count(plugin);
    if (count == 0) return &.{};

    var list: std.ArrayList(dawproject.PluginParamInfo) = .empty;
    for (0..count) |i| {
        var info: clap.ext.params.Info = undefined;
        if (!params.getInfo(plugin, @intCast(i), &info)) continue;
        const name = std.mem.sliceTo(info.name[0..], 0);
        var value: f64 = info.default_value;
        if (!params.getValue(plugin, info.id, &value)) {
            value = info.default_value;
        }
        list.append(allocator, .{
            .id = @intFromEnum(info.id),
            .name = allocator.dupe(u8, name) catch "",
            .min = info.min_value,
            .max = info.max_value,
            .default_value = info.default_value,
            .value = value,
        }) catch {};
    }

    return list.toOwnedSlice(allocator) catch &.{};
}

fn handleLoadProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *ui.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *[ui.track_count]TrackPlugin,
    track_fx: *[ui.track_count][ui.max_fx_slots]TrackPlugin,
    host: *const clap.Host,
    shared: ?*audio_engine.SharedState,
) !void {
    // Show open dialog
    const path = file_dialog.openFile(
        allocator,
        io,
        "Open DAWproject",
        &dawproject_file_types,
    ) catch |err| {
        std.log.err("File dialog error: {}", .{err});
        return;
    };

    if (path == null) {
        // User cancelled
        return;
    }
    defer allocator.free(path.?);

    // Load the project
    var loaded = dawproject.load(allocator, io, path.?) catch |err| {
        std.log.err("Failed to load dawproject: {}", .{err});
        return;
    };
    defer loaded.deinit();

    // Apply to state
    applyDawprojectToState(allocator, &loaded, state, catalog, track_plugins, track_fx, host, shared, io) catch |err| {
        std.log.err("Failed to apply dawproject: {}", .{err});
        return;
    };

    try state.setProjectPath(path.?);
    std.log.info("Loaded project from: {s}", .{path.?});
}

fn capturePluginStateForDawproject(
    allocator: std.mem.Allocator,
    plugin: *const clap.Plugin,
    track_index: usize,
    fx_index: ?usize,
) ?dawproject.PluginStateFile {
    const ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse return null;
    const ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(ext_raw));

    var stream = MemoryOStream.init(allocator);
    stream.stream.context = &stream;
    defer stream.buffer.deinit(allocator);

    if (!ext.save(plugin, &stream.stream)) {
        return null;
    }

    // Build clap-preset container format:
    // [4 bytes: "clap" magic]
    // [4 bytes: plugin ID length (big-endian)]
    // [N bytes: plugin ID string]
    // [remaining: raw plugin state]
    const plugin_id = std.mem.span(plugin.descriptor.id);
    const plugin_id_len: u32 = @intCast(plugin_id.len);
    const header_size = 4 + 4 + plugin_id.len;
    const total_size = header_size + stream.buffer.items.len;

    var container = allocator.alloc(u8, total_size) catch return null;

    // Write magic "clap"
    container[0] = 'c';
    container[1] = 'l';
    container[2] = 'a';
    container[3] = 'p';

    // Write plugin ID length (big-endian)
    container[4] = @intCast((plugin_id_len >> 24) & 0xFF);
    container[5] = @intCast((plugin_id_len >> 16) & 0xFF);
    container[6] = @intCast((plugin_id_len >> 8) & 0xFF);
    container[7] = @intCast(plugin_id_len & 0xFF);

    // Write plugin ID
    @memcpy(container[8..][0..plugin_id.len], plugin_id);

    // Write raw plugin state
    @memcpy(container[header_size..], stream.buffer.items);

    var path_buf: [64]u8 = undefined;
    const plugin_path = if (fx_index) |fx_slot|
        std.fmt.bufPrint(&path_buf, "plugins/track{d}-fx{d}.clap-preset", .{ track_index, fx_slot }) catch return null
    else
        std.fmt.bufPrint(&path_buf, "plugins/track{d}.clap-preset", .{track_index}) catch return null;

    return .{
        .path = allocator.dupe(u8, plugin_path) catch return null,
        .data = container,
    };
}

/// Capture plugin state for undo. Uses state_context extension with project context
/// when available, otherwise falls back to regular state extension.
pub fn capturePluginStateForUndo(allocator: std.mem.Allocator, plugin: *const clap.Plugin) ?[]u8 {
    var stream = MemoryOStream.init(allocator);
    stream.stream.context = &stream;

    // Try state_context extension first (allows plugin to provide optimized state for undo)
    if (plugin.getExtension(plugin, clap.ext.state_context.id)) |ext_raw| {
        const ext: *const clap.ext.state_context.Plugin = @ptrCast(@alignCast(ext_raw));
        if (ext.save(plugin, &stream.stream, .project)) {
            return allocator.dupe(u8, stream.buffer.items) catch {
                stream.buffer.deinit(allocator);
                return null;
            };
        }
        // If state_context.save failed, try regular state extension
        stream.buffer.clearRetainingCapacity();
    }

    // Fall back to regular state extension
    const state_ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse {
        stream.buffer.deinit(allocator);
        return null;
    };
    const state_ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(state_ext_raw));

    if (!state_ext.save(plugin, &stream.stream)) {
        stream.buffer.deinit(allocator);
        return null;
    }

    const data = allocator.dupe(u8, stream.buffer.items) catch {
        stream.buffer.deinit(allocator);
        return null;
    };
    stream.buffer.deinit(allocator);
    return data;
}

fn applyDawprojectToState(
    allocator: std.mem.Allocator,
    loaded: *dawproject.LoadedProject,
    state: *ui.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *[ui.track_count]TrackPlugin,
    track_fx: *[ui.track_count][ui.max_fx_slots]TrackPlugin,
    host: *const clap.Host,
    shared: ?*audio_engine.SharedState,
    io: std.Io,
) !void {
    const proj = &loaded.project;

    // Stop playback
    state.playing = false;
    state.playhead_beat = 0;

    // Apply transport settings
    if (proj.transport) |transport| {
        if (transport.tempo) |tempo| {
            state.bpm = @floatCast(tempo.value);
        }
    }

    // Reset session
    state.session.deinit();
    state.session = ui.SessionView.init(state.allocator);

    // Apply tracks
    const track_count = @min(proj.tracks.len, ui.track_count);
    state.session.track_count = track_count;
    var instrument_device_ids: [ui.track_count]?[]const u8 = [_]?[]const u8{null} ** ui.track_count;
    var fx_device_ids: [ui.track_count][ui.max_fx_slots]?[]const u8 = [_][ui.max_fx_slots]?[]const u8{
        [_]?[]const u8{null} ** ui.max_fx_slots,
    } ** ui.track_count;

    for (0..ui.track_count) |t| {
        state.track_plugins[t].choice_index = 0;
        state.track_plugins[t].gui_open = false;
        state.track_plugins[t].last_valid_choice = 0;
        for (0..ui.max_fx_slots) |fx_index| {
            state.track_fx[t][fx_index].choice_index = 0;
            state.track_fx[t][fx_index].gui_open = false;
            state.track_fx[t][fx_index].last_valid_choice = 0;
        }
    }

    for (0..track_count) |t| {
        const track = proj.tracks[t];
        state.session.tracks[t].setName(track.name);

        if (track.channel) |channel| {
            if (channel.volume) |vol| {
                state.session.tracks[t].volume = @floatCast(vol.value);
            }
            if (channel.mute) |mute| {
                state.session.tracks[t].mute = mute.value;
            }
            state.session.tracks[t].solo = channel.solo;

            // Handle CLAP plugins
            if (channel.devices.len > 0) {
                var fx_slot: usize = 0;
                for (channel.devices) |device| {
                    const choice = findPluginInCatalog(catalog, device.device_id);
                    if (device.device_role == .instrument or device.device_role == .noteFX) {
                        state.track_plugins[t].choice_index = choice;
                        state.track_plugins[t].last_valid_choice = choice;
                        instrument_device_ids[t] = device.id;
                    } else if (device.device_role == .audioFX and fx_slot < ui.max_fx_slots) {
                        state.track_fx[t][fx_slot].choice_index = choice;
                        state.track_fx[t][fx_slot].last_valid_choice = choice;
                        fx_device_ids[t][fx_slot] = device.id;
                        fx_slot += 1;
                    }
                }
            }
        }
    }

    // Apply scenes
    const scene_count = @min(proj.scenes.len, ui.scene_count);
    state.session.scene_count = scene_count;

    for (0..scene_count) |s| {
        state.session.scenes[s].setName(proj.scenes[s].name);
    }

    // Clear piano clips
    for (&state.piano_clips) |*track_clips| {
        for (track_clips) |*clip| {
            clip.clear();
        }
    }

    // Apply session clips from scenes when available, otherwise fall back to arrangement lanes.
    var applied_scene_clips = false;
    if (proj.scenes.len > 0) {
        for (proj.scenes) |scene| {
            if (scene.clip_slots.len > 0) {
                applied_scene_clips = true;
                break;
            }
        }
    }

    if (applied_scene_clips) {
        try applyScenes(state, proj.scenes, proj.tracks, proj.master_track, &instrument_device_ids, &fx_device_ids);
    } else if (proj.arrangement) |arr| {
        if (arr.lanes) |root_lanes| {
            try applyLanes(state, &root_lanes, proj.tracks, &instrument_device_ids, &fx_device_ids);
        }
    }

    // Sync track plugins after state update
    try syncTrackPlugins(allocator, host, track_plugins, track_fx, state, catalog, shared, io, state.buffer_frames, true);
    try syncFxPlugins(allocator, host, track_plugins, track_fx, state, catalog, shared, io, state.buffer_frames, true);

    // Load plugin states from dawproject
    for (0..track_count) |t| {
        const track = proj.tracks[t];
        if (track.channel) |channel| {
            var fx_slot: usize = 0;
            for (channel.devices) |device| {
                if (device.state == null) continue;
                const state_ref = device.state.?;
                const state_data = loaded.plugin_states.get(state_ref.path) orelse continue;
                if (device.device_role == .instrument or device.device_role == .noteFX) {
                    if (track_plugins[t].handle) |handle| {
                        loadPluginStateFromData(handle.plugin, state_data);
                    }
                } else if (device.device_role == .audioFX and fx_slot < ui.max_fx_slots) {
                    if (track_fx[t][fx_slot].handle) |handle| {
                        loadPluginStateFromData(handle.plugin, state_data);
                    }
                    fx_slot += 1;
                }
            }
        }
    }
}

fn findPluginInCatalog(catalog: *const plugins.PluginCatalog, device_id: []const u8) i32 {
    for (catalog.entries.items, 0..) |entry, idx| {
        if (entry.id) |id| {
            if (std.mem.eql(u8, id, device_id)) {
                return @intCast(idx);
            }
        }
    }
    return 0; // Default to "None"
}

fn applyLanes(
    state: *ui.State,
    lanes: *const dawproject.Lanes,
    tracks: []const dawproject.Track,
    instrument_device_ids: *const [ui.track_count]?[]const u8,
    fx_device_ids: *const [ui.track_count][ui.max_fx_slots]?[]const u8,
) !void {
    // Find track index for this lane
    var track_idx: ?usize = null;
    if (lanes.track) |track_id| {
        for (tracks, 0..) |track, t| {
            if (std.mem.eql(u8, track.id, track_id)) {
                track_idx = t;
                break;
            }
        }
    }

    // Process clips in this lane
    if (lanes.clips) |clips| {
        if (track_idx) |t| {
            if (t < ui.track_count) {
                for (clips.clips, 0..) |clip, s| {
                    if (s >= ui.scene_count) break;

                    // Set clip slot state
                    state.session.clips[t][s] = .{
                        .state = .stopped,
                        .length_beats = @floatCast(clip.duration),
                    };

                    // Add notes
                    var piano = &state.piano_clips[t][s];
                    piano.length_beats = @floatCast(clip.duration);
                    piano.notes.clearRetainingCapacity();
                    if (clip.notes) |notes| {
                        for (notes.notes) |note| {
                            piano.addNoteWithVelocity(
                                @intCast(note.key),
                                @floatCast(note.time),
                                @floatCast(note.duration),
                                @floatCast(note.vel),
                                @floatCast(note.rel),
                            ) catch continue;
                        }
                    }
                    const track = tracks[t];
                    const channel = track.channel;
                    const vol_id = if (channel) |ch| if (ch.volume) |vol| vol.id else null else null;
                    const pan_id = if (channel) |ch| if (ch.pan) |pan| pan.id else null else null;
                    try applyAutomationToClip(
                        state.allocator,
                        piano,
                        clip.points,
                        instrument_device_ids[t],
                        &fx_device_ids[t],
                        vol_id,
                        pan_id,
                    );
                }
            }
        }
    }

    // Recurse into child lanes
    for (lanes.children) |child| {
        try applyLanes(state, &child, tracks, instrument_device_ids, fx_device_ids);
    }
}

fn applyScenes(
    state: *ui.State,
    scenes: []const dawproject.Scene,
    tracks: []const dawproject.Track,
    master_track: ?dawproject.Track,
    instrument_device_ids: *const [ui.track_count]?[]const u8,
    fx_device_ids: *const [ui.track_count][ui.max_fx_slots]?[]const u8,
) !void {
    const scene_count = @min(scenes.len, ui.scene_count);
    for (0..scene_count) |s| {
        const scene = scenes[s];
        for (scene.clip_slots) |slot| {
            var track_idx: ?usize = null;
            for (tracks, 0..) |track, t| {
                if (std.mem.eql(u8, track.id, slot.track)) {
                    track_idx = t;
                    break;
                }
            }
            if (track_idx == null and master_track != null) {
                if (std.mem.eql(u8, master_track.?.id, slot.track)) {
                    continue;
                }
            }
            if (track_idx) |t| {
                if (t >= ui.track_count) continue;
                if (slot.clip) |clip| {
                    state.session.clips[t][s] = .{
                        .state = .stopped,
                        .length_beats = @floatCast(clip.duration),
                    };

                    var piano = &state.piano_clips[t][s];
                    piano.length_beats = @floatCast(clip.duration);
                    piano.notes.clearRetainingCapacity();
                    if (clip.notes) |notes| {
                        for (notes.notes) |note| {
                            piano.addNoteWithVelocity(
                                @intCast(note.key),
                                @floatCast(note.time),
                                @floatCast(note.duration),
                                @floatCast(note.vel),
                                @floatCast(note.rel),
                            ) catch continue;
                        }
                    }
                    const track = tracks[t];
                    const channel = track.channel;
                    const vol_id = if (channel) |ch| if (ch.volume) |vol| vol.id else null else null;
                    const pan_id = if (channel) |ch| if (ch.pan) |pan| pan.id else null else null;
                    try applyAutomationToClip(
                        state.allocator,
                        piano,
                        clip.points,
                        instrument_device_ids[t],
                        &fx_device_ids[t],
                        vol_id,
                        pan_id,
                    );
                }
            }
        }
    }
}

fn applyAutomationToClip(
    allocator: std.mem.Allocator,
    piano: *ui.PianoRollClip,
    points_list: []const dawproject.Points,
    instrument_device_id: ?[]const u8,
    fx_device_ids: *const [ui.max_fx_slots]?[]const u8,
    track_volume_param_id: ?[]const u8,
    track_pan_param_id: ?[]const u8,
) !void {
    piano.automation.clear(allocator);
    for (points_list) |points| {
        var new_lane = ui.AutomationLane{
            .target_kind = .parameter,
            .target_id = "",
            .param_id = null,
            .unit = if (points.unit) |unit| try allocator.dupe(u8, unit.toString()) else null,
            .points = .{},
        };
        if (points.target.parameter) |param_id| {
            if (track_volume_param_id != null and std.mem.eql(u8, param_id, track_volume_param_id.?)) {
                new_lane.target_kind = .track;
                new_lane.target_id = try allocator.dupe(u8, "track");
                new_lane.param_id = try allocator.dupe(u8, "volume");
            } else if (track_pan_param_id != null and std.mem.eql(u8, param_id, track_pan_param_id.?)) {
                new_lane.target_kind = .track;
                new_lane.target_id = try allocator.dupe(u8, "track");
                new_lane.param_id = try allocator.dupe(u8, "pan");
            } else if (parseAutomationParamId(param_id, instrument_device_id, fx_device_ids)) |parsed| {
                if (parsed.fx_index) |fx_idx| {
                    new_lane.target_id = try std.fmt.allocPrint(allocator, "fx{d}", .{fx_idx});
                } else {
                    new_lane.target_id = try allocator.dupe(u8, "instrument");
                }
                new_lane.param_id = try allocator.dupe(u8, parsed.param_id);
            } else {
                new_lane.param_id = try allocator.dupe(u8, param_id);
            }
        }
        for (points.points) |point| {
            try new_lane.points.append(allocator, .{
                .time = @floatCast(point.time),
                .value = @floatCast(point.value),
            });
        }
        try piano.automation.lanes.append(allocator, new_lane);
    }
}

const ParsedAutomationParam = struct {
    fx_index: ?usize = null,
    param_id: []const u8,
};

fn parseAutomationParamId(
    param_id: []const u8,
    instrument_device_id: ?[]const u8,
    fx_device_ids: *const [ui.max_fx_slots]?[]const u8,
) ?ParsedAutomationParam {
    const marker = std.mem.indexOf(u8, param_id, "_p") orelse return null;
    const device_id = param_id[0..marker];
    const raw_param = param_id[marker + 2 ..];
    if (instrument_device_id) |inst_id| {
        if (std.mem.eql(u8, inst_id, device_id)) {
            return .{ .fx_index = null, .param_id = raw_param };
        }
    }
    for (fx_device_ids, 0..) |fx_id, idx| {
        if (fx_id) |id| {
            if (std.mem.eql(u8, id, device_id)) {
                return .{ .fx_index = idx, .param_id = raw_param };
            }
        }
    }
    return null;
}

fn loadPluginStateFromData(plugin: *const clap.Plugin, data: []const u8) void {
    const ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse return;
    const ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(ext_raw));

    const payload = stripClapPresetHeader(data) orelse data;
    var stream = MemoryIStream.init(payload);
    stream.stream.context = &stream;
    _ = ext.load(plugin, &stream.stream);
}

fn stripClapPresetHeader(data: []const u8) ?[]const u8 {
    if (data.len < 8) return null;
    if (!std.mem.eql(u8, data[0..4], "clap")) return null;
    const len: usize = (@as(usize, data[4]) << 24) |
        (@as(usize, data[5]) << 16) |
        (@as(usize, data[6]) << 8) |
        @as(usize, data[7]);
    if (data.len < 8 + len) return null;
    return data[(8 + len)..];
}

const MemoryOStream = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    stream: clap.OStream,

    pub fn init(allocator: std.mem.Allocator) MemoryOStream {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .stream = .{
                .context = undefined,
                .write = write,
            },
        };
    }

    fn write(stream: *const clap.OStream, buffer: *const anyopaque, size: u64) callconv(.c) clap.OStream.Result {
        const self: *MemoryOStream = @ptrCast(@alignCast(stream.context));
        const bytes = @as([*]const u8, @ptrCast(buffer))[0..@intCast(size)];
        self.buffer.appendSlice(self.allocator, bytes) catch return .write_error;
        return @enumFromInt(@as(i64, @intCast(bytes.len)));
    }
};

const MemoryIStream = struct {
    data: []const u8,
    offset: usize,
    stream: clap.IStream,

    pub fn init(data: []const u8) MemoryIStream {
        return .{
            .data = data,
            .offset = 0,
            .stream = .{
                .context = undefined,
                .read = read,
            },
        };
    }

    fn read(stream: *const clap.IStream, buffer: *anyopaque, size: u64) callconv(.c) clap.IStream.Result {
        const self: *MemoryIStream = @ptrCast(@alignCast(stream.context));
        if (self.offset >= self.data.len) {
            return .end_of_file;
        }

        const remaining = self.data.len - self.offset;
        const to_read = @min(remaining, @as(usize, @intCast(size)));
        const dest = @as([*]u8, @ptrCast(buffer))[0..to_read];
        @memcpy(dest, self.data[self.offset..][0..to_read]);
        self.offset += to_read;
        return @enumFromInt(@as(i64, @intCast(to_read)));
    }
};
