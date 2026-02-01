const shared = @import("shared");

pub const AudioPorts = shared.ext.audioports;
pub const NotePorts = shared.ext.noteports;
pub const Params = @import("ext/params.zig");
pub const State = struct {
    pub fn create() @import("clap-bindings").ext.state.Plugin {
        return shared.ext.state.create(@import("ext/params.zig"), @import("plugin.zig"));
    }
};
pub const GUI = @import("ext/gui/gui.zig");
pub const VoiceInfo = @import("ext/voice_info.zig");
pub const ThreadPool = @import("ext/thread_pool.zig");
pub const Undo = @import("ext/undo.zig");
