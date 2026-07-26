//! Integration: discover every installed system CLAP and load/close each one.
//! Asserts plugins can be created, initialized, activated, deactivated, and
//! destroyed without crashing the host process.
//!
//! Run: `zig build test-clap-load`

const std = @import("std");
const clap = @import("clap-bindings");
const plugins = @import("plugin/plugins.zig");

const sample_rate: f64 = 44_100;
const max_frames: u32 = 512;

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const MockHost = struct {
    clap_host: clap.Host,
    main_thread_id: std.Thread.Id,

    const thread_check_ext = clap.ext.thread_check.Host{
        .isMainThread = isMainThread,
        .isAudioThread = isAudioThread,
    };

    fn init() MockHost {
        return .{
            .clap_host = .{
                .clap_version = clap.version,
                .host_data = undefined,
                .name = "flux-clap-load-test",
                .vendor = "flux",
                .url = null,
                .version = "0.1",
                .getExtension = getExtension,
                .requestRestart = requestRestart,
                .requestProcess = requestProcess,
                .requestCallback = requestCallback,
            },
            .main_thread_id = std.Thread.getCurrentId(),
        };
    }

    fn clapHost(self: *MockHost) *const clap.Host {
        self.clap_host.host_data = self;
        return &self.clap_host;
    }

    fn getExtension(host: *const clap.Host, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
        _ = host;
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.thread_check.id)) {
            return &thread_check_ext;
        }
        return null;
    }

    fn requestRestart(_: *const clap.Host) callconv(.c) void {}
    fn requestProcess(_: *const clap.Host) callconv(.c) void {}
    fn requestCallback(_: *const clap.Host) callconv(.c) void {}

    fn isMainThread(host: *const clap.Host) callconv(.c) bool {
        const self: *const MockHost = @ptrCast(@alignCast(host.host_data));
        return std.Thread.getCurrentId() == self.main_thread_id;
    }

    fn isAudioThread(_: *const clap.Host) callconv(.c) bool {
        return false;
    }
};

const LoadError = error{
    DynLibOpenFailed,
    MissingClapEntry,
    EntryInitFailed,
    MissingPluginFactory,
    PluginCreateFailed,
    PluginInitFailed,
    PluginActivateFailed,
};

/// Open one CLAP instance, init/activate, then tear down in reverse order.
fn loadAndClose(
    allocator: std.mem.Allocator,
    host: *const clap.Host,
    plugin_path: []const u8,
    plugin_id: []const u8,
) (LoadError || std.mem.Allocator.Error)!void {
    const plugin_path_z = try allocator.dupeSentinel(u8, plugin_path, 0);
    defer allocator.free(plugin_path_z);

    var lib = std.DynLib.open(plugin_path) catch return error.DynLibOpenFailed;
    defer lib.close();

    const entry = lib.lookup(*const clap.Entry, "clap_entry") orelse return error.MissingClapEntry;
    if (!entry.init(plugin_path_z)) return error.EntryInitFailed;
    defer entry.deinit();

    const factory_raw = entry.getFactory(clap.PluginFactory.id) orelse return error.MissingPluginFactory;
    const factory: *const clap.PluginFactory = @ptrCast(@alignCast(factory_raw));

    const id_z = try allocator.dupeSentinel(u8, plugin_id, 0);
    defer allocator.free(id_z);

    const plugin = factory.createPlugin(factory, host, id_z) orelse return error.PluginCreateFailed;
    if (!plugin.init(plugin)) {
        plugin.destroy(plugin);
        return error.PluginInitFailed;
    }
    if (!plugin.activate(plugin, sample_rate, 1, max_frames)) {
        plugin.destroy(plugin);
        return error.PluginActivateFailed;
    }
    plugin.deactivate(plugin);
    plugin.destroy(plugin);
}

pub fn main() !void {
    // GPA: third-party plugins allocate outside our allocator.
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const io = testIo();

    var catalog = try plugins.discover(allocator, io);
    defer catalog.deinit();

    var host = MockHost.init();
    const clap_host = host.clapHost();

    var attempted: usize = 0;
    var ok_count: usize = 0;
    var failed: usize = 0;

    for (catalog.entries.items) |entry| {
        if (entry.kind != .clap) continue;
        const path = entry.path orelse continue;
        const id = entry.id orelse continue;

        attempted += 1;
        loadAndClose(allocator, clap_host, path, id) catch |err| {
            std.debug.print("FAIL {s} id={s} path={s} err={}\n", .{ entry.name, id, path, err });
            failed += 1;
            continue;
        };
        ok_count += 1;
        std.debug.print("OK   {s} ({s})\n", .{ entry.name, id });
    }

    std.debug.print("CLAP load summary: {d} ok, {d} failed, {d} attempted\n", .{ ok_count, failed, attempted });

    // Zero plugins is fine on a clean machine. When any are present, all must load.
    if (failed != 0) std.process.exit(1);
}
