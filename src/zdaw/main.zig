const builtin = @import("builtin");
const std = @import("std");

const clap = @import("clap-bindings");
const glfw = @import("zglfw");
const zaudio = @import("zaudio");
const zgui = @import("zgui");
const zopengl = @import("zopengl");

const ui = @import("ui.zig");

const SampleRate = 48_000;
const Channels = 2;
const MaxFrames = 1024;
const gl_major = 4;
const gl_minor = 1;

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

fn dataCallback(
    _: *zaudio.Device,
    output: ?*anyopaque,
    _: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    if (output == null) return;
    const out_ptr: [*]f32 = @ptrCast(@alignCast(output.?));
    const sample_count: usize = @as(usize, frame_count) * Channels;
    @memset(out_ptr[0..sample_count], 0);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var host = Host.init();
    host.clap_host.host_data = &host;

    var plugin_handle = try PluginHandle.init(allocator, &host.clap_host);
    defer plugin_handle.deinit(allocator);

    zaudio.init(allocator);
    defer zaudio.deinit();

    var device_config = zaudio.Device.Config.init(.playback);
    device_config.playback.format = zaudio.Format.float32;
    device_config.playback.channels = Channels;
    device_config.sample_rate = SampleRate;
    device_config.data_callback = dataCallback;

    var device = try zaudio.Device.create(null, device_config);
    defer device.destroy();
    try device.start();

    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.context_version_major, gl_major);
    glfw.windowHint(.context_version_minor, gl_minor);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    glfw.windowHint(.client_api, .opengl_api);
    glfw.windowHint(.doublebuffer, true);

    const window = try glfw.Window.create(1280, 720, "zdaw", null);
    defer window.destroy();

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    try zopengl.loadCoreProfile(glfw.getProcAddress, gl_major, gl_minor);

    zgui.init(allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    zgui.backend.init(window);
    defer zgui.backend.deinit();

    var state = ui.State.init();
    var space_down = false;

    std.log.info("zdaw running (Ctrl+C to quit)", .{});
    while (!window.shouldClose()) {
        if (window.getKey(.escape) == .press) {
            window.setShouldClose(true);
        }
        const wants_keyboard = zgui.io.getWantCaptureKeyboard();
        const is_space_down = window.getKey(.space) == .press;
        if (!wants_keyboard and is_space_down and !space_down) {
            state.playing = !state.playing;
        }
        space_down = is_space_down;
        glfw.pollEvents();
        const win_size = window.getSize();
        const fb_size = window.getFramebufferSize();
        const gl = zopengl.bindings;
        gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0.08, 0.08, 0.1, 1.0 });

        zgui.backend.newFrame(
            @intCast(@max(win_size[0], 1)),
            @intCast(@max(win_size[1], 1)),
        );
        const fb_scale_x = @as(f32, @floatFromInt(@max(fb_size[0], 1))) / @as(f32, @floatFromInt(@max(win_size[0], 1)));
        const fb_scale_y = @as(f32, @floatFromInt(@max(fb_size[1], 1))) / @as(f32, @floatFromInt(@max(win_size[1], 1)));
        zgui.io.setDisplayFramebufferScale(fb_scale_x, fb_scale_y);
        ui.draw(&state, 1.0);
        zgui.backend.draw();
        window.swapBuffers();

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
