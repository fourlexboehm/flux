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
const WarpPoint = types.WarpPoint;
const Audio = types.Audio;
const Warps = types.Warps;
const Clip = types.Clip;
const Clips = types.Clips;
const Lanes = types.Lanes;
const Arrangement = types.Arrangement;
const ClipSlot = types.ClipSlot;
const Scene = types.Scene;
const Transport = types.Transport;
const Application = types.Application;
const Project = types.Project;

const ClipParent = enum { arrangement, clip_slot, nested };

const ClipFrame = struct {
    clip: Clip,
    points_list: std.ArrayList(Points),
    nested_list: std.ArrayList(Clip),
    nested_id: []const u8 = "",
    warp_points: std.ArrayList(WarpPoint),
    warps: ?Warps = null,
    audio: ?Audio = null,
    parent: ClipParent,
    return_state: ParseState,
};

const ParseState = enum {
    root,
    structure,
    track,
    channel,
    devices,
    device,
    eq_band,
    arrangement,
    root_lanes,
    track_lanes,
    clips,
    clip,
    notes,
    points,
    clip_lanes,
    warps,
    audio,
    nested_clips,
    scenes,
    scene,
    scene_lanes,
    clip_slot,
};

pub fn parseProjectXml(allocator: std.mem.Allocator, xml_data: []const u8) !Project {
    const xml = @import("xml");

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
    var master_track: ?Track = null;
    var scenes_list = std.ArrayList(Scene).empty;
    var lanes_list = std.ArrayList(Lanes).empty;

    var current_track: ?Track = null;
    var current_channel: ?Channel = null;
    var current_devices = std.ArrayList(ClapPlugin).empty;
    var current_device: ?ClapPlugin = null;
    var current_device_params = std.ArrayList(RealParameter).empty;
    var current_eq_bands = std.ArrayList(types.EqBand).empty;
    var current_band: ?types.EqBand = null;
    var root_lanes: ?Lanes = null;
    var current_lanes: ?Lanes = null;
    var current_clips: ?Clips = null;
    var clips_list = std.ArrayList(Clip).empty;
    var current_notes: ?Notes = null;
    var notes_list = std.ArrayList(Note).empty;
    var current_points: ?Points = null;
    var points_point_list = std.ArrayList(AutomationPoint).empty;
    var points_target: AutomationTarget = .{};
    var current_scene: ?Scene = null;
    var current_clip_slot: ?ClipSlot = null;
    var clip_slots_list = std.ArrayList(ClipSlot).empty;
    var clip_stack = std.ArrayList(ClipFrame).empty;
    defer {
        for (clip_stack.items) |*frame| {
            frame.points_list.deinit(allocator);
            frame.nested_list.deinit(allocator);
            frame.warp_points.deinit(allocator);
        }
        clip_stack.deinit(allocator);
    }

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
                } else if (isDeviceElement(elem_name) and state == .devices) {
                    state = .device;
                    const xml_kind = deviceXmlKind(elem_name);
                    var device_id = getAttr(reader, "deviceID") orelse "";
                    // Portable DAWproject builtins without deviceID map to Flux stock FX ids
                    if (device_id.len == 0) {
                        device_id = switch (xml_kind) {
                            .equalizer => "com.flux.builtin.equalizer",
                            .compressor => "com.flux.builtin.compressor",
                            .noise_gate => "com.flux.builtin.noise_gate",
                            .limiter => "com.flux.builtin.limiter",
                            .clap => "",
                        };
                    }
                    current_device = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .name = try allocator.dupe(u8, getAttr(reader, "name") orelse getAttr(reader, "deviceName") orelse elem_name),
                        .device_id = try allocator.dupe(u8, device_id),
                        .device_name = try allocator.dupe(u8, getAttr(reader, "deviceName") orelse getAttr(reader, "name") orelse elem_name),
                        .device_role = parseDeviceRole(getAttr(reader, "deviceRole") orelse "audioFX"),
                        .loaded = parseBool(getAttr(reader, "loaded")),
                        .xml_kind = xml_kind,
                    };
                    current_device_params = std.ArrayList(RealParameter).empty;
                    current_eq_bands = std.ArrayList(types.EqBand).empty;
                } else if (std.mem.eql(u8, elem_name, "Band") and state == .device) {
                    state = .eq_band;
                    current_band = .{
                        .band_type = try allocator.dupe(u8, getAttr(reader, "type") orelse "bell"),
                        .order = parseIntAttr(getAttr(reader, "order")),
                        .freq = .{
                            .id = "",
                            .name = "Freq",
                            .value = 1000,
                            .unit = .hertz,
                        },
                    };
                } else if (std.mem.eql(u8, elem_name, "State") and state == .device) {
                    if (current_device) |*dev| {
                        if (getAttr(reader, "path")) |path| {
                            dev.state = .{
                                .path = try allocator.dupe(u8, path),
                                .external = parseBool(getAttr(reader, "external")),
                            };
                        }
                    }
                } else if ((std.mem.eql(u8, elem_name, "BoolParameter") or std.mem.eql(u8, elem_name, "AutoMakeup") or std.mem.eql(u8, elem_name, "Enabled")) and (state == .device or state == .eq_band)) {
                    const param_value = parseBool(getAttr(reader, "value"));
                    const param_id = getAttr(reader, "id") orelse "";
                    const param_name = getAttr(reader, "name") orelse elem_name;
                    if (state == .eq_band) {
                        if (current_band) |*band| {
                            if (std.mem.eql(u8, elem_name, "Enabled") or std.mem.eql(u8, param_name, "Enabled")) {
                                band.enabled = .{
                                    .id = try allocator.dupe(u8, param_id),
                                    .name = try allocator.dupe(u8, "Enabled"),
                                    .value = param_value,
                                };
                            }
                        }
                    } else if (current_device) |*dev| {
                        if (std.mem.eql(u8, elem_name, "AutoMakeup") or std.mem.eql(u8, param_name, "AutoMakeup")) {
                            dev.auto_makeup = .{
                                .id = try allocator.dupe(u8, param_id),
                                .name = try allocator.dupe(u8, "AutoMakeup"),
                                .value = param_value,
                            };
                        }
                    }
                } else if ((std.mem.eql(u8, elem_name, "RealParameter") or
                    std.mem.eql(u8, elem_name, "Volume") or
                    std.mem.eql(u8, elem_name, "Pan") or
                    std.mem.eql(u8, elem_name, "Attack") or
                    std.mem.eql(u8, elem_name, "Release") or
                    std.mem.eql(u8, elem_name, "Threshold") or
                    std.mem.eql(u8, elem_name, "Ratio") or
                    std.mem.eql(u8, elem_name, "InputGain") or
                    std.mem.eql(u8, elem_name, "OutputGain") or
                    std.mem.eql(u8, elem_name, "Range") or
                    std.mem.eql(u8, elem_name, "Freq") or
                    std.mem.eql(u8, elem_name, "Gain") or
                    std.mem.eql(u8, elem_name, "Q")) and (state == .channel or state == .device or state == .eq_band))
                {
                    // Bitwig writes <Volume>/<Pan>; Flux also accepts generic RealParameter.
                    const param_name = getAttr(reader, "name") orelse elem_name;
                    const param_id = getAttr(reader, "id") orelse "";
                    const param_value = parseFloatAttr(getAttr(reader, "value")) orelse 0.0;
                    const param_unit = parseUnit(getAttr(reader, "unit"));
                    const param_min = parseFloatAttr(getAttr(reader, "min"));
                    const param_max = parseFloatAttr(getAttr(reader, "max"));
                    const parameter_id = parseI32Attr(getAttr(reader, "parameterID"));

                    if (state == .eq_band) {
                        if (current_band) |*band| {
                            const rp = RealParameter{
                                .id = try allocator.dupe(u8, param_id),
                                .name = try allocator.dupe(u8, param_name),
                                .value = param_value,
                                .min = param_min,
                                .max = param_max,
                                .unit = param_unit,
                                .parameter_id = parameter_id,
                            };
                            if (std.mem.eql(u8, elem_name, "Freq") or std.mem.eql(u8, param_name, "Freq")) {
                                band.freq = rp;
                            } else if (std.mem.eql(u8, elem_name, "Gain") or std.mem.eql(u8, param_name, "Gain")) {
                                band.gain = rp;
                            } else if (std.mem.eql(u8, elem_name, "Q") or std.mem.eql(u8, param_name, "Q")) {
                                band.q = rp;
                            }
                        }
                    } else if (state == .device) {
                        if (current_device) |*dev| {
                            const rp = RealParameter{
                                .id = try allocator.dupe(u8, param_id),
                                .name = try allocator.dupe(u8, param_name),
                                .value = param_value,
                                .min = param_min,
                                .max = param_max,
                                .unit = param_unit,
                                .parameter_id = parameter_id,
                            };
                            try current_device_params.append(allocator, rp);
                            // Schema-named fields
                            if (std.mem.eql(u8, elem_name, "Threshold") or std.mem.eql(u8, param_name, "Threshold")) {
                                dev.threshold = try cloneRealParam(allocator, &rp);
                            } else if (std.mem.eql(u8, elem_name, "OutputGain") or std.mem.eql(u8, param_name, "OutputGain") or std.mem.eql(u8, param_name, "Output Gain")) {
                                dev.output_gain = try cloneRealParam(allocator, &rp);
                            } else if (std.mem.eql(u8, elem_name, "InputGain") or std.mem.eql(u8, param_name, "InputGain") or std.mem.eql(u8, param_name, "Input Gain")) {
                                dev.input_gain = try cloneRealParam(allocator, &rp);
                            } else if (std.mem.eql(u8, elem_name, "Ratio") or std.mem.eql(u8, param_name, "Ratio")) {
                                dev.ratio = try cloneRealParam(allocator, &rp);
                            } else if (std.mem.eql(u8, elem_name, "Attack") or std.mem.eql(u8, param_name, "Attack")) {
                                dev.attack = try cloneRealParam(allocator, &rp);
                            } else if (std.mem.eql(u8, elem_name, "Release") or std.mem.eql(u8, param_name, "Release")) {
                                dev.release = try cloneRealParam(allocator, &rp);
                            } else if (std.mem.eql(u8, elem_name, "Range") or std.mem.eql(u8, param_name, "Range")) {
                                dev.range = try cloneRealParam(allocator, &rp);
                            }
                        }
                    } else if (current_channel) |*ch| {
                        const is_volume = std.mem.eql(u8, elem_name, "Volume") or std.mem.eql(u8, param_name, "Volume");
                        const is_pan = std.mem.eql(u8, elem_name, "Pan") or std.mem.eql(u8, param_name, "Pan");
                        if (is_volume) {
                            ch.volume = .{
                                .id = try allocator.dupe(u8, param_id),
                                .name = "Volume",
                                .value = param_value,
                                .min = param_min,
                                .max = param_max,
                                .unit = param_unit,
                            };
                        } else if (is_pan) {
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
                } else if ((std.mem.eql(u8, elem_name, "BoolParameter") or std.mem.eql(u8, elem_name, "Mute")) and state == .channel) {
                    const param_name = getAttr(reader, "name") orelse elem_name;
                    const param_id = getAttr(reader, "id") orelse "";
                    const param_value = parseBool(getAttr(reader, "value"));

                    if (current_channel) |*ch| {
                        if (std.mem.eql(u8, elem_name, "Mute") or std.mem.eql(u8, param_name, "Mute")) {
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
                    state = .root_lanes;
                    root_lanes = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .track = null,
                    };
                } else if (std.mem.eql(u8, elem_name, "Lanes") and state == .root_lanes) {
                    state = .track_lanes;
                    current_lanes = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .track = if (getAttr(reader, "track")) |t| try allocator.dupe(u8, t) else null,
                    };
                } else if (std.mem.eql(u8, elem_name, "Clips") and state == .track_lanes) {
                    state = .clips;
                    current_clips = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .clips = &.{},
                    };
                } else if (std.mem.eql(u8, elem_name, "Clip") and (state == .clips or state == .clip_slot or state == .nested_clips)) {
                    const parent: ClipParent = switch (state) {
                        .clips => .arrangement,
                        .clip_slot => .clip_slot,
                        .nested_clips => .nested,
                        else => .arrangement,
                    };
                    const return_state = state;
                    try clip_stack.append(allocator, .{
                        .clip = try parseClipAttrs(allocator, reader),
                        .points_list = .empty,
                        .nested_list = .empty,
                        .warp_points = .empty,
                        .parent = parent,
                        .return_state = return_state,
                    });
                    state = .clip;
                } else if (std.mem.eql(u8, elem_name, "Clips") and state == .clip) {
                    if (clip_stack.items.len > 0) {
                        const top = &clip_stack.items[clip_stack.items.len - 1];
                        top.nested_id = try allocator.dupe(u8, getAttr(reader, "id") orelse "");
                        top.nested_list = .empty;
                    }
                    state = .nested_clips;
                } else if (std.mem.eql(u8, elem_name, "Lanes") and state == .clip) {
                    state = .clip_lanes;
                } else if (std.mem.eql(u8, elem_name, "Warps") and state == .clip) {
                    if (clip_stack.items.len > 0) {
                        const top = &clip_stack.items[clip_stack.items.len - 1];
                        top.warps = .{
                            .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                            .time_unit = parseTimeUnit(getAttr(reader, "timeUnit")),
                            .content_time_unit = parseTimeUnit(getAttr(reader, "contentTimeUnit")) orelse .seconds,
                            .audio = null,
                            .warps = &.{},
                        };
                        top.warp_points = .empty;
                    }
                    state = .warps;
                } else if (std.mem.eql(u8, elem_name, "Audio") and (state == .clip or state == .warps)) {
                    // Working copy lives on frame.audio until </Audio>; then attach to clip or warps.
                    clip_child_state = state;
                    if (clip_stack.items.len > 0) {
                        clip_stack.items[clip_stack.items.len - 1].audio = try parseAudioAttrs(allocator, reader);
                    }
                    state = .audio;
                } else if (std.mem.eql(u8, elem_name, "File") and state == .audio) {
                    if (clip_stack.items.len > 0) {
                        const top = &clip_stack.items[clip_stack.items.len - 1];
                        if (top.audio) |*audio| {
                            if (getAttr(reader, "path")) |path| {
                                audio.file = .{
                                    .path = try allocator.dupe(u8, path),
                                    .external = parseBool(getAttr(reader, "external")),
                                };
                            }
                        }
                    }
                } else if (std.mem.eql(u8, elem_name, "Warp") and state == .warps) {
                    if (clip_stack.items.len > 0) {
                        const top = &clip_stack.items[clip_stack.items.len - 1];
                        try top.warp_points.append(allocator, .{
                            .time = parseFloatAttr(getAttr(reader, "time")) orelse 0.0,
                            .content_time = parseFloatAttr(getAttr(reader, "contentTime")) orelse 0.0,
                        });
                    }
                } else if (std.mem.eql(u8, elem_name, "Notes") and (state == .clip or state == .clip_lanes)) {
                    clip_child_state = state;
                    state = .notes;
                    current_notes = .{
                        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
                        .notes = &.{},
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
                        .points = &.{},
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
                    const value: f64 = @floatFromInt(parseIntAttr(getAttr(reader, "value")) orelse 0);
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
                } else if (std.mem.eql(u8, elem_name, "Band") and state == .eq_band) {
                    state = .device;
                    if (current_band) |band| {
                        try current_eq_bands.append(allocator, band);
                    }
                    current_band = null;
                } else if (isDeviceElement(elem_name) and state == .device) {
                    state = .devices;
                    if (current_device) |dev| {
                        var dev_copy = dev;
                        dev_copy.parameters = try current_device_params.toOwnedSlice(allocator);
                        dev_copy.eq_bands = try current_eq_bands.toOwnedSlice(allocator);
                        try current_devices.append(allocator, dev_copy);
                    }
                    current_device = null;
                    current_device_params = std.ArrayList(RealParameter).empty;
                    current_eq_bands = std.ArrayList(types.EqBand).empty;
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
                    state = .arrangement;
                } else if (std.mem.eql(u8, elem_name, "Lanes") and state == .track_lanes) {
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
                } else if (std.mem.eql(u8, elem_name, "Clips") and state == .nested_clips) {
                    if (clip_stack.items.len > 0) {
                        const top = &clip_stack.items[clip_stack.items.len - 1];
                        top.clip.nested_clips = .{
                            .id = top.nested_id,
                            .clips = try top.nested_list.toOwnedSlice(allocator),
                        };
                        top.nested_list = .empty;
                    }
                    state = .clip;
                } else if (std.mem.eql(u8, elem_name, "Clip") and state == .clip) {
                    if (clip_stack.items.len == 0) {
                        state = .clips;
                    } else {
                        var frame = clip_stack.pop().?;
                        const finished = try finalizeClipFrame(allocator, &frame);

                        switch (frame.parent) {
                            .arrangement => try clips_list.append(allocator, finished),
                            .clip_slot => {
                                if (current_clip_slot) |*slot| {
                                    slot.clip = finished;
                                }
                            },
                            .nested => {
                                if (clip_stack.items.len > 0) {
                                    try clip_stack.items[clip_stack.items.len - 1].nested_list.append(allocator, finished);
                                }
                            },
                        }
                        state = frame.return_state;
                    }
                } else if (std.mem.eql(u8, elem_name, "Warps") and state == .warps) {
                    if (clip_stack.items.len > 0) {
                        const top = &clip_stack.items[clip_stack.items.len - 1];
                        if (top.warps) |*w| {
                            if (top.audio) |a| w.audio = a;
                            w.warps = try top.warp_points.toOwnedSlice(allocator);
                            top.warp_points = .empty;
                            top.clip.warps = w.*;
                            top.warps = null;
                            top.audio = null;
                        }
                    }
                    state = .clip;
                } else if (std.mem.eql(u8, elem_name, "Audio") and state == .audio) {
                    if (clip_stack.items.len > 0) {
                        const top = &clip_stack.items[clip_stack.items.len - 1];
                        if (clip_child_state == .clip) {
                            top.clip.audio = top.audio;
                            top.audio = null;
                        } else if (clip_child_state == .warps) {
                            if (top.warps) |*w| {
                                w.audio = top.audio;
                            }
                            // keep top.audio until </Warps> so File path is not lost if File came first
                        }
                    }
                    state = clip_child_state;
                } else if (std.mem.eql(u8, elem_name, "Notes") and state == .notes) {
                    if (current_notes) |notes| {
                        if (clip_stack.items.len > 0) {
                            var notes_copy = notes;
                            notes_copy.notes = try notes_list.toOwnedSlice(allocator);
                            clip_stack.items[clip_stack.items.len - 1].clip.notes = notes_copy;
                        }
                    }
                    current_notes = null;
                    notes_list = std.ArrayList(Note).empty;
                    state = clip_child_state;
                } else if (std.mem.eql(u8, elem_name, "Points") and state == .points) {
                    if (current_points) |points| {
                        if (clip_stack.items.len > 0) {
                            var points_copy = points;
                            points_copy.target = points_target;
                            points_copy.points = try points_point_list.toOwnedSlice(allocator);
                            try clip_stack.items[clip_stack.items.len - 1].points_list.append(allocator, points_copy);
                        }
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

    proj.tracks = try tracks_list.toOwnedSlice(allocator);
    proj.master_track = master_track;
    proj.scenes = try scenes_list.toOwnedSlice(allocator);

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

fn parseClipAttrs(allocator: std.mem.Allocator, reader: anytype) !Clip {
    return .{
        .time = parseFloatAttr(getAttr(reader, "time")) orelse 0.0,
        .duration = parseFloatAttr(getAttr(reader, "duration")) orelse 4.0,
        .play_start = parseFloatAttr(getAttr(reader, "playStart")) orelse 0.0,
        .play_stop = parseFloatAttr(getAttr(reader, "playStop")),
        .loop_start = parseFloatAttr(getAttr(reader, "loopStart")),
        .loop_end = parseFloatAttr(getAttr(reader, "loopEnd")),
        .content_time_unit = parseTimeUnit(getAttr(reader, "contentTimeUnit")),
        .fade_time_unit = parseTimeUnit(getAttr(reader, "fadeTimeUnit")),
        .fade_in_time = parseFloatAttr(getAttr(reader, "fadeInTime")),
        .fade_out_time = parseFloatAttr(getAttr(reader, "fadeOutTime")),
        .enable = if (getAttr(reader, "enable")) |e| parseBool(e) else true,
        .name = if (getAttr(reader, "name")) |n| try allocator.dupe(u8, n) else null,
    };
}

fn parseAudioAttrs(allocator: std.mem.Allocator, reader: anytype) !Audio {
    return .{
        .id = try allocator.dupe(u8, getAttr(reader, "id") orelse ""),
        .file = .{ .path = "" },
        .duration = parseFloatAttr(getAttr(reader, "duration")) orelse 0.0,
        .sample_rate = parseIntAttr(getAttr(reader, "sampleRate")) orelse 44100,
        .channels = parseIntAttr(getAttr(reader, "channels")) orelse 2,
        .algorithm = if (getAttr(reader, "algorithm")) |a| try allocator.dupe(u8, a) else null,
    };
}

fn finalizeClipFrame(allocator: std.mem.Allocator, frame: *ClipFrame) !Clip {
    var clip = frame.clip;
    clip.points = try frame.points_list.toOwnedSlice(allocator);
    frame.points_list = .empty;

    // If warps were never closed but we have points, finalize here
    if (clip.warps == null and frame.warps != null) {
        var w = frame.warps.?;
        if (frame.audio) |a| w.audio = a;
        if (frame.warp_points.items.len > 0) {
            w.warps = try frame.warp_points.toOwnedSlice(allocator);
            frame.warp_points = .empty;
        }
        clip.warps = w;
    }

    if (clip.audio == null and frame.audio != null and clip.warps == null) {
        clip.audio = frame.audio;
    }

    // Nested clips not yet attached
    if (clip.nested_clips == null and frame.nested_list.items.len > 0) {
        clip.nested_clips = .{
            .id = frame.nested_id,
            .clips = try frame.nested_list.toOwnedSlice(allocator),
        };
        frame.nested_list = .empty;
    }

    frame.warp_points.deinit(allocator);
    frame.points_list.deinit(allocator);
    frame.nested_list.deinit(allocator);

    return clip;
}

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

fn parseI32Attr(s: ?[]const u8) ?i32 {
    return parseIntAttr(s);
}

fn parseBool(s: ?[]const u8) bool {
    const str = s orelse return false;
    return std.mem.eql(u8, str, "true");
}

fn isDeviceElement(name: []const u8) bool {
    return std.mem.eql(u8, name, "ClapPlugin") or
        std.mem.eql(u8, name, "Equalizer") or
        std.mem.eql(u8, name, "Compressor") or
        std.mem.eql(u8, name, "NoiseGate") or
        std.mem.eql(u8, name, "Limiter") or
        std.mem.eql(u8, name, "BuiltinDevice") or
        std.mem.eql(u8, name, "Vst2Plugin") or
        std.mem.eql(u8, name, "Vst3Plugin") or
        std.mem.eql(u8, name, "AuPlugin") or
        std.mem.eql(u8, name, "Device");
}

fn deviceXmlKind(name: []const u8) types.DeviceXmlKind {
    if (std.mem.eql(u8, name, "Equalizer")) return .equalizer;
    if (std.mem.eql(u8, name, "Compressor")) return .compressor;
    if (std.mem.eql(u8, name, "NoiseGate")) return .noise_gate;
    if (std.mem.eql(u8, name, "Limiter")) return .limiter;
    return .clap;
}

fn cloneRealParam(allocator: std.mem.Allocator, p: *const RealParameter) !RealParameter {
    return .{
        .id = try allocator.dupe(u8, p.id),
        .name = try allocator.dupe(u8, p.name),
        .value = p.value,
        .min = p.min,
        .max = p.max,
        .unit = p.unit,
        .parameter_id = p.parameter_id,
    };
}

fn parseContentType(s: ?[]const u8) ContentType {
    const str = s orelse return .notes;
    // Prefer audio when multi-token (e.g. "audio notes")
    if (std.mem.indexOf(u8, str, "audio") != null and std.mem.indexOf(u8, str, "notes") == null) {
        return .audio;
    }
    if (std.mem.eql(u8, str, "audio")) return .audio;
    if (std.mem.eql(u8, str, "automation")) return .automation;
    if (std.mem.eql(u8, str, "notes")) return .notes;
    if (std.mem.eql(u8, str, "video")) return .video;
    if (std.mem.eql(u8, str, "markers")) return .markers;
    if (std.mem.eql(u8, str, "tracks")) return .tracks;
    // "audio notes" master tracks → notes for structure enum; master is detected via role
    if (std.mem.indexOf(u8, str, "audio") != null) return .audio;
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

pub fn parseTimeUnit(s: ?[]const u8) ?TimeUnit {
    const str = s orelse return null;
    if (std.mem.eql(u8, str, "beats")) return .beats;
    if (std.mem.eql(u8, str, "seconds")) return .seconds;
    return null;
}
