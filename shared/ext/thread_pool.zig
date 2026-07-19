//! Shared CLAP thread_pool extension. Plugin supplies `processVoice(plugin, task_index)`.

const clap = @import("clap-bindings");

pub fn create(
    comptime PluginType: type,
    comptime processVoice: *const fn (*PluginType, u32) void,
) clap.ext.thread_pool.Plugin {
    return .{
        .exec = struct {
            fn exec(clap_plugin: *const clap.Plugin, task_index: u32) callconv(.c) void {
                const plugin = PluginType.fromClapPlugin(clap_plugin);
                processVoice(plugin, task_index);
            }
        }.exec,
    };
}

/// Variant that allows `processVoice` to return an error (logged and ignored).
pub fn createFallible(
    comptime PluginType: type,
    comptime processVoice: *const fn (*PluginType, u32) anyerror!void,
) clap.ext.thread_pool.Plugin {
    const std = @import("std");
    return .{
        .exec = struct {
            fn exec(clap_plugin: *const clap.Plugin, task_index: u32) callconv(.c) void {
                const plugin = PluginType.fromClapPlugin(clap_plugin);
                processVoice(plugin, task_index) catch |err| {
                    std.log.err("Unable to process voice data at index {d}: {}", .{ task_index, err });
                };
            }
        }.exec,
    };
}
