//! Sample asset store for audio clips (main thread only).
//! Decodes media via zaudio (miniaudio). Disk-backed paths for thin dawproject;
//! optional source_bytes only until flushed to samples/recordings.

const std = @import("std");
const zaudio = @import("zaudio");
const peaks_mod = @import("../ui/audio_clip/peaks.zig");

pub const SampleId = u32;
pub const invalid_sample_id: SampleId = std.math.maxInt(SampleId);

pub const peak_bin_count = peaks_mod.peak_bin_count;
pub const PeakBin = peaks_mod.PeakBin;

pub const SampleAsset = struct {
    refcount: u32 = 1,
    /// Project-relative path (e.g. "samples/loop.wav" or pack "audio/loop.wav")
    path_in_project: []u8,
    /// Decoded interleaved f32 PCM
    pcm: []f32,
    channels: u8,
    /// Sample rate of decoded PCM
    sample_rate: u32,
    frame_count: u64,
    /// Full file duration in seconds (for DAWproject Audio.duration)
    duration_seconds: f64,
    /// Original file metadata (for DAWproject attributes)
    original_sample_rate: i32,
    original_channels: i32,
    /// Bits per sample from source container when known (0 = unknown / compressed).
    original_bits: u16 = 0,
    /// Original file bytes until flushed to disk; null when disk-backed.
    source_bytes: ?[]u8 = null,
    /// Last known file size (for dirty / external-change checks).
    file_size: u64 = 0,
    /// Last known mtime in nanoseconds (plugins.statMtimeNs style).
    file_mtime_ns: i64 = 0,
    /// Min/max peaks for UI waveform thumbnails (main thread only).
    peaks: [peak_bin_count]PeakBin = @splat(.{}),
};

pub const SampleStore = struct {
    allocator: std.mem.Allocator,
    assets: std.ArrayList(?SampleAsset),
    path_to_id: std.StringHashMap(SampleId),
    /// Assets freed only after RT snapshot drop (no audio-thread use).
    deferred_free: std.ArrayList(SampleAsset),

    pub fn init(allocator: std.mem.Allocator) SampleStore {
        return .{
            .allocator = allocator,
            .assets = .empty,
            .path_to_id = std.StringHashMap(SampleId).init(allocator),
            .deferred_free = .empty,
        };
    }

    pub fn deinit(self: *SampleStore) void {
        self.flushDeferredFrees();
        for (self.assets.items) |*slot| {
            if (slot.*) |*asset| {
                freeAsset(self.allocator, asset);
            }
        }
        self.assets.deinit(self.allocator);
        self.path_to_id.deinit();
        self.deferred_free.deinit(self.allocator);
    }

    pub fn clear(self: *SampleStore) void {
        for (self.assets.items) |*slot| {
            if (slot.*) |*asset| {
                freeAsset(self.allocator, asset);
                slot.* = null;
            }
        }
        self.path_to_id.clearRetainingCapacity();
        self.flushDeferredFrees();
    }

    /// Free samples whose refcount hit zero. Call only when the audio thread
    /// is not reading the previous snapshot (e.g. end of SharedState.updateFromUi).
    pub fn flushDeferredFrees(self: *SampleStore) void {
        for (self.deferred_free.items) |*asset| {
            freeAsset(self.allocator, asset);
        }
        self.deferred_free.clearRetainingCapacity();
    }

    pub fn get(self: *const SampleStore, id: SampleId) ?*const SampleAsset {
        if (id >= self.assets.items.len) return null;
        if (self.assets.items[id]) |*asset| return asset;
        return null;
    }

    pub fn getMut(self: *SampleStore, id: SampleId) ?*SampleAsset {
        if (id >= self.assets.items.len) return null;
        if (self.assets.items[id]) |*asset| return asset;
        return null;
    }

    pub fn retain(self: *SampleStore, id: SampleId) void {
        if (self.getMut(id)) |asset| {
            asset.refcount +%= 1;
        }
    }

    pub fn release(self: *SampleStore, id: SampleId) void {
        if (id >= self.assets.items.len) return;
        const slot = &self.assets.items[id];
        const asset = &(slot.* orelse return);
        if (asset.refcount <= 1) {
            _ = self.path_to_id.remove(asset.path_in_project);
            // Defer free so the audio thread can finish reading the old snapshot.
            self.deferred_free.append(self.allocator, asset.*) catch {
                // Never free memory that may still be visible to the audio thread.
                // Leaking on allocator exhaustion is safer than a use-after-free.
                slot.* = null;
                return;
            };
            slot.* = null;
        } else {
            asset.refcount -= 1;
        }
    }

    /// Load or retain a sample from in-memory file bytes (e.g. temporary import).
    /// `path` is the package-relative path used as the cache key and export path.
    /// Keeps a copy of bytes until flushed to disk on thin Save.
    pub fn loadFromMemory(self: *SampleStore, path: []const u8, bytes: []const u8) !SampleId {
        if (self.path_to_id.get(path)) |existing| {
            self.retain(existing);
            return existing;
        }

        const decoded = try decodeMemory(self.allocator, bytes);
        errdefer self.allocator.free(decoded.pcm);

        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);

        const source = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(source);

        var peak_bins: [peak_bin_count]PeakBin = @splat(.{});
        peaks_mod.buildPeaks(decoded.pcm, decoded.channels, decoded.frame_count, &peak_bins);
        const bits = probeSourceBits(source);

        const id = try self.allocId();
        self.assets.items[id] = .{
            .refcount = 1,
            .path_in_project = path_owned,
            .pcm = decoded.pcm,
            .channels = decoded.channels,
            .sample_rate = decoded.sample_rate,
            .frame_count = decoded.frame_count,
            .duration_seconds = decoded.duration_seconds,
            .original_sample_rate = decoded.original_sample_rate,
            .original_channels = decoded.original_channels,
            .original_bits = bits,
            .source_bytes = source,
            .file_size = bytes.len,
            .file_mtime_ns = 0,
            .peaks = peak_bins,
        };
        errdefer self.assets.items[id] = null;
        try self.path_to_id.put(path_owned, id);
        return id;
    }

    /// Decode from disk; do not keep source_bytes (Pack/Save read the file).
    /// `path_in_project` is the project-relative key; `abs_path` is the file to open.
    pub fn loadFromPath(
        self: *SampleStore,
        path_in_project: []const u8,
        abs_path: []const u8,
        io: std.Io,
    ) !SampleId {
        if (self.path_to_id.get(path_in_project)) |existing| {
            self.retain(existing);
            return existing;
        }

        const bytes = try readFile(self.allocator, io, abs_path);
        defer self.allocator.free(bytes);

        const st = std.Io.Dir.cwd().statFile(io, abs_path, .{}) catch null;
        const size: u64 = if (st) |s| s.size else bytes.len;
        const mtime_ns: i64 = if (st) |s| @intCast(s.mtime.toNanoseconds()) else 0;

        const decoded = try decodeMemory(self.allocator, bytes);
        errdefer self.allocator.free(decoded.pcm);

        const path_owned = try self.allocator.dupe(u8, path_in_project);
        errdefer self.allocator.free(path_owned);

        var peak_bins: [peak_bin_count]PeakBin = @splat(.{});
        peaks_mod.buildPeaks(decoded.pcm, decoded.channels, decoded.frame_count, &peak_bins);
        const bits = probeSourceBits(bytes);

        const id = try self.allocId();
        self.assets.items[id] = .{
            .refcount = 1,
            .path_in_project = path_owned,
            .pcm = decoded.pcm,
            .channels = decoded.channels,
            .sample_rate = decoded.sample_rate,
            .frame_count = decoded.frame_count,
            .duration_seconds = decoded.duration_seconds,
            .original_sample_rate = decoded.original_sample_rate,
            .original_channels = decoded.original_channels,
            .original_bits = bits,
            .source_bytes = null,
            .file_size = size,
            .file_mtime_ns = mtime_ns,
            .peaks = peak_bins,
        };
        errdefer self.assets.items[id] = null;
        try self.path_to_id.put(path_owned, id);
        return id;
    }

    /// Update project-relative path (e.g. after flushing RAM bytes to samples/).
    pub fn setPathInProject(self: *SampleStore, id: SampleId, new_path: []const u8) !void {
        const asset = self.getMut(id) orelse return error.InvalidSampleId;
        if (std.mem.eql(u8, asset.path_in_project, new_path)) return;

        const owned = try self.allocator.dupe(u8, new_path);
        errdefer self.allocator.free(owned);

        _ = self.path_to_id.remove(asset.path_in_project);
        self.allocator.free(asset.path_in_project);
        asset.path_in_project = owned;
        try self.path_to_id.put(owned, id);
    }

    /// Drop in-memory source after a successful flush to disk.
    pub fn clearSourceBytes(self: *SampleStore, id: SampleId, file_size: u64, mtime_ns: i64) void {
        const asset = self.getMut(id) orelse return;
        if (asset.source_bytes) |bytes| {
            self.allocator.free(bytes);
            asset.source_bytes = null;
        }
        asset.file_size = file_size;
        asset.file_mtime_ns = mtime_ns;
    }

    /// Bytes for Pack: source_bytes if present, else read from abs_path.
    pub fn readSourceForPack(
        self: *const SampleStore,
        id: SampleId,
        abs_path: ?[]const u8,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const asset = self.get(id) orelse return error.InvalidSampleId;
        if (asset.source_bytes) |bytes| {
            return try allocator.dupe(u8, bytes);
        }
        const path = abs_path orelse return error.MissingMediaPath;
        return try readFile(allocator, io, path);
    }

    pub fn sourceSize(self: *const SampleStore, id: SampleId) u64 {
        const asset = self.get(id) orelse return 0;
        if (asset.source_bytes) |b| return b.len;
        return asset.file_size;
    }

    fn allocId(self: *SampleStore) !SampleId {
        for (self.assets.items, 0..) |slot, i| {
            if (slot == null) return @intCast(i);
        }
        try self.assets.append(self.allocator, null);
        return @intCast(self.assets.items.len - 1);
    }

    /// Test helper: allocate a free sample slot without loading media.
    pub fn allocIdForTest(self: *SampleStore) !SampleId {
        return self.allocId();
    }
};

const Decoded = struct {
    pcm: []f32,
    channels: u8,
    sample_rate: u32,
    frame_count: u64,
    duration_seconds: f64,
    original_sample_rate: i32,
    original_channels: i32,
};

fn freeAsset(allocator: std.mem.Allocator, asset: *SampleAsset) void {
    allocator.free(asset.path_in_project);
    allocator.free(asset.pcm);
    if (asset.source_bytes) |bytes| {
        allocator.free(bytes);
    }
    asset.* = undefined;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, abs_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, abs_path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    const data = try allocator.alloc(u8, st.size);
    errdefer allocator.free(data);
    const n = try file.readPositionalAll(io, data, 0);
    if (n != st.size) return error.UnexpectedEof;
    return data;
}

fn decodeMemory(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    // Request f32; 0 channels / 0 rate = use source layout (miniaudio).
    const config = zaudio.Decoder.Config.init(.float32, 0, 0);
    const decoder = try zaudio.Decoder.createFromMemory(bytes.ptr, bytes.len, config);
    defer decoder.destroy();

    var format: zaudio.Format = .unknown;
    var channels: u32 = 0;
    var sample_rate: u32 = 0;
    try decoder.getDataFormat(&format, &channels, &sample_rate, null);
    if (channels == 0 or sample_rate == 0) return error.InvalidAudioFormat;
    if (channels > 32) return error.TooManyChannels;

    const frame_count = try decoder.getLengthInPCMFrames();
    if (frame_count == 0) return error.EmptyAudio;

    const sample_count = std.math.mul(usize, @intCast(frame_count), channels) catch return error.AudioTooLarge;
    const pcm = try allocator.alloc(f32, sample_count);
    errdefer allocator.free(pcm);

    const frames_read = try decoder.readPCMFrames(pcm.ptr, frame_count);
    const actual_frames = frames_read;
    const actual_samples = @as(usize, @intCast(actual_frames)) * channels;
    const pcm_final = if (actual_samples < sample_count)
        try shrinkPcm(allocator, pcm, actual_samples)
    else
        pcm;

    const duration = @as(f64, @floatFromInt(actual_frames)) / @as(f64, @floatFromInt(sample_rate));

    return .{
        .pcm = pcm_final,
        .channels = @intCast(channels),
        .sample_rate = sample_rate,
        .frame_count = actual_frames,
        .duration_seconds = duration,
        .original_sample_rate = @intCast(sample_rate),
        .original_channels = @intCast(channels),
    };
}

fn shrinkPcm(allocator: std.mem.Allocator, pcm: []f32, new_len: usize) ![]f32 {
    defer allocator.free(pcm);
    const out = try allocator.alloc(f32, new_len);
    @memcpy(out, pcm[0..new_len]);
    return out;
}

/// Best-effort bits-per-sample from container (WAV PCM/float). 0 if unknown.
fn probeSourceBits(bytes: []const u8) u16 {
    if (bytes.len < 44) return 0;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return 0;
    if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return 0;

    var off: usize = 12;
    while (off + 8 <= bytes.len) {
        const id = bytes[off .. off + 4];
        const size: usize = std.mem.readInt(u32, bytes[off + 4 .. off + 8][0..4], .little);
        const data_off = off + 8;
        if (data_off > bytes.len) break;

        if (std.mem.eql(u8, id, "fmt ") and data_off + 16 <= bytes.len) {
            // WAVEFORMAT: bits_per_sample at offset 14 within fmt payload
            return std.mem.readInt(u16, bytes[data_off + 14 .. data_off + 16][0..2], .little);
        }

        const next = data_off + size + (size & 1); // word-aligned chunks
        if (next <= off) break;
        off = next;
    }
    return 0;
}
