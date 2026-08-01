const builtin = @import("builtin");
const std = @import("std");
const Step = std.Build.Step;

const macos_flux_frameworks = [_][]const u8{
    "AppKit",   "Cocoa",          "CoreGraphics", "Foundation", "GameController", "Metal", "QuartzCore",
    "CoreMIDI", "CoreFoundation", "CoreServices", "CoreAudio",
};

pub fn build(b: *std.Build) void {
    const wait_for_debugger = b.option(
        bool,
        "wait_for_debugger",
        "Stall when creating a plugin from the factory",
    ) orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    // Zig 0.17 does not derive framework search paths from --sysroot
    // ("unable to find framework … searched paths: none"). Cross-compiling to
    // macOS needs an explicit SDK path via -Dmacos-sdk=… or SDKROOT.
    const macos_sdk = b.option(
        []const u8,
        "macos-sdk",
        "Path to MacOSX*.sdk (cross-compile framework/include/lib search roots)",
    ) orelse b.graph.environ_map.get("SDKROOT");

    const use_llvm = b.option(bool, "use-llvm", "Use LLVM backend (slower builds, required for some optimizations)") orelse (target_os == .macos);
    const incremental = b.option(bool, "incremental", "Enable incremental linking (faster rebuilds, but always re-links even when nothing changed)") orelse false;
    const enable_segfault_handler = b.option(
        bool,
        "enable_segfault_handler",
        "Enable std segfault handler for debug backtraces",
    ) orelse (optimize == .debug);

    const dep_target = .{ .target = target };
    const clap_bindings = b.dependency("clap-bindings", dep_target);
    const regex = b.dependency("regex", dep_target);
    const zaudio = b.dependency("zaudio", dep_target);
    const libz_jobs = b.dependency("libz_jobs", .{
        .target = target,
        .optimize = optimize,
    });
    const zig_xml = b.dependency("zig-xml", dep_target);
    const portmidi_zig = b.dependency("portmidi-zig", dep_target);
    const wdf = b.dependency("wdf", dep_target);
    const sqlite3 = b.dependency("sqlite3", .{});
    const dvui = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
        .@"tree-sitter" = false,
    });
    // Header-only C++ (MIT): fetched via build.zig.zon, no Zig package build.zig.
    const signalsmith_stretch = b.dependency("signalsmith_stretch", .{});
    const signalsmith_linear = b.dependency("signalsmith_linear", .{});
    const emu2413 = b.dependency("emu2413", .{});

    // Host unit tests (not the app). App entry is src/main.zig → DVUI host.
    const flux_test_module = rootModule(b, "src/tests.zig", target, optimize);

    const options = b.addOptions();
    options.addOption(bool, "wait_for_debugger", wait_for_debugger);
    options.addOption(bool, "enable_gui", false);
    options.addOption(bool, "enable_segfault_handler", enable_segfault_handler);
    options.addOption(bool, "use_x11", false);

    const flux_param_table = rootModule(b, "src/builtins/param_table.zig", target, optimize);

    // Host unit-test module graph (src/tests.zig + modules it pulls in).
    flux_test_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    flux_test_module.addImport("regex", regex.module("regex"));
    flux_test_module.addImport("wdf", wdf.module("wdf"));
    flux_test_module.addImport("libz_jobs", libz_jobs.module("libz_jobs"));
    flux_test_module.addImport("xml", zig_xml.module("xml"));
    flux_test_module.addImport("flux_param_table", flux_param_table);
    flux_test_module.addOptions("options", options);
    flux_test_module.addImport("tracy", rootModule(b, "src/util/tracy_stub.zig", target, optimize));
    if (target_os == .macos) {
        addMacosSdkPaths(b, flux_test_module, macos_sdk);
        linkFrameworks(flux_test_module, &macos_flux_frameworks);
    }
    wireFluxNative(b, flux_test_module, .{
        .zaudio = zaudio,
        .sqlite3 = sqlite3,
        .emu2413 = emu2413,
        .portmidi_zig = portmidi_zig,
        .signalsmith_stretch = signalsmith_stretch,
        .signalsmith_linear = signalsmith_linear,
        .target = target,
        .optimize = optimize,
        .target_os = target_os,
    });

    // Flux app: one root build graph. `zig-pkg` is package-manager output only;
    // all imports and native libraries are wired here.
    {
        const flux_module = rootModule(b, "src/main.zig", target, optimize);
        flux_module.addImport("dvui", dvui.module("dvui_sdl3"));
        flux_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
        flux_module.addImport("regex", regex.module("regex"));
        flux_module.addImport("wdf", wdf.module("wdf"));
        flux_module.addImport("libz_jobs", libz_jobs.module("libz_jobs"));
        flux_module.addImport("xml", zig_xml.module("xml"));
        flux_module.addImport("flux_param_table", flux_param_table);
        flux_module.addImport("tracy", rootModule(b, "src/util/tracy_stub.zig", target, optimize));
        flux_module.addOptions("options", options);
        wireFluxNative(b, flux_module, .{
            .zaudio = zaudio,
            .sqlite3 = sqlite3,
            .emu2413 = emu2413,
            .portmidi_zig = portmidi_zig,
            .signalsmith_stretch = signalsmith_stretch,
            .signalsmith_linear = signalsmith_linear,
            .target = target,
            .optimize = optimize,
            .target_os = target_os,
        });
        if (target_os == .macos) {
            addMacosSdkPaths(b, flux_module, macos_sdk);
            linkFrameworks(flux_module, &macos_flux_frameworks);
        }

        const flux_exe = b.addExecutable(.{ .name = "flux", .root_module = flux_module, .use_llvm = use_llvm });
        flux_exe.incremental = incremental;
        b.installArtifact(flux_exe);

        const run_host = b.addRunArtifact(flux_exe);

        const run_flux_step = b.step("run-flux", "Run Flux (DVUI host)");
        run_flux_step.dependOn(&run_host.step);

        // macOS .app wraps the same DVUI binary.
        const bundle_flux_app_step = b.step("bundle-flux-app", "Build Flux.app bundle (macOS)");
        const run_flux_app_step = b.step("run-flux-app", "Build and run Flux.app (macOS)");
        if (target_os == .macos) {
            const create_flux_app_step = createFluxAppBundleFromBinStep(b, "zig-out/bin/flux");
            create_flux_app_step.dependOn(&flux_exe.step);
            bundle_flux_app_step.dependOn(create_flux_app_step);

            const open_flux_app = b.addSystemCommand(&.{ "open", "zig-out/Flux.app" });
            open_flux_app.step.dependOn(create_flux_app_step);
            run_flux_app_step.dependOn(&open_flux_app.step);
        }
    }

    // Tests
    const dsp_test_module = rootModule(b, "src/builtins/instruments/zminimoog/dsp/dsp.zig", target, optimize);
    dsp_test_module.addImport("wdf", wdf.module("wdf"));
    const run_dsp_tests = b.addRunArtifact(b.addTest(.{ .root_module = dsp_test_module, .use_llvm = use_llvm }));

    const flux_tests = b.addTest(.{
        .root_module = flux_test_module,
        .use_llvm = use_llvm,
    });
    const run_flux_tests = b.addRunArtifact(flux_tests);
    run_flux_tests.setCwd(b.path(".")); // media roundtrip fixtures under tests/fixtures

    // Integration: load every installed system CLAP (discover → create → activate → destroy).
    // Standalone exe (not addTest): third-party plugins flood stderr and deadlock zig's
    // listen-mode test runner over pipe buffers.
    const clap_load_module = rootModule(b, "src/clap_plugin_load_test.zig", target, optimize);
    clap_load_module.link_libc = true; // std.c.getenv + DynLib
    clap_load_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    const clap_load_exe = b.addExecutable(.{
        .name = "clap-load-test",
        .root_module = clap_load_module,
        .use_llvm = use_llvm,
    });
    const run_clap_load = b.addRunArtifact(clap_load_exe);
    run_clap_load.setCwd(b.path("."));
    run_clap_load.setEnvironmentVariable("FLUX_CLAP_FULL_SCAN", "1");
    run_clap_load.expectExitCode(0);

    const test_clap_load_step = b.step("test-clap-load", "Load all installed system CLAP plugins");
    test_clap_load_step.dependOn(&run_clap_load.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_dsp_tests.step);
    test_step.dependOn(&run_flux_tests.step);
    test_step.dependOn(&run_clap_load.step);
}

// --- helpers -----------------------------------------------------------------

fn rootModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

fn linkFrameworks(module: *std.Build.Module, names: []const []const u8) void {
    for (names) |name| module.linkFramework(name, .{});
}

const FluxNativeDeps = struct {
    zaudio: *std.Build.Dependency,
    sqlite3: *std.Build.Dependency,
    emu2413: *std.Build.Dependency,
    portmidi_zig: *std.Build.Dependency,
    signalsmith_stretch: *std.Build.Dependency,
    signalsmith_linear: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    target_os: std.Target.Os.Tag,
};

/// Flux-only C/C++/ObjC: sqlite, emu2413, portmidi, stretch, bridges, native drop.
fn wireFluxNative(b: *std.Build, module: *std.Build.Module, d: FluxNativeDeps) void {
    const sqlite3_c = b.addTranslateC(.{
        .root_source_file = d.sqlite3.path("sqlite3.h"),
        .target = d.target,
        .optimize = d.optimize,
        .link_libc = true,
    });
    const portmidi_c = b.addTranslateC(.{
        .root_source_file = d.portmidi_zig.path("pm_common/portmidi.h"),
        .target = d.target,
        .optimize = d.optimize,
        .link_libc = true,
    });
    portmidi_c.addIncludePath(d.portmidi_zig.path("pm_common"));
    const emu2413_c = b.addTranslateC(.{
        .root_source_file = d.emu2413.path("emu2413.h"),
        .target = d.target,
        .optimize = d.optimize,
        .link_libc = true,
    });
    emu2413_c.addIncludePath(d.emu2413.path(""));

    module.link_libc = true;
    module.link_libcpp = true;
    module.addImport("emu2413_c", emu2413_c.createModule());
    module.addImport("zaudio", d.zaudio.module("root"));
    module.addImport("sqlite3", sqlite3_c.createModule());
    module.linkLibrary(d.zaudio.artifact("miniaudio"));

    module.addCSourceFile(.{
        .file = d.sqlite3.path("sqlite3.c"),
        .flags = &.{
            "-std=c99",
            "-DSQLITE_DQS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_OMIT_DEPRECATED=1",
            "-DSQLITE_THREADSAFE=1",
        },
    });
    module.addIncludePath(d.zaudio.path("libs/miniaudio"));
    module.addIncludePath(b.path("src/builtins/native"));
    module.addCSourceFiles(.{
        .root = b.path(""),
        .files = &.{
            "src/builtins/native/dsp_bridge.c",
            "src/builtins/native/sndfilter/compressor.c",
        },
        .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
    });

    const portmidi_module = d.portmidi_zig.module("portmidi");
    portmidi_module.addImport("c", portmidi_c.createModule());
    portmidi_module.addIncludePath(d.portmidi_zig.path("pm_common"));
    module.addImport("portmidi", portmidi_module);
    module.addIncludePath(d.portmidi_zig.path("pm_common"));
    module.addIncludePath(d.portmidi_zig.path("pm_mac"));
    module.addIncludePath(d.portmidi_zig.path("pm_linux"));
    module.addIncludePath(d.portmidi_zig.path("porttime"));
    module.addIncludePath(d.emu2413.path(""));

    module.addCSourceFile(.{
        .file = d.emu2413.path("emu2413.c"),
        // emu2413 relies on well-defined-in-practice signed shifts/overflow that
        // trip Zig's C UBSan in debug builds (e.g. `~res << 1` in lookup_exp_table).
        .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
    });
    // Signalsmith Stretch (MIT) — offline pitch-preserving bake for audio clips.
    module.addIncludePath(d.signalsmith_stretch.path(""));
    module.addIncludePath(d.signalsmith_linear.path("include"));
    module.addIncludePath(b.path("src/audio/stretch"));
    module.addCSourceFiles(.{
        .root = b.path(""),
        .files = &.{"src/audio/stretch/wrapper.cpp"},
        .flags = &.{
            "-std=c++14",
            "-O2",
            "-fno-exceptions",
            "-fno-rtti",
        },
    });

    if (d.target_os == .macos) {
        module.addCSourceFiles(.{
            .root = d.portmidi_zig.path(""),
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
        module.addCSourceFile(.{
            .file = b.path("src/app/native_drop.m"),
            .flags = &.{"-fobjc-arc"},
        });
        // CLAP plugin host NSWindow for DVUI gui_float (also linked into tests).
        module.addIncludePath(b.path("src/plugin"));
        module.addCSourceFile(.{
            .file = b.path("src/plugin/macos_plugin_window.m"),
            .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
        });
    }
    if (d.target_os == .linux) {
        module.linkSystemLibrary("asound", .{});
        module.linkSystemLibrary("pthread", .{});
        module.addCSourceFiles(.{
            .root = d.portmidi_zig.path(""),
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
    }
}

/// Wire MacOSX.sdk Frameworks + headers into a module for cross-compilation.
/// Native macOS builds leave `sdk_path` null and rely on host SDK discovery.
///
/// Zig 0.17 does not derive framework search paths from `--sysroot`
/// ("searched paths: none"), and also does not put `$sysroot/usr/include` on
/// the include path for ObjC/C (e.g. libDER/DERItem.h). Absolute `-L` under
/// the same tree as `--sysroot` is double-prefixed by Zig, so lib stubs
/// (libobjc.tbd) come from the bundled system_sdk package instead.
fn addMacosSdkPaths(b: *std.Build, module: *std.Build.Module, sdk_path: ?[]const u8) void {
    const sdk = sdk_path orelse return;
    module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
        module.addLibraryPath(system_sdk.path("macos12/usr/lib"));
    }
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
            // dsymutil is a host macOS tool — skip when cross-compiling from Linux CI.
            if (optimize == .debug and builtin.os.tag == .macos) {
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

/// Assemble Flux.app around an already-built binary path (e.g. zig-out/bin/flux).
fn createFluxAppBundleFromBinStep(b: *std.Build, bin_path: []const u8) *Step {
    const app_bundle = b.addWriteFiles();
    _ = app_bundle.add("Flux.app/Contents/Info.plist", flux_info_plist);
    _ = app_bundle.add("Flux.app/Contents/PkgInfo", "APPL????\n");
    _ = app_bundle.addCopyFile(
        b.path("assets/Flux.icns"),
        "Flux.app/Contents/Resources/Flux.icns",
    );

    const install_app = b.addInstallDirectory(.{
        .source_dir = app_bundle.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "",
    });

    const mkdir_macos = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/Flux.app/Contents/MacOS" });
    mkdir_macos.step.dependOn(&install_app.step);

    const cp_bin = b.addSystemCommand(&.{ "cp", "-f", bin_path, "zig-out/Flux.app/Contents/MacOS/flux" });
    cp_bin.step.dependOn(&mkdir_macos.step);
    return &cp_bin.step;
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
    \\    <key>CFBundleIconFile</key>
    \\    <string>Flux</string>
    \\    <key>LSMinimumSystemVersion</key>
    \\    <string>13.0</string>
    \\</dict>
    \\</plist>
    \\
;
