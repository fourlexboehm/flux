const builtin = @import("builtin");
const std = @import("std");

const clap = @import("clap-bindings");
const zaudio = @import("zaudio");
const zgui = @import("zgui");
const objc = @import("objc");

const ui = @import("ui.zig");
const audio_engine = @import("audio_engine.zig");
const zsynth = @import("zsynth-core");

const SampleRate = 48_000;
const Channels = 2;
const MaxFrames = 1024;

const Host = struct {
    clap_host: clap.Host,

    pub fn init() Host {
        return .{
            .clap_host = .{
                .clap_version = clap.version,
                .host_data = undefined,
                .name = "zdaw",
                .vendor = "gearmulator",
                .url = null,
                .version = "0.1",
                .getExtension = _getExtension,
                .requestRestart = _requestRestart,
                .requestProcess = _requestProcess,
                .requestCallback = _requestCallback,
            },
        };
    }

    fn _getExtension(_: *const clap.Host, _: [*:0]const u8) callconv(.c) ?*const anyopaque {
        return null;
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

    pub fn init(allocator: std.mem.Allocator, host: *const clap.Host) !PluginHandle {
        const plugin_path = try defaultPluginPath();
        const plugin_path_z = try allocator.dupeZ(u8, plugin_path);
        errdefer allocator.free(plugin_path_z);

        var lib = try std.DynLib.open(plugin_path);
        errdefer lib.close();

        const entry = lib.lookup(*const clap.Entry, "clap_entry") orelse return error.MissingClapEntry;
        if (!entry.init(plugin_path_z)) return error.EntryInitFailed;
        errdefer entry.deinit();

        const factory_raw = entry.getFactory(clap.PluginFactory.id) orelse return error.MissingPluginFactory;
        const factory: *const clap.PluginFactory = @ptrCast(@alignCast(factory_raw));
        const plugin_count = factory.getPluginCount(factory);
        if (plugin_count == 0) return error.NoPluginsFound;

        const desc = factory.getPluginDescriptor(factory, 0) orelse return error.MissingPluginDescriptor;
        const plugin = factory.createPlugin(factory, host, desc.id) orelse return error.PluginCreateFailed;

        if (!plugin.init(plugin)) return error.PluginInitFailed;

        if (!plugin.activate(plugin, SampleRate, 1, MaxFrames)) return error.PluginActivateFailed;
        if (!plugin.startProcessing(plugin)) return error.PluginStartFailed;

        return .{
            .lib = lib,
            .entry = entry,
            .factory = factory,
            .plugin = plugin,
            .plugin_path_z = plugin_path_z,
            .started = true,
            .activated = true,
        };
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

fn dataCallback(
    device: *zaudio.Device,
    output: ?*anyopaque,
    _: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    const user_data = zaudio.Device.getUserData(device) orelse return;
    const engine: *audio_engine.AudioEngine = @ptrCast(@alignCast(user_data));
    engine.render(device, output, frame_count);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    if (builtin.os.tag != .macos) {
        return error.UnsupportedOs;
    }

    var host = Host.init();
    host.clap_host.host_data = &host;

    var track_plugins: [ui.track_count]TrackPlugin = undefined;
    for (&track_plugins) |*track| {
        track.* = .{};
    }

    zaudio.init(allocator);
    defer zaudio.deinit();

    var state = ui.State.init();
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

    var engine = try audio_engine.AudioEngine.init(allocator, SampleRate, MaxFrames, synths);
    defer engine.deinit();
    engine.updateFromUi(&state);

    var device_config = zaudio.Device.Config.init(.playback);
    device_config.playback.format = zaudio.Format.float32;
    device_config.playback.channels = Channels;
    device_config.sample_rate = SampleRate;
    device_config.data_callback = dataCallback;
    device_config.user_data = &engine;

    var device = try zaudio.Device.create(null, device_config);
    defer device.destroy();
    try device.start();

    var app_window = try AppWindow.init("zdaw", 1280, 720);
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

    std.log.info("zdaw running (Ctrl+C to quit)", .{});
    while (app_window.window.isVisible()) {
        const now = std.time.Instant.now() catch last_time;
        const delta_ns = now.since(last_time);
        last_time = now;
        if (delta_ns > 0) {
            const dt = @as(f64, @floatFromInt(delta_ns)) / std.time.ns_per_s;
            ui.tick(&state, dt);
        }
        state.zsynth = synths[state.selected_track];
        engine.updateFromUi(&state);
        const wants_keyboard = zgui.io.getWantCaptureKeyboard();
        if (!wants_keyboard and zgui.isKeyPressed(.space, false)) {
            state.playing = !state.playing;
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
        ui.draw(&state, 1.0);
        try syncTrackPlugins(allocator, &host.clap_host, &track_plugins, &state);
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
}

fn defaultPluginPath() ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => "zig-out/lib/ZSynth.clap/Contents/MacOS/ZSynth",
        .linux => "zig-out/lib/zsynth.clap",
        else => error.UnsupportedOs,
    };
}

fn sleepNs(io: std.Io, ns: u64) void {
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromNanoseconds(@intCast(ns)) }, io) catch {};
}

fn syncTrackPlugins(
    allocator: std.mem.Allocator,
    host: *const clap.Host,
    track_plugins: *[ui.track_count]TrackPlugin,
    state: *ui.State,
) !void {
    for (track_plugins, 0..) |*track, t| {
        const choice = state.track_plugins[t].choice_index;
        const wants_gui = state.track_plugins[t].gui_open;

        if (choice == 0) {
            if (track.handle != null) {
                closePluginGui(track);
                unloadPlugin(track, allocator);
            }
            continue;
        }

        if (track.handle == null) {
            track.handle = try PluginHandle.init(allocator, host);
            track.gui_ext = getGuiExt(track.handle.?);
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
