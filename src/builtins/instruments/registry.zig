//! Static (in-process) registry for the Flux built-in instruments.
//!
//! The instruments have no plugin-side GUI, so nothing here pulls a renderer:
//! the Flux DVUI host draws their editors (`src/ui/panels/editors/`) directly
//! against the in-process plugin. Same shape as the stock FX registry in
//! `src/builtins/root.zig`.

const std = @import("std");
const clap = @import("clap-bindings");

pub const ZSynth = @import("zsynth/plugin.zig").Plugin;
pub const ZMinimoog = @import("zminimoog/plugin.zig").Plugin;
pub const ZPortaFM = @import("zportafm/plugin.zig").Plugin;

pub const Kind = enum {
    zsynth,
    zminimoog,
    zportafm,

    pub fn id(self: Kind) []const u8 {
        return switch (self) {
            .zsynth => "com.juge.zsynth",
            .zminimoog => "com.fourlex.zminimoog",
            .zportafm => "com.fourlex.zportafm",
        };
    }

    pub fn fromId(plugin_id: []const u8) ?Kind {
        inline for (comptime std.enums.values(Kind)) |kind| {
            if (std.mem.eql(u8, plugin_id, kind.id())) return kind;
        }
        return null;
    }
};

pub fn isBuiltinInstrumentId(plugin_id: []const u8) bool {
    return Kind.fromId(plugin_id) != null;
}

/// Instantiate a built-in instrument in-process. The returned CLAP plugin owns
/// itself: `destroy` frees the heap instance (see each plugin's `_destroy`).
pub fn initById(
    allocator: std.mem.Allocator,
    host: *const clap.Host,
    plugin_id: []const u8,
) !*clap.Plugin {
    const kind = Kind.fromId(plugin_id) orelse return error.UnknownBuiltin;
    return switch (kind) {
        .zsynth => &(try ZSynth.init(allocator, host)).plugin,
        .zminimoog => &(try ZMinimoog.init(allocator, host)).plugin,
        .zportafm => &(try ZPortaFM.init(allocator, host)).plugin,
    };
}

test "instrument ids round-trip" {
    try std.testing.expectEqual(Kind.zsynth, Kind.fromId("com.juge.zsynth").?);
    try std.testing.expectEqual(Kind.zminimoog, Kind.fromId("com.fourlex.zminimoog").?);
    try std.testing.expectEqual(Kind.zportafm, Kind.fromId("com.fourlex.zportafm").?);
    try std.testing.expect(Kind.fromId("com.flux.builtin.equalizer") == null);
    try std.testing.expect(isBuiltinInstrumentId("com.juge.zsynth"));
}
