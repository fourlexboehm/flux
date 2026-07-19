//! Shared CLAP voice_info extension for polyphonic instruments.

const clap = @import("clap-bindings");

/// `PluginType` must provide `fromClapPlugin` and `voices.getVoiceCount()`,
/// optionally `voices.getVoiceCapacity()`.
pub fn create(comptime PluginType: type) clap.ext.voice_info.Plugin {
    return .{
        .get = struct {
            fn get(clap_plugin: *const clap.Plugin, info: *clap.ext.voice_info.Info) callconv(.c) bool {
                const plugin = PluginType.fromClapPlugin(clap_plugin);
                info.voice_count = @intCast(plugin.voices.getVoiceCount());
                info.voice_capacity = if (@hasDecl(@TypeOf(plugin.voices), "getVoiceCapacity"))
                    @intCast(plugin.voices.getVoiceCapacity())
                else
                    128;
                info.flags.supports_overlapping_notes = true;
                return true;
            }
        }.get,
    };
}
