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
        pub const Undo = UndoType;
    };
}
