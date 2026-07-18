const std = @import("std");
const clap = @import("clap-bindings");

const audio_engine = @import("../../audio/audio_engine.zig");
const file_dialog = @import("../../app/file_dialog.zig");
const plugin_runtime = @import("../../plugin/plugin_runtime.zig");
const plugins = @import("../../plugin/plugins.zig");
const session_constants = @import("../../session/constants.zig");
const ui_state = @import("../../ui/state.zig");

const project_io = @import("../io.zig");
const apply = @import("apply.zig");

const track_count = session_constants.max_tracks;
const TrackPlugin = plugin_runtime.TrackPlugin;

const dawproject_file_types = [_]file_dialog.FileType{
    .{ .name = "DAWproject", .extensions = &.{"dawproject"} },
};

pub fn handleLoadProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *[track_count]TrackPlugin,
    track_fx: *[track_count][ui_state.max_fx_slots]TrackPlugin,
    host: *const clap.Host,
    shared: ?*audio_engine.SharedState,
) !void {
    // Show open dialog
    const path = file_dialog.openFile(
        allocator,
        io,
        "Open DAWproject",
        &dawproject_file_types,
    ) catch |err| {
        std.log.err("File dialog error: {}", .{err});
        return;
    };

    if (path == null) {
        // User cancelled
        return;
    }
    defer allocator.free(path.?);

    // Load the project
    var loaded = project_io.load(allocator, io, path.?) catch |err| {
        std.log.err("Failed to load dawproject: {}", .{err});
        return;
    };
    defer loaded.deinit();

    // Apply to state
    apply.applyDawprojectToState(allocator, &loaded, state, catalog, track_plugins, track_fx, host, shared, io) catch |err| {
        std.log.err("Failed to apply dawproject: {}", .{err});
        return;
    };

    try state.setProjectPath(path.?);
    if (loaded.needs_thin_save) {
        state.needs_thin_save = true;
        std.log.info("Opened packed project; media under samples/ — Save to convert to thin layout", .{});
    } else {
        state.clearProjectDirty();
    }
    // flux_undo.xml is kept in the archive on Save; full stack restore is not wired yet.
    if (loaded.undo_xml) |_| {
        std.log.info("Project archive includes flux_undo.xml (restore not implemented)", .{});
    }
    std.log.info("Loaded project from: {s}", .{path.?});
}
