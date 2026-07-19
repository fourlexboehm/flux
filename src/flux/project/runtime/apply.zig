const std = @import("std");
const clap = @import("clap-bindings");

const audio_engine = @import("../../audio/audio_engine.zig");
const plugin_runtime = @import("../../plugin/plugin_runtime.zig");
const plugins = @import("../../plugin/plugins.zig");
const session_constants = @import("../../session/constants.zig");
const session_ops = @import("../../session/ops.zig");
const session_view = @import("../../session/types.zig");
const ui_state = @import("../../ui/state.zig");

const types = @import("../format/types.zig");
const project_io = @import("../io.zig");
const apply_clips = @import("apply_clips.zig");
const apply_arrangement = @import("apply_arrangement.zig");
const plugin_state = @import("plugin_state.zig");

const track_count = session_constants.max_tracks;
const scene_count = session_constants.max_scenes;
const master_track_index = session_view.master_track_index;
const TrackPlugin = plugin_runtime.TrackPlugin;

pub fn applyDawprojectToState(
    allocator: std.mem.Allocator,
    loaded: *project_io.LoadedProject,
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
        if (transport.time_signature) |signature| {
            if (signature.numerator > 0 and signature.numerator <= 32 and
                (signature.denominator == 2 or signature.denominator == 4 or signature.denominator == 8 or signature.denominator == 16))
            {
                state.time_signature_numerator = @intCast(signature.numerator);
                state.time_signature_denominator = @intCast(signature.denominator);
            }
        }
    }

    // Reset session
    session_ops.deinit(&state.session);
    state.session = session_ops.init(state.allocator);
    state.clearMissingPlugins();

    // Apply tracks
    const project_track_count = @min(proj.tracks.len, track_count);
    state.session.track_count = project_track_count;
    var instrument_device_ids: [track_count]?[]const u8 = @splat(null);
    var fx_device_ids: [track_count][ui_state.max_fx_slots]?[]const u8 = @splat(@splat(null));

    for (0..project_track_count) |t| {
        state.track_plugins[t].choice_index = 0;
        state.track_plugins[t].gui_open = false;
        state.track_plugins[t].last_valid_choice = 0;
        state.track_fx_slot_count[t] = 1;
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
            if (channel.pan) |pan| {
                state.session.tracks[t].pan = @floatCast(pan.value * 2.0 - 1.0);
            }
            state.session.tracks[t].solo = channel.solo;

            // Handle CLAP plugins
            if (channel.devices.len > 0) {
                var fx_slot: usize = 0;
                for (channel.devices) |device| {
                    const choice = findPluginInCatalog(catalog, device.device_id);
                    if (device.device_role == .instrument or device.device_role == .noteFX) {
                        const resolved_choice = choice orelse 0;
                        state.track_plugins[t].choice_index = resolved_choice;
                        state.track_plugins[t].last_valid_choice = resolved_choice;
                        if (choice == null) {
                            state.missing_track_plugins[t] = try copyMissingPlugin(allocator, loaded, &device);
                        }
                        instrument_device_ids[t] = device.id;
                    } else if ((device.device_role == .audioFX or device.device_role == .analyzer) and fx_slot < ui_state.max_fx_slots) {
                        const resolved_choice = choice orelse 0;
                        state.track_fx[t][fx_slot].choice_index = resolved_choice;
                        state.track_fx[t][fx_slot].last_valid_choice = resolved_choice;
                        if (choice == null) {
                            state.missing_track_fx[t][fx_slot] = try copyMissingPlugin(allocator, loaded, &device);
                        }
                        fx_device_ids[t][fx_slot] = device.id;
                        fx_slot += 1;
                    }
                }
                state.track_fx_slot_count[t] = if (fx_slot < ui_state.max_fx_slots)
                    fx_slot + 1
                else
                    ui_state.max_fx_slots;
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
            if (channel.pan) |pan| {
                state.session.tracks[master_track_index].pan = @floatCast(pan.value * 2.0 - 1.0);
            }
            if (channel.devices.len > 0) {
                var fx_slot: usize = 0;
                for (channel.devices) |device| {
                    const choice = findPluginInCatalog(catalog, device.device_id);
                    if ((device.device_role == .audioFX or device.device_role == .analyzer) and fx_slot < ui_state.max_fx_slots) {
                        const resolved_choice = choice orelse 0;
                        state.track_fx[master_track_index][fx_slot].choice_index = resolved_choice;
                        state.track_fx[master_track_index][fx_slot].last_valid_choice = resolved_choice;
                        if (choice == null) {
                            state.missing_track_fx[master_track_index][fx_slot] = try copyMissingPlugin(allocator, loaded, &device);
                        }
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

    // Clear piano + audio clips + sample store (fresh load)
    state.undo_history.clear();
    for (&state.piano_clips) |*track_clips| {
        for (track_clips) |*clip| {
            clip.clear();
        }
    }
    state.clearAllAudioClips();
    state.sample_store.clear();

    // Prefer Scenes only when they contain real clips. Bitwig often emits empty
    // ClipSlots under Scenes while audio lives only in Arrangement.
    if (scenesHaveClipContent(proj.scenes)) {
        try apply_clips.applyScenes(state, loaded, io, proj.scenes, proj.tracks, proj.master_track, &instrument_device_ids, &fx_device_ids);
    } else if (proj.arrangement) |arr| {
        if (arr.lanes) |root_lanes| {
            try apply_clips.applyLanes(state, loaded, io, &root_lanes, proj.tracks, &instrument_device_ids, &fx_device_ids);
        }
    }

    // Always restore Flux ArrangementView from Arrangement XML (session is independent).
    if (proj.arrangement) |arr| {
        try apply_arrangement.applyArrangement(state, loaded, io, &arr, proj.tracks);
    } else {
        state.arrangement.clearTracks();
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
                if (device.device_role == .instrument or device.device_role == .noteFX) {
                    if (device.state) |state_ref| {
                        if (loaded.plugin_states.get(state_ref.path)) |state_data| {
                            if (track_plugins[t].getPlugin()) |plugin| {
                                plugin_state.loadPluginStateFromData(plugin, state_data);
                            }
                        }
                    }
                } else if ((device.device_role == .audioFX or device.device_role == .analyzer) and fx_slot < ui_state.max_fx_slots) {
                    if (device.state) |state_ref| {
                        if (loaded.plugin_states.get(state_ref.path)) |state_data| {
                            if (track_fx[t][fx_slot].getPlugin()) |plugin| {
                                plugin_state.loadPluginStateFromData(plugin, state_data);
                            }
                        }
                    } else if (track_fx[t][fx_slot].getPlugin()) |plugin| {
                        // DAWproject builtins: load schema children + Parameters
                        if (std.mem.startsWith(u8, device.device_id, "com.flux.builtin.") or device.xml_kind != .clap) {
                            applyBuiltinDevice(plugin, &device);
                        } else if (device.parameters.len > 0) {
                            applyDeviceParams(plugin, device.parameters);
                        }
                    }
                    fx_slot += 1;
                }
            }
        }
    }
    if (proj.master_track) |master_track| {
        if (master_track.channel) |channel| {
            var fx_slot: usize = 0;
            for (channel.devices) |device| {
                if (device.device_role != .audioFX and device.device_role != .analyzer) continue;
                if (fx_slot >= ui_state.max_fx_slots) break;
                if (device.state) |state_ref| {
                    if (loaded.plugin_states.get(state_ref.path)) |state_data| {
                        if (track_fx[master_track_index][fx_slot].getPlugin()) |plugin| {
                            plugin_state.loadPluginStateFromData(plugin, state_data);
                        }
                    }
                } else if (track_fx[master_track_index][fx_slot].getPlugin()) |plugin| {
                    if (std.mem.startsWith(u8, device.device_id, "com.flux.builtin.") or device.xml_kind != .clap) {
                        applyBuiltinDevice(plugin, &device);
                    } else if (device.parameters.len > 0) {
                        applyDeviceParams(plugin, device.parameters);
                    }
                }
                fx_slot += 1;
            }
        }
    }
}

fn findPluginInCatalog(catalog: *const plugins.PluginCatalog, device_id: []const u8) ?i32 {
    for (catalog.entries.items, 0..) |entry, idx| {
        if (entry.id) |id| {
            if (std.mem.eql(u8, id, device_id)) {
                return @intCast(idx);
            }
        }
    }
    return null;
}

/// Apply DAWproject RealParameter list onto a CLAP plugin via params extension.
fn applyDeviceParams(plugin: *const clap.Plugin, parameters: []const types.RealParameter) void {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse return;
    const ext: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    // Prefer parameterID when present (CLAP id bit pattern)
    for (parameters) |param| {
        if (param.parameter_id) |pid| {
            const clap_id: clap.Id = @enumFromInt(@as(u32, @bitCast(pid)));
            // Use flush with a synthetic event is heavy; set via host is not available.
            // Builtins accept values through params flush — push via a one-shot list.
            _ = clap_id;
            _ = ext;
        }
    }
    // Direct path for Flux builtins
    applyBuiltinParamsFromDawproject(plugin, parameters);
}

fn applyBuiltinParamsFromDawproject(plugin: *const clap.Plugin, parameters: []const types.RealParameter) void {
    const id = std.mem.span(plugin.descriptor.id);
    if (!std.mem.startsWith(u8, id, "com.flux.builtin.")) return;
    const flux_builtins = @import("../../builtins/root.zig");
    const bp = flux_builtins.Plugin.fromClapPlugin(plugin);
    for (parameters) |param| {
        if (param.parameter_id) |pid| {
            bp.params.set(@bitCast(pid), param.value);
            continue;
        }
        // Match DAWproject schema names (Attack, Threshold, InputGain, …)
        for (0..bp.params.count) |i| {
            const def = bp.params.defs[i];
            if (std.mem.eql(u8, def.schema_name, param.name) or std.mem.eql(u8, def.name, param.name)) {
                bp.params.setByIndex(@intCast(i), param.value);
                break;
            }
        }
    }
    bp.applyParamsToDsp();
}

/// Apply typed schema fields that may not all be in parameters[] (Attack/Threshold/…).
pub fn applyBuiltinDevice(plugin: *const clap.Plugin, device: *const types.ClapPlugin) void {
    const id = std.mem.span(plugin.descriptor.id);
    if (!std.mem.startsWith(u8, id, "com.flux.builtin.")) return;
    const flux_builtins = @import("../../builtins/root.zig");
    const param_table = flux_builtins.param_table;
    const bp = flux_builtins.Plugin.fromClapPlugin(plugin);
    const p = &bp.params;
    const kind = flux_builtins.Kind.fromId(id) orelse return;

    // Device-level schema children → CLAP ids from param_table
    for (param_table.params) |row| {
        if (!param_table.kindHas(row, kind)) continue;
        if (schemaValueFromDevice(device, row.schema, row.is_bool)) |v| {
            p.set(row.id, v);
        }
    }

    // EQ bands: order attribute maps to band index; field offsets from param_table
    for (device.eq_bands) |band| {
        const bi: usize = if (band.order) |o| @intCast(@max(0, o)) else 0;
        if (bi >= bp.eq.band_count) continue;
        const base = param_table.eqBandBase(bi);
        if (eq_dsp.BandType.fromDawproject(band.band_type)) |bt| {
            p.set(base + 0, @floatFromInt(@intFromEnum(bt)));
        }
        p.set(base + 1, band.freq.value);
        if (band.gain) |g| p.set(base + 2, g.value);
        if (band.q) |q| p.set(base + 3, q.value);
        if (band.enabled) |e| p.set(base + 4, if (e.value) 1 else 0);
    }

    // Also apply flat parameter list (parameterID / names)
    for (device.parameters) |param| {
        if (param.parameter_id) |pid| {
            p.set(@bitCast(pid), param.value);
        } else if (param_table.findBySchema(kind, param.name)) |row| {
            p.set(row.id, param.value);
        } else {
            for (0..p.count) |i| {
                if (std.mem.eql(u8, p.defs[i].schema_name, param.name) or std.mem.eql(u8, p.defs[i].name, param.name)) {
                    p.setByIndex(@intCast(i), param.value);
                    break;
                }
            }
        }
    }
    bp.applyParamsToDsp();
}

fn schemaValueFromDevice(device: *const types.ClapPlugin, schema: []const u8, is_bool: bool) ?f64 {
    if (is_bool) {
        if (std.mem.eql(u8, schema, "AutoMakeup")) {
            if (device.auto_makeup) |v| return if (v.value) 1 else 0;
        }
        return null;
    }
    const real: ?types.RealParameter =
        if (std.mem.eql(u8, schema, "Threshold")) device.threshold
        else if (std.mem.eql(u8, schema, "Ratio")) device.ratio
        else if (std.mem.eql(u8, schema, "Attack")) device.attack
        else if (std.mem.eql(u8, schema, "Release")) device.release
        else if (std.mem.eql(u8, schema, "InputGain")) device.input_gain
        else if (std.mem.eql(u8, schema, "OutputGain")) device.output_gain
        else if (std.mem.eql(u8, schema, "Range")) device.range
        else null;
    if (real) |v| return v.value;
    return null;
}

const eq_dsp = @import("../../builtins/dsp/equalizer.zig");

fn copyMissingPlugin(
    allocator: std.mem.Allocator,
    loaded: *const project_io.LoadedProject,
    device: *const types.ClapPlugin,
) !ui_state.MissingPlugin {
    var params = std.ArrayList(ui_state.MissingPluginParameter).empty;
    errdefer {
        for (params.items) |param| allocator.free(param.name);
        params.deinit(allocator);
    }
    for (device.parameters) |param| {
        const marker = std.mem.indexOf(u8, param.id, "_p") orelse continue;
        const raw_id = param.id[marker + 2 ..];
        const id = std.fmt.parseInt(u32, raw_id, 10) catch continue;
        try params.append(allocator, .{
            .id = id,
            .name = try allocator.dupe(u8, param.name),
            .value = param.value,
            .min = param.min orelse param.value,
            .max = param.max orelse param.value,
        });
    }

    const device_id = try allocator.dupe(u8, device.device_id);
    errdefer allocator.free(device_id);
    const device_name = try allocator.dupe(u8, device.device_name);
    errdefer allocator.free(device_name);
    const state_data = if (device.state) |state_ref|
        if (loaded.plugin_states.get(state_ref.path)) |data|
            try allocator.dupe(u8, data)
        else
            null
    else
        null;
    errdefer if (state_data) |data| allocator.free(data);

    return .{
        .device_id = device_id,
        .device_name = device_name,
        .role = switch (device.device_role) {
            .instrument => .instrument,
            .noteFX => .note_fx,
            .audioFX => .audio_fx,
            .analyzer => .analyzer,
        },
        .loaded = device.loaded,
        .parameters = try params.toOwnedSlice(allocator),
        .state_data = state_data,
    };
}

fn scenesHaveClipContent(scenes: []const types.Scene) bool {
    for (scenes) |scene| {
        for (scene.clip_slots) |slot| {
            if (slot.clip != null) return true;
        }
    }
    return false;
}
