//! Ensure sample media exists under samples/recordings beside a thin project.
//! Used by thin Save and integration tests (Save As must copy from previous dir).

const std = @import("std");
const media_layout = @import("media_layout.zig");
const sample_store = @import("../audio/sample_store.zig");

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
