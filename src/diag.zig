const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");

const glfw = @import("zglfw");
const objc = @import("objc");
const Plugin = @import("plugin.zig");
const GUI = @import("ext/gui/gui.zig");

const AppWindow = struct {
    app: *objc.app_kit.Application,
    window: *objc.app_kit.Window,
    view: *objc.app_kit.View,

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
        window.setContentView(view);
        window.makeKeyAndOrderFront(null);

        return .{
            .app = app,
            .window = window,
            .view = view,
        };
    }

    pub fn deinit(self: *AppWindow) void {
        self.view.release();
        self.window.release();
    }
};

const MockHost = struct {
    clap_host: clap.Host,
    allocator: std.mem.Allocator,
    plugin: ?*Plugin,

    pub fn init(allocator: std.mem.Allocator) !*MockHost {
        const host = try allocator.create(MockHost);
        host.* = .{
            .clap_host = .{
                .clap_version = clap.version,
                .host_data = host,
                .name = "Mock Host",
                .version = "0.1",
                .url = null,
                .vendor = null,
                .getExtension = _getExtension,
                .requestCallback = _requestCallback,
                .requestProcess = _requestProcess,
                .requestRestart = _requestRestart,
            },
            .plugin = null,
            .allocator = allocator,
        };
        return host;
    }

    pub fn deinit(self: *MockHost) void {
        self.allocator.destroy(self);
    }

    pub fn fromClapHost(clap_host: *const clap.Host) *MockHost {
        return @ptrCast(@alignCast(clap_host.host_data));
    }

    pub fn setPlugin(self: *MockHost, plugin: *Plugin) void {
        self.plugin = plugin;
    }

    /// query an extension. the returned pointer is owned by the host. it is forbidden to
    /// call it before `Plugin.init`. you may call in within `Plugin.init` call and after.
    fn _getExtension(_: *const clap.Host, _: [*:0]const u8) callconv(.c) ?*const anyopaque {
        return null;
    }

    /// request the host to deactivate then reactivate
    /// the plugin. the host may delay this operation.
    fn _requestRestart(_: *const clap.Host) callconv(.c) void {}
    /// request the host to start processing the plugin. this is useful
    /// if you have external IO and need to wake the plugin up from "sleep"
    fn _requestProcess(_: *const clap.Host) callconv(.c) void {}

    /// request the host to schedule a call to `Plugin.onMainThread`, on the main thread.
    fn _requestCallback(clap_host: *const clap.Host) callconv(.c) void {
        const host = MockHost.fromClapHost(clap_host);
        if (host.plugin) |plugin| {
            plugin.plugin.onMainThread(&plugin.plugin);
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var host = try MockHost.init(allocator);
    defer host.deinit();

    const plugin = try Plugin.init(allocator, &host.clap_host);
    plugin.sample_rate = 48000;
    defer plugin.deinit();

    host.setPlugin(plugin);

    const plugin_gui_ext = GUI.create();

    switch (builtin.os.tag) {
        .macos => {
            var app_window = try AppWindow.init("ZSynth", 800, 500);
            defer app_window.deinit();
            const window = clap.ext.gui.Window{ .api = "cocoa", .data = .{
                .cocoa = app_window.view,
            } };
            _ = plugin_gui_ext.create(&plugin.plugin, null, false);
            _ = plugin_gui_ext.setParent(&plugin.plugin, &window);
            _ = plugin_gui_ext.show(&plugin.plugin);
            while (app_window.window.isVisible()) {
                if (plugin.gui) |gui| {
                    try gui.update();
                } else {
                    break;
                }
            }
        },
        .linux => {
            _ = plugin_gui_ext.create(&plugin.plugin, null, true);
            while (plugin.gui) |gui| {
                try gui.update();
            }
        },
        else => {
            // TODO
        },
    }
}
