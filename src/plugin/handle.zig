//! DynLib CLAP load/unload primitives — no UI, builtins, or GUI window deps.
//!
//! Used by the DVUI `ui/plugin_host.zig` so the host binary can load
//! instruments/FX without pulling statically-linked builtins into every
//! translation unit.

const std = @import("std");
const clap = @import("clap-bindings");

const audio_constants = @import("../audio/audio_constants.zig");
const audio_engine = @import("../audio/audio_engine.zig");
const engine_ui = @import("../audio/engine_ui.zig");
const session_constants = @import("../session/constants.zig");
const thread_context = @import("../util/thread_context.zig");

pub const track_count = session_constants.max_tracks;
pub const max_fx_slots = engine_ui.max_fx_slots;

/// External CLAP plugin loaded from disk via DynLib.
pub const PluginHandle = struct {
    lib: std.DynLib,
    entry: *const clap.Entry,
    factory: *const clap.PluginFactory,
    plugin: *const clap.Plugin,
    plugin_path_z: [:0]u8,
    activated: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        host: *const clap.Host,
        plugin_path: []const u8,
        plugin_id: ?[]const u8,
        max_frames: u32,
    ) !PluginHandle {
        const plugin_path_z = try allocator.dupeSentinel(u8, plugin_path, 0);
        errdefer allocator.free(plugin_path_z);

        var lib = try std.DynLib.open(plugin_path);
        errdefer lib.close();

        const entry = lib.lookup(*const clap.Entry, "clap_entry") orelse return error.MissingClapEntry;
        if (!entry.init(plugin_path_z)) return error.EntryInitFailed;
        errdefer entry.deinit();

        const factory_raw = entry.getFactory(clap.PluginFactory.id) orelse return error.MissingPluginFactory;
        const factory: *const clap.PluginFactory = @ptrCast(@alignCast(factory_raw));
        const plugin = blk: {
            if (plugin_id) |id| {
                const id_z = try allocator.dupeSentinel(u8, id, 0);
                defer allocator.free(id_z);
                break :blk factory.createPlugin(factory, host, id_z) orelse return error.PluginCreateFailed;
            }

            const plugin_count = factory.getPluginCount(factory);
            if (plugin_count == 0) return error.NoPluginsFound;
            const desc = factory.getPluginDescriptor(factory, 0) orelse return error.MissingPluginDescriptor;
            break :blk factory.createPlugin(factory, host, desc.id) orelse return error.PluginCreateFailed;
        };

        if (!plugin.init(plugin)) return error.PluginInitFailed;

        if (!plugin.activate(plugin, audio_constants.sample_rate, 1, max_frames)) return error.PluginActivateFailed;

        return .{
            .lib = lib,
            .entry = entry,
            .factory = factory,
            .plugin = plugin,
            .plugin_path_z = plugin_path_z,
            .activated = true,
        };
    }

    pub fn deinit(self: *PluginHandle, allocator: std.mem.Allocator) void {
        // stopProcessing is called by unload* before this when SharedState is used.
        if (self.activated) {
            self.plugin.deactivate(self.plugin);
        }
        self.plugin.destroy(self.plugin);
        self.entry.deinit();
        self.lib.close();
        allocator.free(self.plugin_path_z);
    }
};

/// Handle for a builtin (statically linked) plugin.
pub const BuiltinHandle = struct {
    plugin: *clap.Plugin,

    pub fn deinit(self: *BuiltinHandle) void {
        self.plugin.deactivate(self.plugin);
        // destroy() calls the CLAP _destroy callback which already calls plugin.deinit()
        self.plugin.destroy(self.plugin);
    }
};

/// Slim loaded-plugin slot (DynLib and/or static builtin pointer).
/// Host GUI windows (floating or parented NSWindow/X11) for the DVUI path.
pub const LoadedPlugin = struct {
    handle: ?PluginHandle = null,
    builtin: ?BuiltinHandle = null,
    choice_index: i32 = -1,
    /// CLAP gui extension while a host GUI is open (DVUI host).
    gui_ext: ?*const clap.ext.gui.Plugin = null,
    gui_open: bool = false,
    /// Host-owned window handle:
    /// - macOS: NSWindow *
    /// - Linux X11: Display *
    gui_window: ?*anyopaque = null,
    /// macOS: NSView * content view for setParent.
    gui_view: ?*anyopaque = null,
    /// Linux X11: parent Window id (0 = none). Display lives in `gui_window`.
    gui_x11_window: u64 = 0,

    pub fn getPlugin(self: *const LoadedPlugin) ?*const clap.Plugin {
        if (self.handle) |h| return h.plugin;
        if (self.builtin) |b| return b.plugin;
        return null;
    }

    pub fn isLoaded(self: *const LoadedPlugin) bool {
        return self.handle != null or self.builtin != null;
    }

    pub fn clearGuiFlags(self: *LoadedPlugin) void {
        self.gui_ext = null;
        self.gui_open = false;
        self.gui_window = null;
        self.gui_view = null;
        self.gui_x11_window = 0;
    }
};

pub fn pluginHasAudioInput(plugin: *const clap.Plugin) bool {
    const ext_raw = plugin.getExtension(plugin, clap.ext.audio_ports.id) orelse return false;
    const ports: *const clap.ext.audio_ports.Plugin = @ptrCast(@alignCast(ext_raw));
    return ports.count(plugin, true) > 0;
}

pub fn getGuiExt(plugin: *const clap.Plugin) ?*const clap.ext.gui.Plugin {
    const ext_raw = plugin.getExtension(plugin, clap.ext.gui.id) orelse return null;
    return @ptrCast(@alignCast(ext_raw));
}

/// Stop + destroy an instrument slot (main thread; device should be idle or
/// SharedState used to quiesce the audio thread first).
pub fn unloadInstrument(
    slot: *LoadedPlugin,
    allocator: std.mem.Allocator,
    shared: ?*audio_engine.SharedState,
    track_index: usize,
) void {
    if (slot.getPlugin()) |plugin| {
        if (shared) |s| {
            if (s.isPluginStarted(track_index)) {
                const was_audio = thread_context.is_audio_thread;
                thread_context.is_audio_thread = true;
                defer thread_context.is_audio_thread = was_audio;
                plugin.stopProcessing(plugin);
                s.clearPluginStarted(track_index);
            }
        }
    }
    if (slot.handle) |*h| {
        h.deinit(allocator);
    }
    if (slot.builtin) |*b| {
        b.deinit();
    }
    slot.handle = null;
    slot.builtin = null;
    slot.clearGuiFlags();
}

pub fn unloadFx(
    slot: *LoadedPlugin,
    allocator: std.mem.Allocator,
    shared: ?*audio_engine.SharedState,
    track_index: usize,
    fx_index: usize,
) void {
    if (slot.getPlugin()) |plugin| {
        if (shared) |s| {
            if (s.isFxPluginStarted(track_index, fx_index)) {
                const was_audio = thread_context.is_audio_thread;
                thread_context.is_audio_thread = true;
                defer thread_context.is_audio_thread = was_audio;
                plugin.stopProcessing(plugin);
                s.clearFxPluginStarted(track_index, fx_index);
            }
        }
    }
    if (slot.handle) |*h| {
        h.deinit(allocator);
    }
    if (slot.builtin) |*b| {
        b.deinit();
    }
    slot.handle = null;
    slot.builtin = null;
    slot.clearGuiFlags();
}

pub const PluginSnapshot = struct {
    instruments: [track_count]?*const clap.Plugin,
    fx: [track_count][max_fx_slots]?*const clap.Plugin,
};

pub fn collectLoaded(
    instruments: *const [track_count]LoadedPlugin,
    fx: *const [track_count][max_fx_slots]LoadedPlugin,
) PluginSnapshot {
    var inst: [track_count]?*const clap.Plugin = @splat(null);
    var fx_out: [track_count][max_fx_slots]?*const clap.Plugin = @splat(@splat(null));
    for (0..track_count) |t| {
        inst[t] = instruments[t].getPlugin();
        for (0..max_fx_slots) |fx_index| {
            fx_out[t][fx_index] = fx[t][fx_index].getPlugin();
        }
    }
    return .{ .instruments = inst, .fx = fx_out };
}
