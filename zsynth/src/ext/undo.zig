const std = @import("std");
const clap = @import("clap-bindings");
const Plugin = @import("../plugin.zig");

/// Host undo extension (cached on plugin init)
var host_undo: ?*const clap.ext.undo.Host = null;
var host_ptr: ?*const clap.Host = null;

/// Initialize the undo extension by caching the host's undo interface
pub fn init(host: *const clap.Host) void {
    host_ptr = host;
    if (host.getExtension(host, clap.ext.undo.id)) |ext| {
        host_undo = @ptrCast(@alignCast(ext));
        std.log.info("ZSynth: Host supports CLAP undo extension", .{});
    } else {
        std.log.info("ZSynth: Host does not support CLAP undo extension", .{});
    }
}

/// Call this before starting a change (e.g., mouse down on slider)
pub fn beginChange() void {
    if (host_undo) |undo| {
        if (host_ptr) |host| {
            undo.begin_change(host);
        }
    }
}

/// Call this to cancel a pending change
pub fn cancelChange() void {
    if (host_undo) |undo| {
        if (host_ptr) |host| {
            undo.cancel_change(host);
        }
    }
}

/// Call this when a change is complete (e.g., mouse up, or instant change)
pub fn changeMade(name: [*:0]const u8) void {
    if (host_undo) |undo| {
        if (host_ptr) |host| {
            // No delta support for now - host will capture full state
            undo.change_made(host, name, null, 0, false);
        }
    }
}

/// Request the host to perform undo
pub fn requestUndo() void {
    if (host_undo) |undo| {
        if (host_ptr) |host| {
            undo.request_undo(host);
        }
    }
}

/// Request the host to perform redo
pub fn requestRedo() void {
    if (host_undo) |undo| {
        if (host_ptr) |host| {
            undo.request_redo(host);
        }
    }
}

/// Check if host supports undo
pub fn isSupported() bool {
    return host_undo != null;
}
