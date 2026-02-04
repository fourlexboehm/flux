const std = @import("std");

const plugins = @import("plugins.zig");
const plugin_runtime = @import("plugin_runtime.zig");
const session_constants = @import("ui/session_view/constants.zig");
const ui_state = @import("ui/state.zig");

const track_count = session_constants.max_tracks;
const TrackPlugin = plugin_runtime.TrackPlugin;

pub fn updateDeviceState(
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [track_count]TrackPlugin,
    track_fx: *const [track_count][ui_state.max_fx_slots]TrackPlugin,
) void {
    const track_idx = state.device_target_track;
    const choice = switch (state.device_target_kind) {
        .instrument => state.track_plugins[track_idx].choice_index,
        .fx => state.track_fx[track_idx][state.device_target_fx].choice_index,
    };
    const entry = catalog.entryForIndex(choice);
    if (entry == null or entry.?.kind == .none or entry.?.kind == .divider) {
        state.device_kind = .none;
        state.device_clap_plugin = null;
        state.device_clap_name = "";
        return;
    }

    // Get the plugin from TrackPlugin (works for both builtin and external)
    const track_plugin = switch (state.device_target_kind) {
        .instrument => &track_plugins[track_idx],
        .fx => &track_fx[track_idx][state.device_target_fx],
    };
    const plugin = track_plugin.getPlugin();

    if (plugin != null) {
        state.device_kind = .plugin;
        state.device_clap_plugin = plugin;
        state.device_clap_name = entry.?.name;
    } else {
        // Plugin not yet loaded (will be loaded on next sync)
        state.device_kind = .none;
        state.device_clap_plugin = null;
        state.device_clap_name = entry.?.name;
    }
}
