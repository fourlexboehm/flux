const std = @import("std");
const ui_state = @import("../ui/state.zig");
const session_constants = @import("../session/constants.zig");
const session_view = @import("../session/types.zig");
const arr_timeline = @import("../arrangement/timeline.zig");
const arr_clip_mod = @import("../arrangement/clip.zig");
const track_count = session_constants.max_tracks;
const master_track_index = session_view.master_track_index;
const plugins = @import("../plugin/plugins.zig");
const types = @import("format/types.zig");
const io_types = @import("io_types.zig");
const parse = @import("format/parse.zig");
const param_table = @import("flux_param_table");
const BuiltinKind = param_table.Kind;

const RealParameter = types.RealParameter;
const Note = types.Note;
const AutomationPoint = types.AutomationPoint;
const Points = types.Points;
const WarpPoint = types.WarpPoint;
const Clip = types.Clip;
const ClipSlot = types.ClipSlot;
const Scene = types.Scene;
const Track = types.Track;
const Lanes = types.Lanes;
const Channel = types.Channel;
const ClapPlugin = types.ClapPlugin;
const Project = types.Project;
const ContentType = types.ContentType;

const TrackPluginInfo = io_types.TrackPluginInfo;
pub const IdGenerator = struct {
    counter: usize = 0,
    allocator: std.mem.Allocator,

    pub fn next(self: *IdGenerator) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "id{d}", .{self.counter});
        self.counter += 1;
        return id;
    }
};

/// How audio File refs are written into project.xml.
pub const MediaMode = enum {
    /// Thin save: relative paths with external="true"
    external,
    /// Pack: in-zip paths with external="false"
    embedded,
};

/// Convert Flux project state to DAWproject format
pub fn fromFluxProject(
    allocator: std.mem.Allocator,
    state: *const ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugin_info: []const TrackPluginInfo,
    track_fx_plugin_info: []const [ui_state.max_fx_slots]TrackPluginInfo,
    media_mode: MediaMode,
) !Project {
    var ids = IdGenerator{ .allocator = allocator };

    // Build tracks
    var tracks_list = std.ArrayList(Track).empty;
    var track_lanes = std.ArrayList(Lanes).empty;
    var track_ids = std.ArrayList([]const u8).empty; // Store track IDs for ClipSlot references
    var instrument_device_ids: [track_count]?[]const u8 = @splat(null);
    var track_volume_param_ids: [track_count]?[]const u8 = @splat(null);
    var track_pan_param_ids: [track_count]?[]const u8 = @splat(null);
    var fx_device_ids: [track_count][ui_state.max_fx_slots]?[]const u8 = @splat(@splat(null));

    const master_channel_id = try ids.next();

    for (0..state.session.track_count) |t| {
        const track_data = state.session.tracks[t];
        const track_id = try ids.next();
        try track_ids.append(allocator, track_id);
        const channel_id = try ids.next();

        // Build devices if present
        var devices = std.ArrayList(ClapPlugin).empty;
        const choice_index = state.track_plugins[t].choice_index;
        var has_instrument = false;
        if (catalog.entryForIndex(choice_index)) |entry| {
            if (entry.kind == .clap or entry.kind == .builtin) {
                const info = if (t < track_plugin_info.len) track_plugin_info[t] else TrackPluginInfo{};
                const device = try buildClapPlugin(allocator, entry, info, .instrument, &ids);
                instrument_device_ids[t] = device.id;
                try devices.append(allocator, device);
                has_instrument = true;
            }
        }
        if (!has_instrument) if (state.missing_track_plugins[t]) |missing| {
            const info = if (t < track_plugin_info.len) track_plugin_info[t] else TrackPluginInfo{};
            const device = try buildMissingPlugin(allocator, &missing, info, &ids);
            instrument_device_ids[t] = device.id;
            try devices.append(allocator, device);
        };
        for (0..ui_state.max_fx_slots) |fx_index| {
            const fx_choice = state.track_fx[t][fx_index].choice_index;
            var has_fx = false;
            if (catalog.entryForIndex(fx_choice)) |entry| {
                if (entry.kind == .clap or (entry.kind == .builtin and entry.is_audio_effect)) {
                    const info = if (t < track_fx_plugin_info.len) track_fx_plugin_info[t][fx_index] else TrackPluginInfo{};
                    const device = try buildClapPlugin(allocator, entry, info, .audioFX, &ids);
                    fx_device_ids[t][fx_index] = device.id;
                    try devices.append(allocator, device);
                    has_fx = true;
                }
            }
            if (!has_fx) if (state.missing_track_fx[t][fx_index]) |missing| {
                const info = if (t < track_fx_plugin_info.len) track_fx_plugin_info[t][fx_index] else TrackPluginInfo{};
                const device = try buildMissingPlugin(allocator, &missing, info, &ids);
                fx_device_ids[t][fx_index] = device.id;
                try devices.append(allocator, device);
            };
        }

        const vol_id = try ids.next();
        const mute_id = try ids.next();
        const pan_id = try ids.next();
        track_volume_param_ids[t] = vol_id;
        track_pan_param_ids[t] = pan_id;

        const content_attr = try trackContentTypesAttr(allocator, state, t);
        const content_type: ContentType = if (std.mem.eql(u8, content_attr, "audio"))
            .audio
        else
            .notes;

        const track_color = arrangementTrackColor(state, t);

        try tracks_list.append(allocator, .{
            .id = track_id,
            .name = try allocator.dupe(u8, track_data.getName()),
            .color = if (track_color) |c| try colorToHex(allocator, c) else null,
            .content_type = content_type,
            .content_types_attr = content_attr,
            .channel = .{
                .id = channel_id,
                .role = .regular,
                .solo = track_data.solo,
                .destination = master_channel_id,
                .volume = .{
                    .id = vol_id,
                    .name = "Volume",
                    .value = track_data.volume,
                    .min = 0.0,
                    .max = 2.0,
                    .unit = .linear,
                },
                .mute = .{
                    .id = mute_id,
                    .name = "Mute",
                    .value = track_data.mute,
                },
                .pan = .{
                    .id = pan_id,
                    .name = "Pan",
                    .value = (@as(f64, track_data.pan) + 1.0) * 0.5,
                    .min = 0.0,
                    .max = 1.0,
                    .unit = .normalized,
                },
                .devices = try devices.toOwnedSlice(allocator),
            },
        });

        // Arrangement lane: clips from ArrangementView for this session track
        const clips_id = try ids.next();
        const lane_id = try ids.next();
        const arr_clips = try buildArrangementClipsForTrack(allocator, state, t, &ids, media_mode);
        try track_lanes.append(allocator, .{
            .id = lane_id,
            .track = track_id,
            .clips = .{
                .id = clips_id,
                .clips = arr_clips,
            },
        });
    }

    // Master track
    var master_devices = std.ArrayList(ClapPlugin).empty;
    for (0..ui_state.max_fx_slots) |fx_index| {
        const fx_choice = state.track_fx[master_track_index][fx_index].choice_index;
        var has_fx = false;
        if (catalog.entryForIndex(fx_choice)) |entry| {
            if (entry.kind == .clap or (entry.kind == .builtin and entry.is_audio_effect)) {
                const info = if (master_track_index < track_fx_plugin_info.len)
                    track_fx_plugin_info[master_track_index][fx_index]
                else
                    TrackPluginInfo{};
                try master_devices.append(allocator, try buildClapPlugin(allocator, entry, info, .audioFX, &ids));
                has_fx = true;
            }
        }
        if (!has_fx) if (state.missing_track_fx[master_track_index][fx_index]) |missing| {
            const info = if (master_track_index < track_fx_plugin_info.len)
                track_fx_plugin_info[master_track_index][fx_index]
            else
                TrackPluginInfo{};
            try master_devices.append(allocator, try buildMissingPlugin(allocator, &missing, info, &ids));
        };
    }

    const master_track_id = try ids.next();
    const master_vol_id = try ids.next();
    const master_mute_id = try ids.next();
    const master_pan_id = try ids.next();

    const master_track = Track{
        .id = master_track_id,
        .name = "Master",
        .content_type = .audio,
        // Match Bitwig hybrid master labeling
        .content_types_attr = try allocator.dupe(u8, "audio notes"),
        .channel = .{
            .id = master_channel_id,
            .role = .master,
            .volume = .{
                .id = master_vol_id,
                .name = "Volume",
                .value = state.session.tracks[master_track_index].volume,
                .min = 0.0,
                .max = 2.0,
                .unit = .linear,
            },
            .mute = .{
                .id = master_mute_id,
                .name = "Mute",
                .value = state.session.tracks[master_track_index].mute,
            },
            .pan = .{
                .id = master_pan_id,
                .name = "Pan",
                .value = (@as(f64, state.session.tracks[master_track_index].pan) + 1.0) * 0.5,
                .min = 0.0,
                .max = 1.0,
                .unit = .normalized,
            },
            .devices = try master_devices.toOwnedSlice(allocator),
        },
    };

    // Build scenes with ClipSlots
    var scenes = std.ArrayList(Scene).empty;
    for (0..state.session.scene_count) |s| {
        const scene_id = try ids.next();
        const scene_lanes_id = try ids.next();

        // Create ClipSlots for each track
        var clip_slots = std.ArrayList(ClipSlot).empty;

        for (0..state.session.track_count) |t| {
            const slot = state.session.clips[t][s];
            const piano = &state.piano_clips[t][s];
            const audio = &state.audio_clips[t][s];
            const clip_slot_id = try ids.next();

            const has_audio = audio.hasAudio();
            const has_notes = piano.notes.items.len > 0;
            const has_content = slot.state != .empty or has_notes or has_audio;

            if (has_content and has_audio) {
                // Prefer audio when present (one content type per slot)
                const clip = try buildAudioClip(allocator, state, t, s, &ids, media_mode);
                try clip_slots.append(allocator, .{
                    .id = clip_slot_id,
                    .track = track_ids.items[t],
                    .has_stop = true,
                    .clip = clip,
                });
            } else if (has_content) {
                // Convert notes
                var daw_notes = std.ArrayList(Note).empty;
                for (piano.notes.items) |note| {
                    try daw_notes.append(allocator, .{
                        .time = note.start,
                        .duration = note.duration,
                        .key = note.pitch,
                        .vel = note.velocity,
                        .rel = note.release_velocity,
                    });
                }

                const clip_duration = if (slot.state != .empty) slot.length_beats else piano.length_beats;
                const notes_id = try ids.next();
                var points_list = std.ArrayList(Points).empty;
                if (piano.automation.lanes.items.len > 0) {
                    for (piano.automation.lanes.items) |lane| {
                        const points_id = try ids.next();
                        const points = try allocator.alloc(AutomationPoint, lane.points.items.len);
                        for (lane.points.items, 0..) |point, idx| {
                            points[idx] = .{ .time = point.time, .value = point.value };
                        }
                        var param_with_target: ?[]const u8 = null;
                        if (lane.target_kind == .track) {
                            if (lane.param_id) |param_id| {
                                if (std.mem.eql(u8, param_id, "volume")) {
                                    param_with_target = track_volume_param_ids[t];
                                } else if (std.mem.eql(u8, param_id, "pan")) {
                                    param_with_target = track_pan_param_ids[t];
                                }
                            }
                        } else {
                            const device_id = if (std.mem.eql(u8, lane.target_id, "instrument") or lane.target_id.len == 0) blk: {
                                break :blk instrument_device_ids[t] orelse continue;
                            } else if (std.mem.startsWith(u8, lane.target_id, "fx")) blk: {
                                var idx_str = lane.target_id["fx".len..];
                                if (std.mem.startsWith(u8, idx_str, ":")) idx_str = idx_str[1..];
                                const fx_idx = std.fmt.parseInt(usize, idx_str, 10) catch continue;
                                if (fx_idx >= ui_state.max_fx_slots) continue;
                                break :blk fx_device_ids[t][fx_idx] orelse continue;
                            } else {
                                continue;
                            };

                            if (lane.param_id) |param_id| {
                                param_with_target = try std.fmt.allocPrint(allocator, "{s}_p{s}", .{ device_id, param_id });
                            }
                        }
                        if (param_with_target == null) continue;

                        try points_list.append(allocator, .{
                            .id = points_id,
                            .target = .{
                                .parameter = param_with_target,
                            },
                            .unit = if (lane.unit) |unit| parse.parseUnit(unit) else null,
                            .points = points,
                        });
                    }
                }

                const loop_end: f64 = if (piano.loop_end_beats > 0) piano.loop_end_beats else clip_duration;
                try clip_slots.append(allocator, .{
                    .id = clip_slot_id,
                    .track = track_ids.items[t],
                    .has_stop = true,
                    .clip = .{
                        .time = 0.0,
                        .duration = clip_duration,
                        .play_start = piano.play_start_beats,
                        .loop_start = piano.loop_start_beats,
                        .loop_end = loop_end,
                        .name = try clipExportName(allocator, slot, null),
                        .lanes = if (points_list.items.len > 0) .{
                            .id = try ids.next(),
                            .notes = .{
                                .id = notes_id,
                                .notes = try daw_notes.toOwnedSlice(allocator),
                            },
                            .points = try points_list.toOwnedSlice(allocator),
                        } else null,
                        .notes = if (points_list.items.len == 0) .{
                            .id = notes_id,
                            .notes = try daw_notes.toOwnedSlice(allocator),
                        } else null,
                        .points = if (points_list.items.len == 0) &.{} else &.{},
                    },
                });
            } else {
                // Empty slot
                try clip_slots.append(allocator, .{
                    .id = clip_slot_id,
                    .track = track_ids.items[t],
                    .has_stop = true,
                    .clip = null,
                });
            }
        }

        // Add ClipSlot for master track
        const master_clip_slot_id = try ids.next();
        try clip_slots.append(allocator, .{
            .id = master_clip_slot_id,
            .track = master_track_id,
            .has_stop = true,
            .clip = null,
        });

        try scenes.append(allocator, .{
            .id = scene_id,
            .name = try allocator.dupe(u8, state.session.scenes[s].getName()),
            .lanes_id = scene_lanes_id,
            .clip_slots = try clip_slots.toOwnedSlice(allocator),
        });
    }

    // Build arrangement
    const arrangement_id = try ids.next();
    const root_lanes_id = try ids.next();
    const master_lane_id = try ids.next();
    const master_clips_id = try ids.next();

    // Add master lane
    try track_lanes.append(allocator, .{
        .id = master_lane_id,
        .track = master_track_id,
        .clips = .{
            .id = master_clips_id,
            .clips = &.{},
        },
    });

    const tempo_id = try ids.next();
    const timesig_id = try ids.next();

    return .{
        .application = .{
            .name = "Flux",
            .version = "1.0",
        },
        .transport = .{
            .tempo = .{
                .id = tempo_id,
                .name = "Tempo",
                .value = state.bpm,
                .min = 20.0,
                .max = 999.0,
                .unit = .bpm,
            },
            .time_signature = .{
                .id = timesig_id,
                .numerator = state.time_signature_numerator,
                .denominator = state.time_signature_denominator,
            },
        },
        .tracks = try tracks_list.toOwnedSlice(allocator),
        .master_track = master_track,
        .arrangement = .{
            .id = arrangement_id,
            .lanes = .{
                .id = root_lanes_id,
                .time_unit = .beats,
                .children = try track_lanes.toOwnedSlice(allocator),
            },
        },
        .scenes = try scenes.toOwnedSlice(allocator),
    };
}

fn arrangementTrackColor(state: *const ui_state.State, session_track: usize) ?[4]f32 {
    for (state.arrangement.tracks.items) |track| {
        if (track.session_track_index == session_track) return track.color;
    }
    return null;
}

fn buildArrangementClipsForTrack(
    allocator: std.mem.Allocator,
    state: *const ui_state.State,
    session_track: usize,
    ids: *IdGenerator,
    media_mode: MediaMode,
) ![]const Clip {
    var out = std.ArrayList(Clip).empty;
    for (state.arrangement.tracks.items) |arr_track| {
        if (arr_track.session_track_index != session_track) continue;
        for (arr_track.clips.items) |*arr_clip| {
            try out.append(allocator, try buildArrangementClip(allocator, state, arr_clip, ids, media_mode));
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn buildArrangementClip(
    allocator: std.mem.Allocator,
    state: *const ui_state.State,
    arr_clip: *const arr_clip_mod.ArrangementClip,
    ids: *IdGenerator,
    media_mode: MediaMode,
) !Clip {
    const time = ticksToBeats(arr_clip.start_tick);
    const duration = ticksToBeats(arr_clip.duration_ticks);
    const name: ?[]const u8 = blk: {
        const n = arr_clip.name.get();
        if (n.len == 0) break :blk null;
        break :blk try allocator.dupe(u8, n);
    };
    const color = try colorToHex(allocator, arr_clip.color);

    var clip = Clip{
        .time = time,
        .duration = duration,
        .play_start = 0,
        .loop_start = 0,
        .loop_end = duration,
        .enable = arr_clip.enabled,
        .name = name,
        .color = color,
    };

    if (arr_clip.kind == .audio) {
        if (try buildArrangementAudio(allocator, state, arr_clip, duration, ids, media_mode)) |warps| {
            clip.warps = warps;
        }
    } else {
        // MIDI: prefer embedded notes; fall back to session piano clip reference.
        const piano = if (arr_clip.midi) |*m|
            m
        else if (arr_clip.midi_session_track < track_count and arr_clip.midi_session_scene < session_constants.max_scenes)
            &state.piano_clips[arr_clip.midi_session_track][arr_clip.midi_session_scene]
        else
            null;

        if (piano) |p| {
            var daw_notes = std.ArrayList(Note).empty;
            for (p.notes.items) |note| {
                try daw_notes.append(allocator, .{
                    .time = note.start,
                    .duration = note.duration,
                    .key = note.pitch,
                    .vel = note.velocity,
                    .rel = note.release_velocity,
                });
            }
            clip.notes = .{
                .id = try ids.next(),
                .notes = try daw_notes.toOwnedSlice(allocator),
            };
            clip.play_start = p.play_start_beats;
            clip.loop_start = p.loop_start_beats;
            clip.loop_end = if (p.loop_end_beats > 0) p.loop_end_beats else duration;
        }
    }
    return clip;
}

fn buildArrangementAudio(
    allocator: std.mem.Allocator,
    state: *const ui_state.State,
    arr_clip: *const arr_clip_mod.ArrangementClip,
    clip_duration_beats: f64,
    ids: *IdGenerator,
    media_mode: MediaMode,
) !?types.Warps {
    const path = arr_clip.audio_path orelse return null;
    if (path.len == 0) return null;

    // Prefer sample_store (pack remaps path_in_project); fall back to raw path.
    var file_path = path;
    var duration_sec: f64 = clip_duration_beats * 60.0 / @as(f64, @floatCast(state.bpm));
    var sample_rate: i32 = 44100;
    var channels: i32 = 2;
    if (state.sample_store.path_to_id.get(path)) |sid| {
        if (state.sample_store.get(sid)) |asset| {
            file_path = asset.path_in_project;
            duration_sec = asset.duration_seconds;
            sample_rate = asset.original_sample_rate;
            channels = asset.original_channels;
        }
    }

    const warp_points = try allocator.alloc(WarpPoint, 2);
    warp_points[0] = .{ .time = 0.0, .content_time = 0.0 };
    warp_points[1] = .{ .time = clip_duration_beats, .content_time = duration_sec };

    return .{
        .id = try ids.next(),
        .time_unit = .beats,
        .content_time_unit = .seconds,
        .audio = .{
            .id = try ids.next(),
            .file = .{ .path = try allocator.dupe(u8, file_path), .external = media_mode == .external },
            .duration = duration_sec,
            .sample_rate = sample_rate,
            .channels = channels,
            .algorithm = try allocator.dupe(u8, "stretch"),
        },
        .warps = warp_points,
    };
}

fn ticksToBeats(ticks: i64) f64 {
    return @as(f64, @floatFromInt(ticks)) / @as(f64, @floatFromInt(arr_timeline.ppq));
}

fn colorToHex(allocator: std.mem.Allocator, color: [4]f32) ![]const u8 {
    const r: u8 = @intFromFloat(@min(255.0, @max(0.0, color[0] * 255.0)));
    const g: u8 = @intFromFloat(@min(255.0, @max(0.0, color[1] * 255.0)));
    const b: u8 = @intFromFloat(@min(255.0, @max(0.0, color[2] * 255.0)));
    return try std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b });
}

/// DAWproject `contentType` list: notes | audio | "audio notes" (hybrid).
fn trackContentTypesAttr(allocator: std.mem.Allocator, state: *const ui_state.State, track: usize) ![]const u8 {
    const has_audio = state.trackHasAudio(track);
    const has_notes = state.trackHasNotes(track);
    if (has_audio and has_notes) return try allocator.dupe(u8, "audio notes");
    if (has_audio) return try allocator.dupe(u8, "audio");
    return try allocator.dupe(u8, "notes");
}

fn clipExportName(
    allocator: std.mem.Allocator,
    slot: session_view.ClipSlot,
    audio: ?*const @import("../session/audio_clip.zig").AudioClip,
) !?[]const u8 {
    const slot_name = slot.name.get();
    if (slot_name.len > 0) return try allocator.dupe(u8, slot_name);
    if (audio) |a| {
        const audio_name = a.name.get();
        if (audio_name.len > 0) return try allocator.dupe(u8, audio_name);
    }
    return null;
}

fn buildAudioClip(
    allocator: std.mem.Allocator,
    state: *const ui_state.State,
    track: usize,
    scene: usize,
    ids: *IdGenerator,
    media_mode: MediaMode,
) !Clip {
    const slot = state.session.clips[track][scene];
    const audio = &state.audio_clips[track][scene];
    const sample_id = audio.sample_id orelse return error.MissingSample;
    const asset = state.sample_store.get(sample_id) orelse return error.MissingSample;

    const clip_duration: f64 = if (slot.state != .empty)
        slot.length_beats
    else
        audio.length_beats;

    var warp_points: []WarpPoint = undefined;
    if (audio.warps.items.len >= 2) {
        warp_points = try allocator.alloc(WarpPoint, audio.warps.items.len);
        for (audio.warps.items, 0..) |m, i| {
            warp_points[i] = .{ .time = m.beat, .content_time = m.content_seconds };
        }
    } else {
        warp_points = try allocator.alloc(WarpPoint, 2);
        warp_points[0] = .{ .time = 0.0, .content_time = 0.0 };
        warp_points[1] = .{ .time = clip_duration, .content_time = asset.duration_seconds };
    }

    const name = try clipExportName(allocator, slot, audio);

    const algorithm: ?[]const u8 = if (audio.algorithm) |a|
        try allocator.dupe(u8, a)
    else
        try allocator.dupe(u8, "stretch");

    const path = try allocator.dupe(u8, asset.path_in_project);
    const warps_id = try ids.next();
    const audio_id = try ids.next();

    const loop_end: f64 = if (audio.loop_end_beats > 0) audio.loop_end_beats else clip_duration;

    return .{
        .time = 0.0,
        .duration = clip_duration,
        .play_start = audio.play_start_beats,
        .loop_start = audio.loop_start_beats,
        .loop_end = loop_end,
        .fade_in_time = if (audio.fade_in_beats > 0) audio.fade_in_beats else null,
        .fade_out_time = if (audio.fade_out_beats > 0) audio.fade_out_beats else null,
        .fade_time_unit = .beats,
        .enable = true,
        .name = name,
        .warps = .{
            .id = warps_id,
            .time_unit = .beats,
            .content_time_unit = .seconds,
            .audio = .{
                .id = audio_id,
                .file = .{ .path = path, .external = media_mode == .external },
                .duration = asset.duration_seconds,
                .sample_rate = asset.original_sample_rate,
                .channels = asset.original_channels,
                .algorithm = algorithm,
            },
            .warps = warp_points,
        },
    };
}

fn buildClapPlugin(
    allocator: std.mem.Allocator,
    entry: plugins.PluginEntry,
    info: TrackPluginInfo,
    device_role: types.DeviceRole,
    ids: *IdGenerator,
) !ClapPlugin {
    const device_id = try ids.next();
    const enabled_id = try ids.next();
    const clap_plugin_id = info.plugin_id orelse entry.id orelse "";
    const xml_kind = builtinXmlKind(clap_plugin_id);
    const builtin_kind = BuiltinKind.fromId(clap_plugin_id);

    var params = std.ArrayList(RealParameter).empty;
    if (info.params.len > 0) {
        for (info.params) |param| {
            const param_id = try std.fmt.allocPrint(allocator, "{s}_p{d}", .{ device_id, param.id });
            // Prefer schema element names for builtins (InputGain not "Input Gain")
            const schema_name = if (builtin_kind != null)
                param_table.schemaNameForId(param.id) orelse param.name
            else
                param.name;
            try params.append(allocator, .{
                .id = param_id,
                .parameter_id = @bitCast(param.id),
                .name = try allocator.dupe(u8, schema_name),
                .value = param.value,
                .min = param.min,
                .max = param.max,
                .unit = unitFromTable(param_table.unitForSchema(schema_name)),
            });
        }
    }

    // Portable builtins: params live in schema XML elements, no clap-preset.
    const use_state = xml_kind == .clap;

    // Map DAWproject typed children from collected params (schema names from param_table)
    const threshold = try namedParam(allocator, params.items, "Threshold");
    const ratio = try namedParam(allocator, params.items, "Ratio");
    const attack = try namedParam(allocator, params.items, "Attack");
    const release = try namedParam(allocator, params.items, "Release");
    const input_gain = try namedParam(allocator, params.items, "InputGain");
    const output_gain = try namedParam(allocator, params.items, "OutputGain");
    const range = try namedParam(allocator, params.items, "Range");
    const auto_makeup: ?types.BoolParameter = blk: {
        for (params.items) |p| {
            if (std.mem.eql(u8, p.name, "AutoMakeup")) {
                break :blk .{
                    .id = try allocator.dupe(u8, p.id),
                    .name = try allocator.dupe(u8, "AutoMakeup"),
                    .value = p.value >= 0.5,
                    .parameter_id = p.parameter_id,
                };
            }
        }
        break :blk null;
    };

    const eq_bands = if (xml_kind == .equalizer)
        try buildEqBands(allocator, device_id, params.items)
    else
        &[_]types.EqBand{};

    // For dynamics builtins, schema children carry the values; keep Parameters too for param IDs.
    return .{
        .id = device_id,
        .name = try allocator.dupe(u8, entry.name),
        .device_id = try allocator.dupe(u8, clap_plugin_id),
        .device_name = try allocator.dupe(u8, entry.name),
        .device_role = device_role,
        .xml_kind = xml_kind,
        .parameters = try params.toOwnedSlice(allocator),
        .enabled = .{
            .id = enabled_id,
            .name = "On/Off",
            .value = true,
        },
        .state = if (use_state) blk: {
            if (info.state_path) |sp| break :blk .{ .path = try allocator.dupe(u8, sp) };
            break :blk null;
        } else null,
        .eq_bands = eq_bands,
        .threshold = threshold,
        .ratio = ratio,
        .attack = attack,
        .release = release,
        .input_gain = input_gain,
        .output_gain = output_gain,
        .range = range,
        .auto_makeup = auto_makeup,
    };
}

fn builtinXmlKind(plugin_id: []const u8) types.DeviceXmlKind {
    const kind = BuiltinKind.fromId(plugin_id) orelse return .clap;
    return switch (kind) {
        .equalizer => .equalizer,
        .compressor => .compressor,
        .noise_gate => .noise_gate,
        .limiter => .limiter,
    };
}

fn unitFromTable(u: param_table.Unit) types.Unit {
    return switch (u) {
        .linear => .linear,
        .decibel => .decibel,
        .seconds => .seconds,
        .hertz => .hertz,
    };
}

fn namedParam(allocator: std.mem.Allocator, items: []const RealParameter, name: []const u8) !?RealParameter {
    for (items) |p| {
        if (std.mem.eql(u8, p.name, name)) {
            return .{
                .id = try allocator.dupe(u8, p.id),
                .name = try allocator.dupe(u8, name),
                .value = p.value,
                .min = p.min,
                .max = p.max,
                .unit = p.unit,
                .parameter_id = p.parameter_id,
            };
        }
    }
    return null;
}

fn buildEqBands(allocator: std.mem.Allocator, device_id: []const u8, items: []const RealParameter) ![]const types.EqBand {
    var bands = std.ArrayList(types.EqBand).empty;
    const type_names = [_][]const u8{ "highPass", "lowPass", "bandPass", "highShelf", "lowShelf", "bell", "notch" };
    var b: usize = 0;
    while (b < 6) : (b += 1) {
        const base = param_table.eqBandBase(b);
        const type_p = findParamById(items, base + 0) orelse continue;
        const freq_p = findParamById(items, base + 1) orelse continue;
        const gain_p = findParamById(items, base + 2);
        const q_p = findParamById(items, base + 3);
        const en_p = findParamById(items, base + 4);

        const t_idx: usize = @intFromFloat(@max(0, @min(6, type_p.value)));
        const band_type = type_names[t_idx];

        try bands.append(allocator, .{
            .band_type = try allocator.dupe(u8, band_type),
            .order = @intCast(b),
            .freq = .{
                .id = try std.fmt.allocPrint(allocator, "{s}_b{d}_freq", .{ device_id, b }),
                .name = "Freq",
                .value = freq_p.value,
                .min = freq_p.min,
                .max = freq_p.max,
                .unit = unitFromTable(param_table.unitForSchema("Freq")),
                .parameter_id = freq_p.parameter_id,
            },
            .gain = if (gain_p) |g| .{
                .id = try std.fmt.allocPrint(allocator, "{s}_b{d}_gain", .{ device_id, b }),
                .name = "Gain",
                .value = g.value,
                .min = g.min,
                .max = g.max,
                .unit = unitFromTable(param_table.unitForSchema("Gain")),
                .parameter_id = g.parameter_id,
            } else null,
            .q = if (q_p) |q| .{
                .id = try std.fmt.allocPrint(allocator, "{s}_b{d}_q", .{ device_id, b }),
                .name = "Q",
                .value = q.value,
                .min = q.min,
                .max = q.max,
                .unit = unitFromTable(param_table.unitForSchema("Q")),
                .parameter_id = q.parameter_id,
            } else null,
            .enabled = if (en_p) |e| .{
                .id = try std.fmt.allocPrint(allocator, "{s}_b{d}_en", .{ device_id, b }),
                .name = "Enabled",
                .value = e.value >= 0.5,
                .parameter_id = e.parameter_id,
            } else null,
        });
    }
    return try bands.toOwnedSlice(allocator);
}

fn findParamById(items: []const RealParameter, id: u32) ?RealParameter {
    for (items) |p| {
        if (p.parameter_id) |pid| {
            if (@as(u32, @bitCast(pid)) == id) return p;
        }
    }
    return null;
}

fn buildMissingPlugin(
    allocator: std.mem.Allocator,
    missing: *const ui_state.MissingPlugin,
    info: TrackPluginInfo,
    ids: *IdGenerator,
) !ClapPlugin {
    const device_id = try ids.next();
    const enabled_id = try ids.next();
    var params = std.ArrayList(RealParameter).empty;
    for (info.params) |param| {
        try params.append(allocator, .{
            .id = try std.fmt.allocPrint(allocator, "{s}_p{d}", .{ device_id, param.id }),
            .parameter_id = @bitCast(param.id),
            .name = try allocator.dupe(u8, param.name),
            .value = param.value,
            .min = param.min,
            .max = param.max,
            .unit = .linear,
        });
    }

    return .{
        .id = device_id,
        .name = try allocator.dupe(u8, missing.device_name),
        .device_id = try allocator.dupe(u8, missing.device_id),
        .device_name = try allocator.dupe(u8, missing.device_name),
        .device_role = switch (missing.role) {
            .instrument => .instrument,
            .note_fx => .noteFX,
            .audio_fx => .audioFX,
            .analyzer => .analyzer,
        },
        .loaded = missing.loaded,
        .parameters = try params.toOwnedSlice(allocator),
        .enabled = .{
            .id = enabled_id,
            .name = "On/Off",
            .value = true,
        },
        .state = if (info.state_path) |path| .{
            .path = try allocator.dupe(u8, path),
        } else null,
    };
}
