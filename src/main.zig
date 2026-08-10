//! Flux application entry (DVUI host).
//!
//! Built in Flux's root build graph with full AudioEngine.
//! `zig build run-flux` → `zig-out/bin/flux`.
//!
//! UI lives under `src/ui/`.

const builtin = @import("builtin");
const std = @import("std");
const dvui = @import("dvui");
const root = @import("ui/root.zig");
const bench = @import("ui/bench.zig");

/// Force native Wayland *before any SDL call*. Without this, SDL 3 falls back
/// to XWayland when the compositor lacks fifo-v1 — the window is then 1× pixels
/// and the compositor upscales → blurry UI on HiDPI panels (e.g. 2560×1600 @ 2).
///
/// Override anytime with `SDL_VIDEO_DRIVER=x11` (or any non-empty explicit driver).
fn preferNativeWayland() void {
    if (comptime builtin.os.tag != .linux) return;

    const c = struct {
        extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    };

    if (c.getenv("WAYLAND_DISPLAY") == null and c.getenv("WAYLAND_SOCKET") == null) return;

    // Respect a non-empty user override (empty string counts as unset).
    if (c.getenv("SDL_VIDEO_DRIVER")) |v| {
        if (v[0] != 0) return;
    }
    if (c.getenv("SDL_VIDEODRIVER")) |v| {
        if (v[0] != 0) return;
    }

    _ = c.setenv("SDL_VIDEO_DRIVER", "wayland", 1);
    // Stamp SDL hint at override priority so the fifo-v1→XWayland auto-fallback
    // cannot win (SDL treats env as override-priority; we set both).
    const sdl = dvui.backend.c;
    _ = sdl.SDL_SetHintWithPriority(
        sdl.SDL_HINT_VIDEO_DRIVER,
        "wayland",
        @as(sdl.SDL_HintPriority, @intCast(sdl.SDL_HINT_OVERRIDE)),
    );
    std.log.info("HiDPI: forcing SDL_VIDEO_DRIVER=wayland (set SDL_VIDEO_DRIVER=x11 to override)", .{});
}

fn startOptions() dvui.App.StartOptions {
    // Belt-and-suspenders: also run when App config is resolved (may be after
    // some SDL metadata calls, so custom main does the early force).
    preferNativeWayland();
    return .{
        .size = .{ .w = 1100.0, .h = 720.0 },
        .min_size = .{ .w = 640.0, .h = 400.0 },
        .title = "Flux",
        .window_init_options = .{
            .theme = dvui.Theme.builtin.adwaita_dark,
        },
    };
}

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = &startOptions },
    .frameFn = root.frame,
    .initFn = root.init,
    .deinitFn = root.deinit,
};

/// Custom main so Wayland is forced before SDL metadata / logging / Init.
///
/// Bench modes (no window): `FLUX_KERNEL_BENCH=1`, `FLUX_HEADLESS_BENCH=1`
/// (see `ui/bench.zig`, `audio/kernel_bench.zig`, `docs/dvui-migration.md`).
pub fn main(main_init: std.process.Init) !u8 {
    preferNativeWayland();
    if (try bench.maybeRunFromEnv(main_init.gpa, main_init.io)) return 0;
    return try dvui.backend.main(main_init);
}

pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};
