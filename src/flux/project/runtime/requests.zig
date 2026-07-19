const std = @import("std");
const clap = @import("clap-bindings");

const audio_engine = @import("../../audio/audio_engine.zig");
const clap_ids = @import("../../util/clap_ids.zig");
const plugin_runtime = @import("../../plugin/plugin_runtime.zig");
const plugins = @import("../../plugin/plugins.zig");
const session_constants = @import("../../session/constants.zig");
const ui_state = @import("../../ui/state.zig");

const save = @import("save.zig");
const load = @import("load.zig");
const plugin_state = @import("plugin_state.zig");

const track_count = session_constants.max_tracks;
const TrackPlugin = plugin_runtime.TrackPlugin;

pub fn handleFileRequests(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *[track_count]TrackPlugin,
    track_fx: *[track_count][ui_state.max_fx_slots]TrackPlugin,
    host: *const clap.Host,
    shared: ?*audio_engine.SharedState,
) void {
    // Handle save request
    if (state.save_project_request) {
        state.save_project_request = false;
        if (state.project_path == null) {
            state.save_project_as_request = true;
        } else {
            save.handleSaveProject(allocator, io, state, catalog, track_plugins, track_fx, shared) catch |err| {
                std.log.err("Failed to save project: {}", .{err});
            };
        }
    }

    if (state.save_project_as_request) {
        state.save_project_as_request = false;
        save.handleSaveProjectAs(allocator, io, state, catalog, track_plugins, track_fx, shared) catch |err| {
            std.log.err("Failed to save project as: {}", .{err});
        };
    }

    if (state.pack_project_request) {
        state.pack_project_request = false;
        save.handlePackProject(allocator, io, state, catalog, track_plugins, track_fx, shared) catch |err| {
            std.log.err("Failed to pack project: {}", .{err});
        };
    }

    // Handle load request
    if (state.load_project_request) {
        state.load_project_request = false;
        load.handleLoadProject(allocator, io, state, catalog, track_plugins, track_fx, host, shared) catch |err| {
            std.log.err("Failed to load project: {}", .{err});
        };
    }

    // Handle plugin state restore request (for undo/redo)
    if (state.plugin_state_restore_request) |req| {
        state.plugin_state_restore_request = null;
        if (req.track_index < track_count) {
            const plugin: ?*const clap.Plugin = if (req.fx_index) |fx_idx|
                if (fx_idx < ui_state.max_fx_slots) track_fx[req.track_index][fx_idx].getPlugin() else null
            else
                track_plugins[req.track_index].getPlugin();
            if (plugin) |p| {
                plugin_state.loadPluginStateFromData(p, req.state_data);
            }
        }
    }
}

pub fn applyPresetLoadRequests(
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *[track_count]TrackPlugin,
) void {
    const request = state.preset_load_request orelse return;
    const track_idx = request.track_index;
    if (track_idx >= track_count) {
        state.preset_load_request = null;
        return;
    }

    const choice = state.track_plugins[track_idx].choice_index;
    const entry = catalog.entryForIndex(choice) orelse {
        state.preset_load_request = null;
        return;
    };
    if (entry.id == null or !std.mem.eql(u8, entry.id.?, request.plugin_id)) {
        state.preset_load_request = null;
        return;
    }

    const plugin = track_plugins[track_idx].getPlugin() orelse return;
    const preset_ext_raw = plugin.getExtension(plugin, clap.ext.preset_load.id) orelse
        plugin.getExtension(plugin, clap_ids.preset_load_compat_id);
    if (preset_ext_raw) |ext_raw| {
        const ext: *const clap.ext.preset_load.Plugin = @ptrCast(@alignCast(ext_raw));
        const load_key_ptr: ?[*:0]const u8 = if (request.load_key) |key| key.ptr else null;
        const location_ptr: ?[*:0]const u8 = if (request.location_kind == .plugin) null else request.location.ptr;
        const ok = ext.fromLocation(plugin, request.location_kind, location_ptr, load_key_ptr);
        if (!ok) {
            std.log.warn("Preset load failed (plugin returned false)", .{});
        }
    } else {
        std.log.warn("Plugin does not support preset-load extension", .{});
    }

    state.preset_load_request = null;
}
