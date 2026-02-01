const std = @import("std");
const zgui = @import("zgui");
const static_data = @import("static_data");

const imgui_style = @import("../imgui_style.zig");

extern fn zguiCreateContext(shared_font_atlas: ?*const anyopaque) zgui.Context;
extern fn zguiSetCurrentContext(ctx: ?zgui.Context) void;

pub fn init(comptime GUIType: type, gui: *GUIType) !void {
    if (gui.imgui_initialized) {
        std.log.err("ImGui already initialized! Ignoring", .{});
        return error.ImGuiAlreadyInitialized;
    }

    if (zgui.getCurrentContext() == null) {
        zgui.init(gui.plugin.allocator);
        gui.imgui_context = zgui.getCurrentContext();
        gui.owns_imgui_context = true;
        zgui.io.setIniFilename(null);
        zgui.plot.init();
        setContext(GUIType, gui);
    } else {
        const ctx = zguiCreateContext(null);
        zgui.initWithExistingContext(gui.plugin.allocator, ctx);
        gui.imgui_context = ctx;
        gui.owns_imgui_context = true;
        zgui.io.setIniFilename(null);
        zgui.plot.init();
        setContext(GUIType, gui);
    }

    gui.imgui_initialized = true;
}

pub fn deinit(comptime GUIType: type, gui: *GUIType) void {
    zgui.plot.deinit();
    zgui.backend.deinit();
    if (gui.owns_imgui_context) {
        zgui.deinit();
    }
    gui.imgui_initialized = false;
    gui.imgui_context = null;
    gui.owns_imgui_context = false;
}

pub fn applyScaleFactor(comptime GUIType: type, gui: *GUIType) void {
    if (!gui.imgui_initialized) {
        return;
    }

    imgui_style.applyScaleFromMemory(static_data.font, gui.scale_factor);
}

pub fn draw(comptime GUIType: type, comptime ViewType: type, gui: *GUIType) void {
    setContext(GUIType, gui);
    ViewType.drawWindow(gui.plugin);
}

pub fn setContext(comptime GUIType: type, gui: *GUIType) void {
    if (gui.imgui_context) |ctx| {
        zguiSetCurrentContext(ctx);
    }
}
