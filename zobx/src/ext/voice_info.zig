const clap = @import("clap-bindings");
const std = @import("std");

const Plugin = @import("../plugin.zig");

pub fn create() clap.ext.voice_info.Plugin {
    return .{
        .get = _get,
    };
}

fn _get(clap_plugin: *const clap.Plugin, info: *clap.ext.voice_info.Info) callconv(.c) bool {
    const plugin = Plugin.fromClapPlugin(clap_plugin);
    const voice_count = plugin.voices.getVoiceCount();
    info.voice_count = @intCast(voice_count);
    info.voice_capacity = 128;
    info.flags.supports_overlapping_notes = true;
    return true;
}
