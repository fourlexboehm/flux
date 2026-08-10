const builtin = @import("builtin");
const std = @import("std");

const clap = @import("clap-bindings");
const options = @import("options");

pub const Display = opaque {};
pub const Window = c_ulong;
pub const Atom = c_ulong;

const enabled = builtin.os.tag == .linux and options.use_x11;

var threads_initialized = std.atomic.Value(bool).init(false);

// Minimal Xlib surface used by host-parented CLAP GUIs (XWayland on Wayland).
extern fn XInitThreads() callconv(.c) c_int;
extern fn XOpenDisplay(?[*:0]const u8) callconv(.c) ?*Display;
extern fn XCloseDisplay(*Display) callconv(.c) c_int;
extern fn XDefaultRootWindow(*Display) callconv(.c) Window;
extern fn XDefaultScreen(*Display) callconv(.c) c_int;
extern fn XDefaultVisual(*Display, c_int) callconv(.c) ?*anyopaque;
extern fn XDefaultColormap(*Display, c_int) callconv(.c) c_ulong;
extern fn XDefaultDepth(*Display, c_int) callconv(.c) c_int;
extern fn XBlackPixel(*Display, c_int) callconv(.c) c_ulong;
extern fn XWhitePixel(*Display, c_int) callconv(.c) c_ulong;
extern fn XCreateWindow(
    *Display,
    Window,
    c_int,
    c_int,
    c_uint,
    c_uint,
    c_uint,
    c_int,
    c_uint,
    ?*anyopaque,
    c_ulong,
    *XSetWindowAttributes,
) callconv(.c) Window;
extern fn XStoreName(*Display, Window, [*:0]const u8) callconv(.c) c_int;
extern fn XMapWindow(*Display, Window) callconv(.c) c_int;
extern fn XDestroyWindow(*Display, Window) callconv(.c) c_int;
extern fn XFlush(*Display) callconv(.c) c_int;
extern fn XSelectInput(*Display, Window, c_long) callconv(.c) c_int;
extern fn XPending(*Display) callconv(.c) c_int;
extern fn XNextEvent(*Display, *XEvent) callconv(.c) c_int;
extern fn XInternAtom(*Display, [*:0]const u8, c_int) callconv(.c) Atom;
extern fn XSetWMProtocols(*Display, Window, *Atom, c_int) callconv(.c) c_int;
extern fn XResizeWindow(*Display, Window, c_uint, c_uint) callconv(.c) c_int;

const InputOutput: c_uint = 1;
const CWBackPixel: c_ulong = 1 << 1;
const CWBorderPixel: c_ulong = 1 << 3;
const CWColormap: c_ulong = 1 << 13;
const CWEventMask: c_ulong = 1 << 11;

const StructureNotifyMask: c_long = 1 << 17;
const ExposureMask: c_long = 1 << 15;
const KeyPressMask: c_long = 1 << 0;
const KeyReleaseMask: c_long = 1 << 1;
const ButtonPressMask: c_long = 1 << 2;
const ButtonReleaseMask: c_long = 1 << 3;
const PointerMotionMask: c_long = 1 << 6;
const FocusChangeMask: c_long = 1 << 21;

const ClientMessage: c_int = 33;
const ConfigureNotify: c_int = 22;
const Expose: c_int = 12;

const XSetWindowAttributes = extern struct {
    background_pixmap: c_ulong = 0,
    background_pixel: c_ulong = 0,
    border_pixmap: c_ulong = 0,
    border_pixel: c_ulong = 0,
    bit_gravity: c_int = 0,
    win_gravity: c_int = 0,
    backing_store: c_int = 0,
    backing_planes: c_ulong = 0,
    backing_pixel: c_ulong = 0,
    save_under: c_int = 0,
    event_mask: c_long = 0,
    do_not_propagate_mask: c_long = 0,
    override_redirect: c_int = 0,
    colormap: c_ulong = 0,
    cursor: c_ulong = 0,
};

// Only fields we need from the XEvent union.
const XEvent = extern struct {
    type: c_int,
    pad: [24]c_long,
};

const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: extern union {
        b: [20]u8,
        s: [10]c_short,
        l: [5]c_long,
    },
};

const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    event: Window,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: Window,
    override_redirect: c_int,
};

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
    width: u32 = 0,
    height: u32 = 0,
    wm_delete: Atom = 0,
    /// Set when the user closes the window via the WM (title bar X).
    close_requested: bool = false,

    pub fn create(width: u32, height: u32, title: [:0]const u8) !HostWindow {
        if (!isAvailable()) return error.X11Unavailable;

        initThreads();

        const display = XOpenDisplay(null) orelse return error.X11OpenDisplayFailed;
        errdefer _ = XCloseDisplay(display);

        const screen = XDefaultScreen(display);
        const root = XDefaultRootWindow(display);
        const visual = XDefaultVisual(display, screen);
        const colormap = XDefaultColormap(display, screen);
        const depth = XDefaultDepth(display, screen);
        const w: u32 = @max(width, 1);
        const h: u32 = @max(height, 1);

        // Default visual + colormap so OpenGL/X11 plugins under XWayland get a
        // real drawable instead of a black XCreateSimpleWindow shell.
        var attrs: XSetWindowAttributes = .{
            .background_pixel = XBlackPixel(display, screen),
            .border_pixel = XBlackPixel(display, screen),
            .colormap = colormap,
            .event_mask = StructureNotifyMask | ExposureMask | KeyPressMask | KeyReleaseMask |
                ButtonPressMask | ButtonReleaseMask | PointerMotionMask | FocusChangeMask,
        };
        const valuemask = CWBackPixel | CWBorderPixel | CWColormap | CWEventMask;

        const xwin = XCreateWindow(
            display,
            root,
            0,
            0,
            @intCast(w),
            @intCast(h),
            0,
            depth,
            InputOutput,
            visual,
            valuemask,
            &attrs,
        );
        if (xwin == 0) return error.X11CreateWindowFailed;
        errdefer _ = XDestroyWindow(display, xwin);

        _ = XStoreName(display, xwin, title.ptr);
        _ = XSelectInput(display, xwin, attrs.event_mask);

        var wm_delete = XInternAtom(display, "WM_DELETE_WINDOW", 0);
        if (wm_delete != 0) {
            _ = XSetWMProtocols(display, xwin, &wm_delete, 1);
        }

        _ = XMapWindow(display, xwin);
        _ = XFlush(display);

        return .{
            .display = display,
            .window = xwin,
            .width = w,
            .height = h,
            .wm_delete = wm_delete,
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

    pub fn resize(self: *HostWindow, width: u32, height: u32) void {
        const w = @max(width, 1);
        const h = @max(height, 1);
        if (w == self.width and h == self.height) return;
        self.width = w;
        self.height = h;
        _ = XResizeWindow(self.display, self.window, @intCast(w), @intCast(h));
        _ = XFlush(self.display);
    }

    /// Drain pending X events for this host window. Call from the UI tick
    /// while any parented plugin GUI is open so expose/configure/delete run.
    pub fn pumpEvents(self: *HostWindow) void {
        if (comptime !enabled) return;
        // Refresh delete atom if this HostWindow was reconstructed from slot fields.
        if (self.wm_delete == 0) {
            self.wm_delete = XInternAtom(self.display, "WM_DELETE_WINDOW", 0);
        }
        while (XPending(self.display) > 0) {
            var event: XEvent = undefined;
            _ = XNextEvent(self.display, &event);
            switch (event.type) {
                ClientMessage => {
                    const cm: *const XClientMessageEvent = @ptrCast(@alignCast(&event));
                    if (self.wm_delete != 0 and cm.data.l[0] == @as(c_long, @intCast(self.wm_delete))) {
                        self.close_requested = true;
                    }
                },
                ConfigureNotify => {
                    const cfg: *const XConfigureEvent = @ptrCast(@alignCast(&event));
                    if (cfg.window == self.window and cfg.width > 0 and cfg.height > 0) {
                        self.width = @intCast(cfg.width);
                        self.height = @intCast(cfg.height);
                    }
                },
                Expose => {},
                else => {},
            }
        }
    }
};
