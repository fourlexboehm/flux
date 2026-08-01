//! Flux application entry (DVUI host).
//!
//! Built via DVUI's package root (Zig 0.17 dependency issue — see
//! docs/dvui-migration.md). Roots at this tree (`src/`) with full AudioEngine.
//! `zig build run-flux` → `zig-out/bin/flux`.
//!
//! UI lives under `src/ui/`. Legacy zgui host: `src/main_zgui.zig` + `src/ui_zgui/`
//! (reference only; recover a runnable build from git worktree if needed).

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
