//! Integration tests: Bitwig-style embedded media → thin Save As → reopen.
//!
//! Fixture: tests/fixtures/pushMeToTheBedEURORACK.dawproject (Bitwig export, ~24MB).
//!   cp /path/to/pushMeToTheBedEURORACK.dawproject tests/fixtures/

const std = @import("std");
const media_layout = @import("../project/media/layout.zig");
const media_flush = @import("../project/media/flush.zig");
const sample_store = @import("../audio/sample_store.zig");

const Dir = std.Io.Dir;
const SampleStore = sample_store.SampleStore;

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
) !sample_store.SampleId {
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
    try media_flush.flushSampleStoreToDisk(allocator, io, dest_dir, prev_dir, &store);

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
    try media_flush.flushSampleStoreToDisk(allocator, io, dest_dir, prev_dir, &store);

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
        media_flush.flushSampleStoreToDisk(allocator, io, dest_dir, null, &store),
    );
}

test "bitwig fixture: embedded audio hydrate + Save As copies all wavs" {
    const allocator = std.testing.allocator;
    const io = testIo();

    const fixture_candidates = [_][]const u8{
        "tests/fixtures/pushMeToTheBedEURORACK.dawproject",
    };
    var fixture_path: ?[]const u8 = null;
    for (fixture_candidates) |c| {
        if (Dir.cwd().statFile(io, c, .{})) |_| {
            fixture_path = c;
            break;
        } else |_| {}
    }
    if (fixture_path == null) {
        std.log.warn("skip: tests/fixtures/pushMeToTheBedEURORACK.dawproject not found", .{});
        return;
    }

    const work = try makeTempDir(allocator, "bitwig");
    defer {
        Dir.cwd().deleteTree(io, work) catch {};
        allocator.free(work);
    }

    const open_path = try std.fmt.allocPrint(allocator, "{s}/opened.dawproject", .{work});
    defer allocator.free(open_path);
    {
        const src = try media_layout.readEntireFile(allocator, io, fixture_path.?);
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

    const expected = [_][]const u8{
        "audio/Audio 2-1.wav",
        "audio/Audio 2-2.wav",
        "audio/Audio 2-3.wav",
        "audio/Audio 2-4.wav",
        "audio/Audio 2-5.wav",
        "audio/Audio 4-1.wav",
    };

    const open_dir = try media_layout.projectDir(allocator, open_path);
    defer allocator.free(open_dir);
    try media_layout.ensureMediaDirs(io, open_dir);

    var store = SampleStore.init(allocator);
    defer store.deinit();

    for (expected) |zip_path| {
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

    try media_flush.flushSampleStoreToDisk(allocator, io, save_as_dir, open_dir, &store);

    for (expected) |zip_path| {
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
    for (expected) |zip_path| {
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
