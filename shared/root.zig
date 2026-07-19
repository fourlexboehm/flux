pub const clap_entry = @import("clap_entry.zig");
pub const core = @import("core.zig");
pub const gui = @import("gui.zig");
pub const imgui_style = @import("imgui_style.zig");
pub const plugin_extensions = @import("plugin_extensions.zig");

pub const ext = struct {
    pub const audioports = @import("ext/audioports.zig");
    pub const noteports = @import("ext/noteports.zig");
    pub const state = @import("ext/state.zig");
    pub const params = @import("ext/params.zig");
    pub const undo = @import("ext/undo.zig");
    pub const voice_info = @import("ext/voice_info.zig");
    pub const thread_pool = @import("ext/thread_pool.zig");
};
