const builtin = @import("builtin");
const std = @import("std");

const clap = @import("clap-bindings");
const zaudio = @import("zaudio");
const zgui = @import("zgui");
const objc = @import("objc");

const ui = @import("ui.zig");
const audio_engine = @import("audio_engine.zig");
const audio_graph = @import("audio_graph.zig");
const thread_pool = @import("thread_pool.zig");
const zsynth = @import("zsynth-core");
const plugins = @import("plugins.zig");
const project = @import("project.zig");

const SampleRate = 44_100;
const Channels = 2;
const MaxFrames = 128;

/// Thread-local flag set when we're in an audio processing context
pub threadlocal var is_audio_thread: bool = false;

const Host = struct {
    clap_host: clap.Host,
    pool: ?*thread_pool.ThreadPool = null,
    shared_state: ?*audio_engine.SharedState = null,
    main_thread_id: std.Thread.Id = undefined,

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
        // Disabled for comparison testing
        // if (std.mem.eql(u8, std.mem.span(id), clap.ext.thread_pool.id)) {
        //     return &thread_pool_ext;
        // }
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
        const pool = self.pool orelse return false;

        const plugin = audio_graph.current_processing_plugin orelse return false;

        const ext_raw = plugin.getExtension(plugin, clap.ext.thread_pool.id) orelse return false;
        const ext: *const clap.ext.thread_pool.Plugin = @ptrCast(@alignCast(ext_raw));

        pool.execute(plugin, ext.exec, task_count);
        return true;
    }

    fn _requestRestart(_: *const clap.Host) callconv(.c) void {}
    fn _requestProcess(_: *const clap.Host) callconv(.c) void {}
    fn _requestCallback(_: *const clap.Host) callconv(.c) void {}
};

const PluginHandle = struct {
    lib: std.DynLib,
    entry: *const clap.Entry,
    factory: *const clap.PluginFactory,
    plugin: *const clap.Plugin,
    plugin_path_z: [:0]u8,
    started: bool,
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
            .started = false,
            .activated = true,
        };
    }

    pub fn startProcessing(self: *PluginHandle) bool {
        if (self.started) return true;
        if (!self.plugin.startProcessing(self.plugin)) {
            return false;
        }
        self.started = true;
        return true;
    }

    pub fn deinit(self: *PluginHandle, allocator: std.mem.Allocator) void {
        if (self.started) {
            self.plugin.stopProcessing(self.plugin);
        }
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
    gui_window: ?*objc.app_kit.Window = null,
    gui_view: ?*objc.app_kit.View = null,
    gui_open: bool = false,
    choice_index: i32 = -1,
};

const AppWindow = struct {
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
};

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

        const now = end;
        const should_print = if (perf_last_print) |last| now.since(last) >= std.time.ns_per_s else true;
        if (should_print and perf_count > 0) {
            const avg_us = perf_total_us / perf_count;
            const budget_us = @as(u64, frame_count) * 1_000_000 / SampleRate;
            std.debug.print("audio: avg={d}us max={d}us budget={d}us ({d}%)\n", .{ avg_us, perf_max_us, budget_us, avg_us * 100 / budget_us });

            // Adaptive sleep: adjust based on max usage with safety margin
            // Max sleep capped at 200µs to limit worst-case wake latency on play
            if (engine.jobs) |jobs| {
                const usage_pct = perf_max_us * 100 / budget_us;
                const sleep_ns: u64 = if (usage_pct >= 50)
                    10_000 // 10µs - high load, stay responsive
                else if (usage_pct >= 30)
                    50_000 // 50µs
                else
                    200_000; // 200µs - idle, but not too long for quick wake
                jobs.setSleepNs(sleep_ns);
            }

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

    if (builtin.os.tag != .macos) {
        return error.UnsupportedOs;
    }

    var host = Host.init();
    host.clap_host.host_data = &host;

    const cpu_count = std.Thread.getCpuCount() catch 4;
    host.pool = try thread_pool.ThreadPool.init(allocator, cpu_count);
    defer host.pool.?.deinit();

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

    for (synths[0..synth_count]) |plugin| {
        if (!plugin.plugin.startProcessing(&plugin.plugin)) {
            std.log.warn("Failed to start processing for built-in synth", .{});
        }
    }
    for (&track_plugins) |*track| {
        if (track.handle) |*handle| {
            if (!handle.startProcessing()) {
                std.log.warn("Failed to start processing for track plugin", .{});
            }
        }
    }

    var engine = try audio_engine.AudioEngine.init(allocator, SampleRate, MaxFrames);
    defer engine.deinit();
    host.shared_state = &engine.shared;
    engine.pool = host.pool;

    // Initialize libz_jobs work-stealing queue
    var jobs = try audio_graph.JobQueue.init(allocator, io);
    defer jobs.deinit();
    try jobs.start();
    defer jobs.stop();
    defer jobs.join();
    engine.jobs = &jobs;

    engine.updateFromUi(&state);
    engine.updatePlugins(collectTrackPlugins(&catalog, &track_plugins, &state, synths));

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

    var app_window = try AppWindow.init("flux", 1280, 720);
    defer app_window.deinit();

    zgui.init(allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    _ = zgui.io.addFontFromMemory(zsynth.font, std.math.floor(16.0 * app_window.scale_factor));
    zgui.getStyle().scaleAllSizes(app_window.scale_factor);
    zgui.plot.init();
    defer zgui.plot.deinit();
    zgui.backend.init(app_window.view, app_window.device);
    defer zgui.backend.deinit();

    var last_time = try std.time.Instant.now();

    std.log.info("flux running (Ctrl+C to quit)", .{});
    while (app_window.window.isVisible()) {
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

        sleepNs(io, 5 * std.time.ns_per_ms);
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

    for (&track_plugins) |*track| {
        unloadPlugin(track, allocator);
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

    for (track_plugins, 0..) |*track, t| {
        const choice = state.track_plugins[t].choice_index;
        const wants_gui = state.track_plugins[t].gui_open;

        const entry = catalog.entryForIndex(choice);
        const kind = if (entry) |item| item.kind else .none;
        if (kind == .none or kind == .divider) {
            if (track.handle != null) {
                closePluginGui(track);
                prepareUnload(shared, t, io);
                unloadPlugin(track, allocator);
            }
            track.choice_index = choice;
            continue;
        }

        if (track.choice_index != choice) {
            if (track.handle != null) {
                closePluginGui(track);
                prepareUnload(shared, t, io);
                unloadPlugin(track, allocator);
            }
            track.choice_index = choice;
        }

        if (track.handle == null) {
            const path = entry.?.path orelse return error.PluginMissingPath;
            track.handle = try PluginHandle.init(allocator, host, path, entry.?.id);
            track.gui_ext = getGuiExt(track.handle.?);
        }
        if (start_processing and track.handle != null) {
            if (!track.handle.?.startProcessing()) {
                std.log.warn("Failed to start processing for track plugin", .{});
            }
        }

        if (wants_gui and !track.gui_open) {
            if (track.gui_ext) |gui_ext| {
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

fn unloadPlugin(track: *TrackPlugin, allocator: std.mem.Allocator) void {
    if (track.handle) |*handle| {
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
    var api_ptr: [*:0]const u8 = clap.ext.gui.window_api.cocoa;
    _ = gui_ext.getPreferredApi(plugin, &api_ptr, &is_floating);

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
                const view = objc.app_kit.View.alloc().initWithFrame(rect);
                window.setContentView(view);
                window.makeKeyAndOrderFront(null);
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
                track.gui_window = window;
                track.gui_view = view;
            }
        },
        .linux => {},
        else => {},
    }

    if (!gui_ext.show(plugin)) {
        if (track.gui_window) |window| {
            window.setIsVisible(false);
            window.release();
            track.gui_window = null;
        }
        if (track.gui_view) |view| {
            view.release();
            track.gui_view = null;
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
    if (track.gui_window) |window| {
        window.setIsVisible(false);
        window.release();
        track.gui_window = null;
    }
    if (track.gui_view) |view| {
        view.release();
        track.gui_view = null;
    }
    track.gui_open = false;
}
