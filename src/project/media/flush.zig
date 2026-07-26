//! Ensure sample media exists under samples/recordings beside a thin project.
//! Used by thin Save and integration tests (Save As must copy from previous dir).

const std = @import("std");
const media_layout = @import("layout.zig");
const sample_store = @import("../../audio/sample_store.zig");

const Dir = std.Io.Dir;
const SampleStore = sample_store.SampleStore;
const SampleId = sample_store.SampleId;

/// Flush every live sample in the store to `project_dir`.
/// `prev_project_dir` is the previous project folder (Save As) for reading disk-backed media.
pub fn flushSampleStoreToDisk(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    prev_project_dir: ?[]const u8,
    store: *SampleStore,
) !void {
    for (store.assets.items, 0..) |slot, i| {
        if (slot == null) continue;
        try flushOneSample(allocator, io, project_dir, prev_project_dir, store, @intCast(i));
    }
}

pub fn flushOneSample(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    prev_project_dir: ?[]const u8,
    store: *SampleStore,
    sample_id: SampleId,
) !void {
    const asset = store.getMut(sample_id) orelse return;

    // Already on disk under samples/ or recordings/ next to *this* save path
    if (prev_project_dir == null and media_layout.isMediaSubdirPath(asset.path_in_project) and asset.source_bytes == null) {
        const abs = try media_layout.joinRel(allocator, project_dir, asset.path_in_project);
        defer allocator.free(abs);
        if (Dir.cwd().statFile(io, abs, .{})) |st| {
            asset.file_size = st.size;
            asset.file_mtime_ns = @intCast(st.mtime.toNanoseconds());
            return;
        } else |_| {}
    }

    const bytes_owned = try resolveSampleBytes(allocator, io, project_dir, prev_project_dir, asset);
    if (bytes_owned == null) {
        std.log.warn("Save: cannot locate media for {s}", .{asset.path_in_project});
        return error.MediaMissingOnSave;
    }
    const bytes = bytes_owned.?;
    defer allocator.free(bytes);

    // Prefer keeping the relative path when the destination is free or identical.
    if (media_layout.isMediaSubdirPath(asset.path_in_project)) {
        if (media_layout.mediaEqualsBytes(io, project_dir, asset.path_in_project, bytes)) {
            const abs = try media_layout.joinRel(allocator, project_dir, asset.path_in_project);
            defer allocator.free(abs);
            const id_stat = media_layout.statIdentity(io, abs);
            store.clearSourceBytes(
                sample_id,
                if (id_stat) |ident| ident.size else bytes.len,
                if (id_stat) |ident| ident.mtime_ns else 0,
            );
            return;
        }
        const dest_abs = try media_layout.joinRel(allocator, project_dir, asset.path_in_project);
        defer allocator.free(dest_abs);
        if (Dir.cwd().statFile(io, dest_abs, .{})) |_| {
            // Exists but wrong size → unique name below
        } else |_| {
            try media_layout.writeBytesAtomic(allocator, io, dest_abs, bytes);
            const id_stat = media_layout.statIdentity(io, dest_abs);
            store.clearSourceBytes(
                sample_id,
                if (id_stat) |ident| ident.size else bytes.len,
                if (id_stat) |ident| ident.mtime_ns else 0,
            );
            return;
        }
    }

    const preferred = std.fs.path.basename(asset.path_in_project);
    const subdir = if (std.mem.startsWith(u8, asset.path_in_project, media_layout.recordings_dir ++ "/"))
        media_layout.recordings_dir
    else
        media_layout.samples_dir;
    const rel = try media_layout.writeMediaUnique(
        allocator,
        io,
        project_dir,
        subdir,
        preferred,
        bytes,
    );
    defer allocator.free(rel);
    const abs = try media_layout.joinRel(allocator, project_dir, rel);
    defer allocator.free(abs);
    const id_stat = media_layout.statIdentity(io, abs);
    try store.setPathInProject(sample_id, rel);
    store.clearSourceBytes(
        sample_id,
        if (id_stat) |ident| ident.size else bytes.len,
        if (id_stat) |ident| ident.mtime_ns else 0,
    );
}

fn resolveSampleBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    prev_project_dir: ?[]const u8,
    asset: *const sample_store.SampleAsset,
) !?[]u8 {
    if (asset.source_bytes) |b| {
        return try allocator.dupe(u8, b);
    }

    const base = std.fs.path.basename(asset.path_in_project);

    var candidates: [8]?[]const u8 = @splat(null);
    var n: usize = 0;
    const add = struct {
        fn go(list: *[8]?[]const u8, count: *usize, path: ?[]const u8) void {
            if (path == null) return;
            if (count.* >= list.len) return;
            list[count.*] = path;
            count.* += 1;
        }
    }.go;

    if (prev_project_dir) |pd| {
        if (media_layout.isSafeRelativePath(asset.path_in_project)) {
            add(&candidates, &n, media_layout.joinRel(allocator, pd, asset.path_in_project) catch null);
        }
        var rel_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ media_layout.samples_dir, base })) |rel| {
            add(&candidates, &n, media_layout.joinRel(allocator, pd, rel) catch null);
        } else |_| {}
        if (std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ media_layout.pack_audio_dir, base })) |rel| {
            add(&candidates, &n, media_layout.joinRel(allocator, pd, rel) catch null);
        } else |_| {}
    } else if (media_layout.isSafeRelativePath(asset.path_in_project)) {
        add(&candidates, &n, media_layout.joinRel(allocator, project_dir, asset.path_in_project) catch null);
    }
    if (std.fs.path.isAbsolute(asset.path_in_project)) {
        add(&candidates, &n, try allocator.dupe(u8, asset.path_in_project));
    }

    defer {
        for (candidates[0..n]) |c| {
            if (c) |p| allocator.free(p);
        }
    }

    for (candidates[0..n]) |c| {
        const abs = c orelse continue;
        if (media_layout.readEntireFile(allocator, io, abs)) |data| return data else |_| {}
    }

    return null;
}

// ── unit tests ────────────────────────────────────────────────────────────

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

var temp_seq: u64 = 0;

fn makeTempDir(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    temp_seq +%= 1;
    const path = try std.fmt.allocPrint(allocator, "/tmp/flux_media_test_{s}_{d}", .{ name, temp_seq });
    try Dir.cwd().createDirPath(testIo(), path);
    return path;
}

/// Inject a disk-backed sample without zaudio decode (flush only needs path + optional bytes).
fn injectDiskSample(
    store: *SampleStore,
    path_in_project: []const u8,
    source_bytes: ?[]const u8,
) !SampleId {
    const path_owned = try store.allocator.dupe(u8, path_in_project);
    errdefer store.allocator.free(path_owned);
    const pcm = try store.allocator.alloc(f32, 1);
    errdefer store.allocator.free(pcm);
    pcm[0] = 0;
    const source: ?[]u8 = if (source_bytes) |b| try store.allocator.dupe(u8, b) else null;
    errdefer if (source) |s| store.allocator.free(s);

    const id = try store.allocIdForTest();
    store.assets.items[id] = .{
        .refcount = 1,
        .path_in_project = path_owned,
        .pcm = pcm,
        .channels = 1,
        .sample_rate = 44100,
        .frame_count = 1,
        .duration_seconds = 1.0 / 44100.0,
        .original_sample_rate = 44100,
        .original_channels = 1,
        .source_bytes = source,
        .file_size = if (source_bytes) |b| b.len else 0,
        .file_mtime_ns = 0,
    };
    try store.path_to_id.put(path_owned, id);
    return id;
}

test "Save As copies disk-backed samples from previous project dir" {
    const allocator = std.testing.allocator;
    const io = testIo();

    const prev_dir = try makeTempDir(allocator, "prev");
    defer {
        Dir.cwd().deleteTree(io, prev_dir) catch {};
        allocator.free(prev_dir);
    }
    const dest_dir = try makeTempDir(allocator, "dest");
    defer {
        Dir.cwd().deleteTree(io, dest_dir) catch {};
        allocator.free(dest_dir);
    }

    // Fake wav payload (flush does not decode)
    const wav = try allocator.alloc(u8, 4096);
    defer allocator.free(wav);
    @memset(wav, 0xAB);

    const prev_rel = "samples/Audio 2-5.wav";
    try media_layout.ensureMediaDirs(io, prev_dir);
    const prev_abs = try media_layout.joinRel(allocator, prev_dir, prev_rel);
    defer allocator.free(prev_abs);
    try media_layout.writeBytesAtomic(allocator, io, prev_abs, wav);

    var store = SampleStore.init(allocator);
    defer store.deinit();
    // Disk-backed: no source_bytes — same state as loadFromPath after hydrate
    _ = try injectDiskSample(&store, prev_rel, null);

    try media_layout.ensureMediaDirs(io, dest_dir);
    try flushSampleStoreToDisk(allocator, io, dest_dir, prev_dir, &store);

    const dest_abs = try media_layout.joinRel(allocator, dest_dir, prev_rel);
    defer allocator.free(dest_abs);
    const dest_bytes = try media_layout.readEntireFile(allocator, io, dest_abs);
    defer allocator.free(dest_bytes);
    try std.testing.expectEqualSlices(u8, wav, dest_bytes);

    // Path in store stayed stable
    try std.testing.expectEqualStrings(prev_rel, store.get(0).?.path_in_project);
}

test "Save As does not reuse different same-sized destination media" {
    const allocator = std.testing.allocator;
    const io = testIo();
    const prev_dir = try makeTempDir(allocator, "collision_prev");
    defer {
        Dir.cwd().deleteTree(io, prev_dir) catch {};
        allocator.free(prev_dir);
    }
    const dest_dir = try makeTempDir(allocator, "collision_dest");
    defer {
        Dir.cwd().deleteTree(io, dest_dir) catch {};
        allocator.free(dest_dir);
    }

    try media_layout.ensureMediaDirs(io, prev_dir);
    try media_layout.ensureMediaDirs(io, dest_dir);
    const rel = "samples/kick.wav";
    const prev_abs = try media_layout.joinRel(allocator, prev_dir, rel);
    defer allocator.free(prev_abs);
    const dest_abs = try media_layout.joinRel(allocator, dest_dir, rel);
    defer allocator.free(dest_abs);
    try media_layout.writeBytesAtomic(allocator, io, prev_abs, "correct!");
    try media_layout.writeBytesAtomic(allocator, io, dest_abs, "stale!!!");

    var store = SampleStore.init(allocator);
    defer store.deinit();
    const id = try injectDiskSample(&store, rel, null);
    try flushSampleStoreToDisk(allocator, io, dest_dir, prev_dir, &store);

    try std.testing.expectEqualStrings("samples/kick-2.wav", store.get(id).?.path_in_project);
    const copied_abs = try media_layout.joinRel(allocator, dest_dir, store.get(id).?.path_in_project);
    defer allocator.free(copied_abs);
    const copied = try media_layout.readEntireFile(allocator, io, copied_abs);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("correct!", copied);
}

test "Save As fails loudly when media cannot be found" {
    const allocator = std.testing.allocator;
    const io = testIo();

    const dest_dir = try makeTempDir(allocator, "orphan");
    defer {
        Dir.cwd().deleteTree(io, dest_dir) catch {};
        allocator.free(dest_dir);
    }

    var store = SampleStore.init(allocator);
    defer store.deinit();
    _ = try injectDiskSample(&store, "samples/orphan.wav", null);

    try media_layout.ensureMediaDirs(io, dest_dir);
    try std.testing.expectError(
        error.MediaMissingOnSave,
        flushSampleStoreToDisk(allocator, io, dest_dir, null, &store),
    );
}

test "DAWproject fixtures: embedded audio hydrate + Save As copies all wavs" {
    const allocator = std.testing.allocator;
    const io = testIo();
    var fixtures_dir = Dir.cwd().openDir(io, "tests/fixtures", .{ .iterate = true }) catch {
        std.log.warn("skip: tests/fixtures not found", .{});
        return;
    };
    defer fixtures_dir.close(io);

    var count: usize = 0;
    var it = fixtures_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".dawproject")) continue;
        const fixture_path = try std.fmt.allocPrint(allocator, "tests/fixtures/{s}", .{entry.name});
        defer allocator.free(fixture_path);
        try testFixtureSaveAs(allocator, io, fixture_path);
        count += 1;
    }
    if (count == 0) std.log.warn("skip: no .dawproject files under tests/fixtures", .{});
}

fn testFixtureSaveAs(allocator: std.mem.Allocator, io: std.Io, fixture_path: []const u8) !void {
    const work = try makeTempDir(allocator, "fixture");
    defer {
        Dir.cwd().deleteTree(io, work) catch {};
        allocator.free(work);
    }

    const open_path = try std.fmt.allocPrint(allocator, "{s}/opened.dawproject", .{work});
    defer allocator.free(open_path);
    {
        const src = try media_layout.readEntireFile(allocator, io, fixture_path);
        defer allocator.free(src);
        try media_layout.writeBytesAtomic(allocator, io, open_path, src);
    }

    const extract_dir = try std.fmt.allocPrint(allocator, "{s}/extract", .{work});
    defer allocator.free(extract_dir);
    Dir.cwd().deleteTree(io, extract_dir) catch {};
    try Dir.cwd().createDirPath(io, extract_dir);

    {
        var file = try Dir.cwd().openFile(io, open_path, .{});
        defer file.close(io);
        var read_buf: [8192]u8 = undefined;
        var fr = file.reader(io, &read_buf);
        var out_dir = try Dir.cwd().createDirPathOpen(io, extract_dir, .{});
        defer out_dir.close(io);
        try std.zip.extract(out_dir, &fr, .{ .allow_backslashes = true });
    }

    var expected: std.ArrayList([]u8) = .empty;
    defer {
        for (expected.items) |path| allocator.free(path);
        expected.deinit(allocator);
    }
    var extracted = try Dir.cwd().openDir(io, extract_dir, .{ .iterate = true });
    defer extracted.close(io);
    try collectWavs(allocator, io, extracted, "", &expected);
    try std.testing.expect(expected.items.len > 0);

    const open_dir = try media_layout.projectDir(allocator, open_path);
    defer allocator.free(open_dir);
    try media_layout.ensureMediaDirs(io, open_dir);

    var store = SampleStore.init(allocator);
    defer store.deinit();

    for (expected.items) |zip_path| {
        const member_abs = try media_layout.joinRel(allocator, extract_dir, zip_path);
        defer allocator.free(member_abs);
        const bytes = try media_layout.readEntireFile(allocator, io, member_abs);
        defer allocator.free(bytes);

        const base = std.fs.path.basename(zip_path);
        // Hydrate to samples/ next to opened project (like io.load)
        const rel = try media_layout.writeMediaUnique(
            allocator,
            io,
            open_dir,
            media_layout.samples_dir,
            base,
            bytes,
        );
        defer allocator.free(rel);

        // Disk-backed sample pointing at hydrated path (no RAM copy)
        _ = try injectDiskSample(&store, rel, null);
    }

    // Save As → new folder (the failing user path)
    const save_as_dir = try std.fmt.allocPrint(allocator, "{s}/save_as", .{work});
    defer allocator.free(save_as_dir);
    try Dir.cwd().createDirPath(io, save_as_dir);
    try media_layout.ensureMediaDirs(io, save_as_dir);

    try flushSampleStoreToDisk(allocator, io, save_as_dir, open_dir, &store);

    for (expected.items) |zip_path| {
        const base = std.fs.path.basename(zip_path);
        var rel_buf: [256]u8 = undefined;
        const rel = try std.fmt.bufPrint(&rel_buf, "samples/{s}", .{base});
        const abs = try media_layout.joinRel(allocator, save_as_dir, rel);
        defer allocator.free(abs);
        const st = Dir.cwd().statFile(io, abs, .{}) catch {
            std.debug.print("missing after Save As: {s}\n", .{abs});
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(st.size > 1000);
    }

    // "Reopen": every path must still resolve from the new project dir alone
    for (expected.items) |zip_path| {
        const base = std.fs.path.basename(zip_path);
        var rel_buf: [256]u8 = undefined;
        const rel = try std.fmt.bufPrint(&rel_buf, "samples/{s}", .{base});
        const abs = try media_layout.joinRel(allocator, save_as_dir, rel);
        defer allocator.free(abs);
        const data = try media_layout.readEntireFile(allocator, io, abs);
        defer allocator.free(data);
        try std.testing.expect(data.len > 1000);
    }
}

fn collectWavs(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: Dir,
    prefix: []const u8,
    paths: *std.ArrayList([]u8),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            var child = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer child.close(io);
            const child_prefix = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            defer allocator.free(child_prefix);
            try collectWavs(allocator, io, child, child_prefix, paths);
        } else if (entry.kind == .file and std.ascii.endsWithIgnoreCase(entry.name, ".wav")) {
            const path = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            errdefer allocator.free(path);
            try paths.append(allocator, path);
        }
    }
}
