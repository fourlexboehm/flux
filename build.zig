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

    const use_wayland = b.option(
        bool,
        "wayland",
        "Use Wayland on Linux (default: true)",
    ) orelse (builtin.os.tag == .linux);
    const use_x11 = b.option(
        bool,
        "x11",
        "Use X11 on Linux (default: false when wayland=true)",
    ) orelse (!use_wayland);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_segfault_handler = b.option(
        bool,
        "enable_segfault_handler",
        "Enable std segfault handler for debug backtraces",
    ) orelse (optimize == .Debug);
    const clap_bindings = b.dependency("clap-bindings", .{});
    const regex = b.dependency("regex", .{});
    const zgui = b.dependency("zgui", .{
        .shared = false,
        .with_implot = true,
        .backend = switch (builtin.os.tag) {
            .macos => .osx_metal,
            .windows => .win32_dx12,
            else => .glfw_opengl3,
        },
    });
    const zglfw = b.dependency("zglfw", .{
        .shared = false,
        .x11 = use_x11,
        .wayland = use_wayland,
    });
    const zopengl = b.dependency("zopengl", .{});
    const zaudio = b.dependency("zaudio", .{});
    const objc = b.dependency("mach-objc", .{});
    const libz_jobs = b.dependency("libz_jobs", .{});
    const zig_xml = b.dependency("zig-xml", .{});
    const portmidi_zig = b.dependency("portmidi-zig", .{});
    const portmidi = b.dependency("portmidi", .{});
    const zig_wdf = b.dependency("zig-wdf", .{});

    const ztracy = b.dependency("ztracy", .{
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

    const lib = b.addLibrary(.{
        .name = "zsynth",
        .root_module = lib_module,
        .linkage = .dynamic,
    });

    const exe = b.addExecutable(.{
        .name = "zsynth",
        .root_module = exe_module,
    });
    const flux = b.addExecutable(.{
        .name = "flux",
        .root_module = flux_module,
    });

    // Allow options to be passed in to source files
    var options = Step.Options.create(b);
    options.addOption(bool, "wait_for_debugger", wait_for_debugger);
    options.addOption(bool, "enable_gui", true);
    options.addOption(bool, "enable_segfault_handler", enable_segfault_handler);
    const options_core = Step.Options.create(b);
    options_core.addOption(bool, "wait_for_debugger", wait_for_debugger);
    options_core.addOption(bool, "enable_gui", false);
    options_core.addOption(bool, "enable_segfault_handler", enable_segfault_handler);
    const options_core_module = options_core.createModule();

    // Font data is shared between all modules via a common options module
    const font_data = @embedFile("assets/Roboto-Medium.ttf");
    const static_data = Step.Options.create(b);
    static_data.addOption([]const u8, "font", font_data);
    const static_data_module = static_data.createModule();

    const build_targets = [_]*Step.Compile{ lib, exe };
    for (build_targets) |pkg| {
        // Libraries
        pkg.root_module.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
        pkg.root_module.addImport("regex", regex.module("regex"));
        pkg.root_module.addImport("zig_wdf", zig_wdf.module("zig_wdf"));

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

        if (builtin.os.tag == .macos) {
            pkg.root_module.addImport("objc", objc.module("mach-objc"));
            pkg.root_module.linkFramework("AppKit", .{});
            pkg.root_module.linkFramework("Cocoa", .{});
            pkg.root_module.linkFramework("CoreGraphics", .{});
            pkg.root_module.linkFramework("Foundation", .{});
            pkg.root_module.linkFramework("Metal", .{});
            pkg.root_module.linkFramework("QuartzCore", .{});
        }
        if (builtin.os.tag == .linux) {
            if (use_wayland) {
                pkg.root_module.linkSystemLibrary("wayland-client", .{});
                pkg.root_module.linkSystemLibrary("wayland-cursor", .{});
                pkg.root_module.linkSystemLibrary("wayland-egl", .{});
                pkg.root_module.linkSystemLibrary("xkbcommon", .{});
            } else {
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
    zsynth_core.addImport("options", options_core_module);
    zsynth_core.addImport("static_data", static_data_module);
    if (builtin.os.tag == .macos) {
        zsynth_core.addImport("objc", objc.module("mach-objc"));
    }

    zminimoog_core.addImport("clap-bindings", clap_bindings.module("clap-bindings"));
    zminimoog_core.addImport("zgui", zgui.module("root"));
    zminimoog_core.addImport("zglfw", zglfw.module("root"));
    zminimoog_core.addImport("zopengl", zopengl.module("root"));
    zminimoog_core.addImport("tracy", ztracy.module("root"));
    zminimoog_core.addImport("zig_wdf", zig_wdf.module("zig_wdf"));
    zminimoog_core.addImport("options", options_core_module);
    zminimoog_core.addImport("static_data", static_data_module);
    if (builtin.os.tag == .macos) {
        zminimoog_core.addImport("objc", objc.module("mach-objc"));
    }

    // Specific steps for different targets
    // Library
    const rename_dll_step = CreateClapPluginStep.create(b, lib);
    rename_dll_step.step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    b.getInstallStep().dependOn(&rename_dll_step.step);

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
    flux.root_module.addImport("libz_jobs", libz_jobs.module("libz_jobs"));
    flux.root_module.addImport("xml", zig_xml.module("xml"));
    const portmidi_module = portmidi_zig.module("portmidi");
    portmidi_module.addIncludePath(portmidi.path("pm_common"));
    flux.root_module.addImport("portmidi", portmidi_module);
    flux.root_module.addIncludePath(portmidi.path("pm_common"));
    flux.root_module.addIncludePath(portmidi.path("pm_mac"));
    flux.root_module.addIncludePath(portmidi.path("pm_linux"));
    flux.root_module.addIncludePath(portmidi.path("porttime"));
    if (builtin.os.tag == .macos) {
        flux.root_module.addImport("objc", objc.module("mach-objc"));
        flux.root_module.linkFramework("AppKit", .{});
        flux.root_module.linkFramework("Cocoa", .{});
        flux.root_module.linkFramework("CoreGraphics", .{});
        flux.root_module.linkFramework("CoreMIDI", .{});
        flux.root_module.linkFramework("Foundation", .{});
        flux.root_module.linkFramework("Metal", .{});
        flux.root_module.linkFramework("QuartzCore", .{});
        flux.root_module.linkFramework("CoreFoundation", .{});
        flux.root_module.linkFramework("CoreServices", .{});
        flux.root_module.linkFramework("CoreAudio", .{});
        flux.root_module.addCSourceFiles(.{
            .root = portmidi.path(""),
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
    if (builtin.os.tag == .linux) {
        flux.root_module.linkSystemLibrary("asound", .{});
        flux.root_module.linkSystemLibrary("pthread", .{});
        flux.root_module.addCSourceFiles(.{
            .root = portmidi.path(""),
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
        } else {
            flux.root_module.linkSystemLibrary("X11", .{});
        }
    }
    b.installArtifact(flux);

    const run_flux = b.addRunArtifact(flux);
    const run_flux_step = b.step("run-flux", "Run the flux application");
    run_flux_step.dependOn(&run_flux.step);

    // Unit tests for zminimoog DSP - filter module
    const filter_test_module = b.createModule(.{
        .root_source_file = b.path("zminimoog/src/dsp/board4_filter_vca.zig"),
        .target = target,
        .optimize = optimize,
    });
    filter_test_module.addImport("zig_wdf", zig_wdf.module("zig_wdf"));

    const filter_tests = b.addTest(.{
        .root_module = filter_test_module,
    });

    const run_filter_tests = b.addRunArtifact(filter_tests);

    // Unit tests for complete Minimoog
    const dsp_test_module = b.createModule(.{
        .root_source_file = b.path("zminimoog/src/dsp/dsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    dsp_test_module.addImport("zig_wdf", zig_wdf.module("zig_wdf"));

    const dsp_tests = b.addTest(.{
        .root_module = dsp_test_module,
    });

    const run_dsp_tests = b.addRunArtifact(dsp_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_filter_tests.step);
    test_step.dependOn(&run_dsp_tests.step);
}

pub const CreateClapPluginStep = struct {
    pub const base_id = .top_level;

    const Self = @This();

    step: Step,
    build: *std.Build,
    artifact: *Step.Compile,

    pub fn create(b: *std.Build, artifact: *Step.Compile) *Self {
        const self = b.allocator.create(Self) catch unreachable;
        const name = "create clap plugin";
        self.* = Self{
            .step = Step.init(Step.StepOptions{ .id = .top_level, .name = name, .owner = b, .makeFn = make }),
            .build = b,
            .artifact = artifact,
        };
        return self;
    }

    fn make(step: *Step, _: Step.MakeOptions) !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        defer switch (gpa.deinit()) {
            .ok => {},
            .leak => {
                std.log.err("Memory leaks when building!", .{});
            },
        };

        const self: *Self = @fieldParentPtr("step", step);
        if (self.build.build_root.path) |path| {
            const io = self.build.graph.io;
            var dir = try std.Io.Dir.openDirAbsolute(io, path, .{});
            defer dir.close(io);
            switch (builtin.os.tag) {
                .macos => {
                    _ = try dir.updateFile(io, "zig-out/lib/libzsynth.dylib", dir, "zig-out/lib/ZSynth.clap/Contents/MacOS/ZSynth", .{});
                    _ = try dir.updateFile(io, "zsynth/macos/Info.plist", dir, "zig-out/lib/ZSynth.clap/Contents/info.plist", .{});
                    _ = try dir.updateFile(io, "zsynth/macos/PkgInfo", dir, "zig-out/lib/ZSynth.clap/Contents/PkgInfo", .{});
                    if (builtin.mode == .Debug) {
                        // Also generate dynamic symbols for Tracy
                        var child = try std.process.spawn(io, .{
                            .argv = &.{ "dsymutil", "zig-out/lib/ZSynth.clap/Contents/MacOS/ZSynth" },
                            .stdin = .ignore,
                            .stdout = .ignore,
                            .stderr = .ignore,
                        });
                        _ = try child.wait(io);
                    }
                    // Copy the CLAP plugin to the library folder
                    try copyDirRecursiveToHome(allocator, io, &self.build.graph.environ_map, "zig-out/lib/ZSynth.clap/", "Library/Audio/Plug-Ins/CLAP/ZSynth.clap");
                },
                .linux => {
                    _ = try dir.updateFile(io, "zig-out/lib/libzsynth.so", dir, "zig-out/lib/zsynth.clap", .{});
                },
                .windows => {
                    _ = try dir.updateFile(io, "zig-out\\lib\\libzsynth.dll", dir, "zig-out\\lib\\zsynth.clap", .{});
                },
                else => {},
            }
        }
    }
};

fn copyDirRecursiveToHome(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    source_dir: []const u8,
    dest_path_from_home: []const u8,
) !void {
    const home = environ_map.get("HOME") orelse return error.HomeNotFound;
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, dest_path_from_home });
    defer allocator.free(dest_path);
    var cp = try std.process.spawn(io, .{
        .argv = &.{ "cp", "-R", source_dir, dest_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try cp.wait(io);
}
