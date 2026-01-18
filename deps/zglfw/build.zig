const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const options = .{
        .shared = b.option(
            bool,
            "shared",
            "Build GLFW as shared lib",
        ) orelse false,
        .enable_x11 = b.option(
            bool,
            "x11",
            "Whether to build with X11 support (default: true)",
        ) orelse true,
        .enable_wayland = b.option(
            bool,
            "wayland",
            "Whether to build with Wayland support (default: true)",
        ) orelse true,
    };

    const options_step = b.addOptions();
    inline for (std.meta.fields(@TypeOf(options))) |field| {
        options_step.addOption(field.type, field.name, @field(options, field.name));
    }

    const options_module = options_step.createModule();

    const module = b.addModule("root", .{
        .root_source_file = b.path("src/zglfw.zig"),
        .imports = &.{
            .{ .name = "zglfw_options", .module = options_module },
        },
    });

    if (target.result.os.tag == .emscripten) return;

    const glfw = b.addLibrary(.{
        .name = "glfw",
        .linkage = if (options.shared) .dynamic else .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    const is_shared = glfw.linkage == .dynamic;

    if (options.shared and target.result.os.tag == .windows) {
        glfw.root_module.addCMacro("_GLFW_BUILD_DLL", "");
    }

    b.installArtifact(glfw);
    glfw.installHeadersDirectory(b.path("libs/glfw/include"), "", .{});

    addIncludePaths(b, glfw.root_module, target, options);
    // We still need libc enabled for C compilation (headers like `unistd.h`), but
    // when producing a static archive (`libglfw.a`) we must not "link" against
    // non-libc system libs (e.g. `libX11.so`), otherwise Zig will embed the shared
    // object as an archive member and LLD will reject it when consumers link it.
    linkLibC(glfw.root_module);
    if (is_shared) linkPlatformLibs(glfw.root_module, target, options);

    const src_dir = "libs/glfw/src/";
    switch (target.result.os.tag) {
        .windows => {
            glfw.root_module.addCSourceFiles(.{
                .files = &.{
                    src_dir ++ "platform.c",
                    src_dir ++ "monitor.c",
                    src_dir ++ "init.c",
                    src_dir ++ "vulkan.c",
                    src_dir ++ "input.c",
                    src_dir ++ "context.c",
                    src_dir ++ "window.c",
                    src_dir ++ "osmesa_context.c",
                    src_dir ++ "egl_context.c",
                    src_dir ++ "null_init.c",
                    src_dir ++ "null_monitor.c",
                    src_dir ++ "null_window.c",
                    src_dir ++ "null_joystick.c",
                    src_dir ++ "wgl_context.c",
                    src_dir ++ "win32_thread.c",
                    src_dir ++ "win32_init.c",
                    src_dir ++ "win32_monitor.c",
                    src_dir ++ "win32_time.c",
                    src_dir ++ "win32_joystick.c",
                    src_dir ++ "win32_window.c",
                    src_dir ++ "win32_module.c",
                },
                .flags = &.{"-D_GLFW_WIN32"},
            });
        },
        .macos => {
            glfw.root_module.addCSourceFiles(.{
                .files = &.{
                    src_dir ++ "platform.c",
                    src_dir ++ "monitor.c",
                    src_dir ++ "init.c",
                    src_dir ++ "vulkan.c",
                    src_dir ++ "input.c",
                    src_dir ++ "context.c",
                    src_dir ++ "window.c",
                    src_dir ++ "osmesa_context.c",
                    src_dir ++ "egl_context.c",
                    src_dir ++ "null_init.c",
                    src_dir ++ "null_monitor.c",
                    src_dir ++ "null_window.c",
                    src_dir ++ "null_joystick.c",
                    src_dir ++ "posix_thread.c",
                    src_dir ++ "posix_module.c",
                    src_dir ++ "posix_poll.c",
                    src_dir ++ "nsgl_context.m",
                    src_dir ++ "cocoa_time.c",
                    src_dir ++ "cocoa_joystick.m",
                    src_dir ++ "cocoa_init.m",
                    src_dir ++ "cocoa_window.m",
                    src_dir ++ "cocoa_monitor.m",
                },
                .flags = &.{"-D_GLFW_COCOA"},
            });
        },
        .linux => {
            glfw.root_module.addCSourceFiles(.{
                .files = &.{
                    src_dir ++ "platform.c",
                    src_dir ++ "monitor.c",
                    src_dir ++ "init.c",
                    src_dir ++ "vulkan.c",
                    src_dir ++ "input.c",
                    src_dir ++ "context.c",
                    src_dir ++ "window.c",
                    src_dir ++ "osmesa_context.c",
                    src_dir ++ "egl_context.c",
                    src_dir ++ "null_init.c",
                    src_dir ++ "null_monitor.c",
                    src_dir ++ "null_window.c",
                    src_dir ++ "null_joystick.c",
                    src_dir ++ "posix_time.c",
                    src_dir ++ "posix_thread.c",
                    src_dir ++ "posix_module.c",
                },
                .flags = &.{},
            });
            if (options.enable_x11 or options.enable_wayland) {
                glfw.root_module.addCSourceFiles(.{
                    .files = &.{
                        src_dir ++ "xkb_unicode.c",
                        src_dir ++ "linux_joystick.c",
                        src_dir ++ "posix_poll.c",
                    },
                    .flags = &.{},
                });
            }
            if (options.enable_x11) {
                glfw.root_module.addCSourceFiles(.{
                    .files = &.{
                        src_dir ++ "x11_init.c",
                        src_dir ++ "x11_monitor.c",
                        src_dir ++ "x11_window.c",
                        src_dir ++ "glx_context.c",
                    },
                    .flags = &.{},
                });
                glfw.root_module.addCMacro("_GLFW_X11", "1");
            }
            if (options.enable_wayland) {
                glfw.root_module.addCSourceFiles(.{
                    .files = &.{
                        src_dir ++ "wl_init.c",
                        src_dir ++ "wl_monitor.c",
                        src_dir ++ "wl_window.c",
                    },
                    .flags = &.{},
                });
                glfw.root_module.addIncludePath(b.path(src_dir ++ "wayland"));
                glfw.root_module.addCMacro("_GLFW_WAYLAND", "1");
            }
        },
        else => {},
    }
    addIncludePaths(b, module, target, options);

    const test_step = b.step("test", "Run zglfw tests");
    const tests = b.addTest(.{
        .name = "zglfw-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zglfw.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addIncludePaths(b, tests.root_module, target, options);
    linkLibC(tests.root_module);
    linkPlatformLibs(tests.root_module, target, options);
    tests.root_module.addImport("zglfw_options", options_module);
    tests.root_module.linkLibrary(glfw);
    b.installArtifact(tests);
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addIncludePaths(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, options: anytype) void {
    module.addIncludePath(b.path("libs/glfw/include"));
    _ = options;
    switch (target.result.os.tag) {
        .linux => {},
        else => {},
    }
}

fn linkLibC(module: *std.Build.Module) void {
    module.linkSystemLibrary("c", .{});
}

fn linkPlatformLibs(module: *std.Build.Module, target: std.Build.ResolvedTarget, options: anytype) void {
    switch (target.result.os.tag) {
        .windows => {
            module.linkSystemLibrary("gdi32", .{});
            module.linkSystemLibrary("user32", .{});
            module.linkSystemLibrary("shell32", .{});
        },
        .macos => {
            module.linkSystemLibrary("objc", .{});
            module.linkFramework("IOKit", .{});
            module.linkFramework("CoreFoundation", .{});
            module.linkFramework("Metal", .{});
            module.linkFramework("AppKit", .{});
            module.linkFramework("CoreServices", .{});
            module.linkFramework("CoreGraphics", .{});
            module.linkFramework("Foundation", .{});
        },
        .linux => {
            if (options.enable_x11) {
                module.addCMacro("_GLFW_X11", "1");
                module.linkSystemLibrary("X11", .{});
            }
            if (options.enable_wayland) {
                module.addCMacro("_GLFW_WAYLAND", "1");
                module.linkSystemLibrary("wayland-client", .{});
                module.linkSystemLibrary("wayland-cursor", .{});
                module.linkSystemLibrary("wayland-egl", .{});
                module.linkSystemLibrary("xkbcommon", .{});
            }
        },
        else => {},
    }
}
