//! Bespoke DVUI editors for the Flux built-ins, dispatched by CLAP plugin id.
//!
//! Replaces the old plugin-side zgui windows: the built-ins are linked
//! in-process (`plugin/builtin_load.zig`), so the host draws their editors
//! inside the device rack card. Anything without an entry here falls back to
//! the generic `param_chrome` grid.

const std = @import("std");
const dvui = @import("dvui");
const clap = @import("clap-bindings");

const controls = @import("controls.zig");
const stock_fx = @import("stock_fx.zig");
const zsynth = @import("zsynth.zig");
const zminimoog = @import("zminimoog.zig");
const zportafm = @import("zportafm.zig");
const flux_builtins = @import("../../../builtins/root.zig");
const instrument_registry = @import("../../../builtins/instruments/registry.zig");

pub const Target = controls.Target;

const Editor = union(enum) {
    fx: flux_builtins.Kind,
    zsynth,
    zminimoog,
    zportafm,
};

fn editorFor(plugin: *const clap.Plugin) ?Editor {
    const id = std.mem.sliceTo(plugin.descriptor.id, 0);
    if (flux_builtins.Kind.fromId(id)) |kind| return .{ .fx = kind };
    const kind = instrument_registry.Kind.fromId(id) orelse return null;
    return switch (kind) {
        .zsynth => .zsynth,
        .zminimoog => .zminimoog,
        .zportafm => .zportafm,
    };
}

/// True when this plugin has a bespoke editor (so the rack skips param chrome).
pub fn has(plugin: *const clap.Plugin) bool {
    return editorFor(plugin) != null;
}

/// Natural card width for the bespoke editor, or null when there is none.
pub fn cardWidth(plugin: *const clap.Plugin) ?f32 {
    return switch (editorFor(plugin) orelse return null) {
        .fx => |kind| stock_fx.cardWidth(kind),
        .zsynth => zsynth.cardWidth(),
        .zminimoog => zminimoog.cardWidth(),
        .zportafm => zportafm.cardWidth(),
    };
}

/// Draw the bespoke editor into the current rack card body.
/// Returns false when this plugin has no editor (caller draws param chrome).
pub fn draw(plugin: *const clap.Plugin, target: Target, id_extra: usize) bool {
    switch (editorFor(plugin) orelse return false) {
        .fx => |kind| stock_fx.draw(plugin, kind, target, id_extra),
        .zsynth => zsynth.draw(plugin, target, id_extra),
        .zminimoog => zminimoog.draw(plugin, target, id_extra),
        .zportafm => zportafm.draw(plugin, target, id_extra),
    }
    return true;
}
