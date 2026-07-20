const builtin = @import("builtin");

extern fn flux_native_drop_init(ns_view: ?*anyopaque) void;
extern fn flux_native_drop_poll(buf: [*]u8, buf_size: c_int) c_int;
extern fn flux_native_drop_shutdown() void;

var linux_pending_paths: [8][1024]u8 = @splat(@splat(0));
var linux_pending_lens: [8]usize = @splat(0);
var linux_pending_count: usize = 0;

pub fn initMac(view: ?*anyopaque) void {
    if (builtin.os.tag == .macos) {
        flux_native_drop_init(view);
    }
}

pub fn pollMac(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const len = flux_native_drop_poll(buf.ptr, @intCast(buf.len));
    if (len <= 0) return null;
    return buf[0..@intCast(len)];
}

pub fn pollLinux(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    if (linux_pending_count == 0) return null;
    const len = linux_pending_lens[0];
    const n = @min(len, buf.len);
    @memcpy(buf[0..n], linux_pending_paths[0][0..n]);
    var i: usize = 1;
    while (i < linux_pending_count) : (i += 1) {
        linux_pending_paths[i - 1] = linux_pending_paths[i];
        linux_pending_lens[i - 1] = linux_pending_lens[i];
    }
    linux_pending_count -= 1;
    return buf[0..n];
}

pub fn onGlfwDrop(path_count: c_int, paths: [*][*:0]const u8) void {
    var i: c_int = 0;
    while (i < path_count and linux_pending_count < linux_pending_paths.len) : (i += 1) {
        const path = std.mem.span(paths[@intCast(i)]);
        const n = @min(path.len, linux_pending_paths[0].len);
        @memcpy(linux_pending_paths[linux_pending_count][0..n], path[0..n]);
        linux_pending_lens[linux_pending_count] = n;
        linux_pending_count += 1;
    }
}

pub fn shutdownMac() void {
    if (builtin.os.tag == .macos) {
        flux_native_drop_shutdown();
    }
}

const std = @import("std");
