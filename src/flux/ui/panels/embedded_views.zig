const std = @import("std");
const clap = @import("clap-bindings");
const zsynth = @import("zsynth-core");
const zminimoog = @import("zminimoog-core");
const zportafm = @import("zportafm-core");
const flux_builtins = @import("../../builtins/root.zig");

const zsynth_view = zsynth.View;
const zminimoog_view = zminimoog.View;
const zportafm_view = zportafm.View;

pub const EmbeddedViewDrawFn = *const fn (*const clap.Plugin) void;

fn zsynthDraw(clap_plugin: *const clap.Plugin) void {
    const plugin = zsynth.Plugin.fromClapPlugin(clap_plugin);
    zsynth_view.drawEmbedded(plugin, .{ .notify_host = false });
}

fn zminimoogDraw(clap_plugin: *const clap.Plugin) void {
    const plugin = zminimoog.Plugin.fromClapPlugin(clap_plugin);
    zminimoog_view.drawEmbedded(plugin, .{ .notify_host = false });
}

fn zportafmDraw(clap_plugin: *const clap.Plugin) void {
    const plugin = zportafm.Plugin.fromClapPlugin(clap_plugin);
    zportafm_view.drawEmbedded(plugin, .{ .notify_host = false });
}

fn builtinFxDraw(clap_plugin: *const clap.Plugin) void {
    flux_builtins.view.drawFromClap(clap_plugin);
}

pub const embedded_views = std.StaticStringMap(EmbeddedViewDrawFn).initComptime(.{
    .{ "com.juge.zsynth", zsynthDraw },
    .{ "com.fourlex.zminimoog", zminimoogDraw },
    .{ "com.fourlex.zportafm", zportafmDraw },
    .{ "com.flux.builtin.equalizer", builtinFxDraw },
    .{ "com.flux.builtin.compressor", builtinFxDraw },
    .{ "com.flux.builtin.noise_gate", builtinFxDraw },
    .{ "com.flux.builtin.limiter", builtinFxDraw },
});

/// Check if a plugin has an embedded view available.
pub fn hasEmbeddedView(plugin: *const clap.Plugin) bool {
    const id = std.mem.sliceTo(plugin.descriptor.id, 0);
    return embedded_views.get(id) != null;
}

/// Get the embedded view draw function for a plugin, if available.
pub fn getEmbeddedView(plugin: *const clap.Plugin) ?EmbeddedViewDrawFn {
    const id = std.mem.sliceTo(plugin.descriptor.id, 0);
    return embedded_views.get(id);
}
