//! Per-plugin-instance CLAP host undo helper (optional host extension).

const std = @import("std");
const clap = @import("clap-bindings");

pub const State = struct {
    host: *const clap.Host,
    host_undo: ?*const clap.ext.undo.Host,

    pub fn init(host: *const clap.Host) State {
        const host_undo: ?*const clap.ext.undo.Host = if (host.getExtension(host, clap.ext.undo.id)) |ext|
            @ptrCast(@alignCast(ext))
        else
            null;
        std.log.info("Host {s} CLAP undo extension", .{if (host_undo != null) "supports" else "does not support"});
        return .{ .host = host, .host_undo = host_undo };
    }

    pub fn beginChange(self: *const State) void {
        if (self.host_undo) |undo| undo.begin_change(self.host);
    }

    pub fn cancelChange(self: *const State) void {
        if (self.host_undo) |undo| undo.cancel_change(self.host);
    }

    pub fn changeMade(self: *const State, name: [*:0]const u8) void {
        if (self.host_undo) |undo| undo.change_made(self.host, name, null, 0, false);
    }

    pub fn requestUndo(self: *const State) void {
        if (self.host_undo) |undo| undo.request_undo(self.host);
    }

    pub fn requestRedo(self: *const State) void {
        if (self.host_undo) |undo| undo.request_redo(self.host);
    }

    pub fn isSupported(self: *const State) bool {
        return self.host_undo != null;
    }
};
