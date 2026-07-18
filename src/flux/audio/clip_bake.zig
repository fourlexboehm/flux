//! Offline pitch-preserving bake for audio clips (main thread only).
//! Uses Signalsmith Stretch so RT playback is simple 1:1 sample reads.

const std = @import("std");
const stretch_abi = @import("stretch_abi.zig");
const sample_store = @import("sample_store.zig");
const audio_clip_types = @import("../session/audio_clip.zig");
const AudioClip = audio_clip_types.AudioClip;
const WarpMarker = audio_clip_types.WarpMarker;
const BakeKey = audio_clip_types.BakeKey;
const SampleAsset = sample_store.SampleAsset;
const SampleStore = sample_store.SampleStore;

/// Cap baked length to avoid runaway allocations (5 minutes at project SR).
pub const max_baked_seconds: f64 = 5.0 * 60.0;
pub const baked_channels: u8 = 2;

pub fn wantsStretch(algorithm: ?[]const u8) bool {
    const a = algorithm orelse return true; // default: pitch-preserving
    if (a.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(a, "stretch")) return true;
    if (std.ascii.eqlIgnoreCase(a, "signalsmith")) return true;
    // Explicit varispeed / repitch keeps Phase 2 path
    if (std.ascii.eqlIgnoreCase(a, "repitch")) return false;
    if (std.ascii.eqlIgnoreCase(a, "varispeed")) return false;
    if (std.ascii.eqlIgnoreCase(a, "none")) return false;
    // Unknown vendor strings: prefer stretch (musical default)
    return true;
}

pub fn hashWarps(warps: []const WarpMarker) u64 {
    var h: u64 = 14695981039346656037;
    for (warps) |w| {
        h = fnv1a(h, @as(u32, @bitCast(w.beat)));
        h = fnv1a(h, @as(u32, @bitCast(w.content_seconds)));
    }
    return h;
}

fn fnv1a(h: u64, v: u32) u64 {
    var x = h;
    inline for (0..4) |i| {
        const b: u8 = @truncate(v >> @intCast(8 * i));
        x ^= b;
        x *%= 1099511628211;
    }
    return x;
}

pub fn makeBakeKey(clip: *const AudioClip, bpm: f32, host_sr: u32) BakeKey {
    return .{
        .sample_id = clip.sample_id orelse sample_store.invalid_sample_id,
        .bpm = bpm,
        .host_sample_rate = host_sr,
        .length_beats = clip.length_beats,
        .loop_start_beats = clip.loop_start_beats,
        .loop_end_beats = clip.loop_end_beats,
        .warp_hash = hashWarps(clip.warps.items),
        .algorithm_stretch = wantsStretch(clip.algorithm),
    };
}

/// Ensure clip has a valid bake for current BPM/SR. No-op if up to date or not stretch.
/// Safe only on main thread (allocates).
pub fn ensureBaked(
    clip: *AudioClip,
    store: *const SampleStore,
    bpm: f32,
    host_sample_rate: u32,
) !void {
    if (!clip.hasAudio()) {
        clip.clearBake();
        return;
    }
    if (!wantsStretch(clip.algorithm)) {
        clip.clearBake();
        return;
    }

    const key = makeBakeKey(clip, bpm, host_sample_rate);
    if (clip.bake_valid and BakeKey.eql(clip.bake_key, key) and clip.baked_pcm != null) {
        return;
    }

    const sample_id = clip.sample_id.?;
    const asset = store.get(sample_id) orelse {
        clip.clearBake();
        return;
    };

    const baked = try bakeClip(clip.allocator, clip, asset, bpm, host_sample_rate);
    clip.replaceBake(baked.pcm, baked.frames, host_sample_rate, key);
}

const Baked = struct {
    pcm: []f32,
    frames: u64,
};

/// Bake full clip musical length (0..length_beats) at project BPM into stereo host-SR PCM.
fn bakeClip(
    allocator: std.mem.Allocator,
    clip: *const AudioClip,
    asset: *const SampleAsset,
    bpm: f32,
    host_sr: u32,
) !Baked {
    if (bpm <= 0 or host_sr == 0) return error.InvalidRate;
    if (clip.length_beats <= 0) return error.InvalidLength;

    const out_seconds = @as(f64, clip.length_beats) * 60.0 / @as(f64, bpm);
    if (out_seconds > max_baked_seconds) return error.BakeTooLong;

    const total_out_frames: usize = @intFromFloat(@round(out_seconds * @as(f64, @floatFromInt(host_sr))));
    if (total_out_frames == 0) return error.EmptyBake;

    // Build warp segments (at least one spanning the clip).
    var segments_buf: [audio_clip_types.max_warp_points]Segment = undefined;
    const segments = buildSegments(clip, asset, &segments_buf);

    var out = try allocator.alloc(f32, total_out_frames * baked_channels);
    errdefer allocator.free(out);
    @memset(out, 0);

    var out_write: usize = 0;
    for (segments) |seg| {
        if (out_write >= total_out_frames) break;

        const beat_span = seg.beat_end - seg.beat_start;
        if (beat_span <= 0) continue;

        var seg_out_frames: usize = @intFromFloat(@round(beat_span * 60.0 / @as(f64, bpm) * @as(f64, @floatFromInt(host_sr))));
        if (seg_out_frames == 0) continue;
        if (out_write + seg_out_frames > total_out_frames) {
            seg_out_frames = total_out_frames - out_write;
        }

        // Extract source region and resample to host SR (stereo interleaved).
        const in_host = try extractResampledStereo(
            allocator,
            asset,
            seg.content_start,
            seg.content_end,
            host_sr,
        );
        defer allocator.free(in_host);

        const in_frames = in_host.len / baked_channels;
        if (in_frames == 0) {
            out_write += seg_out_frames;
            continue;
        }

        // Near 1:1 ratio (within 0.1%): copy/resample only, skip stretch CPU.
        const ratio = @as(f64, @floatFromInt(seg_out_frames)) / @as(f64, @floatFromInt(in_frames));
        const dest = out[out_write * baked_channels ..][0 .. seg_out_frames * baked_channels];

        if (ratio > 0.999 and ratio < 1.001 and seg_out_frames == in_frames) {
            @memcpy(dest, in_host[0 .. seg_out_frames * baked_channels]);
        } else if (in_frames < 64 or seg_out_frames < 64) {
            // Too short for spectral stretch — linear resample fallback.
            linearResampleStereo(in_host, in_frames, dest, seg_out_frames);
        } else {
            stretch_abi.stretchExact(allocator, baked_channels, @floatFromInt(host_sr), in_host, dest) catch {
                // Fallback if stretch refuses (e.g. very short after seek length).
                linearResampleStereo(in_host, in_frames, dest, seg_out_frames);
            };
        }

        out_write += seg_out_frames;
    }

    return .{ .pcm = out, .frames = total_out_frames };
}

const Segment = struct {
    beat_start: f64,
    beat_end: f64,
    content_start: f64,
    content_end: f64,
};

fn buildSegments(clip: *const AudioClip, asset: *const SampleAsset, buf: []Segment) []Segment {
    const length = @as(f64, clip.length_beats);
    const duration = asset.duration_seconds;

    if (clip.warps.items.len >= 2) {
        var n: usize = 0;
        const warps = clip.warps.items;
        var i: usize = 0;
        while (i + 1 < warps.len and n < buf.len) : (i += 1) {
            const a = warps[i];
            const b = warps[i + 1];
            if (b.beat <= a.beat) continue;
            buf[n] = .{
                .beat_start = a.beat,
                .beat_end = b.beat,
                .content_start = a.content_seconds,
                .content_end = b.content_seconds,
            };
            n += 1;
        }
        if (n > 0) return buf[0..n];
    }

    // Single segment: full clip maps to full sample (or 0..duration).
    buf[0] = .{
        .beat_start = 0,
        .beat_end = length,
        .content_start = 0,
        .content_end = duration,
    };
    return buf[0..1];
}

/// Extract [content_start, content_end) from asset and resample to host_sr stereo interleaved.
fn extractResampledStereo(
    allocator: std.mem.Allocator,
    asset: *const SampleAsset,
    content_start: f64,
    content_end: f64,
    host_sr: u32,
) ![]f32 {
    const src_sr = @as(f64, @floatFromInt(asset.sample_rate));
    if (src_sr <= 0 or asset.frame_count == 0) return try allocator.alloc(f32, 0);

    const start_sec = @max(0.0, content_start);
    const end_sec = @max(start_sec, content_end);
    const span = end_sec - start_sec;
    if (span <= 0) return try allocator.alloc(f32, 0);

    const out_frames: usize = @intFromFloat(@round(span * @as(f64, @floatFromInt(host_sr))));
    if (out_frames == 0) return try allocator.alloc(f32, 0);

    var out = try allocator.alloc(f32, out_frames * baked_channels);
    const ch: usize = asset.channels;
    const pcm = asset.pcm;
    const max_frame = asset.frame_count -| 1;

    for (0..out_frames) |i| {
        const t = start_sec + (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(host_sr)));
        const src_frame_f = t * src_sr;
        const lr = sampleAssetAt(pcm, ch, max_frame, src_frame_f);
        out[i * 2] = lr[0];
        out[i * 2 + 1] = lr[1];
    }
    return out;
}

fn sampleAssetAt(pcm: []const f32, channels: usize, max_frame: u64, frame_f: f64) [2]f32 {
    if (channels == 0 or pcm.len == 0) return .{ 0, 0 };
    const floor_f = @floor(frame_f);
    var idx0: u64 = if (frame_f < 0) 0 else @intFromFloat(floor_f);
    if (idx0 > max_frame) idx0 = max_frame;
    var idx1 = idx0 + 1;
    if (idx1 > max_frame) idx1 = max_frame;
    const frac: f32 = @floatCast(frame_f - floor_f);

    if (channels == 1) {
        const s0 = pcm[@intCast(idx0)];
        const s1 = pcm[@intCast(idx1)];
        const s = s0 + (s1 - s0) * frac;
        return .{ s, s };
    }
    const base0 = @as(usize, @intCast(idx0)) * channels;
    const base1 = @as(usize, @intCast(idx1)) * channels;
    if (base0 + 1 >= pcm.len or base1 + 1 >= pcm.len) return .{ 0, 0 };
    const l0 = pcm[base0];
    const r0 = pcm[base0 + 1];
    const l1 = pcm[base1];
    const r1 = pcm[base1 + 1];
    return .{ l0 + (l1 - l0) * frac, r0 + (r1 - r0) * frac };
}

fn linearResampleStereo(in: []const f32, in_frames: usize, out: []f32, out_frames: usize) void {
    if (out_frames == 0) return;
    if (in_frames == 0) {
        @memset(out, 0);
        return;
    }
    for (0..out_frames) |i| {
        const src_f = if (out_frames == 1)
            0.0
        else
            @as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(in_frames - 1)) / @as(f64, @floatFromInt(out_frames - 1));
        const floor_f = @floor(src_f);
        var idx0: usize = @intFromFloat(floor_f);
        if (idx0 >= in_frames) idx0 = in_frames - 1;
        var idx1 = idx0 + 1;
        if (idx1 >= in_frames) idx1 = in_frames - 1;
        const frac: f32 = @floatCast(src_f - floor_f);
        const l0 = in[idx0 * 2];
        const r0 = in[idx0 * 2 + 1];
        const l1 = in[idx1 * 2];
        const r1 = in[idx1 * 2 + 1];
        out[i * 2] = l0 + (l1 - l0) * frac;
        out[i * 2 + 1] = r0 + (r1 - r0) * frac;
    }
}

/// Bake audio clips that need it (main thread).
/// Prefer `playing_only` so project load / idle frames do not hitch on every clip.
pub fn bakeDirtyClips(
    clips: anytype, // *[max_tracks][max_scenes]AudioClip
    store: *const SampleStore,
    session_clips: anytype, // *[max_tracks][max_scenes]ClipSlot or similar with .state
    track_count: usize,
    scene_count: usize,
    bpm: f32,
    host_sample_rate: u32,
    playing_only: bool,
) void {
    const max_t = @min(track_count, clips.len);
    for (0..max_t) |t| {
        const max_s = @min(scene_count, clips[t].len);
        for (0..max_s) |s| {
            var clip = &clips[t][s];
            if (!clip.hasAudio()) continue;
            if (playing_only) {
                const st = session_clips[t][s].state;
                // Bake for active and soon-to-be-active slots.
                if (st != .playing and st != .queued) continue;
            }
            ensureBaked(clip, store, bpm, host_sample_rate) catch |err| {
                std.log.warn("Audio clip bake failed t={d} s={d}: {}", .{ t, s, err });
            };
        }
    }
}
