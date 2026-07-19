pub const Kind = @import("flux_param_table").Kind;
pub const Plugin = @import("plugin.zig").Plugin;
pub const Params = @import("params.zig").Params;
pub const params = @import("params.zig");
pub const param_table = @import("flux_param_table");
pub const view = @import("view.zig");
pub const undo = @import("undo.zig");
pub const equalizer = @import("dsp/equalizer.zig");
pub const dynamics = @import("dsp/dynamics.zig");

/// Instantiate a builtin FX by plugin id string.
pub fn initById(allocator: std.mem.Allocator, host: *const clap.Host, plugin_id: []const u8) !*Plugin {
    const kind = Kind.fromId(plugin_id) orelse return error.UnknownBuiltin;
    return Plugin.init(allocator, host, kind);
}

pub fn isBuiltinFxId(plugin_id: []const u8) bool {
    return Kind.fromId(plugin_id) != null;
}

const std = @import("std");
const clap = @import("clap-bindings");
