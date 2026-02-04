const std = @import("std");
const types = @import("types.zig");

const Unit = types.Unit;
const TimeUnit = types.TimeUnit;
const MixerRole = types.MixerRole;
const DeviceRole = types.DeviceRole;
const ContentType = types.ContentType;
const RealParameter = types.RealParameter;
const BoolParameter = types.BoolParameter;
const TimeSignatureParameter = types.TimeSignatureParameter;
const FileReference = types.FileReference;
const ClapPlugin = types.ClapPlugin;
const Channel = types.Channel;
const Track = types.Track;
const Note = types.Note;
const Notes = types.Notes;
const AutomationPoint = types.AutomationPoint;
const AutomationTarget = types.AutomationTarget;
const Points = types.Points;
const Clip = types.Clip;
const Clips = types.Clips;
const Lanes = types.Lanes;
const Arrangement = types.Arrangement;
const ClipSlot = types.ClipSlot;
const Scene = types.Scene;
const Transport = types.Transport;
const Application = types.Application;
const Project = types.Project;

pub fn parseProjectXml(allocator: std.mem.Allocator, xml_data: []const u8) !Project {
    const xml = @import("xml");

    // Use streaming XML parser
    var static_reader: xml.Reader.Static = .init(allocator, xml_data, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var proj = Project{
        .application = .{ .name = "Unknown", .version = "1.0" },
    };

    var tempo_value: f64 = 120.0;
    var time_sig_num: u8 = 4;
    var time_sig_den: u8 = 4;

    var tracks_list = std.ArrayList(Track).empty;
    var master_track: ?Track = null; // Separate master track
    var scenes_list = std.ArrayList(Scene).empty;
    var lanes_list = std.ArrayList(Lanes).empty; // Child track lanes

    // Track parsing state
    var current_track: ?Track = null;
    var current_channel: ?Channel = null;
    var current_devices = std.ArrayList(ClapPlugin).empty;
    var current_device: ?ClapPlugin = null;
    var root_lanes: ?Lanes = null; // Root lanes (container)
    var current_lanes: ?Lanes = null; // Current track lane
    var current_clips: ?Clips = null;
    var clips_list = std.ArrayList(Clip).empty;
    var current_clip: ?Clip = null;
    var current_notes: ?Notes = null;
    var notes_list = std.ArrayList(Note).empty;
    var current_points: ?Points = null;
    var clip_points_list = std.ArrayList(Points).empty;
    var points_point_list = std.ArrayList(AutomationPoint).empty;
    var points_target: AutomationTarget = .{};
    var current_scene: ?Scene = null;
    var current_clip_slot: ?ClipSlot = null;
    var clip_slots_list = std.ArrayList(ClipSlot).empty;
    const ClipContext = enum { arrangement, clip_slot };
    var clip_context: ?ClipContext = null;

    // Parse state stack
    const ParseState = enum {
        root,
        structure,
        track,
        channel,
        devices,
        device,
        arrangement,
        root_lanes,
        track_lanes,
        clips,
        clip,
        notes,
        points,
        clip_lanes,
        scenes,
        scene,
        scene_lanes,
        clip_slot,
    };
    var state: ParseState = .root;
    var clip_child_state: ParseState = .clip;

    while (true) {
        const node = reader.read() catch break;
        switch (node) {
            .eof => break,
            .element_start => {
                const elem_name = reader.elementName();

                if (std.mem.eql(u8, elem_name, "Project")) {
                    if (reader.attributeIndex("version")) |idx| {
                        proj.version = reader.attributeValue(idx) catch "1.0";
                    }
                } else if (std.mem.eql(u8, elem_name, "Application")) {
                    if (reader.attributeIndex("name")) |idx| {
                        proj.application.name = reader.attributeValue(idx) catch "Unknown";
                    }
                    if (reader.attributeIndex("version")) |idx| {
                        proj.application.version = reader.attributeValue(idx) catch "1.0";
                    }
                } else if (std.mem.eql(u8, elem_name, "Tempo")) {
                    if (reader.attributeIndex("value")) |idx| {
                        const val_str = reader.attributeValue(idx) catch "120";
                        tempo_value = std.fmt.parseFloat(f64, val_str) catch 120.0;
                    }
                } else if (std.mem.eql(u8, elem_name, "TimeSignature")) {
                    if (reader.attributeIndex("numerator")) |idx| {
                        const val_str = reader.attributeValue(idx) catch "4";
                        time_sig_num = std.fmt.parseInt(u8, val_str, 10) catch 4;
                    }
                    if (reader.attributeIndex("denominator")) |idx| {
                        const val_str = reader.attributeValue(idx) catch "4";
                        time_sig_den = std.fmt.parseInt(u8, val_str, 10) catch 4;
                    }
                } else if (std.mem.eql(u8, elem_name, "Structure")) {
                    state = .structure;
                } else if (std.mem.eql(u8, elem_name, "Track") and state == .structure) {
                    state = .track;
                    current_track = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .name = try allocator.dupe(u8, getAttr(reader, "name") orelse ""),
                        .content_type = parseContentType(getAttr(reader, "contentType")),
                    };
                } else if (std.mem.eql(u8, elem_name, "Channel") and state == .track) {
                    state = .channel;
                    current_channel = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .role = parseMixerRole(getAttr(reader, "role")),
                        .solo = parseBool(getAttr(reader, "solo")),
                        .destination = if (getAttr(reader, "destination")) |d| try allocator.dupe(u8, d) else null,
                    };
                } else if (std.mem.eql(u8, elem_name, "Devices") and state == .channel) {
                    state = .devices;
                } else if (std.mem.eql(u8, elem_name, "ClapPlugin") and state == .devices) {
                    state = .device;
                    current_device = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .name = try allocator.dupe(u8, getAttr(reader, "name") orelse ""),
                        .device_id = try allocator.dupe(u8, getAttr(reader, "deviceID") orelse ""),
                        .device_name = try allocator.dupe(u8, getAttr(reader, "deviceName") orelse ""),
                        .device_role = parseDeviceRole(getAttr(reader, "deviceRole")),
                        .loaded = parseBool(getAttr(reader, "loaded")),
                    };
                } else if (std.mem.eql(u8, elem_name, "State") and state == .device) {
                    // Plugin state file reference
                    if (current_device) |*dev| {
                        if (getAttr(reader, "path")) |path| {
                            dev.state = .{
                                .path = try allocator.dupe(u8, path),
                                .external = parseBool(getAttr(reader, "external")),
                            };
                        }
                    }
                } else if (std.mem.eql(u8, elem_name, "RealParameter") and (state == .channel or state == .device)) {
                    // Parse volume, pan parameters
                    const param_name = getAttr(reader, "name") orelse "";
                    const param_id = getAttr(reader, "id") orelse "";
                    const param_value = parseFloatAttr(getAttr(reader, "value")) orelse 0.0;
                    const param_unit = parseUnit(getAttr(reader, "unit"));
                    const param_min = parseFloatAttr(getAttr(reader, "min"));
                    const param_max = parseFloatAttr(getAttr(reader, "max"));

                    if (current_channel) |*ch| {
                        if (std.mem.eql(u8, param_name, "Volume")) {
                            ch.volume = .{
                                .id = try allocator.dupe(u8, param_id),
                                .name = "Volume",
                                .value = param_value,
                                .min = param_min,
                                .max = param_max,
                                .unit = param_unit,
                            };
                        } else if (std.mem.eql(u8, param_name, "Pan")) {
                            ch.pan = .{
                                .id = try allocator.dupe(u8, param_id),
                                .name = "Pan",
                                .value = param_value,
                                .min = param_min,
                                .max = param_max,
                                .unit = param_unit,
                            };
                        }
                    }
                } else if (std.mem.eql(u8, elem_name, "BoolParameter") and state == .channel) {
                    const param_name = getAttr(reader, "name") orelse "";
                    const param_id = getAttr(reader, "id") orelse "";
                    const param_value = parseBool(getAttr(reader, "value"));

                    if (current_channel) |*ch| {
                        if (std.mem.eql(u8, param_name, "Mute")) {
                            ch.mute = .{
                                .id = try allocator.dupe(u8, param_id),
                                .name = "Mute",
                                .value = param_value,
                            };
                        }
                    }
                } else if (std.mem.eql(u8, elem_name, "Scenes")) {
                    state = .scenes;
                } else if (std.mem.eql(u8, elem_name, "Scene") and state == .scenes) {
                    state = .scene;
                    current_scene = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .name = try allocator.dupe(u8, getAttr(reader, "name") orelse ""),
                        .lanes_id = "",
                        .clip_slots = &.{},
                    };
                    clip_slots_list = std.ArrayList(ClipSlot).empty;
                } else if (std.mem.eql(u8, elem_name, "Lanes") and state == .scene) {
                    state = .scene_lanes;
                    if (current_scene) |*scene| {
                        scene.lanes_id = try allocator.dupe(u8, getAttr(reader, "id") orelse "");
                    }
                } else if (std.mem.eql(u8, elem_name, "ClipSlot") and state == .scene_lanes) {
                    state = .clip_slot;
                    current_clip_slot = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .track = try allocator.dupe(u8, getAttr(reader, "track") orelse ""),
                        .has_stop = parseBool(getAttr(reader, "hasStop")),
                        .clip = null,
                    };
                } else if (std.mem.eql(u8, elem_name, "Arrangement")) {
                    state = .arrangement;
                } else if (std.mem.eql(u8, elem_name, "Lanes") and state == .arrangement) {
                    // Root Lanes (container)
                    state = .root_lanes;
                    root_lanes = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .track = null,
                    };
                } else if (std.mem.eql(u8, elem_name, "Lanes") and state == .root_lanes) {
                    // Track Lanes (child of root)
                    state = .track_lanes;
                    current_lanes = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .track = if (getAttr(reader, "track")) |t| try allocator.dupe(u8, t) else null,
                    };
                } else if (std.mem.eql(u8, elem_name, "Clips") and state == .track_lanes) {
                    state = .clips;
                    current_clips = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .clips = &.{}, // Will be filled in on element_end
                    };
                } else if (std.mem.eql(u8, elem_name, "Clip") and (state == .clips or state == .clip_slot)) {
                    clip_context = if (state == .clips) .arrangement else .clip_slot;
                    state = .clip;
                    clip_points_list = std.ArrayList(Points).empty;
                    current_clip = .{
                        .time = parseFloatAttr(getAttr(reader, "time")) orelse 0.0,
                        .duration = parseFloatAttr(getAttr(reader, "duration")) orelse 4.0,
                        .play_start = parseFloatAttr(getAttr(reader, "playStart")) orelse 0.0,
                        .name = if (getAttr(reader, "name")) |n| try allocator.dupe(u8, n) else null,
                    };
                } else if (std.mem.eql(u8, elem_name, "Lanes") and state == .clip) {
                    state = .clip_lanes;
                } else if (std.mem.eql(u8, elem_name, "Notes") and (state == .clip or state == .clip_lanes)) {
                    clip_child_state = state;
                    state = .notes;
                    current_notes = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .notes = &.{}, // Will be filled in on element_end
                    };
                } else if (std.mem.eql(u8, elem_name, "Note") and state == .notes) {
                    try notes_list.append(allocator, .{
                        .time = parseFloatAttr(getAttr(reader, "time")) orelse 0.0,
                        .duration = parseFloatAttr(getAttr(reader, "duration")) orelse 0.25,
                        .key = @intCast(parseIntAttr(getAttr(reader, "key")) orelse 60),
                        .vel = parseFloatAttr(getAttr(reader, "vel")) orelse 0.8,
                        .rel = parseFloatAttr(getAttr(reader, "rel")) orelse 0.8,
                    });
                } else if (std.mem.eql(u8, elem_name, "Points") and (state == .clip or state == .clip_lanes)) {
                    clip_child_state = state;
                    state = .points;
                    points_target = .{};
                    points_point_list = std.ArrayList(AutomationPoint).empty;
                    current_points = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .target = .{},
                        .unit = if (getAttr(reader, "unit")) |unit| parseUnit(unit) else null,
                        .points = &.{}, // Will be filled in on element_end
                    };
                } else if (std.mem.eql(u8, elem_name, "Target") and state == .points) {
                    points_target = .{
                        .parameter = if (getAttr(reader, "parameter")) |param| try allocator.dupe(u8, param) else null,
                        .expression = if (getAttr(reader, "expression")) |expr| try allocator.dupe(u8, expr) else null,
                        .channel = if (getAttr(reader, "channel")) |chan| @intCast(parseIntAttr(chan) orelse 0) else null,
                        .key = if (getAttr(reader, "key")) |key| @intCast(parseIntAttr(key) orelse 0) else null,
                        .controller = if (getAttr(reader, "controller")) |ctrl| @intCast(parseIntAttr(ctrl) orelse 0) else null,
                    };
                } else if ((std.mem.eql(u8, elem_name, "Point") or std.mem.eql(u8, elem_name, "RealPoint")) and state == .points) {
                    const value = parseFloatAttr(getAttr(reader, "value")) orelse 0.0;
                    try points_point_list.append(allocator, .{
                        .time = parseFloatAttr(getAttr(reader, "time")) orelse 0.0,
                        .value = value,
                    });
                } else if ((std.mem.eql(u8, elem_name, "EnumPoint") or std.mem.eql(u8, elem_name, "IntegerPoint")) and state == .points) {
                    const value = @as(f64, @floatFromInt(parseIntAttr(getAttr(reader, "value")) orelse 0));
                    try points_point_list.append(allocator, .{
                        .time = parseFloatAttr(getAttr(reader, "time")) orelse 0.0,
                        .value = value,
                    });
                } else if (std.mem.eql(u8, elem_name, "BoolPoint") and state == .points) {
                    const value: f64 = if (parseBool(getAttr(reader, "value"))) 1.0 else 0.0;
                    try points_point_list.append(allocator, .{
                        .time = parseFloatAttr(getAttr(reader, "time")) orelse 0.0,
                        .value = value,
                    });
                }
            },
            .element_end => {
                const elem_name = reader.elementName();

                if (std.mem.eql(u8, elem_name, "Structure")) {
                    state = .root;
                } else if (std.mem.eql(u8, elem_name, "Track") and state == .track) {
                    state = .structure;
                    if (current_track) |track| {
                        // Check if this is the master track (channel role = master)
                        const is_master = if (track.channel) |ch| ch.role == .master else false;
                        if (is_master) {
                            master_track = track;
                        } else {
                            try tracks_list.append(allocator, track);
                        }
                    }
                    current_track = null;
                } else if (std.mem.eql(u8, elem_name, "Channel") and state == .channel) {
                    state = .track;
                    if (current_channel) |ch| {
                        if (current_track) |*track| {
                            var channel_copy = ch;
                            channel_copy.devices = try current_devices.toOwnedSlice(allocator);
                            track.channel = channel_copy;
                        }
                    }
                    current_channel = null;
                    current_devices = std.ArrayList(ClapPlugin).empty;
                } else if (std.mem.eql(u8, elem_name, "Devices") and state == .devices) {
                    state = .channel;
                } else if (std.mem.eql(u8, elem_name, "ClapPlugin") and state == .device) {
                    state = .devices;
                    if (current_device) |dev| {
                        try current_devices.append(allocator, dev);
                    }
                    current_device = null;
                } else if (std.mem.eql(u8, elem_name, "Scenes")) {
                    state = .root;
                } else if (std.mem.eql(u8, elem_name, "Scene") and state == .scene) {
                    if (current_scene) |scene| {
                        var scene_copy = scene;
                        scene_copy.clip_slots = try clip_slots_list.toOwnedSlice(allocator);
                        try scenes_list.append(allocator, scene_copy);
                    }
                    current_scene = null;
                    clip_slots_list = std.ArrayList(ClipSlot).empty;
                    state = .scenes;
                } else if (std.mem.eql(u8, elem_name, "Lanes") and state == .scene_lanes) {
                    state = .scene;
                } else if (std.mem.eql(u8, elem_name, "ClipSlot") and state == .clip_slot) {
                    if (current_clip_slot) |slot| {
                        try clip_slots_list.append(allocator, slot);
                    }
                    current_clip_slot = null;
                    state = .scene_lanes;
                } else if (std.mem.eql(u8, elem_name, "Arrangement")) {
                    state = .root;
                } else if (std.mem.eql(u8, elem_name, "Lanes") and state == .root_lanes) {
                    // End of root Lanes - don't add to list, it's the container
                    state = .arrangement;
                } else if (std.mem.eql(u8, elem_name, "Lanes") and state == .track_lanes) {
                    // End of track Lanes - add to list
                    if (current_lanes) |lanes| {
                        try lanes_list.append(allocator, lanes);
                    }
                    current_lanes = null;
                    state = .root_lanes;
                } else if (std.mem.eql(u8, elem_name, "Clips") and state == .clips) {
                    if (current_clips) |clips| {
                        if (current_lanes) |*lanes| {
                            var clips_copy = clips;
                            clips_copy.clips = try clips_list.toOwnedSlice(allocator);
                            lanes.clips = clips_copy;
                        }
                    }
                    current_clips = null;
                    clips_list = std.ArrayList(Clip).empty;
                    state = .track_lanes;
                } else if (std.mem.eql(u8, elem_name, "Clip") and state == .clip) {
                    if (current_clip) |clip| {
                        var clip_copy = clip;
                        clip_copy.points = try clip_points_list.toOwnedSlice(allocator);
                        if (clip_context == .arrangement) {
                            try clips_list.append(allocator, clip_copy);
                        } else if (clip_context == .clip_slot) {
                            if (current_clip_slot) |*slot| {
                                slot.clip = clip_copy;
                            }
                        }
                    }
                    current_clip = null;
                    state = if (clip_context == .clip_slot) .clip_slot else .clips;
                    clip_context = null;
                } else if (std.mem.eql(u8, elem_name, "Notes") and state == .notes) {
                    if (current_notes) |notes| {
                        if (current_clip) |*clip| {
                            var notes_copy = notes;
                            notes_copy.notes = try notes_list.toOwnedSlice(allocator);
                            clip.notes = notes_copy;
                        }
                    }
                    current_notes = null;
                    notes_list = std.ArrayList(Note).empty;
                    state = clip_child_state;
                } else if (std.mem.eql(u8, elem_name, "Points") and state == .points) {
                    if (current_points) |points| {
                        var points_copy = points;
                        points_copy.target = points_target;
                        points_copy.points = try points_point_list.toOwnedSlice(allocator);
                        try clip_points_list.append(allocator, points_copy);
                    }
                    current_points = null;
                    points_point_list = std.ArrayList(AutomationPoint).empty;
                    points_target = .{};
                    state = clip_child_state;
                } else if (std.mem.eql(u8, elem_name, "Lanes") and state == .clip_lanes) {
                    state = .clip;
                }
            },
            else => {},
        }
    }

    // Set transport with parsed values
    proj.transport = .{
        .tempo = .{
            .id = "tempo",
            .name = "Tempo",
            .value = tempo_value,
            .unit = .bpm,
        },
        .time_signature = .{
            .id = "timesig",
            .numerator = time_sig_num,
            .denominator = time_sig_den,
        },
    };

    // Set parsed tracks, master track, and scenes
    proj.tracks = try tracks_list.toOwnedSlice(allocator);
    proj.master_track = master_track;
    proj.scenes = try scenes_list.toOwnedSlice(allocator);

    // Set arrangement with lanes
    if (lanes_list.items.len > 0 or root_lanes != null) {
        var root = root_lanes orelse Lanes{ .id = "root_lanes" };
        root.children = try lanes_list.toOwnedSlice(allocator);
        proj.arrangement = .{
            .id = "arrangement",
            .lanes = root,
        };
    }

    return proj;
}

// Helper to get attribute value
fn getAttr(reader: anytype, name: []const u8) ?[]const u8 {
    if (reader.attributeIndex(name)) |idx| {
        return reader.attributeValue(idx) catch null;
    }
    return null;
}

fn parseFloatAttr(s: ?[]const u8) ?f64 {
    const str = s orelse return null;
    return std.fmt.parseFloat(f64, str) catch null;
}

fn parseIntAttr(s: ?[]const u8) ?i32 {
    const str = s orelse return null;
    return std.fmt.parseInt(i32, str, 10) catch null;
}

fn parseBool(s: ?[]const u8) bool {
    const str = s orelse return false;
    return std.mem.eql(u8, str, "true");
}

fn parseContentType(s: ?[]const u8) ContentType {
    const str = s orelse return .notes;
    if (std.mem.eql(u8, str, "audio")) return .audio;
    if (std.mem.eql(u8, str, "automation")) return .automation;
    if (std.mem.eql(u8, str, "notes")) return .notes;
    if (std.mem.eql(u8, str, "video")) return .video;
    if (std.mem.eql(u8, str, "markers")) return .markers;
    if (std.mem.eql(u8, str, "tracks")) return .tracks;
    return .notes;
}

fn parseMixerRole(s: ?[]const u8) MixerRole {
    const str = s orelse return .regular;
    if (std.mem.eql(u8, str, "regular")) return .regular;
    if (std.mem.eql(u8, str, "master")) return .master;
    if (std.mem.eql(u8, str, "effect")) return .effect;
    if (std.mem.eql(u8, str, "submix")) return .submix;
    if (std.mem.eql(u8, str, "vca")) return .vca;
    return .regular;
}

fn parseDeviceRole(s: ?[]const u8) DeviceRole {
    const str = s orelse return .instrument;
    if (std.mem.eql(u8, str, "instrument")) return .instrument;
    if (std.mem.eql(u8, str, "noteFX")) return .noteFX;
    if (std.mem.eql(u8, str, "audioFX")) return .audioFX;
    if (std.mem.eql(u8, str, "analyzer")) return .analyzer;
    return .instrument;
}

pub fn parseUnit(s: ?[]const u8) Unit {
    const str = s orelse return .linear;
    if (std.mem.eql(u8, str, "linear")) return .linear;
    if (std.mem.eql(u8, str, "normalized")) return .normalized;
    if (std.mem.eql(u8, str, "percent")) return .percent;
    if (std.mem.eql(u8, str, "decibel")) return .decibel;
    if (std.mem.eql(u8, str, "hertz")) return .hertz;
    if (std.mem.eql(u8, str, "semitones")) return .semitones;
    if (std.mem.eql(u8, str, "seconds")) return .seconds;
    if (std.mem.eql(u8, str, "beats")) return .beats;
    if (std.mem.eql(u8, str, "bpm")) return .bpm;
    return .linear;
}
