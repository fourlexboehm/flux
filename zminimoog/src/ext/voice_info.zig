const clap = @import("clap-bindings");
const std = @import("std");

const Plugin = @import("../plugin.zig");

// Voice info
pub fn create() clap.ext.voice_info.Plugin {
    return .{
        .get = _get,
    };
}

/// returns true on success and populates `info.*` with the voice info.
fn _get(clap_plugin: *const clap.Plugin, info: *clap.ext.voice_info.Info) callconv(.c) bool {
    const plugin = Plugin.fromClapPlugin(clap_plugin);

    const voice_count = plugin.voices.getVoiceCount();

    info.voice_count = @intCast(voice_count);
    info.voice_capacity = 128; // Reasonable default
    info.flags.supports_overlapping_notes = true;

    return true;
}
