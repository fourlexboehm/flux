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
const bench = @import("bench.zig");
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

inline fn nsSince(from: std.Io.Timestamp, to: std.Io.Timestamp) u64 {
    const ns = from.durationTo(to).toNanoseconds();
    return if (ns > 0) @intCast(ns) else 0;
}

pub const std_options: std.Options = .{
    .enable_segfault_handler = options.enable_segfault_handler,
};

const TrackPlugin = plugin_runtime.TrackPlugin;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var host = host_mod.Host.init();
    host.clap_host.host_data = &host;

    const cpu_count = std.Thread.getCpuCount() catch 4;
    bench.configureRuntimeTuning(&host, cpu_count);

    if (bench.envBool("FLUX_KERNEL_BENCH")) {
        try bench.runKernelBench(allocator, io);
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

    if (try bench.runHeadlessBench(
        allocator,
        io,
        &host,
        &state,
        &track_plugins,
        &track_fx,
        &engine,
        &device,
        &device_config,
        &buffer_frames,
    )) {
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

            // Counter double-scaling on Wayland by scaling UI against framebuffer scale.
            const initial_win_size = window.getSize();
            const initial_fb_size = window.getFramebufferSize();
            const initial_win_w: f32 = @floatFromInt(@max(initial_win_size[0], 1));
            const initial_win_h: f32 = @floatFromInt(@max(initial_win_size[1], 1));
            const initial_fb_w: f32 = @floatFromInt(@max(initial_fb_size[0], 1));
            const initial_fb_h: f32 = @floatFromInt(@max(initial_fb_size[1], 1));
            const initial_scale_x: f32 = initial_fb_w / initial_win_w;
            const initial_scale_y: f32 = initial_fb_h / initial_win_h;
            const initial_scale: f32 = if (initial_scale_x > 0 and initial_scale_y > 0)
                @min(initial_scale_x, initial_scale_y)
            else
                1.0;
            const ui_scale: f32 = if (initial_scale > 0) 1.0 / initial_scale else 1.0;
            shared_mod.imgui_style.applyFontFromMemory(static_data.font, ui_scale);

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
                ui_draw.draw(&state, ui_scale);
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
