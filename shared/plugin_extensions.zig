pub fn Extensions(
    comptime PluginType: type,
    comptime ViewType: type,
    comptime ParamsType: type,
    comptime VoiceInfoType: type,
    comptime ThreadPoolType: type,
    comptime UndoType: type,
) type {
    const shared = @import("root.zig");

    return struct {
        pub const AudioPorts = shared.ext.audioports;
        pub const NotePorts = shared.ext.noteports;
        pub const Params = ParamsType;
        pub const State = struct {
            pub fn create() @import("clap-bindings").ext.state.Plugin {
                return shared.ext.state.create(ParamsType, PluginType);
            }
        };
        pub const GUI = shared.gui.Gui(PluginType, ViewType);
        pub const VoiceInfo = VoiceInfoType;
        pub const ThreadPool = ThreadPoolType;
        /// Prefer shared.ext.undo; UndoType kept for plugins that re-export it.
        pub const Undo = UndoType;
    };
}

/// Instrument extensions using shared undo/voice_info; params + thread pool still per-plugin.
pub fn InstrumentExtensions(
    comptime PluginType: type,
    comptime ViewType: type,
    comptime ParamsType: type,
    comptime ThreadPoolType: type,
) type {
    const shared = @import("root.zig");
    return Extensions(
        PluginType,
        ViewType,
        ParamsType,
        struct {
            pub fn create() @import("clap-bindings").ext.voice_info.Plugin {
                return shared.ext.voice_info.create(PluginType);
            }
        },
        ThreadPoolType,
        shared.ext.undo,
    );
}
