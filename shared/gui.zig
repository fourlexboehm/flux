pub fn Gui(comptime PluginType: type, comptime ViewType: type) type {
    return struct {
        const Self = @This();

        const builtin = @import("builtin");
        const std = @import("std");
        const tracy = @import("tracy");

        const clap = @import("clap-bindings");
        const objc = @import("objc");
        const glfw = @import("zglfw");
        const zgui = @import("zgui");

        const imgui = @import("gui/imgui.zig");
        const gui_enabled = @import("options").enable_gui;
        const macos = if (gui_enabled) @import("gui/macos.zig") else struct {};
        const linux = if (gui_enabled) @import("gui/linux.zig") else struct {};

        const PlatformData = switch (builtin.os.tag) {
            .macos => struct {
                view: *objc.app_kit.View,
                device: *objc.metal.Device,
                layer: *objc.quartz_core.MetalLayer,
                command_queue: *objc.metal.CommandQueue,
            },
            .linux => struct {
                window: *glfw.Window,
            },
            .windows => struct {},
            else => struct {},
        };

        const window_width = 800;
        const window_height = 500;
        const FPS = 60.0;

        plugin: *PluginType,
        allocator: std.mem.Allocator,

        scale_factor: f32 = 1.0,
        platform_data: ?PlatformData,
        imgui_initialized: bool,
        imgui_context: ?zgui.Context,
        owns_imgui_context: bool,
        visible: bool,
        width: u32,
        height: u32,
        elapsed_since_last_update: f64 = 0.0,

        pub fn init(allocator: std.mem.Allocator, plugin: *PluginType, is_floating: bool) !*Self {
            std.log.debug("GUI init() called", .{});

            if (comptime !gui_enabled) {
                return error.GuiDisabled;
            }

            if (plugin.gui != null) {
                std.log.err("GUI has already been initialized!", .{});
                return error.AlreadyInitialized;
            }

            if (is_floating and builtin.os.tag != .linux) {
                std.log.err("Floating windows are only supported on Linux!", .{});
                return error.FloatingWindowNotSupported;
            }

            const gui = try allocator.create(Self);
            errdefer allocator.destroy(gui);
            gui.* = .{
                .plugin = plugin,
                .allocator = allocator,
                .platform_data = null,
                .visible = true,
                .imgui_initialized = false,
                .imgui_context = null,
                .owns_imgui_context = false,
                .width = window_width,
                .height = window_height,
            };

            try gui.initWindow();

            return gui;
        }

        pub fn deinit(self: *Self) void {
            std.log.debug("GUI deinit() called", .{});
            if (self.platform_data != null) {
                self.deinitWindow();
            }
            self.plugin.gui = null;
            self.allocator.destroy(self);
        }

        pub fn update(self: *Self) !void {
            const zone = tracy.ZoneN(@src(), "GUI update");
            defer zone.End();

            if (comptime !gui_enabled) {
                return;
            }

            switch (builtin.os.tag) {
                .linux => {
                    try linux.update(Self, ViewType, self);
                },
                .macos => {
                    try macos.update(Self, ViewType, self);
                },
                else => {},
            }

            self.elapsed_since_last_update = 0;
        }

        pub fn tick(self: *Self, dt: f64) void {
            self.elapsed_since_last_update += dt;
        }

        pub fn shouldUpdate(self: *const Self) bool {
            return self.elapsed_since_last_update > 1.0 / FPS;
        }

        fn initWindow(self: *Self) !void {
            std.log.debug("Creating window.", .{});
            if (comptime !gui_enabled) {
                return error.GuiDisabled;
            }
            try imgui.init(Self, self);
            if (builtin.os.tag == .linux) {
                try linux.init(Self, self);
            }
        }

        fn deinitWindow(self: *Self) void {
            std.log.debug("Destroying window.", .{});

            if (comptime !gui_enabled) {
                return;
            }

            if (self.platform_data != null) {
                imgui.deinit(Self, self);
                switch (builtin.os.tag) {
                    .macos => {
                        macos.deinit(Self, self);
                    },
                    .linux => {
                        linux.deinit(Self, self);
                    },
                    .windows => {},
                    else => {},
                }
            }
        }

        pub fn show(self: *Self) !void {
            self.visible = true;
            if (comptime !gui_enabled) {
                return;
            }
            if (builtin.os.tag == .linux) {
                if (self.platform_data) |data| {
                    data.window.setAttribute(.visible, true);
                }
            }
        }

        pub fn hide(self: *Self) void {
            self.visible = false;
            if (comptime !gui_enabled) {
                return;
            }
            if (builtin.os.tag == .linux) {
                if (self.platform_data) |data| {
                    data.window.setAttribute(.visible, true);
                }
            }
        }

        fn setTitle(self: *Self, title: [:0]const u8) void {
            switch (builtin.os.tag) {
                .macos => {},
                .linux => {
                    if (self.platform_data) |data| {
                        data.window.setTitle(title);
                    }
                },
                else => {},
            }
        }

        fn getSize(self: *const Self) [2]u32 {
            return [2]u32{ self.width, self.height };
        }

        pub fn create() clap.ext.gui.Plugin {
            return .{
                .isApiSupported = _isApiSupported,
                .getPreferredApi = _getPreferredApi,
                .create = _create,
                .destroy = _destroy,
                .setScale = _setScale,
                .getSize = _getSize,
                .canResize = _canResize,
                .getResizeHints = _getResizeHints,
                .adjustSize = _adjustSize,
                .setSize = _setSize,
                .setParent = _setParent,
                .setTransient = _setTransient,
                .suggestTitle = _suggestTitle,
                .show = _show,
                .hide = _hide,
            };
        }

        fn _isApiSupported(_: *const clap.Plugin, _: [*:0]const u8, is_floating: bool) callconv(.c) bool {
            if (comptime !gui_enabled) {
                return false;
            }
            if (is_floating) return builtin.os.tag == .linux;
            return true;
        }

        fn _getPreferredApi(_: *const clap.Plugin, _: *[*:0]const u8, is_floating: *bool) callconv(.c) bool {
            if (comptime !gui_enabled) {
                is_floating.* = false;
                return false;
            }
            is_floating.* = builtin.os.tag == .linux;
            return true;
        }

        fn _create(clap_plugin: *const clap.Plugin, api: ?[*:0]const u8, is_floating: bool) callconv(.c) bool {
            if (comptime !gui_enabled) {
                return false;
            }
            _ = api;

            std.log.debug("Host called GUI create!", .{});
            const plugin: *PluginType = PluginType.fromClapPlugin(clap_plugin);
            if (plugin.gui != null) {
                std.log.info("GUI has already been initialized, earlying out", .{});
                return false;
            }

            plugin.gui = Self.init(plugin.allocator, plugin, is_floating) catch null;
            return plugin.gui != null;
        }

        fn _destroy(clap_plugin: *const clap.Plugin) callconv(.c) void {
            if (comptime !gui_enabled) {
                return;
            }
            std.log.debug("Host called GUI destroy!", .{});
            const plugin: *PluginType = PluginType.fromClapPlugin(clap_plugin);

            if (plugin.gui) |gui| {
                gui.deinit();
            }
            plugin.gui = null;
        }

        fn _setScale(clap_plugin: *const clap.Plugin, scale_factor: f64) callconv(.c) bool {
            if (comptime !gui_enabled) {
                _ = clap_plugin;
                _ = scale_factor;
                return false;
            }
            _ = clap_plugin;
            _ = scale_factor;
            return false;
        }

        fn _getSize(clap_plugin: *const clap.Plugin, width: *u32, height: *u32) callconv(.c) bool {
            if (comptime !gui_enabled) {
                return false;
            }
            const plugin: *PluginType = PluginType.fromClapPlugin(clap_plugin);
            if (plugin.gui) |gui| {
                const window_size = gui.getSize();
                width.* = window_size[0];
                height.* = window_size[1];
                return true;
            }
            return false;
        }

        fn _canResize(_: *const clap.Plugin) callconv(.c) bool {
            if (comptime !gui_enabled) {
                return false;
            }
            return false;
        }

        fn _getResizeHints(_: *const clap.Plugin, hints: *clap.ext.gui.ResizeHints) callconv(.c) bool {
            if (comptime !gui_enabled) {
                _ = hints;
                return false;
            }
            _ = hints;
            return false;
        }

        fn _adjustSize(_: *const clap.Plugin, width: *u32, height: *u32) callconv(.c) bool {
            if (comptime !gui_enabled) {
                _ = width;
                _ = height;
                return false;
            }
            _ = width;
            _ = height;
            return false;
        }

        fn _setSize(_: *const clap.Plugin, width: u32, height: u32) callconv(.c) bool {
            if (comptime !gui_enabled) {
                _ = width;
                _ = height;
                return false;
            }
            _ = width;
            _ = height;
            return false;
        }

        fn _setParent(clap_plugin: *const clap.Plugin, plugin_window: *const clap.ext.gui.Window) callconv(.c) bool {
            if (comptime !gui_enabled) {
                return false;
            }
            const plugin: *PluginType = PluginType.fromClapPlugin(clap_plugin);
            if (plugin.gui) |gui| {
                switch (builtin.os.tag) {
                    .macos => {
                        const view: *objc.app_kit.View = @ptrCast(plugin_window.data.cocoa);
                        macos.init(Self, gui, view) catch |err| {
                            std.log.err("Error initializing window! {}", .{err});
                            return false;
                        };
                        return true;
                    },
                    else => {},
                }
            }

            return false;
        }

        fn _setTransient(_: *const clap.Plugin, _: *const clap.ext.gui.Window) callconv(.c) bool {
            if (comptime !gui_enabled) {
                return false;
            }
            return true;
        }

        fn _suggestTitle(clap_plugin: *const clap.Plugin, title: [*:0]const u8) callconv(.c) bool {
            if (comptime !gui_enabled) {
                return false;
            }
            const plugin: *PluginType = PluginType.fromClapPlugin(clap_plugin);
            if (plugin.gui) |gui| {
                gui.setTitle(std.mem.span(title));
                return true;
            }
            return false;
        }

        fn _show(clap_plugin: *const clap.Plugin) callconv(.c) bool {
            if (comptime !gui_enabled) {
                return false;
            }

            const plugin: *PluginType = PluginType.fromClapPlugin(clap_plugin);
            if (plugin.gui) |gui| {
                gui.show() catch {
                    return false;
                };
                return true;
            }
            return false;
        }

        fn _hide(clap_plugin: *const clap.Plugin) callconv(.c) bool {
            if (comptime !gui_enabled) {
                return false;
            }
            const plugin: *PluginType = PluginType.fromClapPlugin(clap_plugin);
            if (plugin.gui) |gui| {
                gui.hide();
                return true;
            }
            return false;
        }
    };
}
