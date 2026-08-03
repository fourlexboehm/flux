//! Main-thread CLAP `params.flush` helper for host param chrome.
//!
//! UI code pushes a single param-value event and flushes so `getValue` updates
//! immediately. Concurrent with process is avoided by only calling this from
//! the main thread while the audio graph still also receives controller writes
//! for the next process block (see `engine_ui.ControllerParamWrite`).

const std = @import("std");
const clap = @import("clap-bindings");
const audio_events = @import("../audio/audio_events.zig");

/// Apply one parameter value on the main thread via the params extension.
/// Returns false when the plugin has no params extension.
pub fn flushParamValue(plugin: *const clap.Plugin, param_id: u32, value: f64) bool {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse return false;
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));

    var list: audio_events.EventList = .{};
    list.pushParam(.{
        .header = .{
            .size = @sizeOf(clap.events.ParamValue),
            .sample_offset = 0,
            .space_id = clap.events.core_space_id,
            .type = .param_value,
            .flags = .{ .is_live = true },
        },
        .param_id = @enumFromInt(param_id),
        .cookie = null,
        .note_id = .unspecified,
        .port_index = .unspecified,
        .channel = .unspecified,
        .key = .unspecified,
        .value = value,
    });

    var in_events = audio_events.emptyInputEvents(&list);
    var out_list: audio_events.OutputEventList = .{};
    var out_events = clap.events.OutputEvents{
        .context = &out_list,
        .tryPush = audio_events.outputEventsTryPush,
    };
    params.flush(plugin, &in_events, &out_events);
    return true;
}

/// Read plain value; returns null if missing.
pub fn getParamValue(plugin: *const clap.Plugin, param_id: u32) ?f64 {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse return null;
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    var value: f64 = 0;
    if (!params.getValue(plugin, @enumFromInt(param_id), &value)) return null;
    return value;
}

/// CString name from Info (truncated at first NUL).
pub fn paramName(info: *const clap.ext.params.Info) []const u8 {
    return std.mem.sliceTo(&info.name, 0);
}
