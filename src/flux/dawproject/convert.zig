const std = @import("std");
const ui_state = @import("../ui/state.zig");
const session_constants = @import("../ui/session_view/constants.zig");
const session_view = @import("../ui/session_view.zig");
const track_count = session_constants.max_tracks;
const master_track_index = session_view.master_track_index;
const plugins = @import("../plugins.zig");
const types = @import("types.zig");
const io_types = @import("io_types.zig");
const parse = @import("parse.zig");

const RealParameter = types.RealParameter;
const Note = types.Note;
const AutomationPoint = types.AutomationPoint;
const Points = types.Points;
const Clip = types.Clip;
const ClipSlot = types.ClipSlot;
const Scene = types.Scene;
const Track = types.Track;
const Lanes = types.Lanes;
const Channel = types.Channel;
const ClapPlugin = types.ClapPlugin;
const Project = types.Project;

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

/// Convert Flux project state to DAWproject format
pub fn fromFluxProject(
    allocator: std.mem.Allocator,
    state: *const ui_state.State,
    catalog: *const plugins.PluginCatalog,
    track_plugin_info: []const TrackPluginInfo,
    track_fx_plugin_info: []const [ui_state.max_fx_slots]TrackPluginInfo,
) !Project {
    var ids = IdGenerator{ .allocator = allocator };

    // Build tracks
    var tracks_list = std.ArrayList(Track).empty;
    var track_lanes = std.ArrayList(Lanes).empty;
    var track_ids = std.ArrayList([]const u8).empty; // Store track IDs for ClipSlot references
    var instrument_device_ids: [track_count]?[]const u8 = [_]?[]const u8{null} ** track_count;
    var track_volume_param_ids: [track_count]?[]const u8 = [_]?[]const u8{null} ** track_count;
    var track_pan_param_ids: [track_count]?[]const u8 = [_]?[]const u8{null} ** track_count;
    var fx_device_ids: [track_count][ui_state.max_fx_slots]?[]const u8 = [_][ui_state.max_fx_slots]?[]const u8{
        [_]?[]const u8{null} ** ui_state.max_fx_slots,
    } ** track_count;

    const master_channel_id = try ids.next();

    for (0..state.session.track_count) |t| {
        const track_data = state.session.tracks[t];
        const track_id = try ids.next();
        try track_ids.append(allocator, track_id);
        const channel_id = try ids.next();

        // Build devices if present
        var devices = std.ArrayList(ClapPlugin).empty;
        const choice_index = state.track_plugins[t].choice_index;
        if (catalog.entryForIndex(choice_index)) |entry| {
            if (entry.kind == .clap) {
                const device_id = try ids.next();
                instrument_device_ids[t] = device_id;
                const enabled_id = try ids.next();

                // Get plugin ID and state path from track_plugin_info if available
                const info = if (t < track_plugin_info.len) track_plugin_info[t] else TrackPluginInfo{};
                // Prefer plugin ID from loaded plugin, fall back to catalog entry
                const clap_plugin_id = info.plugin_id orelse entry.id orelse "";
                var params = std.ArrayList(RealParameter).empty;
                if (info.params.len > 0) {
                    for (info.params) |param| {
                        const param_id = try std.fmt.allocPrint(allocator, "{s}_p{d}", .{ device_id, param.id });
                        try params.append(allocator, .{
                            .id = param_id,
                            .name = try allocator.dupe(u8, param.name),
                            .value = param.value,
                            .min = param.min,
                            .max = param.max,
                            .unit = .linear,
                        });
                    }
                }

                try devices.append(allocator, .{
                    .id = device_id,
                    .name = try allocator.dupe(u8, entry.name),
                    .device_id = try allocator.dupe(u8, clap_plugin_id),
                    .device_name = try allocator.dupe(u8, entry.name),
                    .device_role = .instrument,
                    .parameters = try params.toOwnedSlice(allocator),
                    .enabled = .{
                        .id = enabled_id,
                        .name = "On/Off",
                        .value = true,
                    },
                    .state = if (info.state_path) |sp| .{
                        .path = try allocator.dupe(u8, sp),
                    } else null,
                });
            }
        }
        for (0..ui_state.max_fx_slots) |fx_index| {
            const fx_choice = state.track_fx[t][fx_index].choice_index;
            if (catalog.entryForIndex(fx_choice)) |entry| {
                if (entry.kind != .clap) continue;
                const device_id = try ids.next();
                fx_device_ids[t][fx_index] = device_id;
                const enabled_id = try ids.next();
                const info = if (t < track_fx_plugin_info.len) track_fx_plugin_info[t][fx_index] else TrackPluginInfo{};
                const clap_plugin_id = info.plugin_id orelse entry.id orelse "";
                var params = std.ArrayList(RealParameter).empty;
                if (info.params.len > 0) {
                    for (info.params) |param| {
                        const param_id = try std.fmt.allocPrint(allocator, "{s}_p{d}", .{ device_id, param.id });
                        try params.append(allocator, .{
                            .id = param_id,
                            .name = try allocator.dupe(u8, param.name),
                            .value = param.value,
                            .min = param.min,
                            .max = param.max,
                            .unit = .linear,
                        });
                    }
                }

                try devices.append(allocator, .{
                    .id = device_id,
                    .name = try allocator.dupe(u8, entry.name),
                    .device_id = try allocator.dupe(u8, clap_plugin_id),
                    .device_name = try allocator.dupe(u8, entry.name),
                    .device_role = .audioFX,
                    .parameters = try params.toOwnedSlice(allocator),
                    .enabled = .{
                        .id = enabled_id,
                        .name = "On/Off",
                        .value = true,
                    },
                    .state = if (info.state_path) |sp| .{
                        .path = try allocator.dupe(u8, sp),
                    } else null,
                });
            }
        }

        const vol_id = try ids.next();
        const mute_id = try ids.next();
        const pan_id = try ids.next();
        track_volume_param_ids[t] = vol_id;
        track_pan_param_ids[t] = pan_id;

        try tracks_list.append(allocator, .{
            .id = track_id,
            .name = try allocator.dupe(u8, track_data.getName()),
            .content_type = .notes,
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
                    .value = 0.5,
                    .min = 0.0,
                    .max = 1.0,
                    .unit = .normalized,
                },
                .devices = try devices.toOwnedSlice(allocator),
            },
        });

        // Build empty clips container for arrangement (clips go in ClipSlots in Scenes)
        const clips_id = try ids.next();
        const lane_id = try ids.next();
        try track_lanes.append(allocator, .{
            .id = lane_id,
            .track = track_id,
            .clips = .{
                .id = clips_id,
                .clips = &.{}, // Empty - clips are in Scenes/ClipSlots
            },
        });
    }

    // Master track
    var master_devices = std.ArrayList(ClapPlugin).empty;
    for (0..ui_state.max_fx_slots) |fx_index| {
        const fx_choice = state.track_fx[master_track_index][fx_index].choice_index;
        if (catalog.entryForIndex(fx_choice)) |entry| {
            if (entry.kind != .clap) continue;
            const device_id = try ids.next();
            const enabled_id = try ids.next();
            const info = if (master_track_index < track_fx_plugin_info.len)
                track_fx_plugin_info[master_track_index][fx_index]
            else
                TrackPluginInfo{};
            const clap_plugin_id = info.plugin_id orelse entry.id orelse "";
            var params = std.ArrayList(RealParameter).empty;
            if (info.params.len > 0) {
                for (info.params) |param| {
                    const param_id = try std.fmt.allocPrint(allocator, "{s}_p{d}", .{ device_id, param.id });
                    try params.append(allocator, .{
                        .id = param_id,
                        .name = try allocator.dupe(u8, param.name),
                        .value = param.value,
                        .min = param.min,
                        .max = param.max,
                        .unit = .linear,
                    });
                }
            }

            try master_devices.append(allocator, .{
                .id = device_id,
                .name = try allocator.dupe(u8, entry.name),
                .device_id = try allocator.dupe(u8, clap_plugin_id),
                .device_name = try allocator.dupe(u8, entry.name),
                .device_role = .audioFX,
                .parameters = try params.toOwnedSlice(allocator),
                .enabled = .{
                    .id = enabled_id,
                    .name = "On/Off",
                    .value = true,
                },
                .state = if (info.state_path) |sp| .{
                    .path = try allocator.dupe(u8, sp),
                } else null,
            });
        }
    }

    const master_track_id = try ids.next();
    const master_vol_id = try ids.next();
    const master_mute_id = try ids.next();
    const master_pan_id = try ids.next();

    const master_track = Track{
        .id = master_track_id,
        .name = "Master",
        .content_type = .audio,
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
                .value = 0.5,
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
            const clip_slot_id = try ids.next();

            // Check if this slot has content
            const has_content = slot.state != .empty or piano.notes.items.len > 0;

            if (has_content) {
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

                try clip_slots.append(allocator, .{
                    .id = clip_slot_id,
                    .track = track_ids.items[t],
                    .has_stop = true,
                    .clip = .{
                        .time = 0.0,
                        .duration = clip_duration,
                        .play_start = 0.0,
                        .name = null,
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
                .numerator = 4,
                .denominator = 4,
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
