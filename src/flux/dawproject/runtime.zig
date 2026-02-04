const std = @import("std");
const clap = @import("clap-bindings");

const audio_engine = @import("../audio_engine.zig");
const clap_ids = @import("../clap_ids.zig");
const file_dialog = @import("../file_dialog.zig");
const piano_roll_types = @import("../ui/piano_roll/types.zig");
const plugin_runtime = @import("../plugin_runtime.zig");
const plugins = @import("../plugins.zig");
const session_constants = @import("../ui/session_view/constants.zig");
const session_ops = @import("../ui/session_view/ops.zig");
const session_view = @import("../ui/session_view.zig");
const thread_context = @import("../thread_context.zig");
const ui_state = @import("../ui/state.zig");

const dawproject_io = @import("io.zig");
const dawproject_types = @import("types.zig");
const dawproject_io_types = @import("io_types.zig");

const track_count = session_constants.max_tracks;
const scene_count = session_constants.max_scenes;
const master_track_index = session_view.master_track_index;
const TrackPlugin = plugin_runtime.TrackPlugin;

const dawproject_file_types = [_]file_dialog.FileType{
    .{ .name = "DAWproject", .extensions = &.{"dawproject"} },
};

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
            handleSaveProject(allocator, io, state, catalog, track_plugins, track_fx, shared) catch |err| {
                std.log.err("Failed to save project: {}", .{err});
            };
        }
    }

    if (state.save_project_as_request) {
        state.save_project_as_request = false;
        handleSaveProjectAs(allocator, io, state, catalog, track_plugins, track_fx, shared) catch |err| {
            std.log.err("Failed to save project as: {}", .{err});
        };
    }

    // Handle load request
    if (state.load_project_request) {
        state.load_project_request = false;
        handleLoadProject(allocator, io, state, catalog, track_plugins, track_fx, host, shared) catch |err| {
            std.log.err("Failed to load project: {}", .{err});
        };
    }

    // Handle plugin state restore request (for undo/redo)
    if (state.plugin_state_restore_request) |req| {
        state.plugin_state_restore_request = null;
        if (req.track_index < track_count) {
            // All plugins (builtin and external) are now in TrackPlugin
            if (track_plugins[req.track_index].getPlugin()) |plugin| {
                loadPluginStateFromData(plugin, req.state_data);
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

fn handleSaveProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *const ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [track_count]TrackPlugin,
    track_fx: *const [track_count][ui_state.max_fx_slots]TrackPlugin,
    shared: ?*audio_engine.SharedState,
) !void {
    const path = state.project_path orelse return;
    try saveProjectToPath(allocator, io, path, state, catalog, track_plugins, track_fx, shared);
}

fn handleSaveProjectAs(
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

fn saveProjectToPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: *const ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *const [track_count]TrackPlugin,
    track_fx: *const [track_count][ui_state.max_fx_slots]TrackPlugin,
    shared: ?*audio_engine.SharedState,
) !void {
    if (shared) |s| {
        s.setSuspendProcessing(true);
        defer s.setSuspendProcessing(false);
        s.waitForIdle(io);
        const was_audio = thread_context.is_audio_thread;
        thread_context.is_audio_thread = true;
        defer thread_context.is_audio_thread = was_audio;

        const plugins_for_tracks = plugin_runtime.collectPlugins(track_plugins, track_fx);
        defer {
            for (0..track_count) |t| {
                if (plugins_for_tracks.instruments[t] != null) {
                    s.requestStartProcessing(t);
                }
                for (0..ui_state.max_fx_slots) |fx_index| {
                    if (plugins_for_tracks.fx[t][fx_index] != null) {
                        s.requestStartProcessingFx(t, fx_index);
                    }
                }
            }
        }
        for (0..track_count) |t| {
            if (s.isPluginStarted(t)) {
                if (plugins_for_tracks.instruments[t]) |plugin| {
                    plugin.stopProcessing(plugin);
                }
                s.clearPluginStarted(t);
            }
            for (0..ui_state.max_fx_slots) |fx_index| {
                if (s.isFxPluginStarted(t, fx_index)) {
                    if (plugins_for_tracks.fx[t][fx_index]) |plugin| {
                        plugin.stopProcessing(plugin);
                    }
                    s.clearFxPluginStarted(t, fx_index);
                }
            }
        }
    }

    var param_arena = std.heap.ArenaAllocator.init(allocator);
    defer param_arena.deinit();
    const param_alloc = param_arena.allocator();

    // Collect plugin states and plugin info
    var plugin_states: std.ArrayList(dawproject_io_types.PluginStateFile) = .empty;
    defer plugin_states.deinit(allocator);

    var track_plugin_info: [track_count]dawproject_io_types.TrackPluginInfo = undefined;
    for (&track_plugin_info) |*info| {
        info.* = .{};
    }
    var track_fx_plugin_info: [track_count][ui_state.max_fx_slots]dawproject_io_types.TrackPluginInfo = undefined;
    for (&track_fx_plugin_info) |*track_slots| {
        for (track_slots) |*info| {
            info.* = .{};
        }
    }

    for (track_plugins, 0..) |track, t| {
        if (track.handle) |handle| {
            // Get the plugin ID from the loaded plugin's descriptor
            track_plugin_info[t].plugin_id = std.mem.span(handle.plugin.descriptor.id);
            track_plugin_info[t].params = collectPluginParams(param_alloc, handle.plugin);

            if (capturePluginStateForDawproject(allocator, handle.plugin, t, null)) |ps| {
                track_plugin_info[t].state_path = ps.path;
                plugin_states.append(allocator, ps) catch continue;
            }
        }
    }
    for (track_fx, 0..) |track_slots, t| {
        for (track_slots, 0..) |slot, fx_index| {
            if (slot.handle) |handle| {
                track_fx_plugin_info[t][fx_index].plugin_id = std.mem.span(handle.plugin.descriptor.id);
                track_fx_plugin_info[t][fx_index].params = collectPluginParams(param_alloc, handle.plugin);
                if (capturePluginStateForDawproject(allocator, handle.plugin, t, fx_index)) |ps| {
                    track_fx_plugin_info[t][fx_index].state_path = ps.path;
                    plugin_states.append(allocator, ps) catch continue;
                }
            }
        }
    }

    // Save the project
    dawproject_io.save(
        allocator,
        io,
        path,
        state,
        catalog,
        plugin_states.items,
        &track_plugin_info,
        &track_fx_plugin_info,
    ) catch |err| {
        std.log.err("Failed to write dawproject: {}", .{err});
        return;
    };

    std.log.info("Saved project to: {s}", .{path});
}

fn collectPluginParams(
    allocator: std.mem.Allocator,
    plugin: *const clap.Plugin,
) []const dawproject_io_types.PluginParamInfo {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse return &.{};
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const count = params.count(plugin);
    if (count == 0) return &.{};

    var list: std.ArrayList(dawproject_io_types.PluginParamInfo) = .empty;
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

fn handleLoadProject(
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
    var loaded = dawproject_io.load(allocator, io, path.?) catch |err| {
        std.log.err("Failed to load dawproject: {}", .{err});
        return;
    };
    defer loaded.deinit();

    // Apply to state
    applyDawprojectToState(allocator, &loaded, state, catalog, track_plugins, track_fx, host, shared, io) catch |err| {
        std.log.err("Failed to apply dawproject: {}", .{err});
        return;
    };

    try state.setProjectPath(path.?);
    std.log.info("Loaded project from: {s}", .{path.?});
}

fn capturePluginStateForDawproject(
    allocator: std.mem.Allocator,
    plugin: *const clap.Plugin,
    track_index: usize,
    fx_index: ?usize,
) ?dawproject_io_types.PluginStateFile {
    var stream = MemoryOStream.init(allocator);
    stream.stream.context = &stream;
    defer stream.buffer.deinit(allocator);

    if (plugin.getExtension(plugin, clap.ext.state_context.id)) |ext_raw| {
        const ext: *const clap.ext.state_context.Plugin = @ptrCast(@alignCast(ext_raw));
        if (!ext.save(plugin, &stream.stream, .project)) {
            stream.buffer.clearRetainingCapacity();
        }
    }

    if (stream.buffer.items.len == 0) {
        const ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse return null;
        const ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(ext_raw));
        if (!ext.save(plugin, &stream.stream)) {
            return null;
        }
    }

    // Build clap-preset container format:
    // [4 bytes: "clap" magic]
    // [4 bytes: plugin ID length (big-endian)]
    // [N bytes: plugin ID string]
    // [remaining: raw plugin state]
    const plugin_id = std.mem.span(plugin.descriptor.id);
    const plugin_id_len: u32 = @intCast(plugin_id.len);
    const header_size = 4 + 4 + plugin_id.len;
    const total_size = header_size + stream.buffer.items.len;

    var container = allocator.alloc(u8, total_size) catch return null;

    // Write magic "clap"
    container[0] = 'c';
    container[1] = 'l';
    container[2] = 'a';
    container[3] = 'p';

    // Write plugin ID length (big-endian)
    container[4] = @intCast((plugin_id_len >> 24) & 0xFF);
    container[5] = @intCast((plugin_id_len >> 16) & 0xFF);
    container[6] = @intCast((plugin_id_len >> 8) & 0xFF);
    container[7] = @intCast(plugin_id_len & 0xFF);

    // Write plugin ID
    @memcpy(container[8..][0..plugin_id.len], plugin_id);

    // Write raw plugin state
    @memcpy(container[header_size..], stream.buffer.items);

    var path_buf: [64]u8 = undefined;
    const plugin_path = if (fx_index) |fx_slot|
        std.fmt.bufPrint(&path_buf, "plugins/track{d}-fx{d}.clap-preset", .{ track_index, fx_slot }) catch return null
    else
        std.fmt.bufPrint(&path_buf, "plugins/track{d}.clap-preset", .{track_index}) catch return null;

    return .{
        .path = allocator.dupe(u8, plugin_path) catch return null,
        .data = container,
    };
}

/// Capture plugin state for undo. Uses state_context extension with project context
/// when available, otherwise falls back to regular state extension.
pub fn capturePluginStateForUndo(allocator: std.mem.Allocator, plugin: *const clap.Plugin) ?[]u8 {
    var stream = MemoryOStream.init(allocator);
    stream.stream.context = &stream;

    // Try state_context extension first (allows plugin to provide optimized state for undo)
    if (plugin.getExtension(plugin, clap.ext.state_context.id)) |ext_raw| {
        const ext: *const clap.ext.state_context.Plugin = @ptrCast(@alignCast(ext_raw));
        if (ext.save(plugin, &stream.stream, .project)) {
            return allocator.dupe(u8, stream.buffer.items) catch {
                stream.buffer.deinit(allocator);
                return null;
            };
        }
        // If state_context.save failed, try regular state extension
        stream.buffer.clearRetainingCapacity();
    }

    // Fall back to regular state extension
    const state_ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse {
        stream.buffer.deinit(allocator);
        return null;
    };
    const state_ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(state_ext_raw));

    if (!state_ext.save(plugin, &stream.stream)) {
        stream.buffer.deinit(allocator);
        return null;
    }

    const data = allocator.dupe(u8, stream.buffer.items) catch {
        stream.buffer.deinit(allocator);
        return null;
    };
    stream.buffer.deinit(allocator);
    return data;
}

fn applyDawprojectToState(
    allocator: std.mem.Allocator,
    loaded: *dawproject_io.LoadedProject,
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugins: *[track_count]TrackPlugin,
    track_fx: *[track_count][ui_state.max_fx_slots]TrackPlugin,
    host: *const clap.Host,
    shared: ?*audio_engine.SharedState,
    io: std.Io,
) !void {
    const proj = &loaded.project;

    // Stop playback
    state.playing = false;
    state.playhead_beat = 0;

    // Apply transport settings
    if (proj.transport) |transport| {
        if (transport.tempo) |tempo| {
            state.bpm = @floatCast(tempo.value);
        }
    }

    // Reset session
    session_ops.deinit(&state.session);
    state.session = session_ops.init(state.allocator);

    // Apply tracks
    const project_track_count = @min(proj.tracks.len, track_count);
    state.session.track_count = project_track_count;
    var instrument_device_ids: [track_count]?[]const u8 = [_]?[]const u8{null} ** track_count;
    var fx_device_ids: [track_count][ui_state.max_fx_slots]?[]const u8 = [_][ui_state.max_fx_slots]?[]const u8{
        [_]?[]const u8{null} ** ui_state.max_fx_slots,
    } ** track_count;

    for (0..project_track_count) |t| {
        state.track_plugins[t].choice_index = 0;
        state.track_plugins[t].gui_open = false;
        state.track_plugins[t].last_valid_choice = 0;
        for (0..ui_state.max_fx_slots) |fx_index| {
            state.track_fx[t][fx_index].choice_index = 0;
            state.track_fx[t][fx_index].gui_open = false;
            state.track_fx[t][fx_index].last_valid_choice = 0;
        }
    }
    for (0..ui_state.max_fx_slots) |fx_index| {
        state.track_fx[master_track_index][fx_index].choice_index = 0;
        state.track_fx[master_track_index][fx_index].gui_open = false;
        state.track_fx[master_track_index][fx_index].last_valid_choice = 0;
    }
    state.track_fx_slot_count[master_track_index] = 1;

    for (0..project_track_count) |t| {
        const track = proj.tracks[t];
        state.session.tracks[t].setName(track.name);

        if (track.channel) |channel| {
            if (channel.volume) |vol| {
                state.session.tracks[t].volume = @floatCast(vol.value);
            }
            if (channel.mute) |mute| {
                state.session.tracks[t].mute = mute.value;
            }
            state.session.tracks[t].solo = channel.solo;

            // Handle CLAP plugins
            if (channel.devices.len > 0) {
                var fx_slot: usize = 0;
                for (channel.devices) |device| {
                    const choice = findPluginInCatalog(catalog, device.device_id);
                    if (device.device_role == .instrument or device.device_role == .noteFX) {
                        state.track_plugins[t].choice_index = choice;
                        state.track_plugins[t].last_valid_choice = choice;
                        instrument_device_ids[t] = device.id;
                    } else if (device.device_role == .audioFX and fx_slot < ui_state.max_fx_slots) {
                        state.track_fx[t][fx_slot].choice_index = choice;
                        state.track_fx[t][fx_slot].last_valid_choice = choice;
                        fx_device_ids[t][fx_slot] = device.id;
                        fx_slot += 1;
                    }
                }
            }
        }
    }

    if (proj.master_track) |master_track| {
        if (master_track.channel) |channel| {
            if (channel.volume) |vol| {
                state.session.tracks[master_track_index].volume = @floatCast(vol.value);
            }
            if (channel.mute) |mute| {
                state.session.tracks[master_track_index].mute = mute.value;
            }
            if (channel.devices.len > 0) {
                var fx_slot: usize = 0;
                for (channel.devices) |device| {
                    const choice = findPluginInCatalog(catalog, device.device_id);
                    if (device.device_role == .audioFX and fx_slot < ui_state.max_fx_slots) {
                        state.track_fx[master_track_index][fx_slot].choice_index = choice;
                        state.track_fx[master_track_index][fx_slot].last_valid_choice = choice;
                        fx_slot += 1;
                    }
                }
                if (fx_slot > 0 and fx_slot < ui_state.max_fx_slots) {
                    state.track_fx_slot_count[master_track_index] = fx_slot + 1;
                } else if (fx_slot >= ui_state.max_fx_slots) {
                    state.track_fx_slot_count[master_track_index] = ui_state.max_fx_slots;
                }
            }
        }
    }

    // Apply scenes
    const project_scene_count = @min(proj.scenes.len, scene_count);
    state.session.scene_count = project_scene_count;

    for (0..project_scene_count) |s| {
        state.session.scenes[s].setName(proj.scenes[s].name);
    }

    // Clear piano clips
    for (&state.piano_clips) |*track_clips| {
        for (track_clips) |*clip| {
            clip.clear();
        }
    }

    // Apply session clips from scenes when available, otherwise fall back to arrangement lanes.
    var applied_scene_clips = false;
    if (proj.scenes.len > 0) {
        for (proj.scenes) |scene| {
            if (scene.clip_slots.len > 0) {
                applied_scene_clips = true;
                break;
            }
        }
    }

    if (applied_scene_clips) {
        try applyScenes(state, proj.scenes, proj.tracks, proj.master_track, &instrument_device_ids, &fx_device_ids);
    } else if (proj.arrangement) |arr| {
        if (arr.lanes) |root_lanes| {
            try applyLanes(state, &root_lanes, proj.tracks, &instrument_device_ids, &fx_device_ids);
        }
    }

    // Sync track plugins after state update
    try plugin_runtime.syncTrackPlugins(allocator, host, track_plugins, track_fx, state, catalog, shared, io, state.buffer_frames, true);
    try plugin_runtime.syncFxPlugins(allocator, host, track_plugins, track_fx, state, catalog, shared, io, state.buffer_frames, true);

    // Load plugin states from dawproject
    for (0..project_track_count) |t| {
        const track = proj.tracks[t];
        if (track.channel) |channel| {
            var fx_slot: usize = 0;
            for (channel.devices) |device| {
                if (device.state == null) continue;
                const state_ref = device.state.?;
                const state_data = loaded.plugin_states.get(state_ref.path) orelse continue;
                if (device.device_role == .instrument or device.device_role == .noteFX) {
                    if (track_plugins[t].handle) |handle| {
                        loadPluginStateFromData(handle.plugin, state_data);
                    }
                } else if (device.device_role == .audioFX and fx_slot < ui_state.max_fx_slots) {
                    if (track_fx[t][fx_slot].handle) |handle| {
                        loadPluginStateFromData(handle.plugin, state_data);
                    }
                    fx_slot += 1;
                }
            }
        }
    }
}

fn findPluginInCatalog(catalog: *const plugins.PluginCatalog, device_id: []const u8) i32 {
    for (catalog.entries.items, 0..) |entry, idx| {
        if (entry.id) |id| {
            if (std.mem.eql(u8, id, device_id)) {
                return @intCast(idx);
            }
        }
    }
    return 0; // Default to "None"
}

fn applyLanes(
    state: *ui_state.State,
    lanes: *const dawproject_types.Lanes,
    tracks: []const dawproject_types.Track,
    instrument_device_ids: *const [track_count]?[]const u8,
    fx_device_ids: *const [track_count][ui_state.max_fx_slots]?[]const u8,
) !void {
    // Find track index for this lane
    var track_idx: ?usize = null;
    if (lanes.track) |track_id| {
        for (tracks, 0..) |track, t| {
            if (std.mem.eql(u8, track.id, track_id)) {
                track_idx = t;
                break;
            }
        }
    }

    // Process clips in this lane
    if (lanes.clips) |clips| {
        if (track_idx) |t| {
            if (t < track_count) {
                for (clips.clips, 0..) |clip, s| {
                    if (s >= scene_count) break;

                    // Set clip slot state
                    state.session.clips[t][s] = .{
                        .state = .stopped,
                        .length_beats = @floatCast(clip.duration),
                    };

                    // Add notes
                    var piano = &state.piano_clips[t][s];
                    piano.length_beats = @floatCast(clip.duration);
                    piano.notes.clearRetainingCapacity();
                    if (clip.notes) |notes| {
                        for (notes.notes) |note| {
                            piano.addNoteWithVelocity(
                                @intCast(note.key),
                                @floatCast(note.time),
                                @floatCast(note.duration),
                                @floatCast(note.vel),
                                @floatCast(note.rel),
                            ) catch continue;
                        }
                    }
                    const track = tracks[t];
                    const channel = track.channel;
                    const vol_id = if (channel) |ch| if (ch.volume) |vol| vol.id else null else null;
                    const pan_id = if (channel) |ch| if (ch.pan) |pan| pan.id else null else null;
                    try applyAutomationToClip(
                        state.allocator,
                        piano,
                        clip.points,
                        instrument_device_ids[t],
                        &fx_device_ids[t],
                        vol_id,
                        pan_id,
                    );
                }
            }
        }
    }

    // Recurse into child lanes
    for (lanes.children) |child| {
        try applyLanes(state, &child, tracks, instrument_device_ids, fx_device_ids);
    }
}

fn applyScenes(
    state: *ui_state.State,
    scenes: []const dawproject_types.Scene,
    tracks: []const dawproject_types.Track,
    master_track: ?dawproject_types.Track,
    instrument_device_ids: *const [track_count]?[]const u8,
    fx_device_ids: *const [track_count][ui_state.max_fx_slots]?[]const u8,
) !void {
    const project_scene_count = @min(scenes.len, scene_count);
    for (0..project_scene_count) |s| {
        const scene = scenes[s];
        for (scene.clip_slots) |slot| {
            var track_idx: ?usize = null;
            for (tracks, 0..) |track, t| {
                if (std.mem.eql(u8, track.id, slot.track)) {
                    track_idx = t;
                    break;
                }
            }
            if (track_idx == null and master_track != null) {
                if (std.mem.eql(u8, master_track.?.id, slot.track)) {
                    continue;
                }
            }
            if (track_idx) |t| {
                if (t >= track_count) continue;
                if (slot.clip) |clip| {
                    state.session.clips[t][s] = .{
                        .state = .stopped,
                        .length_beats = @floatCast(clip.duration),
                    };

                    var piano = &state.piano_clips[t][s];
                    piano.length_beats = @floatCast(clip.duration);
                    piano.notes.clearRetainingCapacity();
                    if (clip.notes) |notes| {
                        for (notes.notes) |note| {
                            piano.addNoteWithVelocity(
                                @intCast(note.key),
                                @floatCast(note.time),
                                @floatCast(note.duration),
                                @floatCast(note.vel),
                                @floatCast(note.rel),
                            ) catch continue;
                        }
                    }
                    const track = tracks[t];
                    const channel = track.channel;
                    const vol_id = if (channel) |ch| if (ch.volume) |vol| vol.id else null else null;
                    const pan_id = if (channel) |ch| if (ch.pan) |pan| pan.id else null else null;
                    try applyAutomationToClip(
                        state.allocator,
                        piano,
                        clip.points,
                        instrument_device_ids[t],
                        &fx_device_ids[t],
                        vol_id,
                        pan_id,
                    );
                }
            }
        }
    }
}

fn applyAutomationToClip(
    allocator: std.mem.Allocator,
    piano: *piano_roll_types.PianoRollClip,
    points_list: []const dawproject_types.Points,
    instrument_device_id: ?[]const u8,
    fx_device_ids: *const [ui_state.max_fx_slots]?[]const u8,
    track_volume_param_id: ?[]const u8,
    track_pan_param_id: ?[]const u8,
) !void {
    piano.automation.clear(allocator);
    for (points_list) |points| {
        var new_lane = piano_roll_types.AutomationLane{
            .target_kind = .parameter,
            .target_id = "",
            .param_id = null,
            .unit = if (points.unit) |unit| try allocator.dupe(u8, unit.toString()) else null,
            .points = .{},
        };
        if (points.target.parameter) |param_id| {
            if (track_volume_param_id != null and std.mem.eql(u8, param_id, track_volume_param_id.?)) {
                new_lane.target_kind = .track;
                new_lane.target_id = try allocator.dupe(u8, "track");
                new_lane.param_id = try allocator.dupe(u8, "volume");
            } else if (track_pan_param_id != null and std.mem.eql(u8, param_id, track_pan_param_id.?)) {
                new_lane.target_kind = .track;
                new_lane.target_id = try allocator.dupe(u8, "track");
                new_lane.param_id = try allocator.dupe(u8, "pan");
            } else if (parseAutomationParamId(param_id, instrument_device_id, fx_device_ids)) |parsed| {
                if (parsed.fx_index) |fx_idx| {
                    new_lane.target_id = try std.fmt.allocPrint(allocator, "fx{d}", .{fx_idx});
                } else {
                    new_lane.target_id = try allocator.dupe(u8, "instrument");
                }
                new_lane.param_id = try allocator.dupe(u8, parsed.param_id);
            } else {
                new_lane.param_id = try allocator.dupe(u8, param_id);
            }
        }
        for (points.points) |point| {
            try new_lane.points.append(allocator, .{
                .time = @floatCast(point.time),
                .value = @floatCast(point.value),
            });
        }
        try piano.automation.lanes.append(allocator, new_lane);
    }
}

const ParsedAutomationParam = struct {
    fx_index: ?usize = null,
    param_id: []const u8,
};

fn parseAutomationParamId(
    param_id: []const u8,
    instrument_device_id: ?[]const u8,
    fx_device_ids: *const [ui_state.max_fx_slots]?[]const u8,
) ?ParsedAutomationParam {
    const marker = std.mem.indexOf(u8, param_id, "_p") orelse return null;
    const device_id = param_id[0..marker];
    const raw_param = param_id[marker + 2 ..];
    if (instrument_device_id) |inst_id| {
        if (std.mem.eql(u8, inst_id, device_id)) {
            return .{ .fx_index = null, .param_id = raw_param };
        }
    }
    for (fx_device_ids, 0..) |fx_id, idx| {
        if (fx_id) |id| {
            if (std.mem.eql(u8, id, device_id)) {
                return .{ .fx_index = idx, .param_id = raw_param };
            }
        }
    }
    return null;
}

pub fn loadPluginStateFromData(plugin: *const clap.Plugin, data: []const u8) void {
    const ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse return;
    const ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(ext_raw));

    const payload = stripClapPresetHeader(data) orelse data;
    var stream = MemoryIStream.init(payload);
    stream.stream.context = &stream;
    _ = ext.load(plugin, &stream.stream);
}

fn stripClapPresetHeader(data: []const u8) ?[]const u8 {
    if (data.len < 8) return null;
    if (!std.mem.eql(u8, data[0..4], "clap")) return null;
    const len: usize = (@as(usize, data[4]) << 24) |
        (@as(usize, data[5]) << 16) |
        (@as(usize, data[6]) << 8) |
        @as(usize, data[7]);
    if (data.len < 8 + len) return null;
    return data[(8 + len)..];
}

const MemoryOStream = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    stream: clap.OStream,

    pub fn init(allocator: std.mem.Allocator) MemoryOStream {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .stream = .{
                .context = undefined,
                .write = write,
            },
        };
    }

    fn write(stream: *const clap.OStream, buffer: *const anyopaque, size: u64) callconv(.c) clap.OStream.Result {
        const self: *MemoryOStream = @ptrCast(@alignCast(stream.context));
        const bytes = @as([*]const u8, @ptrCast(buffer))[0..@intCast(size)];
        self.buffer.appendSlice(self.allocator, bytes) catch return .write_error;
        return @enumFromInt(@as(i64, @intCast(bytes.len)));
    }
};

const MemoryIStream = struct {
    data: []const u8,
    offset: usize,
    stream: clap.IStream,

    pub fn init(data: []const u8) MemoryIStream {
        return .{
            .data = data,
            .offset = 0,
            .stream = .{
                .context = undefined,
                .read = read,
            },
        };
    }

    fn read(stream: *const clap.IStream, buffer: *anyopaque, size: u64) callconv(.c) clap.IStream.Result {
        const self: *MemoryIStream = @ptrCast(@alignCast(stream.context));
        if (self.offset >= self.data.len) {
            return .end_of_file;
        }

        const remaining = self.data.len - self.offset;
        const to_read = @min(remaining, @as(usize, @intCast(size)));
        const dest = @as([*]u8, @ptrCast(buffer))[0..to_read];
        @memcpy(dest, self.data[self.offset..][0..to_read]);
        self.offset += to_read;
        return @enumFromInt(@as(i64, @intCast(to_read)));
    }
};
