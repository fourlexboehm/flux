const std = @import("std");
const clap = @import("clap-bindings");
const Plugin = @import("../plugin.zig");

var host_undo: ?*const clap.ext.undo.Host = null;
var host_ptr: ?*const clap.Host = null;

pub fn init(host: *const clap.Host) void {
    host_ptr = host;
    if (host.getExtension(host, clap.ext.undo.id)) |ext| {
        host_undo = @ptrCast(@alignCast(ext));
        std.log.info("ZObx: Host supports CLAP undo extension", .{});
    } else {
        std.log.info("ZObx: Host does not support CLAP undo extension", .{});
    }
}

pub fn beginChange() void {
    if (host_undo) |undo| {
        if (host_ptr) |host| {
            undo.begin_change(host);
        }
    }
}

pub fn cancelChange() void {
    if (host_undo) |undo| {
        if (host_ptr) |host| {
            undo.cancel_change(host);
        }
    }
}

pub fn changeMade(name: [*:0]const u8) void {
    if (host_undo) |undo| {
        if (host_ptr) |host| {
            undo.change_made(host, name, null, 0, false);
        }
    }
}

pub fn requestUndo() void {
    if (host_undo) |undo| {
        if (host_ptr) |host| {
            undo.request_undo(host);
        }
    }
}

pub fn requestRedo() void {
    if (host_undo) |undo| {
        if (host_ptr) |host| {
            undo.request_redo(host);
        }
    }
}

pub fn isSupported() bool {
    return host_undo != null;
}
