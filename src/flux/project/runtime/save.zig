const std = @import("std");
const clap = @import("clap-bindings");

const audio_engine = @import("../../audio/audio_engine.zig");
const file_dialog = @import("../../app/file_dialog.zig");
const plugin_runtime = @import("../../plugin/plugin_runtime.zig");
const plugins = @import("../../plugin/plugins.zig");
const session_constants = @import("../../session/constants.zig");
const thread_context = @import("../../util/thread_context.zig");
const ui_state = @import("../../ui/state.zig");

const project_io = @import("../io.zig");
const io_types = @import("../io_types.zig");
const plugin_state = @import("plugin_state.zig");

const track_count = session_constants.max_tracks;
const TrackPlugin = plugin_runtime.TrackPlugin;

const dawproject_file_types = [_]file_dialog.FileType{
    .{ .name = "DAWproject", .extensions = &.{"dawproject"} },
};

const WriteMode = enum { thin_save, pack };

pub fn handleSaveProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [track_count]TrackPlugin,
    track_fx: *const [track_count][ui_state.max_fx_slots]TrackPlugin,
    shared: ?*audio_engine.SharedState,
) !void {
    const path = state.project_path orelse return;
    try saveProjectToPath(allocator, io, path, state, catalog, track_plugins, track_fx, shared);
}

pub fn handleSaveProjectAs(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [track_count]TrackPlugin,
    track_fx: *const [track_count][ui_state.max_fx_slots]TrackPlugin,
    shared: ?*audio_engine.SharedState,
) !void {
    const default_name = if (state.project_path) |path| std.fs.path.basename(path) else "project.dawproject";

    const path = file_dialog.saveFile(
        allocator,
        io,
        "Save DAWproject",
        default_name,
        &dawproject_file_types,
    ) catch |err| {
        std.log.err("File dialog error: {}", .{err});
        return;
    };

    if (path == null) {
        return;
    }
    defer allocator.free(path.?);

    try saveProjectToPath(allocator, io, path.?, state, catalog, track_plugins, track_fx, shared);
    try state.setProjectPath(path.?);
}

pub fn handlePackProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [track_count]TrackPlugin,
    track_fx: *const [track_count][ui_state.max_fx_slots]TrackPlugin,
    shared: ?*audio_engine.SharedState,
) !void {
    const default_name = blk: {
        if (state.project_path) |pp| {
            const base = std.fs.path.stem(pp);
            break :blk try std.fmt.allocPrint(allocator, "{s}-packed.dawproject", .{base});
        }
        break :blk try allocator.dupe(u8, "project-packed.dawproject");
    };
    defer allocator.free(default_name);

    const path = file_dialog.saveFile(
        allocator,
        io,
        "Pack Project",
        default_name,
        &dawproject_file_types,
    ) catch |err| {
        std.log.err("File dialog error: {}", .{err});
        return;
    };
    if (path == null) return;
    defer allocator.free(path.?);

    try writeProjectToPath(allocator, io, path.?, state, catalog, track_plugins, track_fx, shared, .pack);
    std.log.info("Packed project to: {s}", .{path.?});
}

fn saveProjectToPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [track_count]TrackPlugin,
    track_fx: *const [track_count][ui_state.max_fx_slots]TrackPlugin,
    shared: ?*audio_engine.SharedState,
) !void {
    try writeProjectToPath(allocator, io, path, state, catalog, track_plugins, track_fx, shared, .thin_save);
}

fn writeProjectToPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [track_count]TrackPlugin,
    track_fx: *const [track_count][ui_state.max_fx_slots]TrackPlugin,
    shared: ?*audio_engine.SharedState,
    mode: WriteMode,
) !void {
    var param_arena = std.heap.ArenaAllocator.init(allocator);
    defer param_arena.deinit();
    const param_alloc = param_arena.allocator();

    var plugin_states: std.ArrayList(io_types.PluginStateFile) = .empty;
    defer {
        for (plugin_states.items) |ps| {
            allocator.free(ps.path);
            allocator.free(ps.data);
        }
        plugin_states.deinit(allocator);
    }

    var track_plugin_info: [track_count]io_types.TrackPluginInfo = undefined;
    for (&track_plugin_info) |*info| info.* = .{};
    var track_fx_plugin_info: [track_count][ui_state.max_fx_slots]io_types.TrackPluginInfo = undefined;
    for (&track_fx_plugin_info) |*track_slots| {
        for (track_slots) |*info| info.* = .{};
    }

    // Plugin calls require a stable, stopped processing state. Resume before
    // media copying, XML generation, compression, and filesystem writes.
    {
        const plugins_for_tracks = plugin_runtime.collectPlugins(track_plugins, track_fx);
        const was_audio = thread_context.is_audio_thread;
        if (shared) |s| {
            s.setSuspendProcessing(true);
            s.waitForIdle(io);
            thread_context.is_audio_thread = true;
            for (0..track_count) |t| {
                if (s.isPluginStarted(t)) {
                    if (plugins_for_tracks.instruments[t]) |plugin| plugin.stopProcessing(plugin);
                    s.clearPluginStarted(t);
                }
                for (0..ui_state.max_fx_slots) |fx_index| {
                    if (s.isFxPluginStarted(t, fx_index)) {
                        if (plugins_for_tracks.fx[t][fx_index]) |plugin| plugin.stopProcessing(plugin);
                        s.clearFxPluginStarted(t, fx_index);
                    }
                }
            }
        }
        defer {
            if (shared) |s| {
                for (0..track_count) |t| {
                    if (plugins_for_tracks.instruments[t] != null) s.requestStartProcessing(t);
                    for (0..ui_state.max_fx_slots) |fx_index| {
                        if (plugins_for_tracks.fx[t][fx_index] != null) s.requestStartProcessingFx(t, fx_index);
                    }
                }
                thread_context.is_audio_thread = was_audio;
                s.setSuspendProcessing(false);
            }
        }

        for (track_plugins, 0..) |track, t| {
            if (track.getPlugin()) |plugin| {
                track_plugin_info[t].plugin_id = std.mem.span(plugin.descriptor.id);
                track_plugin_info[t].params = collectPluginParams(param_alloc, plugin);
                if (plugin_state.capturePluginStateForDawproject(allocator, plugin, t, null)) |ps| {
                    track_plugin_info[t].state_path = ps.path;
                    try plugin_states.append(allocator, ps);
                }
            } else if (state.missing_track_plugins[t]) |missing| {
                track_plugin_info[t].plugin_id = missing.device_id;
                track_plugin_info[t].params = missingPluginParams(param_alloc, &missing);
                if (copyMissingPluginState(allocator, &missing, t, null)) |ps| {
                    track_plugin_info[t].state_path = ps.path;
                    try plugin_states.append(allocator, ps);
                }
            }
        }
        for (track_fx, 0..) |track_slots, t| {
            for (track_slots, 0..) |slot, fx_index| {
                if (slot.getPlugin()) |plugin| {
                    track_fx_plugin_info[t][fx_index].plugin_id = std.mem.span(plugin.descriptor.id);
                    track_fx_plugin_info[t][fx_index].params = collectPluginParams(param_alloc, plugin);
                    if (plugin_state.capturePluginStateForDawproject(allocator, plugin, t, fx_index)) |ps| {
                        track_fx_plugin_info[t][fx_index].state_path = ps.path;
                        try plugin_states.append(allocator, ps);
                    }
                } else if (state.missing_track_fx[t][fx_index]) |missing| {
                    track_fx_plugin_info[t][fx_index].plugin_id = missing.device_id;
                    track_fx_plugin_info[t][fx_index].params = missingPluginParams(param_alloc, &missing);
                    if (copyMissingPluginState(allocator, &missing, t, fx_index)) |ps| {
                        track_fx_plugin_info[t][fx_index].state_path = ps.path;
                        try plugin_states.append(allocator, ps);
                    }
                }
            }
        }
    }

    switch (mode) {
        .thin_save => {
            try project_io.save(
                allocator,
                io,
                path,
                state,
                catalog,
                plugin_states.items,
                &track_plugin_info,
                &track_fx_plugin_info,
            );
            state.clearProjectDirty();
            std.log.info("Saved project to: {s}", .{path});
        },
        .pack => {
            try project_io.pack(
                allocator,
                io,
                path,
                state,
                catalog,
                plugin_states.items,
                &track_plugin_info,
                &track_fx_plugin_info,
            );
        },
    }
}

fn collectPluginParams(
    allocator: std.mem.Allocator,
    plugin: *const clap.Plugin,
) []const io_types.PluginParamInfo {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse return &.{};
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const count = params.count(plugin);
    if (count == 0) return &.{};

    var list: std.ArrayList(io_types.PluginParamInfo) = .empty;
    for (0..count) |i| {
        var info: clap.ext.params.Info = undefined;
        if (!params.getInfo(plugin, @intCast(i), &info)) continue;
        const name = std.mem.sliceTo(info.name[0..], 0);
        var value: f64 = info.default_value;
        if (!params.getValue(plugin, info.id, &value)) {
            value = info.default_value;
        }
        list.append(allocator, .{
            .id = @intFromEnum(info.id),
            .name = allocator.dupe(u8, name) catch "",
            .min = info.min_value,
            .max = info.max_value,
            .default_value = info.default_value,
            .value = value,
        }) catch {};
    }

    return list.toOwnedSlice(allocator) catch &.{};
}

fn missingPluginParams(
    allocator: std.mem.Allocator,
    missing: *const ui_state.MissingPlugin,
) []const io_types.PluginParamInfo {
    const params = allocator.alloc(io_types.PluginParamInfo, missing.parameters.len) catch return &.{};
    for (missing.parameters, params) |source, *dest| {
        dest.* = .{
            .id = source.id,
            .name = source.name,
            .min = source.min,
            .max = source.max,
            .default_value = source.value,
            .value = source.value,
        };
    }
    return params;
}

fn copyMissingPluginState(
    allocator: std.mem.Allocator,
    missing: *const ui_state.MissingPlugin,
    track_index: usize,
    fx_index: ?usize,
) ?io_types.PluginStateFile {
    const data = missing.state_data orelse return null;
    var path_buf: [64]u8 = undefined;
    const path = if (fx_index) |fx_slot|
        std.fmt.bufPrint(&path_buf, "plugins/track{d}-fx{d}.clap-preset", .{ track_index, fx_slot }) catch return null
    else
        std.fmt.bufPrint(&path_buf, "plugins/track{d}.clap-preset", .{track_index}) catch return null;
    const path_copy = allocator.dupe(u8, path) catch return null;
    const data_copy = allocator.dupe(u8, data) catch {
        allocator.free(path_copy);
        return null;
    };
    return .{
        .path = path_copy,
        .data = data_copy,
    };
}
