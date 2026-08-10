//! CLAP GUI open/close for the slim DVUI host.
//!
//! Prefers a **floating** GUI API (plugin-owned window). Falls back to a host
//! parent window when the plugin only supports embedded parenting:
//! - macOS: NSWindow + setParent via `macos_plugin_window.m`
//! - Linux: X11 `HostWindow` + setParent via `linux_x11.zig` (most stock CLAPs)

const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");

const plugin_call_context = @import("call_context.zig");
const plugin_handle = @import("handle.zig");

const LoadedPlugin = plugin_handle.LoadedPlugin;

const linux_x11 = if (builtin.os.tag == .linux) @import("linux_x11.zig") else struct {
    pub const HostWindow = struct {
        display: ?*anyopaque = null,
        window: u64 = 0,
        pub fn create(_: u32, _: u32, _: [:0]const u8) !@This() {
            return error.X11Unavailable;
        }
        pub fn destroy(self: *@This()) void {
            _ = self;
        }
        pub fn clapWindow(self: @This()) clap.ext.gui.Window {
            _ = self;
            return .{
                .api = clap.ext.gui.window_api.x11,
                .data = .{ .x11 = 0 },
            };
        }
    };
    pub fn isAvailable() bool {
        return false;
    }
    pub fn initThreads() void {}
};

/// C ABI for `macos_plugin_window.m` (no @cImport — Zig 0.17 test path).
const FluxPluginWindow = extern struct {
    ns_window: ?*anyopaque = null,
    ns_view: ?*anyopaque = null,
};

const flux_plugin_window_create = if (builtin.os.tag == .macos)
    struct {
        extern fn flux_plugin_window_create(out: *FluxPluginWindow, width: u32, height: u32, title: [*:0]const u8) bool;
    }.flux_plugin_window_create
else
    struct {
        fn f(_: *FluxPluginWindow, _: u32, _: u32, _: [*:0]const u8) bool {
            return false;
        }
    }.f;

const flux_plugin_window_destroy = if (builtin.os.tag == .macos)
    struct {
        extern fn flux_plugin_window_destroy(win: *FluxPluginWindow) void;
    }.flux_plugin_window_destroy
else
    struct {
        fn f(_: *FluxPluginWindow) void {}
    }.f;

const plugin_window_title: [:0]const u8 = "Plugin";

const GuiPlan = struct {
    api: [*:0]const u8,
    is_floating: bool,
};

fn isApi(api: [*:0]const u8, expected: [*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(api), std.mem.span(expected));
}

fn choosePlan(plugin: *const clap.Plugin, gui_ext: *const clap.ext.gui.Plugin) !GuiPlan {
    var preferred_api: [*:0]const u8 = switch (builtin.os.tag) {
        .linux => clap.ext.gui.window_api.wayland,
        else => clap.ext.gui.window_api.cocoa,
    };
    var preferred_floating = true;
    const has_preferred = gui_ext.getPreferredApi(plugin, &preferred_api, &preferred_floating);

    if (has_preferred and preferred_floating and
        gui_ext.isApiSupported(plugin, preferred_api, true))
    {
        // Prefer floating when the plugin asks for it — but on Linux X11 only
        // when DISPLAY is available.
        if (!(builtin.os.tag == .linux and isApi(preferred_api, clap.ext.gui.window_api.x11) and !linux_x11.isAvailable())) {
            return .{ .api = preferred_api, .is_floating = true };
        }
    }

    switch (builtin.os.tag) {
        .macos => {
            if (gui_ext.isApiSupported(plugin, clap.ext.gui.window_api.cocoa, true)) {
                return .{ .api = clap.ext.gui.window_api.cocoa, .is_floating = true };
            }
            if (gui_ext.isApiSupported(plugin, clap.ext.gui.window_api.cocoa, false)) {
                return .{ .api = clap.ext.gui.window_api.cocoa, .is_floating = false };
            }
            if (has_preferred and gui_ext.isApiSupported(plugin, preferred_api, preferred_floating)) {
                return .{ .api = preferred_api, .is_floating = preferred_floating };
            }
            return error.GuiUnsupported;
        },
        .linux => {
            // Parent first: most CLAPs only support non-floating X11.
            if (linux_x11.isAvailable() and gui_ext.isApiSupported(plugin, clap.ext.gui.window_api.x11, false)) {
                return .{ .api = clap.ext.gui.window_api.x11, .is_floating = false };
            }
            if (gui_ext.isApiSupported(plugin, clap.ext.gui.window_api.wayland, true)) {
                return .{ .api = clap.ext.gui.window_api.wayland, .is_floating = true };
            }
            if (linux_x11.isAvailable() and gui_ext.isApiSupported(plugin, clap.ext.gui.window_api.x11, true)) {
                return .{ .api = clap.ext.gui.window_api.x11, .is_floating = true };
            }
            if (has_preferred and preferred_floating and
                gui_ext.isApiSupported(plugin, preferred_api, true))
            {
                return .{ .api = preferred_api, .is_floating = true };
            }
            return error.GuiNeedsParent;
        },
        else => return error.GuiUnsupported,
    }
}

fn pluginGuiSize(plugin: *const clap.Plugin, gui_ext: *const clap.ext.gui.Plugin) [2]u32 {
    var width: u32 = 0;
    var height: u32 = 0;
    if (!gui_ext.getSize(plugin, &width, &height)) {
        width = 800;
        height = 500;
    }
    return .{ @max(width, 1), @max(height, 1) };
}

fn destroyHostWindow(slot: *LoadedPlugin) void {
    switch (builtin.os.tag) {
        .macos => {
            if (slot.gui_window == null and slot.gui_view == null) return;
            var win = FluxPluginWindow{
                .ns_window = slot.gui_window,
                .ns_view = slot.gui_view,
            };
            flux_plugin_window_destroy(&win);
        },
        .linux => {
            if (slot.gui_window) |display_raw| {
                if (slot.gui_x11_window != 0) {
                    var host = linux_x11.HostWindow{
                        .display = @ptrCast(@alignCast(display_raw)),
                        .window = @intCast(slot.gui_x11_window),
                    };
                    host.destroy();
                }
            }
        },
        else => {},
    }
    slot.gui_window = null;
    slot.gui_view = null;
    slot.gui_x11_window = 0;
}

fn createMacosParentWindow(
    plugin: *const clap.Plugin,
    gui_ext: *const clap.ext.gui.Plugin,
    slot: *LoadedPlugin,
) !void {
    if (builtin.os.tag != .macos) return error.GuiUnsupported;

    const size = pluginGuiSize(plugin, gui_ext);
    var win: FluxPluginWindow = .{ .ns_window = null, .ns_view = null };
    if (!flux_plugin_window_create(&win, size[0], size[1], plugin_window_title)) {
        return error.GuiWindowCreateFailed;
    }
    slot.gui_window = win.ns_window;
    slot.gui_view = win.ns_view;

    const view = win.ns_view orelse {
        destroyHostWindow(slot);
        return error.GuiWindowCreateFailed;
    };
    const window_handle = clap.ext.gui.Window{
        .api = clap.ext.gui.window_api.cocoa,
        .data = .{ .cocoa = view },
    };
    if (!gui_ext.setParent(plugin, &window_handle)) {
        destroyHostWindow(slot);
        return error.GuiSetParentFailed;
    }
}

fn createLinuxParentWindow(
    plugin: *const clap.Plugin,
    gui_ext: *const clap.ext.gui.Plugin,
    slot: *LoadedPlugin,
) !void {
    if (builtin.os.tag != .linux) return error.GuiUnsupported;

    const size = pluginGuiSize(plugin, gui_ext);
    var host_window = try linux_x11.HostWindow.create(size[0], size[1], plugin_window_title);

    const window_handle = host_window.clapWindow();
    if (!gui_ext.setParent(plugin, &window_handle)) {
        host_window.destroy();
        return error.GuiSetParentFailed;
    }
    // Transfer ownership into LoadedPlugin fields (no heap allocation).
    // Stack copy is abandoned — do not call destroy after this.
    slot.gui_window = @ptrCast(host_window.display);
    slot.gui_x11_window = @intCast(host_window.window);
    slot.gui_view = null;
}

/// Call once at process start on Linux so Xlib is thread-safe before any plugin
/// opens a GUI (must precede other Xlib use).
pub fn initPlatform() void {
    if (builtin.os.tag == .linux) {
        linux_x11.initThreads();
    }
}

/// Open plugin GUI into `slot` (sets gui_open / gui_ext / window fields).
pub fn open(slot: *LoadedPlugin) !void {
    if (slot.gui_open) return;
    const plugin = slot.getPlugin() orelse return error.NoPlugin;
    const gui_ext = plugin_handle.getGuiExt(plugin) orelse return error.NoGuiExtension;

    const previous = plugin_call_context.enter(plugin);
    defer plugin_call_context.restore(previous);

    const plan = try choosePlan(plugin, gui_ext);

    if (!gui_ext.create(plugin, plan.api, plan.is_floating)) {
        return error.GuiCreateFailed;
    }

    if (!plan.is_floating) {
        const parent_err = switch (builtin.os.tag) {
            .macos => createMacosParentWindow(plugin, gui_ext, slot),
            .linux => createLinuxParentWindow(plugin, gui_ext, slot),
            else => error.GuiNeedsParent,
        };
        parent_err catch |err| {
            gui_ext.destroy(plugin);
            return err;
        };
    } else {
        _ = gui_ext.suggestTitle(plugin, plugin_window_title);
    }

    if (!gui_ext.show(plugin)) {
        destroyHostWindow(slot);
        gui_ext.destroy(plugin);
        return error.GuiShowFailed;
    }

    slot.gui_ext = gui_ext;
    slot.gui_open = true;
}

pub fn close(slot: *LoadedPlugin) void {
    if (!slot.gui_open) return;
    if (slot.getPlugin()) |plugin| {
        const previous = plugin_call_context.enter(plugin);
        defer plugin_call_context.restore(previous);
        if (slot.gui_ext) |gui_ext| {
            _ = gui_ext.hide(plugin);
            gui_ext.destroy(plugin);
        }
    }
    destroyHostWindow(slot);
    slot.clearGuiFlags();
}

/// True if we can open a GUI for this plugin (floating or host-parented).
pub fn hasFloatingGui(plugin: *const clap.Plugin) bool {
    const gui_ext = plugin_handle.getGuiExt(plugin) orelse return false;
    _ = choosePlan(plugin, gui_ext) catch return false;
    return true;
}

/// Dispatch CLAP main-thread work for an open GUI (timers, UI updates).
pub fn pumpOnMainThread(plugin: *const clap.Plugin) void {
    const previous = plugin_call_context.enter(plugin);
    defer plugin_call_context.restore(previous);
    plugin.onMainThread(plugin);
}
