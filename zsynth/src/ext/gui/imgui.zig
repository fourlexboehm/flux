const std = @import("std");
const zgui = @import("zgui");
const static_data = @import("static_data");

const GUI = @import("gui.zig");
const view = @import("view.zig");

extern fn zguiCreateContext(shared_font_atlas: ?*const anyopaque) zgui.Context;
extern fn zguiSetCurrentContext(ctx: ?zgui.Context) void;

pub fn init(gui: *GUI) !void {
    if (gui.imgui_initialized) {
        std.log.err("ImGui already initialized! Ignoring", .{});
        return error.ImGuiAlreadyInitialized;
    }

    if (zgui.getCurrentContext() == null) {
        // Initialize ImGui and take ownership of the context.
        zgui.init(gui.plugin.allocator);
        gui.imgui_context = zgui.getCurrentContext();
        gui.owns_imgui_context = true;
        zgui.io.setIniFilename(null);
        zgui.plot.init();
        setContext(gui);
    } else {
        // Create a dedicated context for the plugin GUI to avoid conflicts with the host.
        const ctx = zguiCreateContext(null);
        zgui.initWithExistingContext(gui.plugin.allocator, ctx);
        gui.imgui_context = ctx;
        gui.owns_imgui_context = true;
        zgui.io.setIniFilename(null);
        zgui.plot.init();
        setContext(gui);
    }

    gui.imgui_initialized = true;
}

pub fn deinit(gui: *GUI) void {
    zgui.plot.deinit();
    zgui.backend.deinit();
    if (gui.owns_imgui_context) {
        zgui.deinit();
    }
    gui.imgui_initialized = false;
    gui.imgui_context = null;
    gui.owns_imgui_context = false;
}

pub fn applyScaleFactor(gui: *GUI) void {
    if (!gui.imgui_initialized) {
        return;
    }

    _ = zgui.io.addFontFromMemory(static_data.font, std.math.floor(16.0 * gui.scale_factor));
    zgui.getStyle().scaleAllSizes(gui.scale_factor);
}

// Platform-agnostic draw function
pub fn draw(gui: *GUI) void {
    setContext(gui);
    view.drawWindow(gui.plugin);
}

pub fn setContext(gui: *GUI) void {
    if (gui.imgui_context) |ctx| {
        zguiSetCurrentContext(ctx);
    }
}
