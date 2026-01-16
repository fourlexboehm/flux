const std = @import("std");
const clap = @import("clap-bindings");

const ui = @import("ui.zig");
const plugins = @import("plugins.zig");

pub const default_path = "proj.json";

pub const Project = struct {
    version: u32 = 1,
    bpm: f32,
    quantize_index: i32,
    track_count: usize,
    scene_count: usize,
    tracks: []TrackData,
    scenes: []SceneData,
    clips: []ClipData,
};

pub const TrackData = struct {
    name: []const u8,
    volume: f32,
    mute: bool,
    solo: bool,
    device: DeviceData,
};

pub const SceneData = struct {
    name: []const u8,
};

pub const ClipData = struct {
    track: usize,
    scene: usize,
    slot_state: ui.ClipState,
    slot_length: f32,
    piano_length: f32,
    notes: []ui.Note,
};

pub const DeviceData = struct {
    kind: plugins.PluginKind,
    choice_index: i32,
    name: []const u8,
    path: ?[]const u8,
    id: ?[]const u8,
    state_base64: ?[]const u8,
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?std.json.Parsed(Project) {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const max_size: u64 = 32 * 1024 * 1024;
    const size = @min(stat.size, max_size);
    const data = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(data);
    const read_len = try file.readPositionalAll(io, data, 0);

    return try std.json.parseFromSlice(Project, allocator, data[0..read_len], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: *const ui.State,
    catalog: *const plugins.PluginCatalog,
    plugin_ptrs: [ui.track_count]?*const clap.Plugin,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const project = try buildProject(arena.allocator(), state, catalog, plugin_ptrs);
    const json = try std.json.Stringify.valueAlloc(allocator, project, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, json);
}

pub fn apply(project: *const Project, state: *ui.State, catalog: *const plugins.PluginCatalog) !void {
    state.playing = false;
    state.playhead_beat = 0;
    state.bpm = project.bpm;
    state.quantize_index = project.quantize_index;

    state.session.deinit();
    state.session = ui.SessionView.init(state.allocator);

    state.session.track_count = @min(project.track_count, ui.track_count);
    state.session.scene_count = @min(project.scene_count, ui.scene_count);

    for (0..state.session.track_count) |t| {
        if (t < project.tracks.len) {
            const track = project.tracks[t];
            state.session.tracks[t].setName(track.name);
            state.session.tracks[t].volume = track.volume;
            state.session.tracks[t].mute = track.mute;
            state.session.tracks[t].solo = track.solo;
        } else {
            var buf: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "Track {d}", .{t + 1}) catch "Track";
            state.session.tracks[t].setName(label);
        }
    }

    for (0..state.session.scene_count) |s| {
        if (s < project.scenes.len) {
            state.session.scenes[s].setName(project.scenes[s].name);
        } else {
            var buf: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "Scene {d}", .{s + 1}) catch "Scene";
            state.session.scenes[s].setName(label);
        }
    }

    for (&state.piano_clips) |*track_clips| {
        for (track_clips) |*clip| {
            clip.clear();
        }
    }

    for (project.clips) |clip| {
        if (clip.track >= state.session.track_count or clip.scene >= state.session.scene_count) {
            continue;
        }

        const slot_state: ui.ClipState = if (clip.slot_state == .empty and clip.notes.len > 0) .stopped else clip.slot_state;
        const slot_length: f32 = if (clip.slot_state == .empty and clip.notes.len > 0) clip.piano_length else clip.slot_length;
        state.session.clips[clip.track][clip.scene] = .{
            .state = slot_state,
            .length_beats = slot_length,
        };

        var piano = &state.piano_clips[clip.track][clip.scene];
        piano.length_beats = clip.piano_length;
        piano.notes.clearRetainingCapacity();
        for (clip.notes) |note| {
            try piano.notes.append(state.allocator, note);
        }
    }

    for (0..ui.track_count) |t| {
        state.track_plugins[t].choice_index = 0;
        state.track_plugins[t].gui_open = false;
        state.track_plugins[t].last_valid_choice = 0;
    }

    for (0..state.session.track_count) |t| {
        if (t >= project.tracks.len) {
            continue;
        }
        const resolved = resolveDeviceIndex(catalog, project.tracks[t].device);
        state.track_plugins[t].choice_index = resolved;
        state.track_plugins[t].last_valid_choice = resolved;
    }
}

pub fn applyDeviceStates(
    allocator: std.mem.Allocator,
    project: *const Project,
    plugin_ptrs: [ui.track_count]?*const clap.Plugin,
) void {
    for (project.tracks, 0..) |track, t| {
        if (t >= plugin_ptrs.len) break;
        const encoded = track.device.state_base64 orelse continue;
        const plugin = plugin_ptrs[t] orelse continue;
        loadPluginState(allocator, plugin, encoded) catch |err| {
            std.log.warn("Failed to load plugin state for track {d}: {}", .{ t, err });
        };
    }
}

fn buildProject(
    allocator: std.mem.Allocator,
    state: *const ui.State,
    catalog: *const plugins.PluginCatalog,
    plugin_ptrs: [ui.track_count]?*const clap.Plugin,
) !Project {
    const track_count = state.session.track_count;
    const scene_count = state.session.scene_count;

    const tracks = try allocator.alloc(TrackData, track_count);
    for (0..track_count) |t| {
        const track = state.session.tracks[t];
        const name = try allocator.dupe(u8, track.getName());
        const device = try buildDevice(allocator, catalog, state.track_plugins[t].choice_index, plugin_ptrs[t]);
        tracks[t] = .{
            .name = name,
            .volume = track.volume,
            .mute = track.mute,
            .solo = track.solo,
            .device = device,
        };
    }

    const scenes = try allocator.alloc(SceneData, scene_count);
    for (0..scene_count) |s| {
        scenes[s] = .{ .name = try allocator.dupe(u8, state.session.scenes[s].getName()) };
    }

    var clips_list: std.ArrayList(ClipData) = .empty;
    for (0..track_count) |t| {
        for (0..scene_count) |s| {
            const slot = state.session.clips[t][s];
            const piano = &state.piano_clips[t][s];
            const has_notes = piano.notes.items.len > 0;
            if (slot.state == .empty and !has_notes) {
                continue;
            }

            const stored_state: ui.ClipState = if (slot.state == .empty and has_notes) .stopped else slot.state;
            const stored_length: f32 = if (slot.state == .empty and has_notes) piano.length_beats else slot.length_beats;

            const notes = try allocator.alloc(ui.Note, piano.notes.items.len);
            @memcpy(notes, piano.notes.items);

            try clips_list.append(allocator, .{
                .track = t,
                .scene = s,
                .slot_state = stored_state,
                .slot_length = stored_length,
                .piano_length = piano.length_beats,
                .notes = notes,
            });
        }
    }

    return .{
        .bpm = state.bpm,
        .quantize_index = state.quantize_index,
        .track_count = track_count,
        .scene_count = scene_count,
        .tracks = tracks,
        .scenes = scenes,
        .clips = clips_list.items,
    };
}

fn buildDevice(
    allocator: std.mem.Allocator,
    catalog: *const plugins.PluginCatalog,
    choice_index: i32,
    plugin_ptr: ?*const clap.Plugin,
) !DeviceData {
    var device = DeviceData{
        .kind = .none,
        .choice_index = choice_index,
        .name = "",
        .path = null,
        .id = null,
        .state_base64 = null,
    };

    if (catalog.entryForIndex(choice_index)) |entry| {
        device.kind = entry.kind;
        device.name = try allocator.dupe(u8, entry.name);
        if (entry.path) |path| {
            device.path = try allocator.dupe(u8, path);
        }
        if (entry.id) |id| {
            device.id = try allocator.dupe(u8, id);
        }
    }

    if (plugin_ptr) |plugin| {
        if (try capturePluginState(allocator, plugin)) |state| {
            std.log.info("Captured plugin state bytes={d} base64={d}", .{ state.raw_len, state.encoded.len });
            device.state_base64 = state.encoded;
        }
    }

    return device;
}

fn resolveDeviceIndex(catalog: *const plugins.PluginCatalog, device: DeviceData) i32 {
    if (device.kind == .none or device.kind == .divider) {
        return 0;
    }

    if (device.choice_index >= 0) {
        if (catalog.entryForIndex(device.choice_index)) |entry| {
            if (entryMatchesDevice(entry, device)) {
                return device.choice_index;
            }
        }
    }

    for (catalog.entries.items, 0..) |entry, idx| {
        if (entryMatchesDevice(entry, device)) {
            return @intCast(idx);
        }
    }

    return 0;
}

fn entryMatchesDevice(entry: plugins.PluginEntry, device: DeviceData) bool {
    if (entry.kind != device.kind) return false;
    if (device.id) |id| {
        if (entry.id) |entry_id| {
            if (std.mem.eql(u8, entry_id, id)) return true;
        }
    }
    if (device.path) |path| {
        if (entry.path) |entry_path| {
            if (std.mem.eql(u8, entry_path, path)) return true;
        }
    }
    if (device.name.len > 0 and std.mem.eql(u8, entry.name, device.name)) {
        return true;
    }
    return false;
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
        std.mem.copyForwards(u8, dest, self.data[self.offset..][0..to_read]);
        self.offset += to_read;
        return @enumFromInt(@as(i64, @intCast(to_read)));
    }
};

const PluginState = struct {
    encoded: []const u8,
    raw_len: usize,
};

fn capturePluginState(allocator: std.mem.Allocator, plugin: *const clap.Plugin) !?PluginState {
    const ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse return null;
    const ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(ext_raw));

    var stream = MemoryOStream.init(allocator);
    stream.stream.context = &stream;
    defer stream.buffer.deinit(allocator);
    if (!ext.save(plugin, &stream.stream)) {
        std.log.warn("Plugin state save returned false", .{});
        return null;
    }

    const encoded = try encodeBase64(allocator, stream.buffer.items);
    return .{
        .encoded = encoded,
        .raw_len = stream.buffer.items.len,
    };
}

fn loadPluginState(allocator: std.mem.Allocator, plugin: *const clap.Plugin, encoded: []const u8) !void {
    const ext_raw = plugin.getExtension(plugin, clap.ext.state.id) orelse return;
    const ext: *const clap.ext.state.Plugin = @ptrCast(@alignCast(ext_raw));

    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);

    var stream = MemoryIStream.init(decoded);
    stream.stream.context = &stream;
    _ = ext.load(plugin, &stream.stream);
}

fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const out = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(out, data);
    return out;
}
