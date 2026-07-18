const std = @import("std");
const session_view = @import("types.zig");
const session_constants = @import("constants.zig");
const sample_store = @import("../audio/sample_store.zig");

const NameField = session_view.NameField;
const SampleId = sample_store.SampleId;
const SampleStore = sample_store.SampleStore;

pub const max_warp_points = 64;
pub const default_clip_bars = session_constants.default_clip_bars;
pub const beats_per_bar = session_constants.beats_per_bar;

pub const WarpMarker = struct {
    beat: f32,
    content_seconds: f32,
};

/// Identity of a pitch-preserving bake (invalidate when any field changes).
pub const BakeKey = struct {
    sample_id: SampleId = sample_store.invalid_sample_id,
    bpm: f32 = 0,
    host_sample_rate: u32 = 0,
    length_beats: f32 = 0,
    loop_start_beats: f32 = 0,
    loop_end_beats: f32 = 0,
    warp_hash: u64 = 0,
    algorithm_stretch: bool = false,

    pub fn eql(a: BakeKey, b: BakeKey) bool {
        return a.sample_id == b.sample_id and
            a.bpm == b.bpm and
            a.host_sample_rate == b.host_sample_rate and
            a.length_beats == b.length_beats and
            a.loop_start_beats == b.loop_start_beats and
            a.loop_end_beats == b.loop_end_beats and
            a.warp_hash == b.warp_hash and
            a.algorithm_stretch == b.algorithm_stretch;
    }
};

/// Session-grid audio clip payload (parallel to PianoRollClip).
pub const AudioClip = struct {
    allocator: std.mem.Allocator,
    length_beats: f32 = default_clip_bars * beats_per_bar,
    sample_id: ?SampleId = null,
    play_start_beats: f32 = 0,
    loop_start_beats: f32 = 0,
    /// 0 means "use length_beats"
    loop_end_beats: f32 = 0,
    fade_in_beats: f32 = 0,
    fade_out_beats: f32 = 0,
    warps: std.ArrayListUnmanaged(WarpMarker) = .empty,
    /// Free-form DAWproject algorithm string (e.g. "stretch")
    algorithm: ?[]u8 = null,
    name: NameField = .{},

    // ── Offline pitch-preserving bake (main thread; RT only reads) ──────────
    /// Stereo interleaved f32 at project sample rate. Null when using varispeed.
    baked_pcm: ?[]f32 = null,
    baked_frames: u64 = 0,
    baked_sample_rate: u32 = 0,
    bake_key: BakeKey = .{},
    bake_valid: bool = false,
    /// Freed after RT snapshot drop (same pattern as SampleStore deferred free).
    deferred_bake_free: std.ArrayListUnmanaged([]f32) = .empty,

    pub fn init(allocator: std.mem.Allocator) AudioClip {
        return .{
            .allocator = allocator,
            .length_beats = default_clip_bars * beats_per_bar,
        };
    }

    pub fn deinit(self: *AudioClip, store: ?*SampleStore) void {
        self.clear(store);
        self.flushDeferredBakeFrees();
        self.deferred_bake_free.deinit(self.allocator);
        self.warps.deinit(self.allocator);
    }

    pub fn hasAudio(self: *const AudioClip) bool {
        return self.sample_id != null;
    }

    pub fn hasBaked(self: *const AudioClip) bool {
        return self.bake_valid and self.baked_pcm != null and self.baked_frames > 0;
    }

    pub fn clear(self: *AudioClip, store: ?*SampleStore) void {
        if (self.sample_id) |id| {
            if (store) |s| s.release(id);
            self.sample_id = null;
        }
        if (self.algorithm) |algo| {
            self.allocator.free(algo);
            self.algorithm = null;
        }
        self.clearBake();
        self.warps.clearRetainingCapacity();
        self.play_start_beats = 0;
        self.loop_start_beats = 0;
        self.loop_end_beats = 0;
        self.fade_in_beats = 0;
        self.fade_out_beats = 0;
        self.name = .{};
        self.length_beats = default_clip_bars * beats_per_bar;
    }

    pub fn clearBake(self: *AudioClip) void {
        if (self.baked_pcm) |pcm| {
            self.queueBakeFree(pcm);
            self.baked_pcm = null;
        }
        self.baked_frames = 0;
        self.baked_sample_rate = 0;
        self.bake_key = .{};
        self.bake_valid = false;
    }

    pub fn replaceBake(
        self: *AudioClip,
        pcm: []f32,
        frames: u64,
        sample_rate: u32,
        key: BakeKey,
    ) void {
        if (self.baked_pcm) |old| {
            self.queueBakeFree(old);
        }
        self.baked_pcm = pcm;
        self.baked_frames = frames;
        self.baked_sample_rate = sample_rate;
        self.bake_key = key;
        self.bake_valid = true;
    }

    fn queueBakeFree(self: *AudioClip, pcm: []f32) void {
        self.deferred_bake_free.append(self.allocator, pcm) catch {
            // The active RT snapshot may still reference this buffer. Leak on
            // allocator exhaustion rather than introducing a use-after-free.
        };
    }

    /// Call after RT snapshot swap while audio thread is idle.
    pub fn flushDeferredBakeFrees(self: *AudioClip) void {
        for (self.deferred_bake_free.items) |pcm| {
            self.allocator.free(pcm);
        }
        self.deferred_bake_free.clearRetainingCapacity();
    }

    pub fn setAlgorithm(self: *AudioClip, algo: ?[]const u8) !void {
        if (self.algorithm) |old| {
            self.allocator.free(old);
            self.algorithm = null;
        }
        if (algo) |a| {
            if (a.len > 0) {
                self.algorithm = try self.allocator.dupe(u8, a);
            }
        }
        self.bake_valid = false;
    }

    pub fn setWarps(self: *AudioClip, markers: []const WarpMarker) !void {
        self.warps.clearRetainingCapacity();
        try self.warps.ensureTotalCapacity(self.allocator, markers.len);
        for (markers) |m| {
            try self.warps.append(self.allocator, m);
        }
        self.bake_valid = false;
    }

    pub fn setSample(self: *AudioClip, store: *SampleStore, id: SampleId) void {
        if (self.sample_id) |old| {
            if (old != id) store.release(old);
        }
        self.sample_id = id;
        self.bake_valid = false;
        // caller already owns one ref from load/retain
    }

    /// Copy clip metadata and retain sample ref into `dst` (dst must be empty or will be cleared).
    pub fn copyTo(self: *const AudioClip, dst: *AudioClip, store: *SampleStore) !void {
        dst.clear(store);
        errdefer dst.clear(store);
        dst.length_beats = self.length_beats;
        dst.play_start_beats = self.play_start_beats;
        dst.loop_start_beats = self.loop_start_beats;
        dst.loop_end_beats = self.loop_end_beats;
        dst.fade_in_beats = self.fade_in_beats;
        dst.fade_out_beats = self.fade_out_beats;
        dst.name = self.name;
        try dst.setAlgorithm(self.algorithm);
        try dst.setWarps(self.warps.items);
        if (self.sample_id) |id| {
            store.retain(id);
            dst.sample_id = id;
        }
        // Bake is not copied — destination rebakes on next ensureBaked.
        dst.bake_valid = false;
    }

    /// Replace this clip with ownership moved from `src`, preserving any bake
    /// buffers that still need to survive the active RT snapshot.
    pub fn takeFrom(self: *AudioClip, src: *AudioClip, store: *SampleStore) void {
        self.clear(store);
        src.deferred_bake_free.appendSlice(self.allocator, self.deferred_bake_free.items) catch {};
        self.deferred_bake_free.deinit(self.allocator);
        self.warps.deinit(self.allocator);
        self.* = src.*;
        src.* = AudioClip.init(self.allocator);
    }

    pub fn loopEnd(self: *const AudioClip) f32 {
        if (self.loop_end_beats > 0) return self.loop_end_beats;
        return self.length_beats;
    }
};

/// Command-owned audio state. Retaining the sample keeps it alive after the
/// corresponding live clip is cleared or overwritten.
pub const AudioClipSnapshot = struct {
    clip: AudioClip,
    store: *SampleStore,

    pub fn capture(src: *const AudioClip, store: *SampleStore) !AudioClipSnapshot {
        var snapshot = AudioClipSnapshot{
            .clip = AudioClip.init(src.allocator),
            .store = store,
        };
        errdefer snapshot.deinit();
        try src.copyTo(&snapshot.clip, store);
        return snapshot;
    }

    pub fn apply(self: *const AudioClipSnapshot, dst: *AudioClip) !void {
        try self.clip.copyTo(dst, self.store);
    }

    pub fn deinit(self: *AudioClipSnapshot) void {
        self.clip.deinit(self.store);
    }
};
