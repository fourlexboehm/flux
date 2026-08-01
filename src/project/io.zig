const std = @import("std");
const plugins = @import("../plugin/plugins.zig");
const undo = @import("../undo/root.zig");
const types = @import("format/types.zig");
const convert = @import("convert.zig");
const xml_writer = @import("format/xml_writer.zig");
const zip_writer = @import("format/zip_writer.zig");
const parse = @import("format/parse.zig");
const io_types = @import("io_types.zig");
const media_layout = @import("media/layout.zig");
const media_flush = @import("media/flush.zig");
const flatten = @import("format/flatten.zig");
const sample_store_mod = @import("../audio/sample_store.zig");

const Project = types.Project;
const TrackPluginInfo = io_types.TrackPluginInfo;
const PluginStateFile = io_types.PluginStateFile;
const ZipWriter = zip_writer.ZipWriter;
const fromFluxProject = convert.fromFluxProject;
const toXml = xml_writer.toXml;
const Dir = std.Io.Dir;
const WarpPoint = types.WarpPoint;
const Clip = types.Clip;
const max_fx_slots = @import("../audio/engine_ui.zig").max_fx_slots;

pub const LoadedProject = struct {
    arena: std.heap.ArenaAllocator,
    project: Project,
    plugin_states: std.StringHashMap([]const u8),
    /// XML path → absolute filesystem path for decode (external or hydrated).
    media_abs_paths: std.StringHashMap([]const u8),
    /// XML path → project-relative path after hydrate (e.g. samples/kick.wav).
    media_rel_paths: std.StringHashMap([]const u8),
    /// Directory containing the .dawproject file.
    project_dir: []const u8,
    /// Packed/Bitwig project was converted to external layout; next Save should thin-write.
    needs_thin_save: bool,
    /// Optional flux_undo.xml bytes from the archive (restored by runtime/load.zig).
    undo_xml: ?[]const u8 = null,
    /// Embedded media still in RAM when hydrate-to-disk was skipped (path → bytes).
    embedded_media: std.StringHashMap([]const u8),

    pub fn deinit(self: *LoadedProject) void {
        self.arena.deinit();
    }
};

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

/// Thin Save: small ZIP + media under samples/recordings beside the project.
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: anytype,
    catalog: *const plugins.PluginCatalog,
    plugin_states: []const PluginStateFile,
    track_plugin_info: []const TrackPluginInfo,
    track_fx_plugin_info: []const [max_fx_slots]TrackPluginInfo,
) !void {
    const project_dir = try media_layout.projectDir(allocator, path);
    defer allocator.free(project_dir);

    // Previous project dir (Save As): copy disk-backed samples from here when dest is empty.
    var prev_dir_owned: ?[]u8 = null;
    defer if (prev_dir_owned) |p| allocator.free(p);
    const prev_dir: ?[]const u8 = blk: {
        const old_path = state.project_path orelse break :blk null;
        // Same destination → no separate prev dir.
        if (std.mem.eql(u8, old_path, path)) break :blk null;
        const old_dir = try media_layout.projectDir(allocator, old_path);
        if (std.mem.eql(u8, old_dir, project_dir)) {
            allocator.free(old_dir);
            break :blk null;
        }
        prev_dir_owned = old_dir;
        break :blk old_dir;
    };

    try media_layout.ensureMediaDirs(io, project_dir);
    try flushReferencedSamples(allocator, io, project_dir, prev_dir, state);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const daw_project = try fromFluxProject(
        arena.allocator(),
        state,
        catalog,
        track_plugin_info,
        track_fx_plugin_info,
        .external,
    );
    const xml = try toXml(arena.allocator(), &daw_project);

    if (Dir.cwd().createFile(io, "debug_project.xml", .{ .truncate = true })) |*debug_file| {
        defer debug_file.close(io);
        var dbuf: [8192]u8 = undefined;
        var dw = debug_file.writer(io, &dbuf);
        dw.interface.writeAll(xml) catch {};
        dw.interface.flush() catch {};
    } else |_| {}

    var zip = ZipWriter.init(arena.allocator());
    defer zip.deinit();

    try zip.addFile("project.xml", xml);
    try zip.addFile("metadata.xml", metadata_xml);

    if (comptime @hasField(@TypeOf(state.*), "undo_history")) {
        const undo_xml = undo.serializeToXml(arena.allocator(), &state.undo_history) catch |err| blk: {
            std.log.warn("Failed to serialize undo history: {}", .{err});
            break :blk null;
        };
        if (undo_xml) |data| try zip.addFile("flux_undo.xml", data);
    }

    for (plugin_states) |ps| {
        try zip.addFile(ps.path, ps.data);
    }

    // Thin: never embed samples/ or recordings/
    const zip_data = try zip.finish();
    try writeZipAtomic(allocator, io, path, zip_data);
}

/// Pack Project…: self-contained dawproject with embedded audio.
pub fn pack(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: anytype,
    catalog: *const plugins.PluginCatalog,
    plugin_states: []const PluginStateFile,
    track_plugin_info: []const TrackPluginInfo,
    track_fx_plugin_info: []const [max_fx_slots]TrackPluginInfo,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Remap sample paths → unique audio/… zip members for XML + archive.
    var pack_path_by_id = std.AutoHashMap(u32, []const u8).init(aa);
    var used_names = std.StringHashMap(void).init(aa);
    var originals: std.ArrayList(struct { id: u32, path: []const u8 }) = .empty;

    // Session audio clips
    for (0..state.session.track_count) |t| {
        for (0..state.session.scene_count) |s| {
            const clip = state.slotAudioConst(t, s) orelse continue;
            const sample_id = clip.sample_id orelse continue;
            if (pack_path_by_id.contains(sample_id)) continue;
            const asset = state.sample_store.get(sample_id) orelse continue;
            const base = std.fs.path.basename(asset.path_in_project);
            const member = try uniquePackMember(aa, &used_names, base);
            try pack_path_by_id.put(sample_id, member);
            try originals.append(aa, .{
                .id = sample_id,
                .path = try aa.dupe(u8, asset.path_in_project),
            });
        }
    }
    // Arrangement clip audio (pooled clips referenced by placements). Samples
    // live in the shared `sample_store`; collect any only referenced here.
    for (state.arrangement.tracks.items) |arr_track| {
        for (arr_track.clips.items) |*arr_clip| {
            const audio = state.arrangement.placementAudio(arr_clip) orelse continue;
            const sample_id = audio.sample_id orelse continue;
            if (pack_path_by_id.contains(sample_id)) continue;
            const asset = state.sample_store.get(sample_id) orelse continue;
            const base = std.fs.path.basename(asset.path_in_project);
            const member = try uniquePackMember(aa, &used_names, base);
            try pack_path_by_id.put(sample_id, member);
            try originals.append(aa, .{
                .id = sample_id,
                .path = try aa.dupe(u8, asset.path_in_project),
            });
        }
    }

    // Collect media bytes before path rewrite (uses current path_in_project).
    const project_dir: ?[]const u8 = if (state.project_path) |pp|
        try media_layout.projectDir(aa, pp)
    else
        null;

    var media_for_zip: std.ArrayList(struct { member: []const u8, data: []const u8 }) = .empty;
    {
        var it = pack_path_by_id.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const member = entry.value_ptr.*;
            const asset = state.sample_store.get(id) orelse continue;
            const abs: ?[]const u8 = blk: {
                if (asset.source_bytes != null) break :blk null;
                if (project_dir) |pd| {
                    break :blk try media_layout.joinRel(aa, pd, asset.path_in_project);
                }
                break :blk null;
            };
            const bytes = state.sample_store.readSourceForPack(id, abs, io, aa) catch |err| {
                std.log.err("Pack: missing media for {s}: {}", .{ asset.path_in_project, err });
                return error.MissingMediaForPack;
            };
            try media_for_zip.append(aa, .{ .member = member, .data = bytes });
        }
    }

    // Temporarily set pack paths for XML, then restore sample_store paths.
    // Arrangement placements resolve audio via `sample_id` → sample_store, so
    // rewriting the store paths below covers both views (no per-clip rewrite).
    defer {
        for (originals.items) |item| {
            state.sample_store.setPathInProject(item.id, item.path) catch {};
        }
    }
    {
        var it = pack_path_by_id.iterator();
        while (it.next()) |entry| {
            try state.sample_store.setPathInProject(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    const daw_project = try fromFluxProject(
        aa,
        state,
        catalog,
        track_plugin_info,
        track_fx_plugin_info,
        .embedded,
    );
    const xml = try toXml(aa, &daw_project);

    var zip = ZipWriter.init(aa);
    defer zip.deinit();
    try zip.addFile("project.xml", xml);
    try zip.addFile("metadata.xml", metadata_xml);

    if (comptime @hasField(@TypeOf(state.*), "undo_history")) {
        if (undo.serializeToXml(aa, &state.undo_history) catch null) |data| try zip.addFile("flux_undo.xml", data);
    }
    for (plugin_states) |ps| {
        try zip.addFile(ps.path, ps.data);
    }
    for (media_for_zip.items) |m| {
        try zip.addFile(m.member, m.data);
    }

    const zip_data = try zip.finish();
    try writeZipAtomic(allocator, io, path, zip_data);
}

/// Load project from a .dawproject file (ZIP archive).
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !LoadedProject {
    var file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return loadFromFile(allocator, io, file, path);
}

fn loadFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    project_path: []const u8,
) !LoadedProject {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const project_dir = try media_layout.projectDir(aa, project_path);

    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);

    const tmp_extract_path = "/tmp/flux_dawproject_tmp";
    Dir.cwd().deleteTree(io, tmp_extract_path) catch {};
    // .iterate required: loadMediaTree / plugins dir walk (Linux BADF without it).
    var tmp_dir = try Dir.cwd().createDirPathOpen(io, tmp_extract_path, .{
        .open_options = .{ .iterate = true },
    });
    defer {
        tmp_dir.close(io);
        Dir.cwd().deleteTree(io, tmp_extract_path) catch {};
    }

    std.zip.extract(tmp_dir, &file_reader, .{
        .allow_backslashes = true,
    }) catch |err| {
        std.log.err("ZIP extract failed: {}", .{err});
        return error.ZipExtractFailed;
    };

    var project_xml_file = tmp_dir.openFile(io, "project.xml", .{}) catch {
        return error.MissingProjectXml;
    };
    defer project_xml_file.close(io);

    const xml_stat = try project_xml_file.stat(io);
    const project_xml = try aa.alloc(u8, xml_stat.size);
    const xml_bytes = try project_xml_file.readPositionalAll(io, project_xml, 0);
    if (xml_bytes != xml_stat.size) return error.UnexpectedEof;

    var plugin_states = std.StringHashMap([]const u8).init(aa);
    if (tmp_dir.openDir(io, "plugins", .{ .iterate = true })) |*plugins_dir| {
        defer plugins_dir.close(io);
        var dir_iter = plugins_dir.iterate();
        while (try dir_iter.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const full_path = try std.fmt.allocPrint(aa, "plugins/{s}", .{entry.name});
            var plugin_file = try plugins_dir.openFile(io, entry.name, .{});
            defer plugin_file.close(io);
            const plugin_stat = try plugin_file.stat(io);
            const plugin_data = try aa.alloc(u8, plugin_stat.size);
            const n = try plugin_file.readPositionalAll(io, plugin_data, 0);
            if (n != plugin_stat.size) return error.UnexpectedEof;
            try plugin_states.put(full_path, plugin_data);
        }
    } else |_| {}

    var undo_xml: ?[]const u8 = null;
    if (tmp_dir.openFile(io, "flux_undo.xml", .{})) |*uf| {
        defer uf.close(io);
        const st = try uf.stat(io);
        const data = try aa.alloc(u8, st.size);
        const n = try uf.readPositionalAll(io, data, 0);
        if (n == st.size) undo_xml = data;
    } else |_| {}

    // Embedded media tree from zip (path → bytes); not used for external refs.
    var embedded_media = std.StringHashMap([]const u8).init(aa);
    try loadMediaTree(aa, io, tmp_dir, "", &embedded_media);

    const parsed_project = try parse.parseProjectXml(aa, project_xml);

    var media_abs_paths = std.StringHashMap([]const u8).init(aa);
    var media_rel_paths = std.StringHashMap([]const u8).init(aa);
    var needs_thin_save = false;

    // Collect unique audio file refs from the project tree.
    var audio_paths: std.ArrayList([]const u8) = .empty;
    try collectProjectAudioPaths(aa, &parsed_project, &audio_paths);

    // Writable project dir? Prefer hydrate beside the file.
    const dir_writable = blk: {
        Dir.cwd().createDirPath(io, project_dir) catch break :blk false;
        break :blk true;
    };

    for (audio_paths.items) |xml_path_raw| {
        // Normalize path separators for consistent map keys.
        const xml_path = try aa.dupe(u8, xml_path_raw);
        for (xml_path) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        if (media_abs_paths.contains(xml_path)) continue;

        // Prefer external resolve if file exists beside project; else try embedded.
        const external_abs = if (media_layout.isSafeRelativePath(xml_path))
            media_layout.joinRel(aa, project_dir, xml_path) catch null
        else
            null;

        if (external_abs) |abs| {
            if (Dir.cwd().statFile(io, abs, .{})) |_| {
                try media_abs_paths.put(xml_path, abs);
                try media_rel_paths.put(xml_path, try aa.dupe(u8, xml_path));
                continue;
            } else |_| {}
        }

        // Embedded media must match the normalized XML path exactly.
        const bytes = embedded_media.get(xml_path) orelse {
            std.log.warn("Audio media missing: {s}", .{xml_path});
            continue;
        };

        if (dir_writable) {
            media_layout.ensureMediaDirs(io, project_dir) catch {};
            const base = std.fs.path.basename(xml_path);
            if (media_layout.writeMediaUnique(aa, io, project_dir, media_layout.samples_dir, base, bytes)) |rel| {
                const abs = try media_layout.joinRel(aa, project_dir, rel);
                try media_abs_paths.put(xml_path, abs);
                try media_rel_paths.put(xml_path, rel);
                needs_thin_save = true;
                std.log.info("Hydrated embedded media {s} → {s}", .{ xml_path, rel });
                continue;
            } else |err| {
                std.log.warn("Failed to hydrate {s}: {}", .{ xml_path, err });
            }
        }
        // Fallback: keep embedded bytes for decode (path stays archive-relative).
        try media_rel_paths.put(xml_path, try aa.dupe(u8, xml_path));
        needs_thin_save = true;
    }

    return .{
        .arena = arena,
        .project = parsed_project,
        .plugin_states = plugin_states,
        .media_abs_paths = media_abs_paths,
        .media_rel_paths = media_rel_paths,
        .project_dir = project_dir,
        .needs_thin_save = needs_thin_save,
        .undo_xml = undo_xml,
        .embedded_media = embedded_media,
    };
}

fn writeZipAtomic(allocator: std.mem.Allocator, io: std.Io, path: []const u8, zip_data: []const u8) !void {
    try media_layout.writeBytesAtomic(allocator, io, path, zip_data);
}

fn flushReferencedSamples(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    prev_project_dir: ?[]const u8,
    state: anytype,
) !void {
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    for (0..state.session.track_count) |t| {
        for (0..state.session.scene_count) |s| {
            const audio = state.slotAudioConst(t, s) orelse continue;
            const sample_id = audio.sample_id orelse continue;
            if (seen.contains(sample_id)) continue;
            try seen.put(sample_id, {});
            try media_flush.flushOneSample(allocator, io, project_dir, prev_project_dir, state.sample_store, sample_id);
        }
    }
    // Arrangement audio clips (may reference samples not used in session)
    for (state.arrangement.tracks.items) |arr_track| {
        for (arr_track.clips.items) |*arr_clip| {
            const audio = state.arrangement.placementAudio(arr_clip) orelse continue;
            const sample_id = audio.sample_id orelse continue;
            if (seen.contains(sample_id)) continue;
            try seen.put(sample_id, {});
            try media_flush.flushOneSample(allocator, io, project_dir, prev_project_dir, state.sample_store, sample_id);
        }
    }
}

fn uniquePackMember(
    allocator: std.mem.Allocator,
    used: *std.StringHashMap(void),
    base_name: []const u8,
) ![]const u8 {
    const safe = try media_layout.sanitizeBaseName(allocator, base_name);
    defer allocator.free(safe);
    const stem = std.fs.path.stem(safe);
    const ext = std.fs.path.extension(safe);

    var n: u32 = 0;
    while (n < 10_000) : (n += 1) {
        const member = if (n == 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ media_layout.pack_audio_dir, safe })
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}-{d}{s}", .{ media_layout.pack_audio_dir, stem, n + 1, ext });
        if (used.contains(member)) {
            allocator.free(member);
            continue;
        }
        try used.put(member, {});
        return member;
    }
    return error.UniqueNameExhausted;
}

const skip_media_names = [_][]const u8{
    "project.xml",
    "metadata.xml",
    "flux_undo.xml",
};

fn shouldSkipMediaName(name: []const u8) bool {
    for (skip_media_names) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

fn loadMediaTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: Dir,
    prefix: []const u8,
    media_files: *std.StringHashMap([]const u8),
) !void {
    var dir_iter = dir.iterate();
    while (try dir_iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, "plugins")) continue;
            const child_prefix = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            var child = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer child.close(io);
            try loadMediaTree(allocator, io, child, child_prefix, media_files);
        } else if (entry.kind == .file) {
            if (prefix.len == 0 and shouldSkipMediaName(entry.name)) continue;
            // Normalize zip member paths to forward slashes (match XML File path).
            const full_path = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            for (full_path) |*c| {
                if (c.* == '\\') c.* = '/';
            }

            var f = try dir.openFile(io, entry.name, .{});
            defer f.close(io);
            const file_stat = try f.stat(io);
            const data = try allocator.alloc(u8, file_stat.size);
            const n = try f.readPositionalAll(io, data, 0);
            if (n != file_stat.size) return error.UnexpectedEof;
            try media_files.put(full_path, data);
        }
    }
}

fn collectProjectAudioPaths(
    allocator: std.mem.Allocator,
    project: *const Project,
    out: *std.ArrayList([]const u8),
) !void {
    for (project.scenes) |scene| {
        for (scene.clip_slots) |slot| {
            if (slot.clip) |*clip| {
                try flatten.collectAudioPaths(allocator, clip, out);
            }
        }
    }
    if (project.arrangement) |arr| {
        if (arr.lanes) |*lanes| {
            try collectLanesAudioPaths(allocator, lanes, out);
        }
    }
}

fn collectLanesAudioPaths(
    allocator: std.mem.Allocator,
    lanes: *const types.Lanes,
    out: *std.ArrayList([]const u8),
) !void {
    if (lanes.clips) |clips| {
        for (clips.clips) |*clip| {
            try flatten.collectAudioPaths(allocator, clip, out);
        }
    }
    for (lanes.children) |*child| {
        try collectLanesAudioPaths(allocator, child, out);
    }
}
// ── unit tests ────────────────────────────────────────────────────────────

test "audio warps parse and write round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const warps_pts = [_]WarpPoint{
        .{ .time = 0.0, .content_time = 0.0 },
        .{ .time = 8.0, .content_time = 2.823541666666667 },
    };
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1.0" },
        .tracks = &.{
            .{
                .id = "tr1",
                .name = "Drumloop",
                .content_type = .audio,
                .channel = .{
                    .id = "ch1",
                    .role = .regular,
                },
            },
        },
        .arrangement = .{
            .id = "arr",
            .lanes = .{
                .id = "root",
                .time_unit = .beats,
                .children = &.{
                    .{
                        .id = "tr1lanes",
                        .track = "tr1",
                        .clips = .{
                            .id = "tr1clips",
                            .clips = &.{
                                .{
                                    .time = 0.0,
                                    .duration = 8.0,
                                    .play_start = 0.0,
                                    .loop_start = 0.0,
                                    .loop_end = 8.0,
                                    .name = "Drumfunk3 170bpm",
                                    .warps = .{
                                        .id = "w1",
                                        .time_unit = .beats,
                                        .content_time_unit = .seconds,
                                        .audio = .{
                                            .id = "a1",
                                            .file = .{ .path = "audio/Drumfunk3 170bpm.wav" },
                                            .duration = 2.823541666666667,
                                            .sample_rate = 48000,
                                            .channels = 2,
                                            .algorithm = "stretch",
                                        },
                                        .warps = &warps_pts,
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Warps") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Audio") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "audio/Drumfunk3 170bpm.wav") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "algorithm=\"stretch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "contentTime") != null);

    const parsed = try parse.parseProjectXml(allocator, xml);
    try std.testing.expect(parsed.arrangement != null);
    const root = parsed.arrangement.?.lanes.?;
    try std.testing.expect(root.children.len >= 1);
    const clips = root.children[0].clips.?;
    try std.testing.expectEqual(@as(usize, 1), clips.clips.len);
    const clip = clips.clips[0];
    try std.testing.expect(clip.warps != null);
    const warps = clip.warps.?;
    try std.testing.expect(warps.audio != null);
    try std.testing.expectEqualStrings("audio/Drumfunk3 170bpm.wav", warps.audio.?.file.path);
    try std.testing.expectEqual(@as(i32, 48000), warps.audio.?.sample_rate);
    try std.testing.expectEqual(@as(i32, 2), warps.audio.?.channels);
    try std.testing.expectEqualStrings("stretch", warps.audio.?.algorithm.?);
    try std.testing.expectEqual(@as(usize, 2), warps.warps.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), warps.warps[0].time, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), warps.warps[1].time, 1e-6);
    // Writer formats floats to 6 decimal places
    try std.testing.expectApproxEqAbs(@as(f64, 2.823541666666667), warps.warps[1].content_time, 1e-6);
}

test "dawproject portable builtins equalizer compressor parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const xml =
        \\<?xml version="1.0"?>
        \\<Project version="1.0">
        \\  <Application name="Flux" version="0.1"/>
        \\  <Structure>
        \\    <Track contentType="notes" id="t0" name="T1">
        \\      <Channel id="c0" role="regular">
        \\        <Devices>
        \\          <Compressor deviceID="com.flux.builtin.compressor" deviceName="Compressor" deviceRole="audioFX" loaded="true" id="d0" name="Compressor">
        \\            <Parameters>
        \\              <RealParameter id="d0_p10" parameterID="10" name="Compress" min="0" max="1" unit="linear" value="0.3"/>
        \\              <RealParameter id="d0_p11" parameterID="11" name="Output" min="0" max="1" unit="linear" value="0.5"/>
        \\            </Parameters>
        \\            <Threshold id="d0_th" name="Threshold" unit="linear" value="0.3"/>
        \\          </Compressor>
        \\          <Equalizer deviceID="com.flux.builtin.equalizer" deviceName="Equalizer" deviceRole="audioFX" loaded="true" id="d1" name="Equalizer">
        \\            <Parameters>
        \\              <RealParameter id="d1_p100" parameterID="100" name="Input Gain" min="-24" max="24" unit="linear" value="0"/>
        \\            </Parameters>
        \\          </Equalizer>
        \\          <Limiter deviceID="com.flux.builtin.limiter" deviceName="Limiter" deviceRole="audioFX" loaded="true" id="d2" name="Limiter"/>
        \\          <NoiseGate deviceID="com.flux.builtin.noise_gate" deviceName="Noise Gate" deviceRole="audioFX" loaded="true" id="d3" name="Noise Gate">
        \\            <Threshold id="d3_th" name="Threshold" unit="linear" value="0.5"/>
        \\          </NoiseGate>
        \\        </Devices>
        \\      </Channel>
        \\    </Track>
        \\  </Structure>
        \\</Project>
    ;
    const parsed = try parse.parseProjectXml(allocator, xml);
    const ch = parsed.tracks[0].channel.?;
    try std.testing.expectEqual(@as(usize, 4), ch.devices.len);
    try std.testing.expect(ch.devices[0].xml_kind == .compressor);
    try std.testing.expectEqualStrings("com.flux.builtin.compressor", ch.devices[0].device_id);
    try std.testing.expect(ch.devices[0].parameters.len >= 2);
    try std.testing.expect(ch.devices[1].xml_kind == .equalizer);
    try std.testing.expect(ch.devices[2].xml_kind == .limiter);
    try std.testing.expect(ch.devices[3].xml_kind == .noise_gate);
}

test "bitwig midi clip playStart loop and clap plugin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Subset of LOAD DIVA.dawproject: instrument + session MIDI punch/loop region.
    const xml =
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Project version="1.0">
        \\  <Application name="Bitwig Studio" version="6.0"/>
        \\  <Transport>
        \\    <Tempo max="666" min="20" unit="bpm" value="110" id="id0" name="Tempo"/>
        \\    <TimeSignature denominator="4" numerator="4" id="id1" name="Time Signature"/>
        \\  </Transport>
        \\  <Structure>
        \\    <Track contentType="notes" loaded="true" id="id2" name="Diva" color="#ff5706">
        \\      <Channel audioChannels="2" destination="id20" role="regular" solo="false" id="id3">
        \\        <Devices>
        \\          <ClapPlugin deviceID="com.u-he.Diva" deviceName="Diva" deviceRole="instrument" loaded="true" id="id7" name="Diva">
        \\            <Parameters/>
        \\            <Enabled value="true" id="id8" name="On/Off"/>
        \\            <State path="plugins/0d8762f7-b4ee-4fb2-98c1-381f17999991.clap-preset"/>
        \\          </ClapPlugin>
        \\        </Devices>
        \\        <Mute value="false" id="id6" name="Mute"/>
        \\        <Pan max="1" min="0" unit="normalized" value="0.5" id="id5" name="Pan"/>
        \\        <Volume max="2" min="0" unit="linear" value="0.316228" id="id4" name="Volume"/>
        \\      </Channel>
        \\    </Track>
        \\  </Structure>
        \\  <Scenes>
        \\    <Scene id="id43" name="Scene 1">
        \\      <Lanes id="id44">
        \\        <ClipSlot hasStop="true" track="id2" id="id45">
        \\          <Clip time="0.0" duration="24.0" playStart="8.0" loopStart="6.0" loopEnd="22.0" enable="true">
        \\            <Notes id="id46">
        \\              <Note time="7.598730" duration="2.745760" channel="0" key="29" vel="0.700000" rel="0.500000"/>
        \\              <Note time="10.557340" duration="2.554195" channel="0" key="33" vel="0.700000" rel="0.500000"/>
        \\            </Notes>
        \\          </Clip>
        \\        </ClipSlot>
        \\      </Lanes>
        \\    </Scene>
        \\  </Scenes>
        \\</Project>
    ;

    const parsed = try parse.parseProjectXml(allocator, xml);
    try std.testing.expectEqual(@as(usize, 1), parsed.tracks.len);
    const track = parsed.tracks[0];
    try std.testing.expectEqualStrings("Diva", track.name);
    try std.testing.expect(track.channel != null);
    const ch = track.channel.?;
    try std.testing.expect(ch.volume != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.316228), ch.volume.?.value, 1e-6);
    try std.testing.expect(ch.pan != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), ch.pan.?.value, 1e-6);
    try std.testing.expect(ch.mute != null);
    try std.testing.expect(!ch.mute.?.value);
    try std.testing.expectEqual(@as(usize, 1), ch.devices.len);
    try std.testing.expectEqualStrings("com.u-he.Diva", ch.devices[0].device_id);
    try std.testing.expectEqualStrings("plugins/0d8762f7-b4ee-4fb2-98c1-381f17999991.clap-preset", ch.devices[0].state.?.path);

    try std.testing.expectEqual(@as(usize, 1), parsed.scenes.len);
    const slot = parsed.scenes[0].clip_slots[0];
    try std.testing.expect(slot.clip != null);
    const clip = slot.clip.?;
    try std.testing.expectApproxEqAbs(@as(f64, 24.0), clip.duration, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), clip.play_start, 1e-9);
    try std.testing.expect(clip.loop_start != null);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), clip.loop_start.?, 1e-9);
    try std.testing.expect(clip.loop_end != null);
    try std.testing.expectApproxEqAbs(@as(f64, 22.0), clip.loop_end.?, 1e-9);
    try std.testing.expect(clip.notes != null);
    try std.testing.expectEqual(@as(usize, 2), clip.notes.?.notes.len);
}

test "external audio file attribute round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const warps_pts = [_]WarpPoint{
        .{ .time = 0.0, .content_time = 0.0 },
        .{ .time = 4.0, .content_time = 1.0 },
    };
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1.0" },
        .tracks = &.{
            .{
                .id = "tr1",
                .name = "Audio",
                .content_type = .audio,
                .channel = .{ .id = "ch1" },
            },
        },
        .scenes = &.{
            .{
                .id = "sc1",
                .name = "Scene 1",
                .lanes_id = "sl1",
                .clip_slots = &.{
                    .{
                        .id = "cs1",
                        .track = "tr1",
                        .clip = .{
                            .time = 0,
                            .duration = 4,
                            .warps = .{
                                .id = "w1",
                                .time_unit = .beats,
                                .content_time_unit = .seconds,
                                .audio = .{
                                    .id = "a1",
                                    .file = .{ .path = "samples/kick.wav", .external = true },
                                    .duration = 1.0,
                                    .sample_rate = 48000,
                                    .channels = 2,
                                },
                                .warps = &warps_pts,
                            },
                        },
                    },
                },
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    try std.testing.expect(std.mem.indexOf(u8, xml, "samples/kick.wav") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "external=\"true\"") != null);

    const parsed = try parse.parseProjectXml(allocator, xml);
    const file = parsed.scenes[0].clip_slots[0].clip.?.warps.?.audio.?.file;
    try std.testing.expectEqualStrings("samples/kick.wav", file.path);
    try std.testing.expect(file.external);
}

test "arrangement tracks clips colors positions and media round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const warp_points = [_]WarpPoint{
        .{ .time = 0.0, .content_time = 0.0 },
        .{ .time = 3.5, .content_time = 1.75 },
    };
    const notes = [_]types.Note{.{
        .time = 0.25,
        .duration = 0.5,
        .key = 64,
        .vel = 0.75,
        .rel = 0.6,
    }};
    const lanes = [_]types.Lanes{
        .{
            .id = "audio-lane",
            .track = "audio-track",
            .clips = .{
                .id = "audio-clips",
                .clips = &.{.{
                    .time = 1.25,
                    .duration = 3.5,
                    .enable = false,
                    .name = "Take 1",
                    .color = "#336699",
                    .warps = .{
                        .id = "audio-warps",
                        .time_unit = .beats,
                        .content_time_unit = .seconds,
                        .audio = .{
                            .id = "audio-source",
                            .file = .{ .path = "samples/take-1.wav", .external = true },
                            .duration = 1.75,
                            .sample_rate = 48000,
                            .channels = 2,
                        },
                        .warps = &warp_points,
                    },
                }},
            },
        },
        .{
            .id = "midi-lane",
            .track = "midi-track",
            .clips = .{
                .id = "midi-clips",
                .clips = &.{.{
                    .time = 8.0,
                    .duration = 4.0,
                    .name = "Lead",
                    .color = "#cc8844",
                    .notes = .{ .id = "lead-notes", .notes = &notes },
                }},
            },
        },
    };
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1.0" },
        .tracks = &.{
            .{ .id = "audio-track", .name = "Audio", .color = "#224466" },
            .{ .id = "midi-track", .name = "MIDI", .color = "#88aa44" },
        },
        .arrangement = .{
            .id = "arrangement",
            .lanes = .{ .id = "root-lanes", .time_unit = .beats, .children = &lanes },
        },
    };

    const xml = try toXml(allocator, &proj);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Arrangement") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "external=\"true\"") != null);

    const parsed = try parse.parseProjectXml(allocator, xml);
    try std.testing.expectEqualStrings("#224466", parsed.tracks[0].color.?);
    try std.testing.expectEqualStrings("#88aa44", parsed.tracks[1].color.?);

    const children = parsed.arrangement.?.lanes.?.children;
    try std.testing.expectEqual(@as(usize, 2), children.len);
    const audio_clip = children[0].clips.?.clips[0];
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), audio_clip.time, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), audio_clip.duration, 1e-6);
    try std.testing.expect(!audio_clip.enable);
    try std.testing.expectEqualStrings("Take 1", audio_clip.name.?);
    try std.testing.expectEqualStrings("#336699", audio_clip.color.?);
    try std.testing.expectEqualStrings("samples/take-1.wav", audio_clip.warps.?.audio.?.file.path);
    try std.testing.expect(audio_clip.warps.?.audio.?.file.external);

    const midi_clip = children[1].clips.?.clips[0];
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), midi_clip.time, 1e-6);
    try std.testing.expectEqualStrings("#cc8844", midi_clip.color.?);
    try std.testing.expectEqual(@as(usize, 1), midi_clip.notes.?.notes.len);
    try std.testing.expectEqual(@as(i32, 64), midi_clip.notes.?.notes[0].key);
}

test "all DAWproject fixtures load and model-round-trip" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var fixtures = Dir.cwd().openDir(io, "tests/fixtures", .{ .iterate = true }) catch {
        std.log.warn("skip: tests/fixtures not found", .{});
        return;
    };
    defer fixtures.close(io);

    var count: usize = 0;
    var it = fixtures.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".dawproject")) continue;

        const work = try std.fmt.allocPrint(allocator, "/tmp/flux_fixture_{d}", .{count});
        defer allocator.free(work);
        Dir.cwd().deleteTree(io, work) catch {};
        try Dir.cwd().createDirPath(io, work);
        defer Dir.cwd().deleteTree(io, work) catch {};

        const source = try std.fmt.allocPrint(allocator, "tests/fixtures/{s}", .{entry.name});
        defer allocator.free(source);
        const copied = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ work, entry.name });
        defer allocator.free(copied);
        const bytes = try media_layout.readEntireFile(allocator, io, source);
        defer allocator.free(bytes);
        try media_layout.writeBytesAtomic(allocator, io, copied, bytes);

        var loaded = try load(allocator, io, copied);
        defer loaded.deinit();
        try std.testing.expect(loaded.project.application.name.len > 0);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const xml = try toXml(arena.allocator(), &loaded.project);
        const reparsed = try parse.parseProjectXml(arena.allocator(), xml);
        try std.testing.expectEqual(loaded.project.tracks.len, reparsed.tracks.len);
        try std.testing.expectEqual(loaded.project.scenes.len, reparsed.scenes.len);
        try std.testing.expectEqual(loaded.project.arrangement != null, reparsed.arrangement != null);
        count += 1;
    }
    if (count == 0) std.log.warn("skip: no .dawproject files under tests/fixtures", .{});
}
