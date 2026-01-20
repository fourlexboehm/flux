//! DAWproject format support (.dawproject files)
//! DAWproject is an open exchange format for DAW projects.
//! Files are ZIP archives containing project.xml and optional audio/plugin state files.
//!
//! Spec: https://github.com/bitwig/dawproject

const std = @import("std");
const ui = @import("ui.zig");
const plugins = @import("plugins.zig");
const undo = @import("undo/root.zig");

// ============================================================================
// DAWproject Types (subset matching project.xsd)
// ============================================================================

pub const Unit = enum {
    linear,
    normalized,
    percent,
    decibel,
    hertz,
    semitones,
    seconds,
    beats,
    bpm,

    pub fn toString(self: Unit) []const u8 {
        return switch (self) {
            .linear => "linear",
            .normalized => "normalized",
            .percent => "percent",
            .decibel => "decibel",
            .hertz => "hertz",
            .semitones => "semitones",
            .seconds => "seconds",
            .beats => "beats",
            .bpm => "bpm",
        };
    }
};

pub const TimeUnit = enum {
    beats,
    seconds,

    pub fn toString(self: TimeUnit) []const u8 {
        return switch (self) {
            .beats => "beats",
            .seconds => "seconds",
        };
    }
};

pub const MixerRole = enum {
    regular,
    master,
    effect,
    submix,
    vca,

    pub fn toString(self: MixerRole) []const u8 {
        return switch (self) {
            .regular => "regular",
            .master => "master",
            .effect => "effect",
            .submix => "submix",
            .vca => "vca",
        };
    }
};

pub const DeviceRole = enum {
    instrument,
    noteFX,
    audioFX,
    analyzer,

    pub fn toString(self: DeviceRole) []const u8 {
        return switch (self) {
            .instrument => "instrument",
            .noteFX => "noteFX",
            .audioFX => "audioFX",
            .analyzer => "analyzer",
        };
    }
};

pub const ContentType = enum {
    audio,
    automation,
    notes,
    video,
    markers,
    tracks,

    pub fn toString(self: ContentType) []const u8 {
        return switch (self) {
            .audio => "audio",
            .automation => "automation",
            .notes => "notes",
            .video => "video",
            .markers => "markers",
            .tracks => "tracks",
        };
    }
};

/// Real-valued parameter (tempo, volume, pan, etc.)
pub const RealParameter = struct {
    id: []const u8,
    name: []const u8,
    value: f64,
    min: ?f64 = null,
    max: ?f64 = null,
    unit: Unit,
};

/// Boolean parameter (mute, solo, enabled)
pub const BoolParameter = struct {
    id: []const u8,
    name: []const u8,
    value: bool,
};

/// Time signature parameter
pub const TimeSignatureParameter = struct {
    id: []const u8,
    name: []const u8 = "Time Signature",
    numerator: i32,
    denominator: i32,
};

/// File reference (for plugin state, audio files)
pub const FileReference = struct {
    path: []const u8,
    external: bool = false,
};

/// CLAP plugin device
pub const ClapPlugin = struct {
    id: []const u8,
    name: []const u8,
    device_id: []const u8, // e.g. "org.surge-synth-team.surge-xt"
    device_name: []const u8,
    device_role: DeviceRole,
    loaded: bool = true,
    enabled: ?BoolParameter = null,
    state: ?FileReference = null,
};

/// Channel with volume, pan, mute, devices
pub const Channel = struct {
    id: []const u8,
    audio_channels: i32 = 2,
    role: MixerRole = .regular,
    solo: bool = false,
    destination: ?[]const u8 = null, // ID reference to master channel
    volume: ?RealParameter = null,
    pan: ?RealParameter = null,
    mute: ?BoolParameter = null,
    devices: []const ClapPlugin = &.{},
};

/// Track containing a channel
pub const Track = struct {
    id: []const u8,
    name: []const u8,
    color: ?[]const u8 = null,
    content_type: ContentType = .notes,
    loaded: bool = true,
    channel: ?Channel = null,
};

/// MIDI note
pub const Note = struct {
    time: f64, // in beats
    duration: f64,
    channel: i32 = 0,
    key: i32, // MIDI pitch 0-127
    vel: f64 = 0.8, // velocity 0.0-1.0
    rel: f64 = 0.8, // release velocity
};

/// Notes container
pub const Notes = struct {
    id: []const u8,
    notes: []const Note,
};

/// Clip containing notes or other content
pub const Clip = struct {
    time: f64, // start time in beats
    duration: f64,
    play_start: f64 = 0.0,
    name: ?[]const u8 = null,
    notes: ?Notes = null,
};

/// Clips container
pub const Clips = struct {
    id: []const u8,
    clips: []const Clip,
};

/// Lanes (track lanes in arrangement)
pub const Lanes = struct {
    id: []const u8,
    track: ?[]const u8 = null, // ID reference
    time_unit: ?TimeUnit = null,
    clips: ?Clips = null,
    children: []const Lanes = &.{},
};

/// Arrangement (timeline)
pub const Arrangement = struct {
    id: []const u8,
    lanes: ?Lanes = null,
};

/// ClipSlot (for session view - one per track per scene)
pub const ClipSlot = struct {
    id: []const u8,
    track: []const u8, // IDREF to track
    has_stop: bool = true,
    clip: ?Clip = null,
};

/// Scene (for session view)
pub const Scene = struct {
    id: []const u8,
    name: []const u8,
    lanes_id: []const u8, // ID for the Lanes container
    clip_slots: []const ClipSlot = &.{},
};

/// Transport settings
pub const Transport = struct {
    tempo: ?RealParameter = null,
    time_signature: ?TimeSignatureParameter = null,
};

/// Application info
pub const Application = struct {
    name: []const u8,
    version: []const u8,
};

/// Root project structure
pub const Project = struct {
    version: []const u8 = "1.0",
    application: Application,
    transport: ?Transport = null,
    tracks: []const Track = &.{},
    master_track: ?Track = null,
    arrangement: ?Arrangement = null,
    scenes: []const Scene = &.{},
};

// ============================================================================
// XML Writer
// ============================================================================

pub const XmlWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    indent_level: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn toOwnedSlice(self: *Self) ![]u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    fn writeIndent(self: *Self) !void {
        for (0..self.indent_level) |_| {
            try self.buffer.appendSlice(self.allocator, "  ");
        }
    }

    fn writeEscaped(self: *Self, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '<' => try self.buffer.appendSlice(self.allocator, "&lt;"),
                '>' => try self.buffer.appendSlice(self.allocator, "&gt;"),
                '&' => try self.buffer.appendSlice(self.allocator, "&amp;"),
                '"' => try self.buffer.appendSlice(self.allocator, "&quot;"),
                '\'' => try self.buffer.appendSlice(self.allocator, "&apos;"),
                else => try self.buffer.append(self.allocator, c),
            }
        }
    }

    fn writeAttr(self: *Self, name: []const u8, value: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, " ");
        try self.buffer.appendSlice(self.allocator, name);
        try self.buffer.appendSlice(self.allocator, "=\"");
        try self.writeEscaped(value);
        try self.buffer.appendSlice(self.allocator, "\"");
    }

    fn writeAttrFloat(self: *Self, name: []const u8, value: f64) !void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.6}", .{value}) catch return;
        try self.writeAttr(name, s);
    }

    fn writeAttrInt(self: *Self, name: []const u8, value: anytype) !void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        try self.writeAttr(name, s);
    }

    fn writeAttrBool(self: *Self, name: []const u8, value: bool) !void {
        try self.writeAttr(name, if (value) "true" else "false");
    }

    pub fn writeProject(self: *Self, proj: *const Project) !void {
        try self.buffer.appendSlice(self.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n");
        try self.buffer.appendSlice(self.allocator, "<Project");
        try self.writeAttr("version", proj.version);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        // Application
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Application");
        try self.writeAttr("name", proj.application.name);
        try self.writeAttr("version", proj.application.version);
        try self.buffer.appendSlice(self.allocator, "/>\n");

        // Transport
        if (proj.transport) |transport| {
            try self.writeTransport(&transport);
        }

        // Structure (tracks)
        if (proj.tracks.len > 0 or proj.master_track != null) {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<Structure>\n");
            self.indent_level += 1;

            for (proj.tracks) |track| {
                try self.writeTrack(&track);
            }
            if (proj.master_track) |master| {
                try self.writeTrack(&master);
            }

            self.indent_level -= 1;
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "</Structure>\n");
        }

        // Arrangement
        if (proj.arrangement) |arr| {
            try self.writeArrangement(&arr);
        }

        // Scenes
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Scenes");
        if (proj.scenes.len == 0) {
            try self.buffer.appendSlice(self.allocator, "/>\n");
        } else {
            try self.buffer.appendSlice(self.allocator, ">\n");
            self.indent_level += 1;
            for (proj.scenes) |scene| {
                try self.writeScene(&scene);
            }
            self.indent_level -= 1;
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "</Scenes>\n");
        }

        self.indent_level -= 1;
        try self.buffer.appendSlice(self.allocator, "</Project>\n");
    }

    fn writeTransport(self: *Self, transport: *const Transport) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Transport>\n");
        self.indent_level += 1;

        if (transport.tempo) |tempo| {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<Tempo");
            if (tempo.max) |max| try self.writeAttrFloat("max", max);
            if (tempo.min) |min| try self.writeAttrFloat("min", min);
            try self.writeAttr("unit", tempo.unit.toString());
            try self.writeAttrFloat("value", tempo.value);
            try self.writeAttr("id", tempo.id);
            try self.writeAttr("name", tempo.name);
            try self.buffer.appendSlice(self.allocator, "/>\n");
        }

        if (transport.time_signature) |ts| {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<TimeSignature");
            try self.writeAttrInt("denominator", ts.denominator);
            try self.writeAttrInt("numerator", ts.numerator);
            try self.writeAttr("id", ts.id);
            try self.writeAttr("name", ts.name);
            try self.buffer.appendSlice(self.allocator, "/>\n");
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Transport>\n");
    }

    fn writeTrack(self: *Self, track: *const Track) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Track");
        try self.writeAttr("contentType", track.content_type.toString());
        try self.writeAttrBool("loaded", track.loaded);
        try self.writeAttr("id", track.id);
        try self.writeAttr("name", track.name);
        if (track.color) |color| try self.writeAttr("color", color);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        if (track.channel) |channel| {
            try self.writeChannel(&channel);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Track>\n");
    }

    fn writeChannel(self: *Self, channel: *const Channel) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Channel");
        try self.writeAttrInt("audioChannels", channel.audio_channels);
        if (channel.destination) |dest| try self.writeAttr("destination", dest);
        try self.writeAttr("role", channel.role.toString());
        try self.writeAttrBool("solo", channel.solo);
        try self.writeAttr("id", channel.id);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        // Devices
        if (channel.devices.len > 0) {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<Devices>\n");
            self.indent_level += 1;

            for (channel.devices) |device| {
                try self.writeClapPlugin(&device);
            }

            self.indent_level -= 1;
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "</Devices>\n");
        }

        // Mute
        if (channel.mute) |mute| {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<Mute");
            try self.writeAttrBool("value", mute.value);
            try self.writeAttr("id", mute.id);
            try self.writeAttr("name", mute.name);
            try self.buffer.appendSlice(self.allocator, "/>\n");
        }

        // Pan
        if (channel.pan) |pan| {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<Pan");
            if (pan.max) |max| try self.writeAttrFloat("max", max);
            if (pan.min) |min| try self.writeAttrFloat("min", min);
            try self.writeAttr("unit", pan.unit.toString());
            try self.writeAttrFloat("value", pan.value);
            try self.writeAttr("id", pan.id);
            try self.writeAttr("name", pan.name);
            try self.buffer.appendSlice(self.allocator, "/>\n");
        }

        // Volume
        if (channel.volume) |vol| {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<Volume");
            if (vol.max) |max| try self.writeAttrFloat("max", max);
            if (vol.min) |min| try self.writeAttrFloat("min", min);
            try self.writeAttr("unit", vol.unit.toString());
            try self.writeAttrFloat("value", vol.value);
            try self.writeAttr("id", vol.id);
            try self.writeAttr("name", vol.name);
            try self.buffer.appendSlice(self.allocator, "/>\n");
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Channel>\n");
    }

    fn writeClapPlugin(self: *Self, device: *const ClapPlugin) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<ClapPlugin");
        try self.writeAttr("deviceID", device.device_id);
        try self.writeAttr("deviceName", device.device_name);
        try self.writeAttr("deviceRole", device.device_role.toString());
        try self.writeAttrBool("loaded", device.loaded);
        try self.writeAttr("id", device.id);
        try self.writeAttr("name", device.name);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Parameters/>\n");

        if (device.enabled) |enabled| {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<Enabled");
            try self.writeAttrBool("value", enabled.value);
            try self.writeAttr("id", enabled.id);
            try self.writeAttr("name", enabled.name);
            try self.buffer.appendSlice(self.allocator, "/>\n");
        }

        if (device.state) |state| {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<State");
            try self.writeAttr("path", state.path);
            if (state.external) try self.writeAttrBool("external", true);
            try self.buffer.appendSlice(self.allocator, "/>\n");
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</ClapPlugin>\n");
    }

    fn writeArrangement(self: *Self, arr: *const Arrangement) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Arrangement");
        try self.writeAttr("id", arr.id);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        if (arr.lanes) |lanes| {
            try self.writeLanes(&lanes);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Arrangement>\n");
    }

    fn writeLanes(self: *Self, lanes: *const Lanes) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Lanes");
        if (lanes.time_unit) |tu| try self.writeAttr("timeUnit", tu.toString());
        if (lanes.track) |track| try self.writeAttr("track", track);
        try self.writeAttr("id", lanes.id);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        // Child lanes
        for (lanes.children) |child| {
            try self.writeLanes(&child);
        }

        // Clips
        if (lanes.clips) |clips| {
            try self.writeClips(&clips);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Lanes>\n");
    }

    fn writeClips(self: *Self, clips: *const Clips) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Clips");
        try self.writeAttr("id", clips.id);
        if (clips.clips.len == 0) {
            try self.buffer.appendSlice(self.allocator, "/>\n");
            return;
        }
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        for (clips.clips) |clip| {
            try self.writeClip(&clip);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Clips>\n");
    }

    fn writeClip(self: *Self, clip: *const Clip) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Clip");
        try self.writeAttrFloat("time", clip.time);
        try self.writeAttrFloat("duration", clip.duration);
        try self.writeAttrFloat("playStart", clip.play_start);
        if (clip.name) |name| try self.writeAttr("name", name);

        if (clip.notes == null) {
            try self.buffer.appendSlice(self.allocator, "/>\n");
            return;
        }
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        if (clip.notes) |notes| {
            try self.writeNotes(&notes);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Clip>\n");
    }

    fn writeNotes(self: *Self, notes: *const Notes) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Notes");
        try self.writeAttr("id", notes.id);
        if (notes.notes.len == 0) {
            try self.buffer.appendSlice(self.allocator, "/>\n");
            return;
        }
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        for (notes.notes) |note| {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<Note");
            try self.writeAttrFloat("time", note.time);
            try self.writeAttrFloat("duration", note.duration);
            try self.writeAttrInt("channel", note.channel);
            try self.writeAttrInt("key", note.key);
            try self.writeAttrFloat("vel", note.vel);
            try self.writeAttrFloat("rel", note.rel);
            try self.buffer.appendSlice(self.allocator, "/>\n");
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Notes>\n");
    }

    fn writeScene(self: *Self, scene: *const Scene) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Scene");
        try self.writeAttr("id", scene.id);
        try self.writeAttr("name", scene.name);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        // Lanes container for ClipSlots
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Lanes");
        try self.writeAttr("id", scene.lanes_id);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        for (scene.clip_slots) |slot| {
            try self.writeClipSlot(&slot);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Lanes>\n");

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Scene>\n");
    }

    fn writeClipSlot(self: *Self, slot: *const ClipSlot) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<ClipSlot");
        try self.writeAttrBool("hasStop", slot.has_stop);
        try self.writeAttr("track", slot.track);
        try self.writeAttr("id", slot.id);

        if (slot.clip == null) {
            try self.buffer.appendSlice(self.allocator, "/>\n");
            return;
        }

        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        // Write the clip with session-style attributes
        if (slot.clip) |clip| {
            try self.writeSessionClip(&clip);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</ClipSlot>\n");
    }

    fn writeSessionClip(self: *Self, clip: *const Clip) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Clip");
        try self.writeAttrFloat("time", clip.time);
        try self.writeAttrFloat("duration", clip.duration);
        try self.writeAttrFloat("playStart", clip.play_start);
        try self.writeAttrFloat("loopStart", 0.0);
        try self.writeAttrFloat("loopEnd", clip.duration);
        try self.writeAttrBool("enable", true);
        if (clip.name) |name| try self.writeAttr("name", name);

        if (clip.notes == null) {
            try self.buffer.appendSlice(self.allocator, "/>\n");
            return;
        }
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        if (clip.notes) |notes| {
            try self.writeNotes(&notes);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Clip>\n");
    }
};

// ============================================================================
// Conversion from Flux Project
// ============================================================================

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
    state: *const ui.State,
    catalog: *const plugins.PluginCatalog,
    track_plugin_info: []const TrackPluginInfo,
) !Project {
    var ids = IdGenerator{ .allocator = allocator };

    // Build tracks
    var tracks_list = std.ArrayList(Track).empty;
    var track_lanes = std.ArrayList(Lanes).empty;
    var track_ids = std.ArrayList([]const u8).empty; // Store track IDs for ClipSlot references

    const master_channel_id = try ids.next();

    for (0..state.session.track_count) |t| {
        const track_data = state.session.tracks[t];
        const track_id = try ids.next();
        try track_ids.append(allocator, track_id);
        const channel_id = try ids.next();

        // Build device if present
        var devices = std.ArrayList(ClapPlugin).empty;
        const choice_index = state.track_plugins[t].choice_index;
        if (catalog.entryForIndex(choice_index)) |entry| {
            if (entry.kind == .clap) {
                const device_id = try ids.next();
                const enabled_id = try ids.next();

                // Get plugin ID and state path from track_plugin_info if available
                const info = if (t < track_plugin_info.len) track_plugin_info[t] else TrackPluginInfo{};
                // Prefer plugin ID from loaded plugin, fall back to catalog entry
                const clap_plugin_id = info.plugin_id orelse entry.id orelse "";

                try devices.append(allocator, .{
                    .id = device_id,
                    .name = try allocator.dupe(u8, entry.name),
                    .device_id = try allocator.dupe(u8, clap_plugin_id),
                    .device_name = try allocator.dupe(u8, entry.name),
                    .device_role = .instrument,
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
                .value = 1.0,
                .min = 0.0,
                .max = 2.0,
                .unit = .linear,
            },
            .mute = .{
                .id = master_mute_id,
                .name = "Mute",
                .value = false,
            },
            .pan = .{
                .id = master_pan_id,
                .name = "Pan",
                .value = 0.5,
                .min = 0.0,
                .max = 1.0,
                .unit = .normalized,
            },
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
                        .vel = 0.8,
                        .rel = 0.8,
                    });
                }

                const clip_duration = if (slot.state != .empty) slot.length_beats else piano.length_beats;
                const notes_id = try ids.next();

                try clip_slots.append(allocator, .{
                    .id = clip_slot_id,
                    .track = track_ids.items[t],
                    .has_stop = true,
                    .clip = .{
                        .time = 0.0,
                        .duration = clip_duration,
                        .play_start = 0.0,
                        .name = null,
                        .notes = .{
                            .id = notes_id,
                            .notes = try daw_notes.toOwnedSlice(allocator),
                        },
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

/// Serialize project to XML string
pub fn toXml(allocator: std.mem.Allocator, proj: *const Project) ![]u8 {
    var writer = XmlWriter.init(allocator);
    defer writer.deinit();
    try writer.writeProject(proj);
    return writer.toOwnedSlice();
}

// ============================================================================
// ZIP Writer (std.zip only supports reading)
// ============================================================================

const ZipWriter = struct {
    const FileEntry = struct {
        name: []const u8,
        data: []const u8,
        crc32: u32,
        offset: u32,
    };

    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    entries: std.ArrayList(FileEntry),

    fn init(allocator: std.mem.Allocator) ZipWriter {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .entries = .empty,
        };
    }

    fn deinit(self: *ZipWriter) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
    }

    // Helper to write little-endian values
    fn writeU16(self: *ZipWriter, val: u16) !void {
        try self.buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, val)));
    }

    fn writeU32(self: *ZipWriter, val: u32) !void {
        try self.buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, val)));
    }

    fn addFile(self: *ZipWriter, name: []const u8, data: []const u8) !void {
        const offset: u32 = @intCast(self.buffer.items.len);
        const crc = std.hash.Crc32.hash(data);
        const size: u32 = @intCast(data.len);

        // Write local file header (30 bytes + filename)
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 'P', 'K', 3, 4 }); // signature
        try self.writeU16(20); // version needed
        try self.writeU16(0); // flags
        try self.writeU16(0); // compression (store)
        try self.writeU16(0); // mod time
        try self.writeU16(0); // mod date
        try self.writeU32(crc); // crc32
        try self.writeU32(size); // compressed size
        try self.writeU32(size); // uncompressed size
        try self.writeU16(@intCast(name.len)); // filename length
        try self.writeU16(0); // extra field length
        try self.buffer.appendSlice(self.allocator, name); // filename
        try self.buffer.appendSlice(self.allocator, data); // file data

        // Store entry for central directory
        try self.entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .data = data,
            .crc32 = crc,
            .offset = offset,
        });
    }

    fn finish(self: *ZipWriter) ![]const u8 {
        const central_offset: u32 = @intCast(self.buffer.items.len);

        // Write central directory entries
        for (self.entries.items) |entry| {
            try self.buffer.appendSlice(self.allocator, &[_]u8{ 'P', 'K', 1, 2 }); // signature
            try self.writeU16(20); // version made by
            try self.writeU16(20); // version needed
            try self.writeU16(0); // flags
            try self.writeU16(0); // compression
            try self.writeU16(0); // mod time
            try self.writeU16(0); // mod date
            try self.writeU32(entry.crc32); // crc32
            try self.writeU32(@intCast(entry.data.len)); // compressed size
            try self.writeU32(@intCast(entry.data.len)); // uncompressed size
            try self.writeU16(@intCast(entry.name.len)); // filename length
            try self.writeU16(0); // extra field length
            try self.writeU16(0); // comment length
            try self.writeU16(0); // disk number start
            try self.writeU16(0); // internal file attributes
            try self.writeU32(0); // external file attributes
            try self.writeU32(entry.offset); // local header offset
            try self.buffer.appendSlice(self.allocator, entry.name); // filename
        }

        const central_size: u32 = @intCast(self.buffer.items.len - central_offset);
        const num_entries: u16 = @intCast(self.entries.items.len);

        // Write end of central directory (22 bytes)
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 'P', 'K', 5, 6 }); // signature
        try self.writeU16(0); // disk number
        try self.writeU16(0); // disk with central dir
        try self.writeU16(num_entries); // entries on this disk
        try self.writeU16(num_entries); // total entries
        try self.writeU32(central_size); // central directory size
        try self.writeU32(central_offset); // central directory offset
        try self.writeU16(0); // comment length

        return self.buffer.items;
    }
};

// ============================================================================
// Save/Load Functions
// ============================================================================

pub const PluginStateFile = struct {
    path: []const u8, // e.g. "plugins/abc123.clap-preset"
    data: []const u8, // raw binary state
};

/// Plugin info for a track, used when building the DAWproject
pub const TrackPluginInfo = struct {
    plugin_id: ?[]const u8 = null, // CLAP plugin ID, e.g. "com.digital-suburban.dexed"
    state_path: ?[]const u8 = null, // Path in ZIP, e.g. "plugins/track0.clap-preset"
};

/// Save project to a .dawproject file (ZIP archive)
/// Structure:
///   myproject.dawproject (ZIP)
///   ├── project.xml
///   ├── plugins/
///   │   └── {uuid}.clap-preset
///   └── metadata.xml (optional)
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: *const ui.State,
    catalog: *const plugins.PluginCatalog,
    plugin_states: []const PluginStateFile,
    track_plugin_info: []const TrackPluginInfo,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const daw_project = try fromFluxProject(arena.allocator(), state, catalog, track_plugin_info);
    const xml = try toXml(arena.allocator(), &daw_project);

    // Debug: also write raw XML for inspection
    if (std.Io.Dir.cwd().createFile(io, "debug_project.xml", .{ .truncate = true })) |*debug_file| {
        defer debug_file.close(io);
        var dbuf: [8192]u8 = undefined;
        var dw = debug_file.writer(io, &dbuf);
        dw.interface.writeAll(xml) catch {};
        dw.interface.flush() catch {};
    } else |_| {}

    // Build ZIP in memory
    var zip_writer = ZipWriter.init(arena.allocator());
    defer zip_writer.deinit();

    // Add project.xml
    try zip_writer.addFile("project.xml", xml);

    // Bitwig expects metadata.xml to exist; include an empty template.
    const metadata_xml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
        "<MetaData>\n" ++
        "    <Title></Title>\n" ++
        "    <Artist></Artist>\n" ++
        "    <Album></Album>\n" ++
        "    <OriginalArtist></OriginalArtist>\n" ++
        "    <Songwriter></Songwriter>\n" ++
        "    <Producer></Producer>\n" ++
        "    <Year></Year>\n" ++
        "    <Genre></Genre>\n" ++
        "    <Copyright></Copyright>\n" ++
        "    <Comment></Comment>\n" ++
        "</MetaData>\n";
    try zip_writer.addFile("metadata.xml", metadata_xml);

    const undo_xml = undo.serializeToXml(arena.allocator(), &state.undo_history) catch |err| blk: {
        std.log.warn("Failed to serialize undo history: {}", .{err});
        break :blk null;
    };
    if (undo_xml) |data| {
        try zip_writer.addFile("flux_undo.xml", data);
    }

    // Add plugin state files
    for (plugin_states) |ps| {
        try zip_writer.addFile(ps.path, ps.data);
    }

    const zip_data = try zip_writer.finish();

    // Write to file
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var fw = file.writer(io, &write_buf);
    try fw.interface.writeAll(zip_data);
    try fw.interface.flush();
}

/// Load project from a .dawproject file (ZIP archive)
/// Returns the parsed Project structure
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !LoadedProject {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    return loadFromFile(allocator, io, file);
}

pub const LoadedProject = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    project: Project,
    plugin_states: std.StringHashMap([]const u8),

    pub fn deinit(self: *LoadedProject) void {
        self.plugin_states.deinit();
        self.arena.deinit();
    }
};

fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !LoadedProject {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // Create a File.Reader for the ZIP
    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);

    // Create temp directory for extraction
    var tmp_dir = try std.Io.Dir.cwd().createDirPathOpen(io, ".dawproject_tmp", .{});
    defer {
        tmp_dir.close(io);
        // Clean up temp directory
        std.Io.Dir.cwd().deleteTree(io, ".dawproject_tmp") catch {};
    }

    // Extract ZIP contents
    std.zip.extract(tmp_dir, &file_reader, .{
        .allow_backslashes = true,
    }) catch |err| {
        std.log.err("ZIP extract failed: {}", .{err});
        return error.ZipExtractFailed;
    };

    // Read project.xml
    var project_xml_file = tmp_dir.openFile(io, "project.xml", .{}) catch {
        return error.MissingProjectXml;
    };
    defer project_xml_file.close(io);

    const xml_stat = try project_xml_file.stat(io);
    const project_xml = try arena.allocator().alloc(u8, xml_stat.size);
    const xml_bytes = try project_xml_file.readPositionalAll(io, project_xml, 0);
    if (xml_bytes != xml_stat.size) return error.UnexpectedEof;

    // Read plugin state files from plugins/ directory
    var plugin_states = std.StringHashMap([]const u8).init(arena.allocator());

    if (tmp_dir.openDir(io, "plugins", .{})) |*plugins_dir| {
        defer plugins_dir.close(io);

        var dir_iter = plugins_dir.iterate();
        while (try dir_iter.next(io)) |entry| {
            if (entry.kind == .file) {
                const full_path = try std.fmt.allocPrint(arena.allocator(), "plugins/{s}", .{entry.name});

                var plugin_file = try plugins_dir.openFile(io, entry.name, .{});
                defer plugin_file.close(io);

                const plugin_stat = try plugin_file.stat(io);
                const plugin_data = try arena.allocator().alloc(u8, plugin_stat.size);
                const bytes = try plugin_file.readPositionalAll(io, plugin_data, 0);
                if (bytes != plugin_stat.size) return error.UnexpectedEof;

                try plugin_states.put(full_path, plugin_data);
            }
        }
    } else |_| {
        // No plugins directory, that's OK
    }

    // Parse the XML
    const parsed_project = try parseProjectXml(arena.allocator(), project_xml);

    return .{
        .allocator = allocator,
        .arena = arena,
        .project = parsed_project,
        .plugin_states = plugin_states,
    };
}

// ============================================================================
// XML Parsing
// ============================================================================

fn parseProjectXml(allocator: std.mem.Allocator, xml_data: []const u8) !Project {
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
        scenes,
        scene,
        scene_lanes,
        clip_slot,
    };
    var state: ParseState = .root;

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
                    current_clip = .{
                        .time = parseFloatAttr(getAttr(reader, "time")) orelse 0.0,
                        .duration = parseFloatAttr(getAttr(reader, "duration")) orelse 4.0,
                        .play_start = parseFloatAttr(getAttr(reader, "playStart")) orelse 0.0,
                        .name = if (getAttr(reader, "name")) |n| try allocator.dupe(u8, n) else null,
                    };
                } else if (std.mem.eql(u8, elem_name, "Notes") and state == .clip) {
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
                        if (clip_context == .arrangement) {
                            try clips_list.append(allocator, clip);
                        } else if (clip_context == .clip_slot) {
                            if (current_clip_slot) |*slot| {
                                slot.clip = clip;
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

fn parseUnit(s: ?[]const u8) Unit {
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

// ============================================================================
// Tests
// ============================================================================

test "xml escaping" {
    const allocator = std.testing.allocator;
    var writer = XmlWriter.init(allocator);
    defer writer.deinit();

    try writer.writeEscaped("Hello <World> & \"Test\"");
    const result = try writer.toOwnedSlice();
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello &lt;World&gt; &amp; &quot;Test&quot;", result);
}

test "basic project xml" {
    const allocator = std.testing.allocator;

    const proj = Project{
        .application = .{ .name = "Test", .version = "1.0" },
        .transport = .{
            .tempo = .{
                .id = "id0",
                .name = "Tempo",
                .value = 120.0,
                .unit = .bpm,
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<?xml version=\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Project version=\"1.0\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "Tempo") != null);
}
