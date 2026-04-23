const builtin = @import("builtin");
const std = @import("std");

const clap = @import("clap-bindings");
const options = @import("options");

pub const Display = opaque {};
pub const Window = c_ulong;

const enabled = builtin.os.tag == .linux and options.use_x11;

var threads_initialized = std.atomic.Value(bool).init(false);

extern fn XInitThreads() callconv(.c) c_int;
extern fn XOpenDisplay(?[*:0]const u8) callconv(.c) ?*Display;
extern fn XCloseDisplay(*Display) callconv(.c) c_int;
extern fn XDefaultRootWindow(*Display) callconv(.c) Window;
extern fn XCreateSimpleWindow(*Display, Window, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) Window;
extern fn XStoreName(*Display, Window, [*:0]const u8) callconv(.c) c_int;
extern fn XMapWindow(*Display, Window) callconv(.c) c_int;
extern fn XDestroyWindow(*Display, Window) callconv(.c) c_int;
extern fn XFlush(*Display) callconv(.c) c_int;

pub fn initThreads() void {
    if (comptime !enabled) return;
    if (threads_initialized.swap(true, .acq_rel)) return;

    if (XInitThreads() == 0) {
        std.log.warn("XInitThreads failed; X11 plugin GUIs may be unstable", .{});
    }
}

pub fn isAvailable() bool {
    if (comptime !enabled) return false;
    return std.c.getenv("DISPLAY") != null;
}

pub const HostWindow = struct {
    display: *Display,
    window: Window,

    pub fn create(width: u32, height: u32, title: [:0]const u8) !HostWindow {
        if (!isAvailable()) return error.X11Unavailable;

        initThreads();

        const display = XOpenDisplay(null) orelse return error.X11OpenDisplayFailed;
        errdefer _ = XCloseDisplay(display);

        const root = XDefaultRootWindow(display);
        const xwin = XCreateSimpleWindow(
            display,
            root,
            0,
            0,
            @intCast(@max(width, 1)),
            @intCast(@max(height, 1)),
            0,
            0,
            0,
        );
        if (xwin == 0) return error.X11CreateWindowFailed;
        errdefer _ = XDestroyWindow(display, xwin);

        _ = XStoreName(display, xwin, title.ptr);
        _ = XMapWindow(display, xwin);
        _ = XFlush(display);

        return .{
            .display = display,
            .window = xwin,
        };
    }

    pub fn destroy(self: *HostWindow) void {
        if (self.window != 0) {
            _ = XDestroyWindow(self.display, self.window);
            self.window = 0;
        }
        _ = XCloseDisplay(self.display);
    }

    pub fn clapWindow(self: HostWindow) clap.ext.gui.Window {
        return .{
            .api = clap.ext.gui.window_api.x11,
            .data = .{ .x11 = self.window },
        };
    }
};
