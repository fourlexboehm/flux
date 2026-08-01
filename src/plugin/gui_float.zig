//! CLAP GUI open/close for the slim DVUI host.
//!
//! Prefers a **floating** GUI API (plugin-owned window). On macOS, falls back to
//! a host-created NSWindow + setParent via `macos_plugin_window.m` when the
//! plugin only supports non-floating cocoa (most stock CLAPs).

const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");

const plugin_call_context = @import("call_context.zig");
const plugin_handle = @import("handle.zig");

const LoadedPlugin = plugin_handle.LoadedPlugin;

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

const GuiPlan = struct {
    api: [*:0]const u8,
    is_floating: bool,
};

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
        return .{ .api = preferred_api, .is_floating = true };
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
            if (gui_ext.isApiSupported(plugin, clap.ext.gui.window_api.wayland, true)) {
                return .{ .api = clap.ext.gui.window_api.wayland, .is_floating = true };
            }
            if (gui_ext.isApiSupported(plugin, clap.ext.gui.window_api.x11, true)) {
                return .{ .api = clap.ext.gui.window_api.x11, .is_floating = true };
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
    if (builtin.os.tag != .macos) {
        slot.gui_window = null;
        slot.gui_view = null;
        return;
    }
    if (slot.gui_window == null and slot.gui_view == null) return;
    var win = FluxPluginWindow{
        .ns_window = slot.gui_window,
        .ns_view = slot.gui_view,
    };
    flux_plugin_window_destroy(&win);
    slot.gui_window = null;
    slot.gui_view = null;
}

fn createMacosParentWindow(
    plugin: *const clap.Plugin,
    gui_ext: *const clap.ext.gui.Plugin,
    slot: *LoadedPlugin,
) !void {
    if (builtin.os.tag != .macos) return error.GuiUnsupported;

    const size = pluginGuiSize(plugin, gui_ext);
    var win: FluxPluginWindow = .{ .ns_window = null, .ns_view = null };
    if (!flux_plugin_window_create(&win, size[0], size[1], "Plugin")) {
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
        if (builtin.os.tag == .macos) {
            createMacosParentWindow(plugin, gui_ext, slot) catch |err| {
                gui_ext.destroy(plugin);
                return err;
            };
        } else {
            gui_ext.destroy(plugin);
            return error.GuiNeedsParent;
        }
    } else {
        _ = gui_ext.suggestTitle(plugin, "Plugin");
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

/// True if we can open a GUI for this plugin (floating or macOS parented).
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
