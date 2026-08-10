//! Flux application entry (DVUI host).
//!
//! Built in Flux's root build graph with full AudioEngine.
//! `zig build run-flux` → `zig-out/bin/flux`.
//!
//! UI lives under `src/ui/`.

const std = @import("std");
const dvui = @import("dvui");
const root = @import("ui/root.zig");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 1100.0, .h = 720.0 },
            .min_size = .{ .w = 640.0, .h = 400.0 },
            .title = "Flux",
            .window_init_options = .{
                .theme = dvui.Theme.builtin.adwaita_dark,
            },
        },
    },
    .frameFn = root.frame,
    .initFn = root.init,
    .deinitFn = root.deinit,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};
