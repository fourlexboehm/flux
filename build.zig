const builtin = @import("builtin");
const std = @import("std");
const Step = std.Build.Step;

pub fn build(b: *std.Build) void {
    const wait_for_debugger = b.option(
        bool,
        "wait_for_debugger",
        "Stall when creating a plugin from the factory",
    ) orelse false;

    const profiling = b.option(
        bool,
        "profiling",
        "Enable profiling with tracy. Profiling is enabled by default in debug builds, but not in release builds.",
    ) orelse false;

    const disable_profiling = b.option(
        bool,
        "disable_profiling",
        "Disable profiling. This will override the enable profiling flag",
    ) orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    const GuiBackend = enum { osx_metal, win32_dx12, glfw_opengl3 };
    const default_gui_backend: GuiBackend = switch (target_os) {
        .macos => .osx_metal,
        .windows => .win32_dx12,
        else => .glfw_opengl3,
    };
    const gui_backend = b.option(GuiBackend, "gui-backend", "GUI backend (default: auto-detect from target)") orelse default_gui_backend;

    const use_wayland = b.option(
        bool,
        "wayland",
        "Use Wayland on Linux (default: true)",
    ) orelse (gui_backend == .glfw_opengl3);
    const use_x11 = b.option(
        bool,
        "x11",
        "Use X11/XWayland on Linux for plugin windows (default: true with GLFW)",
    ) orelse (gui_backend == .glfw_opengl3);
    const use_llvm = b.option(bool, "use-llvm", "Use LLVM backend (slower builds, required for some optimizations)") orelse (target_os == .macos);
    const no_lib = b.option(bool, "no-lib", "Skip building the CLAP plugin library") orelse false;
    const incremental = b.option(bool, "incremental", "Enable incremental linking (faster rebuilds, but always re-links even when nothing changed)") orelse false;
    const enable_segfault_handler = b.option(
        bool,
        "enable_segfault_handler",
        "Enable std segfault handler for debug backtraces",
    ) orelse (optimize == .Debug);
    const dep_target = .{
        .target = target,
    };
    const clap_bindings = b.dependency("clap-bindings", dep_target);
    const regex = b.dependency("regex", dep_target);
    const zgui = b.dependency("zgui", .{
        .target = target,
        .shared = false,
        .with_implot = true,
        .backend = gui_backend,
    });
    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .shared = false,
        .x11 = use_x11,
        .wayland = use_wayland,
    });
    const zopengl = b.dependency("zopengl", dep_target);
    const zaudio = b.dependency("zaudio", dep_target);
    const objc = b.dependency("mach-objc", dep_target);
    const objc_no_helpers = b.createModule(.{
        .root_source_file = objc.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const libz_jobs = b.dependency("libz_jobs", dep_target);
    const zig_xml = b.dependency("zig-xml", dep_target);
    const portmidi_zig = b.dependency("portmidi-zig", dep_target);
    const wdf = b.dependency("wdf", dep_target);
    const portmidi_c = b.addTranslateC(.{
        .root_source_file = portmidi_zig.path("pm_common/portmidi.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    portmidi_c.addIncludePath(portmidi_zig.path("pm_common"));
    const emu2413_c = b.addTranslateC(.{
        .root_source_file = b.path("zportafm/native/emu2413/emu2413.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    emu2413_c.addIncludePath(b.path("zportafm/native"));

    const ztracy = b.dependency("ztracy", .{
        .target = target,
        .enable_ztracy = (builtin.mode == .Debug or profiling == true) and !disable_profiling,
        .callstack = 20,
        .on_demand = true,
    });

    const lib_module = b.createModule(.{
        .root_source_file = b.path("zsynth/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe_module = b.createModule(.{
        .root_source_file = b.path("zsynth/src/diag.zig"),
        .target = target,
        .optimize = optimize,
    });
    const flux_module = b.createModule(.{
        .root_source_file = b.path("src/flux/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zsynth_core = b.createModule(.{
        .root_source_file = b.path("zsynth/src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zminimoog_core = b.createModule(.{
        .root_source_file = b.path("zminimoog/src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zportafm_core = b.createModule(.{
        .root_source_file = b.path("zportafm/src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = if (!no_lib) blk: {
        const l = b.addLibrary(.{
            .name = "zsynth",
            .root_module = lib_module,
            .linkage = .dynamic,
            .use_llvm = use_llvm,
        });
        l.incremental = incremental;
        break :blk l;
    } else null;

    const exe = b.addExecutable(.{
        .name = "zsynth",
        .root_module = exe_module,
        .use_llvm = use_llvm,
    });
    exe.incremental = incremental;
    const flux = b.addExecutable(.{
        .name = "flux",
        .root_module = flux_module,
        .use_llvm = use_llvm,
    });
    flux.bundle_ubsan_rt = true;
    flux.incremental = incremental;

    // Allow options to be passed in to source files
    const options = b.addOptions();
    options.addOption(bool, "wait_for_debugger", wait_for_debugger);
    options.addOption(bool, "enable_gui", true);
    options.addOption(bool, "enable_segfault_handler", enable_segfault_handler);
    options.addOption(bool, "use_x11", use_x11);
    const options_core = b.addOptions();
    options_core.addOption(bool, "wait_for_debugger", wait_for_debugger);
    options_core.addOption(bool, "enable_gui", false);
    options_core.addOption(bool, "enable_segfault_handler", enable_segfault_handler);
    const options_core_module = options_core.createModule();

    // Font data is shared between all modules via a common options module
    const font_data = @embedFile("assets/Roboto-Medium.ttf");
    const static_data = b.addOptions();
    static_data.addOption([]const u8, "font", font_data);
    const static_data_module = static_data.createModule();

    const shared = b.createModule(.{
        .root_source_file = b.path("shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    shared.addImport("tracy", ztracy.module("root"));
    shared.addImport("options", options_core_module);
    shared.addImport("static_data", static_data_module);
    shared.addImport("zgui", zgui.module("root"));
    shared.addImport("zglfw", zglfw.module("root"));
    shared.addImport("zopengl", zopengl.module("root"));
    if (target_os == .macos) {
        objc_no_helpers.linkSystemLibrary("objc", .{});
        objc_no_helpers.linkFramework("AppKit", .{});
        objc_no_helpers.linkFramework("CoreVideo", .{});
        objc_no_helpers.linkFramework("QuartzCore", .{});

        shared.addImport("objc", objc_no_helpers);
    }

    const build_targets: []const *Step.Compile = if (no_lib) &.{exe} else &.{ lib.?, exe };
    for (build_targets) |pkg| {
        // Libraries
        pkg.root_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
        pkg.root_module.addImport("regex", regex.module("regex"));
        pkg.root_module.addImport("wdf", wdf.module("wdf"));
        pkg.root_module.addImport("shared", shared);

        // GUI Related libraries
        pkg.root_module.addImport("zgui", zgui.module("root"));
        pkg.root_module.linkLibrary(zgui.artifact("imgui"));
        pkg.root_module.addImport("zglfw", zglfw.module("root"));
        pkg.root_module.linkLibrary(zglfw.artifact("glfw"));
        pkg.root_module.addImport("zopengl", zopengl.module("root"));
        pkg.root_module.linkLibrary(zopengl.artifact("zopengl"));

        // Profiling
        pkg.root_module.addImport("tracy", ztracy.module("root"));
        pkg.root_module.linkLibrary(ztracy.artifact("tracy"));

        pkg.root_module.addOptions("options", options);
        pkg.root_module.addImport("static_data", static_data_module);

        if (target_os == .macos) {
            pkg.root_module.addImport("objc", objc_no_helpers);
            pkg.root_module.linkFramework("AppKit", .{});
            pkg.root_module.linkFramework("Cocoa", .{});
            pkg.root_module.linkFramework("CoreGraphics", .{});
            pkg.root_module.linkFramework("Foundation", .{});
            pkg.root_module.linkFramework("GameController", .{});
            pkg.root_module.linkFramework("Metal", .{});
            pkg.root_module.linkFramework("QuartzCore", .{});
        }
        if (target_os == .linux) {
            if (use_wayland) {
                pkg.root_module.linkSystemLibrary("wayland-client", .{});
                pkg.root_module.linkSystemLibrary("wayland-cursor", .{});
                pkg.root_module.linkSystemLibrary("wayland-egl", .{});
                pkg.root_module.linkSystemLibrary("xkbcommon", .{});
            }
            if (use_x11) {
                pkg.root_module.linkSystemLibrary("X11", .{});
            }
        }
    }

    zsynth_core.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    zsynth_core.addImport("regex", regex.module("regex"));
    zsynth_core.addImport("zgui", zgui.module("root"));
    zsynth_core.addImport("zglfw", zglfw.module("root"));
    zsynth_core.addImport("zopengl", zopengl.module("root"));
    zsynth_core.addImport("tracy", ztracy.module("root"));
    zsynth_core.addImport("shared", shared);
    zsynth_core.addImport("options", options_core_module);
    zsynth_core.addImport("static_data", static_data_module);
    if (target_os == .macos) {
        zsynth_core.addImport("objc", objc_no_helpers);
    }

    zminimoog_core.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    zminimoog_core.addImport("zgui", zgui.module("root"));
    zminimoog_core.addImport("zglfw", zglfw.module("root"));
    zminimoog_core.addImport("zopengl", zopengl.module("root"));
    zminimoog_core.addImport("tracy", ztracy.module("root"));
    zminimoog_core.addImport("wdf", wdf.module("wdf"));
    zminimoog_core.addImport("shared", shared);
    zminimoog_core.addImport("options", options_core_module);
    zminimoog_core.addImport("static_data", static_data_module);
    if (target_os == .macos) {
        zminimoog_core.addImport("objc", objc_no_helpers);
    }

    zportafm_core.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    zportafm_core.addImport("zgui", zgui.module("root"));
    zportafm_core.addImport("tracy", ztracy.module("root"));
    zportafm_core.addImport("shared", shared);
    zportafm_core.addImport("options", options_core_module);
    zportafm_core.addImport("static_data", static_data_module);
    zportafm_core.addImport("emu2413_c", emu2413_c.createModule());
    zportafm_core.addIncludePath(b.path("zportafm/native"));

    // Specific steps for different targets
    // Library
    if (!no_lib) {
        const clap_plugin_step = createClapPluginStep(b, lib.?, target_os, optimize);
        b.getInstallStep().dependOn(clap_plugin_step);
    }

    // Also create executable for testing
    if (optimize == .Debug) {
        b.installArtifact(exe);
        const run_exe = b.addRunArtifact(exe);

        const run_step = b.step("run", "Run the application");
        run_step.dependOn(&run_exe.step);
    }

    flux.root_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    flux.root_module.addImport("zsynth-core", zsynth_core);
    flux.root_module.addImport("zminimoog-core", zminimoog_core);
    flux.root_module.addImport("zportafm-core", zportafm_core);
    flux.root_module.addImport("zaudio", zaudio.module("root"));
    flux.root_module.addImport("zgui", zgui.module("root"));
    flux.root_module.addImport("zglfw", zglfw.module("root"));
    flux.root_module.linkLibrary(zglfw.artifact("glfw"));
    flux.root_module.addImport("zopengl", zopengl.module("root"));
    flux.root_module.linkLibrary(zopengl.artifact("zopengl"));
    flux.root_module.linkLibrary(zgui.artifact("imgui"));
    flux.root_module.linkLibrary(zaudio.artifact("miniaudio"));
    flux.root_module.addImport("tracy", ztracy.module("root"));
    flux.root_module.linkLibrary(ztracy.artifact("tracy"));
    flux.root_module.addOptions("options", options);
    flux.root_module.addImport("static_data", static_data_module);
    flux.root_module.addImport("shared", shared);
    flux.root_module.addImport("libz_jobs", libz_jobs.module("libz_jobs"));
    flux.root_module.addImport("xml", zig_xml.module("xml"));
    const portmidi_module = portmidi_zig.module("portmidi");
    portmidi_module.addImport("c", portmidi_c.createModule());
    portmidi_module.addIncludePath(portmidi_zig.path("pm_common"));
    flux.root_module.addImport("portmidi", portmidi_module);
    flux.root_module.addIncludePath(portmidi_zig.path("pm_common"));
    flux.root_module.addIncludePath(portmidi_zig.path("pm_mac"));
    flux.root_module.addIncludePath(portmidi_zig.path("pm_linux"));
    flux.root_module.addIncludePath(portmidi_zig.path("porttime"));
    flux.root_module.addIncludePath(b.path("zportafm/native"));
    flux.root_module.addIncludePath(zgui.path("libs/imgui"));
    flux.root_module.link_libc = true;
    flux.root_module.addCSourceFiles(.{
        .root = b.path(""),
        .files = &.{
            "zportafm/native/emu2413/emu2413.c",
        },
        .flags = &.{"-std=c11"},
    });
    flux.root_module.addCSourceFiles(.{
        .root = b.path(""),
        .files = &.{
            "src/flux/zgui_bridge.cpp",
        },
        .flags = &.{"-std=c++17"},
    });
    if (target_os == .macos) {
        flux.root_module.addImport("objc", objc_no_helpers);
        flux.root_module.linkFramework("AppKit", .{});
        flux.root_module.linkFramework("Cocoa", .{});
        flux.root_module.linkFramework("CoreGraphics", .{});
        flux.root_module.linkFramework("CoreMIDI", .{});
        flux.root_module.linkFramework("Foundation", .{});
        flux.root_module.linkFramework("GameController", .{});
        flux.root_module.linkFramework("Metal", .{});
        flux.root_module.linkFramework("QuartzCore", .{});
        flux.root_module.linkFramework("CoreFoundation", .{});
        flux.root_module.linkFramework("CoreServices", .{});
        flux.root_module.linkFramework("CoreAudio", .{});
        flux.root_module.addCSourceFiles(.{
            .root = portmidi_zig.path(""),
            .files = &.{
                "pm_common/portmidi.c",
                "pm_common/pmutil.c",
                "pm_mac/pmmac.c",
                "pm_mac/pmmacosxcm.c",
                "porttime/porttime.c",
                "porttime/ptmacosx_mach.c",
            },
            .flags = &.{},
        });
    }
    if (target_os == .linux) {
        flux.root_module.linkSystemLibrary("asound", .{});
        flux.root_module.linkSystemLibrary("pthread", .{});
        flux.root_module.addCSourceFiles(.{
            .root = portmidi_zig.path(""),
            .files = &.{
                "pm_common/portmidi.c",
                "pm_common/pmutil.c",
                "pm_linux/pmlinux.c",
                "pm_linux/pmlinuxalsa.c",
                "pm_linux/pmlinuxnull.c",
                "porttime/porttime.c",
                "porttime/ptlinux.c",
            },
            .flags = &.{"-DPMALSA"},
        });
        if (use_wayland) {
            flux.root_module.linkSystemLibrary("wayland-client", .{});
            flux.root_module.linkSystemLibrary("wayland-cursor", .{});
            flux.root_module.linkSystemLibrary("wayland-egl", .{});
            flux.root_module.linkSystemLibrary("xkbcommon", .{});
        }
        if (use_x11) {
            flux.root_module.linkSystemLibrary("X11", .{});
        }
    }
    b.installArtifact(flux);

    const run_flux = b.addRunArtifact(flux);
    const run_flux_step = b.step("run-flux", "Run the flux application");
    run_flux_step.dependOn(&run_flux.step);
    const bundle_flux_app_step = b.step("bundle-flux-app", "Build Flux.app bundle (macOS)");
    const run_flux_app_step = b.step("run-flux-app", "Build and run Flux.app (macOS)");
    if (target_os == .macos) {
        const create_flux_app_step = createFluxAppBundleStep(b, flux);
        create_flux_app_step.dependOn(b.getInstallStep());
        bundle_flux_app_step.dependOn(create_flux_app_step);

        const open_flux_app = b.addSystemCommand(&.{ "open", "zig-out/Flux.app" });
        open_flux_app.step.dependOn(create_flux_app_step);
        run_flux_app_step.dependOn(&open_flux_app.step);
    }

    // Unit tests for zminimoog DSP - filter module
    const filter_test_module = b.createModule(.{
        .root_source_file = b.path("zminimoog/src/dsp/board4_filter_vca.zig"),
        .target = target,
        .optimize = optimize,
    });
    filter_test_module.addImport("wdf", wdf.module("wdf"));

    const filter_tests = b.addTest(.{
        .root_module = filter_test_module,
        .use_llvm = use_llvm,
    });

    const run_filter_tests = b.addRunArtifact(filter_tests);

    // Unit tests for complete Minimoog
    const dsp_test_module = b.createModule(.{
        .root_source_file = b.path("zminimoog/src/dsp/dsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    dsp_test_module.addImport("wdf", wdf.module("wdf"));

    const dsp_tests = b.addTest(.{
        .root_module = dsp_test_module,
        .use_llvm = use_llvm,
    });

    const run_dsp_tests = b.addRunArtifact(dsp_tests);

    const zsynth_smoke_test_module = b.createModule(.{
        .root_source_file = b.path("zsynth/src/plugin_smoke_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    zsynth_smoke_test_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    zsynth_smoke_test_module.addImport("regex", regex.module("regex"));
    zsynth_smoke_test_module.addImport("zgui", zgui.module("root"));
    zsynth_smoke_test_module.addImport("zglfw", zglfw.module("root"));
    zsynth_smoke_test_module.addImport("zopengl", zopengl.module("root"));
    zsynth_smoke_test_module.addImport("tracy", ztracy.module("root"));
    zsynth_smoke_test_module.addImport("shared", shared);
    zsynth_smoke_test_module.addImport("options", options_core_module);
    zsynth_smoke_test_module.addImport("static_data", static_data_module);
    if (target_os == .macos) {
        zsynth_smoke_test_module.addImport("objc", objc_no_helpers);
    }

    const zsynth_smoke_tests = b.addTest(.{
        .root_module = zsynth_smoke_test_module,
        .filters = &.{"zsynth produces audio after note on"},
        .use_llvm = use_llvm,
    });
    zsynth_smoke_tests.root_module.linkLibrary(zgui.artifact("imgui"));
    zsynth_smoke_tests.root_module.linkLibrary(zglfw.artifact("glfw"));
    zsynth_smoke_tests.root_module.linkLibrary(zopengl.artifact("zopengl"));
    zsynth_smoke_tests.root_module.linkLibrary(ztracy.artifact("tracy"));
    if (target_os == .macos) {
        zsynth_smoke_tests.root_module.linkFramework("AppKit", .{});
        zsynth_smoke_tests.root_module.linkFramework("Cocoa", .{});
        zsynth_smoke_tests.root_module.linkFramework("CoreGraphics", .{});
        zsynth_smoke_tests.root_module.linkFramework("Foundation", .{});
        zsynth_smoke_tests.root_module.linkFramework("GameController", .{});
        zsynth_smoke_tests.root_module.linkFramework("Metal", .{});
        zsynth_smoke_tests.root_module.linkFramework("QuartzCore", .{});
    }
    const run_zsynth_smoke_tests = b.addRunArtifact(zsynth_smoke_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_filter_tests.step);
    test_step.dependOn(&run_dsp_tests.step);
    test_step.dependOn(&run_zsynth_smoke_tests.step);
}

fn createClapPluginStep(
    b: *std.Build,
    lib: *Step.Compile,
    target_os: std.Target.Os.Tag,
    optimize: std.builtin.OptimizeMode,
) *Step {
    switch (target_os) {
        .macos => {
            const clap_bundle = b.addWriteFiles();
            const plugin_bin = clap_bundle.addCopyFile(
                lib.getEmittedBin(),
                "ZSynth.clap/Contents/MacOS/ZSynth",
            );
            _ = clap_bundle.addCopyFile(
                b.path("zsynth/macos/Info.plist"),
                "ZSynth.clap/Contents/info.plist",
            );
            _ = clap_bundle.addCopyFile(
                b.path("zsynth/macos/PkgInfo"),
                "ZSynth.clap/Contents/PkgInfo",
            );

            var bundle_ready: *Step = &clap_bundle.step;
            if (optimize == .Debug) {
                const dsym = b.addSystemCommand(&.{"dsymutil"});
                dsym.addFileArg(plugin_bin);
                dsym.step.dependOn(&clap_bundle.step);
                bundle_ready = &dsym.step;
            }

            const install_bundle = b.addInstallDirectory(.{
                .source_dir = clap_bundle.getDirectory(),
                .install_dir = .lib,
                .install_subdir = "",
            });
            install_bundle.step.dependOn(bundle_ready);
            return &install_bundle.step;
        },
        .linux, .windows => {
            const install_clap = b.addInstallFileWithDir(
                lib.getEmittedBin(),
                .lib,
                "zsynth.clap",
            );
            return &install_clap.step;
        },
        else => return &b.addInstallArtifact(lib, .{}).step,
    }
}

fn createFluxAppBundleStep(b: *std.Build, flux: *Step.Compile) *Step {
    const app_bundle = b.addWriteFiles();
    _ = app_bundle.addCopyFile(
        flux.getEmittedBin(),
        "Flux.app/Contents/MacOS/flux",
    );
    _ = app_bundle.add("Flux.app/Contents/Info.plist", flux_info_plist);
    _ = app_bundle.add("Flux.app/Contents/PkgInfo", "APPL????\n");

    const install_app = b.addInstallDirectory(.{
        .source_dir = app_bundle.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "",
    });
    return &install_app.step;
}

const flux_info_plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\    <key>CFBundleName</key>
    \\    <string>Flux</string>
    \\    <key>CFBundleDisplayName</key>
    \\    <string>Flux</string>
    \\    <key>CFBundleIdentifier</key>
    \\    <string>com.gearmulator.flux</string>
    \\    <key>CFBundleVersion</key>
    \\    <string>0.1</string>
    \\    <key>CFBundleShortVersionString</key>
    \\    <string>0.1</string>
    \\    <key>CFBundlePackageType</key>
    \\    <string>APPL</string>
    \\    <key>CFBundleExecutable</key>
    \\    <string>flux</string>
    \\    <key>LSMinimumSystemVersion</key>
    \\    <string>13.0</string>
    \\</dict>
    \\</plist>
    \\
;
