const std = @import("std");
const ui_state = @import("../ui/state.zig");
const plugins = @import("../plugin/plugins.zig");
const undo = @import("../undo/root.zig");
const types = @import("types.zig");
const convert = @import("convert.zig");
const xml_writer = @import("xml_writer.zig");
const zip_writer = @import("zip_writer.zig");
const parse = @import("parse.zig");
const io_types = @import("io_types.zig");
const media_layout = @import("media_layout.zig");
const media_flush = @import("media_flush.zig");
const flatten = @import("flatten.zig");
const sample_store_mod = @import("../audio/sample_store.zig");

const Project = types.Project;
const TrackPluginInfo = io_types.TrackPluginInfo;
const PluginStateFile = io_types.PluginStateFile;
const ZipWriter = zip_writer.ZipWriter;
const fromFluxProject = convert.fromFluxProject;
const toXml = xml_writer.toXml;
const Dir = std.Io.Dir;

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
    /// Optional flux_undo.xml bytes from the archive (full deserialize not wired yet).
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
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    plugin_states: []const PluginStateFile,
    track_plugin_info: []const TrackPluginInfo,
    track_fx_plugin_info: []const [ui_state.max_fx_slots]TrackPluginInfo,
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

    const undo_xml = undo.serializeToXml(arena.allocator(), &state.undo_history) catch |err| blk: {
        std.log.warn("Failed to serialize undo history: {}", .{err});
        break :blk null;
    };
    if (undo_xml) |data| {
        try zip.addFile("flux_undo.xml", data);
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
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    plugin_states: []const PluginStateFile,
    track_plugin_info: []const TrackPluginInfo,
    track_fx_plugin_info: []const [ui_state.max_fx_slots]TrackPluginInfo,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Remap sample paths → unique audio/… zip members for XML + archive.
    var pack_path_by_id = std.AutoHashMap(u32, []const u8).init(aa);
    var used_names = std.StringHashMap(void).init(aa);
    var originals: std.ArrayList(struct { id: u32, path: []const u8 }) = .empty;

    for (0..state.session.track_count) |t| {
        for (0..state.session.scene_count) |s| {
            const clip = &state.audio_clips[t][s];
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

    // Temporarily set pack paths for XML, then restore.
    {
        var it = pack_path_by_id.iterator();
        while (it.next()) |entry| {
            try state.sample_store.setPathInProject(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    defer {
        for (originals.items) |item| {
            state.sample_store.setPathInProject(item.id, item.path) catch {};
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

    if (undo.serializeToXml(aa, &state.undo_history) catch null) |data| {
        try zip.addFile("flux_undo.xml", data);
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
    var tmp_dir = try Dir.cwd().createDirPathOpen(io, tmp_extract_path, .{});
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
    if (tmp_dir.openDir(io, "plugins", .{})) |*plugins_dir| {
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
    state: *ui_state.State,
) !void {
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    for (0..state.session.track_count) |t| {
        for (0..state.session.scene_count) |s| {
            const sample_id = state.audio_clips[t][s].sample_id orelse continue;
            if (seen.contains(sample_id)) continue;
            try seen.put(sample_id, {});
            try media_flush.flushOneSample(allocator, io, project_dir, prev_project_dir, &state.sample_store, sample_id);
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
            var child = try dir.openDir(io, entry.name, .{});
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
