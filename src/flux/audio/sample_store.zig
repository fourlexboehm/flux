//! Sample asset store for audio clips (main thread only).
//! Loads media via zaudio (miniaudio), keeps source bytes for DAWproject re-export.

const std = @import("std");
const zaudio = @import("zaudio");
const peaks_mod = @import("../ui/audio_clip/peaks.zig");

pub const SampleId = u32;
pub const invalid_sample_id: SampleId = std.math.maxInt(SampleId);

pub const peak_bin_count = peaks_mod.peak_bin_count;
pub const PeakBin = peaks_mod.PeakBin;

pub const SampleAsset = struct {
    refcount: u32 = 1,
    /// Path inside the .dawproject package (e.g. "audio/loop.wav")
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
    /// Original file bytes for lossless re-export
    source_bytes: []u8,
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

    /// Load or retain a sample from in-memory file bytes (e.g. from dawproject ZIP).
    /// `path` is the package-relative path used as the cache key and export path.
    pub fn loadFromMemory(self: *SampleStore, path: []const u8, bytes: []const u8) !SampleId {
        if (self.path_to_id.get(path)) |existing| {
            self.retain(existing);
            return existing;
        }

        const decoded = try decodeMemory(self.allocator, bytes);
        errdefer {
            self.allocator.free(decoded.pcm);
        }

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
            .peaks = peak_bins,
        };
        errdefer self.assets.items[id] = null;
        try self.path_to_id.put(path_owned, id);
        return id;
    }

    fn allocId(self: *SampleStore) !SampleId {
        for (self.assets.items, 0..) |slot, i| {
            if (slot == null) return @intCast(i);
        }
        try self.assets.append(self.allocator, null);
        return @intCast(self.assets.items.len - 1);
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
    allocator.free(asset.source_bytes);
    asset.* = undefined;
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
