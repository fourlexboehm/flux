const std = @import("std");
const types = @import("types.zig");
const param_table = @import("flux_param_table");
const BuiltinKind = param_table.Kind;

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

    pub fn writeIndent(self: *Self) !void {
        for (0..self.indent_level) |_| {
            try self.buffer.appendSlice(self.allocator, "  ");
        }
    }

    pub fn writeEscaped(self: *Self, s: []const u8) !void {
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

    pub fn writeAttr(self: *Self, name: []const u8, value: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, " ");
        try self.buffer.appendSlice(self.allocator, name);
        try self.buffer.appendSlice(self.allocator, "=\"");
        try self.writeEscaped(value);
        try self.buffer.appendSlice(self.allocator, "\"");
    }

    pub fn writeAttrFloat(self: *Self, name: []const u8, value: f64) !void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.6}", .{value}) catch return;
        try self.writeAttr(name, s);
    }

    pub fn writeAttrInt(self: *Self, name: []const u8, value: anytype) !void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        try self.writeAttr(name, s);
    }

    pub fn writeAttrBool(self: *Self, name: []const u8, value: bool) !void {
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
        // DAWproject contentType is a space-separated list (hybrid: "audio notes")
        const content_attr = track.content_types_attr orelse track.content_type.toString();
        try self.writeAttr("contentType", content_attr);
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
                try self.writeDevice(&device);
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

    fn writeDevice(self: *Self, device: *const ClapPlugin) !void {
        const tag = device.xml_kind.xmlTag();
        try self.writeIndent();
        try self.buffer.append(self.allocator, '<');
        try self.buffer.appendSlice(self.allocator, tag);
        try self.writeAttr("deviceID", device.device_id);
        try self.writeAttr("deviceName", device.device_name);
        try self.writeAttr("deviceRole", device.device_role.toString());
        try self.writeAttrBool("loaded", device.loaded);
        try self.writeAttr("id", device.id);
        try self.writeAttr("name", device.name);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        if (device.parameters.len > 0) {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<Parameters>\n");
            self.indent_level += 1;
            for (device.parameters) |param| {
                try self.writeRealParameter("RealParameter", &param);
            }
            self.indent_level -= 1;
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "</Parameters>\n");
        }

        // Base device children must precede builtin-specific extension children.
        if (device.enabled) |enabled| {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<Enabled");
            try self.writeAttrBool("value", enabled.value);
            try self.writeAttr("id", enabled.id);
            if (enabled.parameter_id) |pid| try self.writeAttrInt("parameterID", pid);
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

        if (device.xml_kind == .equalizer) {
            for (device.eq_bands) |band| try self.writeEqBand(&band);
        }
        if (kindFromXml(device.xml_kind)) |kind| {
            try self.writeBuiltinSchemaChildren(device, kind);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.append(self.allocator, '<');
        try self.buffer.append(self.allocator, '/');
        try self.buffer.appendSlice(self.allocator, tag);
        try self.buffer.appendSlice(self.allocator, ">\n");
    }

    fn kindFromXml(xml_kind: types.DeviceXmlKind) ?BuiltinKind {
        return switch (xml_kind) {
            .clap => null,
            .equalizer => .equalizer,
            .compressor => .compressor,
            .noise_gate => .noise_gate,
            .limiter => .limiter,
        };
    }

    /// Write device-level schema children in param_table order (XSD sequence).
    fn writeBuiltinSchemaChildren(self: *Self, device: *const ClapPlugin, kind: BuiltinKind) !void {
        for (param_table.params) |row| {
            if (!param_table.kindHas(row, kind)) continue;
            if (row.is_bool) {
                if (boolParamForSchema(device, row.schema)) |b| {
                    try self.writeBoolParameter(row.schema, &b);
                }
            } else if (realParamForSchema(device, row.schema)) |p| {
                try self.writeRealParameter(row.schema, &p);
            }
        }
    }

    fn realParamForSchema(device: *const ClapPlugin, schema: []const u8) ?RealParameter {
        if (std.mem.eql(u8, schema, "Attack")) return device.attack;
        if (std.mem.eql(u8, schema, "Release")) return device.release;
        if (std.mem.eql(u8, schema, "Threshold")) return device.threshold;
        if (std.mem.eql(u8, schema, "Ratio")) return device.ratio;
        if (std.mem.eql(u8, schema, "InputGain")) return device.input_gain;
        if (std.mem.eql(u8, schema, "OutputGain")) return device.output_gain;
        if (std.mem.eql(u8, schema, "Range")) return device.range;
        return null;
    }

    fn boolParamForSchema(device: *const ClapPlugin, schema: []const u8) ?BoolParameter {
        if (std.mem.eql(u8, schema, "AutoMakeup")) return device.auto_makeup;
        return null;
    }

    fn writeEqBand(self: *Self, band: *const types.EqBand) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Band");
        try self.writeAttr("type", band.band_type);
        if (band.order) |o| try self.writeAttrInt("order", o);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;
        try self.writeRealParameter("Freq", &band.freq);
        if (band.gain) |p| try self.writeRealParameter("Gain", &p);
        if (band.q) |p| try self.writeRealParameter("Q", &p);
        if (band.enabled) |p| try self.writeBoolParameter("Enabled", &p);
        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Band>\n");
    }

    fn writeBoolParameter(self: *Self, tag: []const u8, param: *const BoolParameter) !void {
        try self.writeIndent();
        try self.buffer.append(self.allocator, '<');
        try self.buffer.appendSlice(self.allocator, tag);
        try self.writeAttrBool("value", param.value);
        try self.writeAttr("id", param.id);
        if (param.parameter_id) |pid| try self.writeAttrInt("parameterID", pid);
        try self.writeAttr("name", param.name);
        try self.buffer.appendSlice(self.allocator, "/>\n");
    }

    fn writeRealParameter(self: *Self, tag: []const u8, param: *const RealParameter) !void {
        try self.writeIndent();
        try self.buffer.append(self.allocator, '<');
        try self.buffer.appendSlice(self.allocator, tag);
        try self.writeAttr("id", param.id);
        if (param.parameter_id) |pid| try self.writeAttrInt("parameterID", pid);
        try self.writeAttr("name", param.name);
        if (param.min) |min| try self.writeAttrFloat("min", min);
        if (param.max) |max| try self.writeAttrFloat("max", max);
        try self.writeAttr("unit", param.unit.toString());
        try self.writeAttrFloat("value", param.value);
        try self.buffer.appendSlice(self.allocator, "/>\n");
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

    fn writeLanes(self: *Self, lanes: *const Lanes) std.mem.Allocator.Error!void {
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

        if (lanes.notes) |notes| {
            try self.writeNotes(&notes);
        }

        for (lanes.points) |points| {
            try self.writePoints(&points);
        }

        // Clips
        if (lanes.clips) |clips| {
            try self.writeClips(&clips);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Lanes>\n");
    }

    // Explicit error set breaks recursive writeClips ↔ writeClip ↔ writeClipBody inference cycle.
    const WriteError = std.mem.Allocator.Error;

    fn writeClips(self: *Self, clips: *const Clips) WriteError!void {
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

    fn writeClip(self: *Self, clip: *const Clip) WriteError!void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Clip");
        try self.writeClipAttrs(clip);
        if (!clipHasBody(clip)) {
            try self.buffer.appendSlice(self.allocator, "/>\n");
            return;
        }
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;
        try self.writeClipBody(clip);
        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Clip>\n");
    }

    fn writeClipAttrs(self: *Self, clip: *const Clip) WriteError!void {
        try self.writeAttrFloat("time", clip.time);
        try self.writeAttrFloat("duration", clip.duration);
        if (clip.content_time_unit) |tu| try self.writeAttr("contentTimeUnit", tu.toString());
        try self.writeAttrFloat("playStart", clip.play_start);
        if (clip.play_stop) |v| try self.writeAttrFloat("playStop", v);
        if (clip.loop_start) |v| try self.writeAttrFloat("loopStart", v);
        if (clip.loop_end) |v| try self.writeAttrFloat("loopEnd", v);
        if (clip.fade_time_unit) |tu| try self.writeAttr("fadeTimeUnit", tu.toString());
        if (clip.fade_in_time) |v| try self.writeAttrFloat("fadeInTime", v);
        if (clip.fade_out_time) |v| try self.writeAttrFloat("fadeOutTime", v);
        if (!clip.enable) try self.writeAttrBool("enable", false);
        if (clip.name) |name| try self.writeAttr("name", name);
    }

    fn clipHasBody(clip: *const Clip) bool {
        return clip.lanes != null or clip.notes != null or clip.points.len > 0 or
            clip.warps != null or clip.audio != null or clip.nested_clips != null;
    }

    fn writeClipBody(self: *Self, clip: *const Clip) WriteError!void {
        // Prefer nested structure when present (Bitwig-style); else flat content.
        if (clip.nested_clips) |nested| {
            try self.writeClips(&nested);
        } else if (clip.warps) |warps| {
            try self.writeWarps(&warps);
        } else if (clip.audio) |audio| {
            try self.writeAudio(&audio);
        } else if (clip.lanes) |lanes| {
            try self.writeLanes(&lanes);
        } else if (clip.notes) |notes| {
            try self.writeNotes(&notes);
        }
        // Clip-level automation may coexist with any content type.
        for (clip.points) |points| {
            try self.writePoints(&points);
        }
    }

    fn writeWarps(self: *Self, warps: *const Warps) WriteError!void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Warps");
        if (warps.time_unit) |tu| try self.writeAttr("timeUnit", tu.toString());
        try self.writeAttr("contentTimeUnit", warps.content_time_unit.toString());
        if (warps.id.len > 0) try self.writeAttr("id", warps.id);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        if (warps.audio) |audio| {
            try self.writeAudio(&audio);
        }
        for (warps.warps) |wp| {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<Warp");
            try self.writeAttrFloat("time", wp.time);
            try self.writeAttrFloat("contentTime", wp.content_time);
            try self.buffer.appendSlice(self.allocator, "/>\n");
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Warps>\n");
    }

    fn writeAudio(self: *Self, audio: *const Audio) WriteError!void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Audio");
        if (audio.algorithm) |algo| try self.writeAttr("algorithm", algo);
        try self.writeAttrInt("channels", audio.channels);
        try self.writeAttrFloat("duration", audio.duration);
        try self.writeAttrInt("sampleRate", audio.sample_rate);
        if (audio.id.len > 0) try self.writeAttr("id", audio.id);
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<File");
        try self.writeAttr("path", audio.file.path);
        if (audio.file.external) try self.writeAttrBool("external", true);
        try self.buffer.appendSlice(self.allocator, "/>\n");

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Audio>\n");
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

    fn writePoints(self: *Self, points: *const Points) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Points");
        try self.writeAttr("id", points.id);
        if (points.unit) |unit| {
            try self.writeAttr("unit", unit.toString());
        }
        if (points.points.len == 0) {
            try self.buffer.appendSlice(self.allocator, "/>\n");
            return;
        }
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;

        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "<Target");
        if (points.target.parameter) |param| try self.writeAttr("parameter", param);
        if (points.target.expression) |expr| try self.writeAttr("expression", expr);
        if (points.target.channel) |channel| try self.writeAttrInt("channel", channel);
        if (points.target.key) |key| try self.writeAttrInt("key", key);
        if (points.target.controller) |controller| try self.writeAttrInt("controller", controller);
        try self.buffer.appendSlice(self.allocator, "/>\n");

        for (points.points) |point| {
            try self.writeIndent();
            try self.buffer.appendSlice(self.allocator, "<RealPoint");
            try self.writeAttrFloat("time", point.time);
            try self.writeAttrFloat("value", point.value);
            try self.buffer.appendSlice(self.allocator, "/>\n");
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Points>\n");
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
        const loop_start = clip.loop_start orelse 0.0;
        const loop_end = clip.loop_end orelse clip.duration;
        try self.writeAttrFloat("loopStart", loop_start);
        try self.writeAttrFloat("loopEnd", loop_end);
        try self.writeAttrBool("enable", clip.enable);
        if (clip.name) |name| try self.writeAttr("name", name);

        if (!clipHasBody(clip)) {
            try self.buffer.appendSlice(self.allocator, "/>\n");
            return;
        }
        try self.buffer.appendSlice(self.allocator, ">\n");
        self.indent_level += 1;
        try self.writeClipBody(clip);
        self.indent_level -= 1;
        try self.writeIndent();
        try self.buffer.appendSlice(self.allocator, "</Clip>\n");
    }
};

/// Serialize project to XML string
pub fn toXml(allocator: std.mem.Allocator, proj: *const Project) ![]u8 {
    var writer = XmlWriter.init(allocator);
    defer writer.deinit();
    try writer.writeProject(proj);
    return writer.toOwnedSlice();
}
