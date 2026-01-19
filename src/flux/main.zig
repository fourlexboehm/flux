const builtin = @import("builtin");
const std = @import("std");

const clap = @import("clap-bindings");
const zaudio = @import("zaudio");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const objc = if (builtin.os.tag == .macos) @import("objc") else struct {};

const ui = @import("ui.zig");
const audio_engine = @import("audio_engine.zig");
const audio_graph = @import("audio_graph.zig");
const zsynth = @import("zsynth-core");
const plugins = @import("plugins.zig");
const project = @import("project.zig");
const dawproject = @import("dawproject.zig");
const file_dialog = @import("file_dialog.zig");

const SampleRate = 44_100;
const Channels = 2;
const MaxFrames = 128;

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

    const thread_pool_ext = clap.ext.thread_pool.Host{
        .requestExec = _requestExec,
    };

    const thread_check_ext = clap.ext.thread_check.Host{
        .isMainThread = _isMainThread,
        .isAudioThread = _isAudioThread,
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

        if (!plugin.activate(plugin, SampleRate, 1, MaxFrames)) return error.PluginActivateFailed;

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

const TrackPlugin = struct {
    handle: ?PluginHandle = null,
    gui_ext: ?*const clap.ext.gui.Plugin = null,
    gui_window: ?*anyopaque = null,
    gui_view: ?*anyopaque = null,
    gui_open: bool = false,
    choice_index: i32 = -1,
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

    if (frame_count > MaxFrames) {
        std.log.warn("Audio callback frame_count={} (requested {})", .{ frame_count, MaxFrames });
    }
    const user_data = zaudio.Device.getUserData(device) orelse return;
    const engine: *audio_engine.AudioEngine = @ptrCast(@alignCast(user_data));
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

        // Print stats once per second
        const now = end;
        const should_print = if (perf_last_print) |last| now.since(last) >= std.time.ns_per_s else true;
        if (should_print and perf_count > 0) {
            const avg_us = perf_total_us / perf_count;
            std.debug.print("audio: avg={d}us max={d}us budget={d}us ({d}%)\n", .{ avg_us, perf_max_us, budget_us, avg_us * 100 / budget_us });
            perf_total_us = 0;
            perf_max_us = 0;
            perf_count = 0;
            perf_last_print = now;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const project_path = project.default_path;

    var host = Host.init();
    host.clap_host.host_data = &host;

    const cpu_count = std.Thread.getCpuCount() catch 4;
    host.jobs_fanout = @intCast(if (cpu_count > 1) @min(cpu_count - 1, 16) else 0);

    var track_plugins: [ui.track_count]TrackPlugin = undefined;
    for (&track_plugins) |*track| {
        track.* = .{};
    }

    zaudio.init(allocator);
    defer zaudio.deinit();

    var catalog = try plugins.discover(allocator, io);
    defer catalog.deinit();

    var state = ui.State.init(allocator);
    defer state.deinit();
    state.plugin_items = catalog.items_z;
    state.plugin_divider_index = catalog.divider_index;
    var synths: [ui.track_count]*zsynth.Plugin = undefined;
    var synth_count: usize = 0;
    errdefer {
        for (synths[0..synth_count]) |plugin| {
            plugin.deinit();
        }
    }
    for (0..ui.track_count) |track_index| {
        const plugin = try zsynth.Plugin.init(allocator, &host.clap_host);
        if (!plugin.plugin.init(&plugin.plugin)) return error.PluginInitFailed;
        if (!plugin.plugin.activate(&plugin.plugin, SampleRate, 1, MaxFrames)) {
            return error.PluginActivateFailed;
        }
        synths[track_index] = plugin;
        synth_count += 1;
    }
    defer {
        for (synths[0..synth_count]) |plugin| {
            plugin.deinit();
        }
    }
    state.zsynth = synths[0];

    const loaded_project = project.load(allocator, io, project_path) catch |err| blk: {
        std.log.warn("Failed to load project: {}", .{err});
        break :blk null;
    };
    if (loaded_project) |parsed| {
        defer parsed.deinit();
        try project.apply(&parsed.value, &state, &catalog);
        state.zsynth = synths[state.selectedTrack()];
        try syncTrackPlugins(allocator, &host.clap_host, &track_plugins, &state, &catalog, null, io, false);
        const loaded_plugins = collectTrackPlugins(&catalog, &track_plugins, &state, synths);
        project.applyDeviceStates(allocator, &parsed.value, loaded_plugins);
    }

    var engine = try audio_engine.AudioEngine.init(allocator, SampleRate, MaxFrames);
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
    engine.updatePlugins(collectTrackPlugins(&catalog, &track_plugins, &state, synths));

    // Request startProcessing for all loaded plugins (will be called from audio thread)
    for (0..ui.track_count) |t| {
        engine.shared.requestStartProcessing(t);
    }

    var device_config = zaudio.Device.Config.init(.playback);
    device_config.playback.format = zaudio.Format.float32;
    device_config.playback.channels = Channels;
    device_config.sample_rate = SampleRate;
    device_config.period_size_in_frames = MaxFrames;
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

    var last_time = try std.time.Instant.now();

    std.log.info("flux running (Ctrl+C to quit)", .{});
    switch (builtin.os.tag) {
        .macos => {
            var app_window = try AppWindow.init("flux", 1280, 720);
            defer app_window.deinit();

            _ = zgui.io.addFontFromMemory(zsynth.font, std.math.floor(16.0 * app_window.scale_factor));
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
                state.zsynth = synths[state.selectedTrack()];
                updateDeviceState(&state, &catalog, &track_plugins);
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
                ui.draw(&state, 1.0);
                handleFileRequests(allocator, io, &state, &catalog, &track_plugins, &host.clap_host, &engine.shared, synths);
                engine.updateFromUi(&state);
                try syncTrackPlugins(allocator, &host.clap_host, &track_plugins, &state, &catalog, &engine.shared, io, true);
                engine.updatePlugins(collectTrackPlugins(&catalog, &track_plugins, &state, synths));
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
                const target_fps: u32 = if (state.playing or interactive or any_plugin_gui_open) 60 else 20;
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
            _ = zgui.io.addFontFromMemory(zsynth.font, std.math.floor(16.0 * ui_scale));
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
                state.zsynth = synths[state.selectedTrack()];
                updateDeviceState(&state, &catalog, &track_plugins);
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

                gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0.08, 0.08, 0.1, 1.0 });
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
                ui.draw(&state, 1.0);
                handleFileRequests(allocator, io, &state, &catalog, &track_plugins, &host.clap_host, &engine.shared, synths);
                engine.updateFromUi(&state);
                try syncTrackPlugins(allocator, &host.clap_host, &track_plugins, &state, &catalog, &engine.shared, io, true);
                engine.updatePlugins(collectTrackPlugins(&catalog, &track_plugins, &state, synths));
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
                const target_fps: u32 = if (state.playing or interactive or any_plugin_gui_open) 60 else 20;
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

    const plugins_for_save = collectTrackPlugins(&catalog, &track_plugins, &state, synths);
    project.save(allocator, io, project_path, &state, &catalog, plugins_for_save) catch |err| {
        std.log.warn("Failed to save project: {}", .{err});
    };

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
) void {
    const choice = state.track_plugins[state.selectedTrack()].choice_index;
    const entry = catalog.entryForIndex(choice);
    if (entry == null or entry.?.kind == .none or entry.?.kind == .divider) {
        state.device_kind = .none;
        state.device_clap_plugin = null;
        state.device_clap_name = "";
        return;
    }

    switch (entry.?.kind) {
        .builtin => {
            state.device_kind = .builtin;
            state.device_clap_plugin = null;
            state.device_clap_name = "";
        },
        .clap => {
            state.device_kind = .clap;
            state.device_clap_name = entry.?.name;
            const handle = track_plugins[state.selectedTrack()].handle;
            state.device_clap_plugin = if (handle) |h| h.plugin else null;
        },
        else => {
            state.device_kind = .none;
            state.device_clap_plugin = null;
            state.device_clap_name = "";
        },
    }
}

fn collectTrackPlugins(
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [ui.track_count]TrackPlugin,
    state: *const ui.State,
    synths: [ui.track_count]*zsynth.Plugin,
) [ui.track_count]?*const clap.Plugin {
    var plugins_out: [ui.track_count]?*const clap.Plugin = [_]?*const clap.Plugin{null} ** ui.track_count;
    for (0..ui.track_count) |t| {
        const choice = state.track_plugins[t].choice_index;
        const entry = catalog.entryForIndex(choice);
        if (entry == null) {
            continue;
        }
        switch (entry.?.kind) {
            .builtin => {
                plugins_out[t] = &synths[t].plugin;
            },
            .clap => {
                plugins_out[t] = if (track_plugins[t].handle) |handle| handle.plugin else null;
            },
            else => {},
        }
    }
    return plugins_out;
}

fn syncTrackPlugins(
    allocator: std.mem.Allocator,
    host: *const clap.Host,
    track_plugins: *[ui.track_count]TrackPlugin,
    state: *ui.State,
    catalog: *const plugins.PluginCatalog,
    shared: ?*audio_engine.SharedState,
    io: std.Io,
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
        if (kind == .none or kind == .divider) {
            if (track.handle != null) {
                closePluginGui(track);
                prepareUnload(shared, t, io);
                unloadPlugin(track, allocator, shared, t);
            }
            track.choice_index = choice;
            continue;
        }

        if (track.choice_index != choice) {
            if (track.handle != null) {
                closePluginGui(track);
                prepareUnload(shared, t, io);
                unloadPlugin(track, allocator, shared, t);
            }
            track.choice_index = choice;
        }

        if (track.handle == null) {
            const path = entry.?.path orelse return error.PluginMissingPath;
            track.handle = try PluginHandle.init(allocator, host, path, entry.?.id);
            track.gui_ext = getGuiExt(track.handle.?);
            // Request startProcessing from audio thread (CLAP requires audio thread for this call)
            if (start_processing) {
                if (shared) |s| {
                    s.requestStartProcessing(t);
                }
            }
        }

        if (wants_gui and !track.gui_open) {
            if (track.gui_ext) |gui_ext| {
                // Close all other plugin GUI windows first (but keep their gui_open state)
                for (track_plugins) |*other_track| {
                    if (other_track.gui_open) {
                        closePluginGui(other_track);
                    }
                }
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

fn unloadPlugin(track: *TrackPlugin, allocator: std.mem.Allocator, shared: ?*audio_engine.SharedState, track_index: usize) void {
    if (track.handle) |*handle| {
        // Check if plugin was started via shared state and call stopProcessing if needed
        if (shared) |s| {
            if (s.isPluginStarted(track_index)) {
                // Set audio thread flag for stopProcessing (per CLAP spec, host controls
                // which thread is "audio thread" and can designate any thread when only
                // one is active. The audio device is already stopped at this point.)
                const was_audio = is_audio_thread;
                is_audio_thread = true;
                defer is_audio_thread = was_audio;
                handle.plugin.stopProcessing(handle.plugin);
                s.clearPluginStarted(track_index);
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
                // Set window to floating level so it stays above the main window
                const NSFloatingWindowLevel: c_long = 3;
                objc.objc.msgSend(window, "setLevel:", void, .{NSFloatingWindowLevel});
                const view = objc.app_kit.View.alloc().initWithFrame(rect);
                window.setContentView(view);
                // Use orderFront instead of makeKeyAndOrderFront to keep keyboard focus on main window
                objc.objc.msgSend(window, "orderFront:", void, .{@as(?*anyopaque, null)});
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
    host: *const clap.Host,
    shared: ?*audio_engine.SharedState,
    synths: [ui.track_count]*zsynth.Plugin,
) void {
    // Handle save request
    if (state.save_project_request) {
        state.save_project_request = false;
        handleSaveProject(allocator, io, state, catalog, track_plugins) catch |err| {
            std.log.err("Failed to save project: {}", .{err});
        };
    }

    // Handle load request
    if (state.load_project_request) {
        state.load_project_request = false;
        handleLoadProject(allocator, io, state, catalog, track_plugins, host, shared, synths) catch |err| {
            std.log.err("Failed to load project: {}", .{err});
        };
    }
}

fn handleSaveProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *const ui.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [ui.track_count]TrackPlugin,
) !void {
    // Show save dialog
    const path = file_dialog.saveFile(
        allocator,
        io,
        "Save DAWproject",
        "project.dawproject",
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

    // Collect plugin states
    var plugin_states: std.ArrayList(dawproject.PluginStateFile) = .empty;
    defer plugin_states.deinit(allocator);

    for (track_plugins, 0..) |track, t| {
        if (track.handle) |handle| {
            if (capturePluginStateForDawproject(allocator, handle.plugin, t)) |ps| {
                plugin_states.append(allocator, ps) catch continue;
            }
        }
    }

    // Save the project
    dawproject.save(allocator, io, path.?, state, catalog, plugin_states.items) catch |err| {
        std.log.err("Failed to write dawproject: {}", .{err});
        return;
    };

    std.log.info("Saved project to: {s}", .{path.?});
}

fn handleLoadProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *ui.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *[ui.track_count]TrackPlugin,
    host: *const clap.Host,
    shared: ?*audio_engine.SharedState,
    synths: [ui.track_count]*zsynth.Plugin,
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
    applyDawprojectToState(allocator, &loaded, state, catalog, track_plugins, host, shared, io, synths) catch |err| {
        std.log.err("Failed to apply dawproject: {}", .{err});
        return;
    };

    std.log.info("Loaded project from: {s}", .{path.?});
}

fn capturePluginStateForDawproject(allocator: std.mem.Allocator, plugin: *const clap.Plugin, track_index: usize) ?dawproject.PluginStateFile {
    const ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse return null;
    const ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(ext_raw));

    var stream = MemoryOStream.init(allocator);
    stream.stream.context = &stream;
    defer stream.buffer.deinit(allocator);

    if (!ext.save(plugin, &stream.stream)) {
        return null;
    }

    const data = allocator.dupe(u8, stream.buffer.items) catch return null;
    var path_buf: [64]u8 = undefined;
    const plugin_path = std.fmt.bufPrint(&path_buf, "plugins/track{d}.clap-preset", .{track_index}) catch return null;

    return .{
        .path = allocator.dupe(u8, plugin_path) catch return null,
        .data = data,
    };
}

fn applyDawprojectToState(
    allocator: std.mem.Allocator,
    loaded: *dawproject.LoadedProject,
    state: *ui.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *[ui.track_count]TrackPlugin,
    host: *const clap.Host,
    shared: ?*audio_engine.SharedState,
    io: std.Io,
    synths: [ui.track_count]*zsynth.Plugin,
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
                const device = channel.devices[0];
                // Find matching plugin in catalog
                const choice = findPluginInCatalog(catalog, device.device_id);
                state.track_plugins[t].choice_index = choice;
                state.track_plugins[t].last_valid_choice = choice;
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

    // Apply arrangement lanes (clips)
    if (proj.arrangement) |arr| {
        if (arr.lanes) |root_lanes| {
            try applyLanes(state, &root_lanes, proj.tracks);
        }
    }

    // Sync track plugins after state update
    try syncTrackPlugins(allocator, host, track_plugins, state, catalog, shared, io, true);

    // Load plugin states from dawproject
    for (0..track_count) |t| {
        if (track_plugins[t].handle) |handle| {
            const track = proj.tracks[t];
            if (track.channel) |channel| {
                if (channel.devices.len > 0) {
                    const device = channel.devices[0];
                    if (device.state) |state_ref| {
                        if (loaded.plugin_states.get(state_ref.path)) |state_data| {
                            loadPluginStateFromData(handle.plugin, state_data);
                        }
                    }
                }
            }
        }
    }

    _ = synths;
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

fn applyLanes(state: *ui.State, lanes: *const dawproject.Lanes, tracks: []const dawproject.Track) !void {
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
                    if (clip.notes) |notes| {
                        var piano = &state.piano_clips[t][s];
                        piano.length_beats = @floatCast(clip.duration);
                        piano.notes.clearRetainingCapacity();

                        for (notes.notes) |note| {
                            piano.notes.append(state.allocator, .{
                                .pitch = @intCast(note.key),
                                .start = @floatCast(note.time),
                                .duration = @floatCast(note.duration),
                            }) catch continue;
                        }
                    }
                }
            }
        }
    }

    // Recurse into child lanes
    for (lanes.children) |child| {
        try applyLanes(state, &child, tracks);
    }
}

fn loadPluginStateFromData(plugin: *const clap.Plugin, data: []const u8) void {
    const ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse return;
    const ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(ext_raw));

    var stream = MemoryIStream.init(data);
    stream.stream.context = &stream;
    _ = ext.load(plugin, &stream.stream);
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
