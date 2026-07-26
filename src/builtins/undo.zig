//! CLAP host undo helpers for stock builtin FX.

const clap = @import("clap-bindings");
const Plugin = @import("plugin.zig").Plugin;

fn hostUndo(plugin: *const Plugin) ?*const clap.ext.undo.Host {
    const ext = plugin.host.getExtension(plugin.host, clap.ext.undo.id) orelse return null;
    return @ptrCast(@alignCast(ext));
}

/// Call before a continuous edit starts (e.g. mouse down on slider).
pub fn beginChange(plugin: *const Plugin) void {
    if (hostUndo(plugin)) |undo| undo.begin_change(plugin.host);
}

/// Call to discard a pending change (e.g. slider released with no edit).
pub fn cancelChange(plugin: *const Plugin) void {
    if (hostUndo(plugin)) |undo| undo.cancel_change(plugin.host);
}

/// Call when a change is complete (gesture end or instant control).
pub fn changeMade(plugin: *const Plugin, name: [*:0]const u8) void {
    if (hostUndo(plugin)) |undo| {
        // No delta — host captures full plugin state.
        undo.change_made(plugin.host, name, null, 0, false);
    }
}
