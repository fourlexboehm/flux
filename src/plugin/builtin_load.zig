//! Static (in-process) CLAP builtin instantiation — no DynLib, no UI.
//!
//! Stock Flux FX (equalizer / compressor / gate / limiter) ship without a
//! `.clap` bundle path in the catalog; the DVUI host loads them here, matching
//! the zgui `plugin_runtime.loadBuiltinPlugin` path for FX only.
//!
//! Instrument builtins (ZSynth / ZMinimoog / ZPortaFM) load the same way now
//! that they carry no plugin-side GUI: the DVUI host draws their editors
//! (`src/ui/panels/editors/`) against the in-process instance.

const std = @import("std");
const clap = @import("clap-bindings");

const audio_constants = @import("../audio/audio_constants.zig");
const plugin_handle = @import("handle.zig");
const flux_builtins = @import("../builtins/root.zig");
const instrument_registry = @import("../builtins/instruments/registry.zig");

const BuiltinHandle = plugin_handle.BuiltinHandle;
const LoadedPlugin = plugin_handle.LoadedPlugin;

pub const Error = error{
    UnknownBuiltin,
    PluginInitFailed,
    PluginActivateFailed,
    OutOfMemory,
};

/// True when `plugin_id` is a stock Flux audio FX that can be linked in-process.
pub fn isStaticFxId(plugin_id: []const u8) bool {
    return flux_builtins.isBuiltinFxId(plugin_id);
}

/// True when `plugin_id` is a Flux built-in instrument linked in-process.
pub fn isStaticInstrumentId(plugin_id: []const u8) bool {
    return instrument_registry.isBuiltinInstrumentId(plugin_id);
}

/// True for any Flux built-in (instrument or FX) that needs no `.clap` bundle.
pub fn isStaticId(plugin_id: []const u8) bool {
    return isStaticFxId(plugin_id) or isStaticInstrumentId(plugin_id);
}

/// Instantiate a stock Flux FX into `slot.builtin`. Caller must ensure the slot
/// is unloaded first. Does not open a GUI (builtins use host param chrome).
pub fn loadStaticFx(
    slot: *LoadedPlugin,
    allocator: std.mem.Allocator,
    host: *const clap.Host,
    plugin_id: []const u8,
    max_frames: u32,
) Error!void {
    if (!flux_builtins.isBuiltinFxId(plugin_id)) return error.UnknownBuiltin;

    const plugin = flux_builtins.initById(allocator, host, plugin_id) catch |err| switch (err) {
        error.UnknownBuiltin => return error.UnknownBuiltin,
        error.OutOfMemory => return error.OutOfMemory,
    };

    try activateIntoSlot(slot, &plugin.plugin, max_frames);
}

/// Instantiate a Flux built-in instrument into `slot.builtin`. Caller must
/// ensure the slot is unloaded first. No plugin GUI: the host draws the editor.
pub fn loadStaticInstrument(
    slot: *LoadedPlugin,
    allocator: std.mem.Allocator,
    host: *const clap.Host,
    plugin_id: []const u8,
    max_frames: u32,
) Error!void {
    const plugin = instrument_registry.initById(allocator, host, plugin_id) catch |err| switch (err) {
        error.UnknownBuiltin => return error.UnknownBuiltin,
        error.OutOfMemory => return error.OutOfMemory,
    };
    try activateIntoSlot(slot, plugin, max_frames);
}

/// Shared static tail: init + activate, then publish into the slot.
fn activateIntoSlot(slot: *LoadedPlugin, plugin: *clap.Plugin, max_frames: u32) Error!void {
    if (!plugin.init(plugin)) {
        // destroy → _destroy → deinit (frees the heap Plugin)
        plugin.destroy(plugin);
        return error.PluginInitFailed;
    }
    if (!plugin.activate(plugin, audio_constants.sample_rate, 1, max_frames)) {
        plugin.destroy(plugin);
        return error.PluginActivateFailed;
    }

    slot.builtin = BuiltinHandle{ .plugin = plugin };
    slot.handle = null;
    slot.gui_ext = null;
    slot.clearGuiFlags();
}

test "static fx id recognition" {
    try std.testing.expect(isStaticFxId("com.flux.builtin.equalizer"));
    try std.testing.expect(isStaticFxId("com.flux.builtin.compressor"));
    try std.testing.expect(!isStaticFxId("com.juge.zsynth"));
    try std.testing.expect(!isStaticFxId("org.surge-synth-team.surge-xt"));
}

test "static instrument id recognition" {
    try std.testing.expect(isStaticInstrumentId("com.juge.zsynth"));
    try std.testing.expect(isStaticInstrumentId("com.fourlex.zminimoog"));
    try std.testing.expect(isStaticInstrumentId("com.fourlex.zportafm"));
    try std.testing.expect(!isStaticInstrumentId("com.flux.builtin.limiter"));
    try std.testing.expect(isStaticId("com.flux.builtin.limiter"));
}

const TestHost = struct {
    clap_host: clap.Host = .{
        .clap_version = clap.version,
        .host_data = undefined,
        .name = "flux-test",
        .vendor = "flux",
        .url = null,
        .version = "0.1",
        .getExtension = getExtension,
        .requestRestart = noop,
        .requestProcess = noop,
        .requestCallback = noop,
    },

    fn getExtension(_: *const clap.Host, _: [*:0]const u8) callconv(.c) ?*const anyopaque {
        return null;
    }
    fn noop(_: *const clap.Host) callconv(.c) void {}
};

test "built-in instruments instantiate in-process" {
    var host = TestHost{};
    for ([_][]const u8{
        "com.juge.zsynth",
        "com.fourlex.zminimoog",
        "com.fourlex.zportafm",
    }) |id| {
        var slot = LoadedPlugin{};
        try loadStaticInstrument(&slot, std.testing.allocator, &host.clap_host, id, 512);
        try std.testing.expect(slot.isLoaded());
        const plugin = slot.getPlugin().?;
        try std.testing.expectEqualStrings(id, std.mem.sliceTo(plugin.descriptor.id, 0));
        slot.builtin.?.deinit();
        slot.builtin = null;
    }
}

test "unknown builtin id is rejected" {
    var host = TestHost{};
    var slot = LoadedPlugin{};
    try std.testing.expectError(
        error.UnknownBuiltin,
        loadStaticInstrument(&slot, std.testing.allocator, &host.clap_host, "com.example.nope", 512),
    );
    try std.testing.expect(!slot.isLoaded());
}
