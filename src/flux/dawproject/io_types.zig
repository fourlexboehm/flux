pub const PluginStateFile = struct {
    path: []const u8, // e.g. "plugins/abc123.clap-preset"
    data: []const u8, // raw binary state
};

pub const PluginParamInfo = struct {
    id: u32,
    name: []const u8,
    min: f64,
    max: f64,
    default_value: f64,
    value: f64,
};

/// Plugin info for a track, used when building the DAWproject
pub const TrackPluginInfo = struct {
    plugin_id: ?[]const u8 = null, // CLAP plugin ID, e.g. "com.digital-suburban.dexed"
    state_path: ?[]const u8 = null, // Path in ZIP, e.g. "plugins/track0.clap-preset"
    params: []const PluginParamInfo = &.{},
};
