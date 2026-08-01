//! DAWproject file requests for the DVUI host.

const std = @import("std");
const dvui = @import("dvui");
const project_io = @import("../project/io.zig");
const io_types = @import("../project/io_types.zig");
const plugin_state = @import("../project/runtime/plugin_state.zig");
const engine_ui = @import("../audio/engine_ui.zig");
const host_mod = @import("host.zig");
const state_mod = @import("state.zig");
const plugin_host = @import("plugin_host.zig");
const project_view = @import("../document/project_view.zig");
const apply_clips = @import("../project/runtime/apply_clips.zig");
const apply_arrangement = @import("../project/runtime/apply_arrangement.zig");
const audio_runtime = @import("audio_runtime.zig");
const session_constants = @import("../session/constants.zig");
const session_types = @import("../session/types.zig");
const project_types = @import("../project/format/types.zig");
const document_model = @import("../document/model.zig");
const document_commands = @import("../document/commands.zig");

const io: std.Io = std.Io.Threaded.global_single_threaded.io();

pub fn handleRequests(state: *state_mod.State) void {
    if (!host_mod.ready() or !plugin_host.ready()) return;

    if (state.save_project_request) {
        state.save_project_request = false;
        if (state.project_path_len == 0) {
            state.save_project_as_request = true;
        } else {
            saveTo(state, state.project_path[0..state.project_path_len]) catch |err|
                std.log.err("Failed to save project: {}", .{err});
        }
    }

    if (state.save_project_as_request) {
        state.save_project_as_request = false;
        saveAs(state) catch |err| std.log.err("Failed to save project as: {}", .{err});
    }

    if (state.load_project_request) {
        state.load_project_request = false;
        loadFromDialog(state) catch |err| std.log.err("Failed to load project: {}", .{err});
    }
}

fn loadFromDialog(state: *state_mod.State) !void {
    const allocator = host_mod.g.allocator;
    const path = try dvui.dialogNativeFileOpen(allocator, .{
        .title = "Open DAWproject",
        .filters = &.{"*.dawproject"},
        .filter_description = "DAWproject",
    }) orelse return;
    defer allocator.free(path);

    var loaded = try project_io.load(allocator, io, path);
    defer loaded.deinit();
    try applyLoaded(state, &loaded);
    setProjectPath(state, path);
    std.log.info("Loaded project from: {s}", .{path});
}

fn applyLoaded(state: *state_mod.State, loaded: *project_io.LoadedProject) !void {
    const allocator = host_mod.g.allocator;
    const ph = &plugin_host.g;
    const proj = &loaded.project;

    state.playing = false;
    state.playhead_beat = 0;
    if (proj.transport) |transport| {
        if (transport.tempo) |tempo| state.bpm = @floatCast(tempo.value);
        if (transport.time_signature) |signature| {
            if (signature.numerator > 0 and signature.numerator <= 32 and
                (signature.denominator == 2 or signature.denominator == 4 or signature.denominator == 8 or signature.denominator == 16))
            {
                state.time_signature_numerator = @intCast(signature.numerator);
                state.time_signature_denominator = @intCast(signature.denominator);
            }
        }
    }

    const engine = if (audio_runtime.ready() and audio_runtime.g.engine != null)
        &audio_runtime.g.engine.?
    else
        null;
    ph.unloadAll(engine);
    ph.clearPendingProjectStates();
    host_mod.g.deinit();
    document_model.g.reset();
    host_mod.g = host_mod.Host.init(&document_model.g);
    host_mod.g.wireInternalRefs();

    ph.instrument_choice = @splat(.{});
    ph.fx_choice = @splat(@splat(.{}));
    ph.fx_counts = @splat(0);

    // Bulk document-load transaction: assignments below intentionally bypass
    // interactive commands and publish one revision after all appliers finish.
    const project_track_count = @min(proj.tracks.len, session_constants.max_tracks);
    document_model.g.session.track_count = project_track_count;
    var instrument_device_ids: [session_constants.max_tracks]?[]const u8 = @splat(null);
    var fx_device_ids: [session_constants.max_tracks][engine_ui.max_fx_slots]?[]const u8 = @splat(@splat(null));

    for (proj.tracks[0..project_track_count], 0..) |track, t| {
        document_model.g.session.tracks[t].setName(track.name);
        if (track.channel) |channel| {
            if (channel.volume) |volume| document_model.g.session.tracks[t].volume = @floatCast(volume.value);
            if (channel.pan) |pan| document_model.g.session.tracks[t].pan = @floatCast(pan.value * 2.0 - 1.0);
            if (channel.mute) |mute| document_model.g.session.tracks[t].mute = mute.value;
            document_model.g.session.tracks[t].solo = channel.solo;

            var fx_count: usize = 0;
            for (channel.devices) |device| {
                if (device.device_role == .instrument or device.device_role == .noteFX) {
                    const choice = findPluginChoice(ph, device.device_id);
                    ph.instrument_choice[t] = .{
                        .choice_index = choice orelse 0,
                        .enabled = if (device.enabled) |enabled| enabled.value else true,
                    };
                    if (choice != null) try queueDeviceState(ph, loaded, t, null, &device);
                    instrument_device_ids[t] = device.id;
                } else if ((device.device_role == .audioFX or device.device_role == .analyzer) and fx_count < engine_ui.max_fx_slots) {
                    const choice = findPluginChoice(ph, device.device_id);
                    ph.fx_choice[t][fx_count] = .{
                        .choice_index = choice orelse 0,
                        .enabled = if (device.enabled) |enabled| enabled.value else true,
                    };
                    if (choice != null) try queueDeviceState(ph, loaded, t, fx_count, &device);
                    fx_device_ids[t][fx_count] = device.id;
                    fx_count += 1;
                }
            }
            ph.fx_counts[t] = fx_count;
        }
    }

    if (proj.master_track) |master| if (master.channel) |channel| {
        const master_index = session_types.master_track_index;
        if (channel.volume) |volume| document_model.g.session.tracks[master_index].volume = @floatCast(volume.value);
        if (channel.pan) |pan| document_model.g.session.tracks[master_index].pan = @floatCast(pan.value * 2.0 - 1.0);
        if (channel.mute) |mute| document_model.g.session.tracks[master_index].mute = mute.value;
        document_model.g.session.tracks[master_index].solo = channel.solo;

        var fx_count: usize = 0;
        for (channel.devices) |device| {
            if (device.device_role != .audioFX and device.device_role != .analyzer) continue;
            if (fx_count >= engine_ui.max_fx_slots) break;
            const choice = findPluginChoice(ph, device.device_id);
            ph.fx_choice[master_index][fx_count] = .{
                .choice_index = choice orelse 0,
                .enabled = if (device.enabled) |enabled| enabled.value else true,
            };
            if (choice != null) try queueDeviceState(ph, loaded, master_index, fx_count, &device);
            fx_count += 1;
        }
        ph.fx_counts[master_index] = fx_count;
    };

    const scene_count = @min(proj.scenes.len, session_constants.max_scenes);
    document_model.g.session.scene_count = scene_count;
    for (proj.scenes[0..scene_count], 0..) |scene, s| document_model.g.session.scenes[s].setName(scene.name);

    var view = project_view.LoadView.init(
        document_model.g.view(),
        allocator,
        state.bpm,
        state.time_signature_numerator,
    );
    defer view.deinit();
    if (scenesHaveClipContent(proj.scenes)) {
        try apply_clips.applyScenes(&view, loaded, io, proj.scenes, proj.tracks, proj.master_track, &instrument_device_ids, &fx_device_ids);
    } else if (proj.arrangement) |arrangement| {
        if (arrangement.lanes) |lanes| try apply_clips.applyLanes(&view, loaded, io, &lanes, proj.tracks, &instrument_device_ids, &fx_device_ids);
    }
    if (proj.arrangement) |arrangement| {
        try apply_arrangement.applyArrangement(&view, loaded, io, &arrangement, proj.tracks);
    } else {
        document_commands.syncArrangementTracks(&document_model.g);
    }

    ph.projectToDocumentHost(&host_mod.g);
    document_model.g.markChanged();
    host_mod.g.projectChrome(state);
}

fn findPluginChoice(ph: *const plugin_host.PluginHost, device_id: []const u8) ?i32 {
    for (ph.catalog.entries.items, 0..) |entry, index| {
        const id = entry.id orelse continue;
        if (std.mem.eql(u8, id, device_id)) return @intCast(index);
    }
    return null;
}

fn queueDeviceState(
    ph: *plugin_host.PluginHost,
    loaded: *const project_io.LoadedProject,
    track: usize,
    fx_index: ?usize,
    device: *const project_types.ClapPlugin,
) !void {
    const state_ref = device.state orelse return;
    const data = loaded.plugin_states.get(state_ref.path) orelse return;
    try ph.queueProjectState(track, fx_index, data);
}

fn scenesHaveClipContent(scenes: []const @import("../project/format/types.zig").Scene) bool {
    for (scenes) |scene| for (scene.clip_slots) |slot| if (slot.clip != null) return true;
    return false;
}

fn saveAs(state: *state_mod.State) !void {
    const allocator = host_mod.g.allocator;
    const default_name = if (state.project_path_len > 0)
        std.fs.path.basename(state.project_path[0..state.project_path_len])
    else
        "project.dawproject";
    const path = try dvui.dialogNativeFileSave(allocator, .{
        .title = "Save DAWproject",
        .path = default_name,
        .filters = &.{"*.dawproject"},
        .filter_description = "DAWproject",
    }) orelse return;
    defer allocator.free(path);
    try saveTo(state, path);
    setProjectPath(state, path);
}

fn saveTo(state: *state_mod.State, path: []const u8) !void {
    const allocator = host_mod.g.allocator;
    const ph = &plugin_host.g;
    if (!ph.catalog_ready) return error.PluginCatalogUnavailable;

    var plugin_states: std.ArrayList(io_types.PluginStateFile) = .empty;
    defer {
        for (plugin_states.items) |item| {
            allocator.free(item.path);
            allocator.free(item.data);
        }
        plugin_states.deinit(allocator);
    }

    var instruments: [state_mod.max_tracks]io_types.TrackPluginInfo = @splat(.{});
    var effects: [state_mod.max_tracks][engine_ui.max_fx_slots]io_types.TrackPluginInfo = @splat(@splat(.{}));
    for (0..state_mod.max_tracks) |track| {
        instruments[track].enabled = ph.instrument_choice[track].enabled;
        if (ph.instruments[track].getPlugin()) |plugin| {
            instruments[track].plugin_id = std.mem.span(plugin.descriptor.id);
            if (plugin_state.capturePluginStateForDawproject(allocator, plugin, track, null)) |captured| {
                instruments[track].state_path = captured.path;
                try plugin_states.append(allocator, captured);
            }
        }
        for (0..engine_ui.max_fx_slots) |fx| {
            effects[track][fx].enabled = ph.fx_choice[track][fx].enabled;
            if (ph.fx[track][fx].getPlugin()) |plugin| {
                effects[track][fx].plugin_id = std.mem.span(plugin.descriptor.id);
                if (plugin_state.capturePluginStateForDawproject(allocator, plugin, track, fx)) |captured| {
                    effects[track][fx].state_path = captured.path;
                    try plugin_states.append(allocator, captured);
                }
            }
        }
    }

    var project_instruments: [state_mod.max_tracks]project_view.DeviceChoice = @splat(.{});
    var project_effects: [state_mod.max_tracks][engine_ui.max_fx_slots]project_view.DeviceChoice = @splat(@splat(.{}));
    for (0..state_mod.max_tracks) |track| {
        project_instruments[track] = .{
            .choice_index = ph.instrument_choice[track].choice_index,
            .enabled = ph.instrument_choice[track].enabled,
        };
        for (0..engine_ui.max_fx_slots) |fx| {
            project_effects[track][fx] = .{
                .choice_index = ph.fx_choice[track][fx].choice_index,
                .enabled = ph.fx_choice[track][fx].enabled,
            };
        }
    }
    var view = project_view.View.init(
        document_model.g.view(),
        state.bpm,
        state.time_signature_numerator,
        state.time_signature_denominator,
        if (state.project_path_len > 0) state.project_path[0..state.project_path_len] else null,
        project_instruments,
        project_effects,
    );
    try project_io.save(allocator, io, path, &view, &ph.catalog, plugin_states.items, &instruments, &effects);
    std.log.info("Saved project to: {s}", .{path});
}

fn setProjectPath(state: *state_mod.State, path: []const u8) void {
    const len = @min(path.len, state.project_path.len);
    @memcpy(state.project_path[0..len], path[0..len]);
    state.project_path_len = len;
}
