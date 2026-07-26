const builtin = @import("builtin");
const std = @import("std");
const Step = std.Build.Step;

const macos_gui_frameworks = [_][]const u8{
    "AppKit", "Cocoa", "CoreGraphics", "Foundation", "GameController", "Metal", "QuartzCore",
};
const macos_flux_frameworks = macos_gui_frameworks ++ [_][]const u8{
    "CoreMIDI", "CoreFoundation", "CoreServices", "CoreAudio",
};

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

    // Zig 0.17 does not derive framework search paths from --sysroot
    // ("unable to find framework … searched paths: none"). Cross-compiling to
    // macOS needs an explicit SDK path via -Dmacos-sdk=… or SDKROOT.
    const macos_sdk = b.option(
        []const u8,
        "macos-sdk",
        "Path to MacOSX*.sdk (cross-compile framework/include/lib search roots)",
    ) orelse b.graph.environ_map.get("SDKROOT");

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

    const dep_target = .{ .target = target };
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
    // Prefer the full MacOSX.sdk when provided (CI cross-compile); deps also fall
    // back to their bundled system_sdk for Frameworks on non-mac hosts.
    if (target_os == .macos) {
        addMacosSdkPaths(b, zgui.artifact("imgui").root_module, macos_sdk);
        addMacosSdkPaths(b, zglfw.artifact("glfw").root_module, macos_sdk);
    }
    const zopengl = b.dependency("zopengl", dep_target);
    const zaudio = b.dependency("zaudio", dep_target);
    const objc = b.dependency("mach-objc", dep_target);
    const objc_no_helpers = b.createModule(.{
        .root_source_file = objc.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const libz_jobs = b.dependency("libz_jobs", .{
        .target = target,
        .optimize = optimize,
    });
    const zig_xml = b.dependency("zig-xml", dep_target);
    const portmidi_zig = b.dependency("portmidi-zig", dep_target);
    const wdf = b.dependency("wdf", dep_target);
    const sqlite3 = b.dependency("sqlite3", .{});
    // Header-only C++ (MIT): fetched via build.zig.zon, no Zig package build.zig.
    const signalsmith_stretch = b.dependency("signalsmith_stretch", .{});
    const signalsmith_linear = b.dependency("signalsmith_linear", .{});
    const emu2413 = b.dependency("emu2413", .{});

    const ztracy = b.dependency("ztracy", .{
        .target = target,
        .enable_ztracy = (builtin.mode == .Debug or profiling == true) and !disable_profiling,
        .callstack = 20,
        .on_demand = true,
    });

    const lib_module = rootModule(b, "src/builtins/instruments/zsynth/main.zig", target, optimize);
    const exe_module = rootModule(b, "src/builtins/instruments/zsynth/diag.zig", target, optimize);
    const flux_module = rootModule(b, "src/main.zig", target, optimize);

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

    const static_data = b.addOptions();
    static_data.addOption([]const u8, "font", @embedFile("assets/Roboto-Medium.ttf"));
    static_data.addOption([]const u8, "icon_rgba", @embedFile("assets/icon-64.rgba"));
    static_data.addOption(u32, "icon_size", 64);
    const static_data_module = static_data.createModule();

    const flux_param_table = rootModule(b, "src/builtins/param_table.zig", target, optimize);
    const shared = rootModule(b, "shared/root.zig", target, optimize);
    shared.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    shared.addImport("options", options_core_module);
    shared.addImport("static_data", static_data_module);
    shared.addImport("zgui", zgui.module("root"));
    shared.addImport("zglfw", zglfw.module("root"));
    shared.addImport("zopengl", zopengl.module("root"));
    shared.addImport("tracy", ztracy.module("root"));
    if (target_os == .macos) {
        addMacosSdkPaths(b, objc_no_helpers, macos_sdk);
        objc_no_helpers.linkSystemLibrary("objc", .{});
        linkFrameworks(objc_no_helpers, &.{ "AppKit", "CoreVideo", "QuartzCore" });
        shared.addImport("objc", objc_no_helpers);
    }

    const gui = GuiCtx{
        .b = b,
        .zgui = zgui,
        .zglfw = zglfw,
        .zopengl = zopengl,
        .ztracy = ztracy,
        .static_data = static_data_module,
        .objc = objc_no_helpers,
        .target_os = target_os,
        .macos_sdk = macos_sdk,
        .use_wayland = use_wayland,
        .use_x11 = use_x11,
    };

    const build_targets: []const *Step.Compile = if (no_lib) &.{exe} else &.{ lib.?, exe };
    for (build_targets) |pkg| {
        pkg.root_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
        pkg.root_module.addImport("regex", regex.module("regex"));
        pkg.root_module.addImport("wdf", wdf.module("wdf"));
        pkg.root_module.addImport("shared", shared);
        pkg.root_module.addOptions("options", options);
        wireGui(pkg.root_module, gui, .{
            .linux_display = true,
            .frameworks = &macos_gui_frameworks,
        });
    }

    if (!no_lib) {
        b.getInstallStep().dependOn(createClapPluginStep(b, lib.?, target_os, optimize));
    }

    if (optimize == .Debug) {
        b.installArtifact(exe);
        const run_step = b.step("run", "Run the application");
        run_step.dependOn(&b.addRunArtifact(exe).step);
    }

    // Flux DAW
    flux.root_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    flux.root_module.addImport("regex", regex.module("regex"));
    flux.root_module.addImport("wdf", wdf.module("wdf"));
    flux.root_module.addImport("shared", shared);
    flux.root_module.addImport("libz_jobs", libz_jobs.module("libz_jobs"));
    flux.root_module.addImport("xml", zig_xml.module("xml"));
    flux.root_module.addImport("flux_param_table", flux_param_table);
    flux.root_module.addOptions("options", options);
    wireGui(flux.root_module, gui, .{
        .linux_display = true,
        .frameworks = &macos_flux_frameworks,
    });
    wireFluxNative(b, flux.root_module, .{
        .zaudio = zaudio,
        .sqlite3 = sqlite3,
        .emu2413 = emu2413,
        .portmidi_zig = portmidi_zig,
        .signalsmith_stretch = signalsmith_stretch,
        .signalsmith_linear = signalsmith_linear,
        .zgui = zgui,
        .target = target,
        .optimize = optimize,
        .target_os = target_os,
    });
    b.installArtifact(flux);

    const run_flux_step = b.step("run-flux", "Run the flux application");
    run_flux_step.dependOn(&b.addRunArtifact(flux).step);
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

    // Tests
    const dsp_test_module = rootModule(b, "src/builtins/instruments/zminimoog/dsp/dsp.zig", target, optimize);
    dsp_test_module.addImport("wdf", wdf.module("wdf"));
    const run_dsp_tests = b.addRunArtifact(b.addTest(.{ .root_module = dsp_test_module, .use_llvm = use_llvm }));

    const zsynth_smoke_test_module = rootModule(b, "src/builtins/instruments/zsynth/plugin_smoke_test.zig", target, optimize);
    zsynth_smoke_test_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    zsynth_smoke_test_module.addImport("regex", regex.module("regex"));
    zsynth_smoke_test_module.addImport("shared", shared);
    zsynth_smoke_test_module.addImport("options", options_core_module);
    const zsynth_smoke_tests = b.addTest(.{
        .root_module = zsynth_smoke_test_module,
        .filters = &.{"zsynth produces audio after note on"},
        .use_llvm = use_llvm,
    });
    // Wire on the test compile step's module (same pattern as before for linked artifacts).
    wireGui(zsynth_smoke_tests.root_module, gui, .{
        .linux_display = false,
        .frameworks = &macos_gui_frameworks,
    });
    const run_zsynth_smoke_tests = b.addRunArtifact(zsynth_smoke_tests);

    const flux_tests = b.addTest(.{
        .root_module = flux_module,
        .use_llvm = use_llvm,
    });
    const run_flux_tests = b.addRunArtifact(flux_tests);
    run_flux_tests.setCwd(b.path(".")); // media roundtrip fixtures under tests/fixtures

    // Integration: load every installed system CLAP (discover → create → activate → destroy).
    // Standalone exe (not addTest): third-party plugins flood stderr and deadlock zig's
    // listen-mode test runner over pipe buffers.
    const clap_load_module = rootModule(b, "src/clap_plugin_load_test.zig", target, optimize);
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
    test_step.dependOn(&run_zsynth_smoke_tests.step);
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

const GuiCtx = struct {
    b: *std.Build,
    zgui: *std.Build.Dependency,
    zglfw: *std.Build.Dependency,
    zopengl: *std.Build.Dependency,
    ztracy: *std.Build.Dependency,
    static_data: *std.Build.Module,
    objc: *std.Build.Module,
    target_os: std.Target.Os.Tag,
    macos_sdk: ?[]const u8,
    use_wayland: bool,
    use_x11: bool,
};

fn wireGui(module: *std.Build.Module, gui: GuiCtx, cfg: struct {
    linux_display: bool,
    frameworks: []const []const u8,
}) void {
    module.addImport("zgui", gui.zgui.module("root"));
    module.addImport("zglfw", gui.zglfw.module("root"));
    module.addImport("zopengl", gui.zopengl.module("root"));
    module.addImport("tracy", gui.ztracy.module("root"));
    module.linkLibrary(gui.zgui.artifact("imgui"));
    module.linkLibrary(gui.zglfw.artifact("glfw"));
    module.linkLibrary(gui.zopengl.artifact("zopengl"));
    module.linkLibrary(gui.ztracy.artifact("tracy"));
    module.addImport("static_data", gui.static_data);
    if (gui.target_os == .macos) {
        addMacosSdkPaths(gui.b, module, gui.macos_sdk);
        module.addImport("objc", gui.objc);
        linkFrameworks(module, cfg.frameworks);
    }
    if (cfg.linux_display and gui.target_os == .linux) {
        linkLinuxDisplay(module, gui.use_wayland, gui.use_x11);
    }
}

fn linkLinuxDisplay(module: *std.Build.Module, use_wayland: bool, use_x11: bool) void {
    if (use_wayland) {
        module.linkSystemLibrary("wayland-client", .{});
        module.linkSystemLibrary("wayland-cursor", .{});
        module.linkSystemLibrary("wayland-egl", .{});
        module.linkSystemLibrary("xkbcommon", .{});
    }
    if (use_x11) module.linkSystemLibrary("X11", .{});
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
    zgui: *std.Build.Dependency,
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
    module.addIncludePath(d.zgui.path("libs/imgui"));

    module.addCSourceFile(.{
        .file = d.emu2413.path("emu2413.c"),
        .flags = &.{"-std=c11"},
    });
    module.addCSourceFiles(.{
        .root = b.path(""),
        .files = &.{"src/zgui_bridge.cpp"},
        .flags = &.{"-std=c++17"},
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
    _ = app_bundle.addCopyFile(
        b.path("assets/Flux.icns"),
        "Flux.app/Contents/Resources/Flux.icns",
    );

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
    \\    <key>CFBundleIconFile</key>
    \\    <string>Flux</string>
    \\    <key>LSMinimumSystemVersion</key>
    \\    <string>13.0</string>
    \\</dict>
    \\</plist>
    \\
;
