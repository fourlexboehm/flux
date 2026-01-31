const clap = @import("clap-bindings");
const std = @import("std");

const Plugin = @import("../plugin.zig");
const audio = @import("../audio/audio.zig");

pub fn create() clap.ext.thread_pool.Plugin {
    return .{
        .exec = _exec,
    };
}

pub fn _exec(clap_plugin: *const clap.Plugin, task_index: u32) callconv(.c) void {
    const plugin = Plugin.fromClapPlugin(clap_plugin);
    audio.processVoice(plugin, task_index);
}
