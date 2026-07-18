//! Real-time audio clip player (varispeed).
//! Main thread publishes ClipAudioRt + sample table; audio thread only reads.

const std = @import("std");
const sample_store = @import("sample_store.zig");
const session_constants = @import("../ui/session_view/constants.zig");
const audio_clip_types = @import("../ui/audio_clip/types.zig");

pub const SampleId = sample_store.SampleId;
pub const invalid_sample_id = sample_store.invalid_sample_id;

pub const max_warp_points = audio_clip_types.max_warp_points;
/// Fixed sample-table capacity published to the audio thread.
pub const max_rt_samples = 128;
pub const default_clip_bars = session_constants.default_clip_bars;
pub const beats_per_bar = session_constants.beats_per_bar;

pub const WarpMarkerRt = struct {
    beat: f32 = 0,
    content_seconds: f32 = 0,
};

/// Fixed-size RT copy of a session audio clip (no heap pointers except via sample_id / baked).
pub const ClipAudioRt = struct {
    sample_id: SampleId = invalid_sample_id,
    length_beats: f32 = default_clip_bars * beats_per_bar,
    play_start_beats: f32 = 0,
    loop_start_beats: f32 = 0,
    /// 0 means "use length_beats"
    loop_end_beats: f32 = 0,
    fade_in_beats: f32 = 0,
    fade_out_beats: f32 = 0,
    warp_count: u8 = 0,
    warps: [max_warp_points]WarpMarkerRt = @splat(.{}),
    /// When set, RT plays this buffer 1:1 (pitch-preserving bake). Ignore warps/varispeed.
    baked_pcm: ?[*]const f32 = null,
    baked_frames: u64 = 0,
    /// Always stereo interleaved when baked.
    baked_channels: u8 = 2,
    use_baked: bool = false,

    pub fn hasAudio(self: *const ClipAudioRt) bool {
        return self.sample_id != invalid_sample_id or self.use_baked;
    }

    pub fn loopEnd(self: *const ClipAudioRt) f32 {
        if (self.loop_end_beats > 0) return self.loop_end_beats;
        return self.length_beats;
    }

    pub fn clear(self: *ClipAudioRt) void {
        self.* = .{};
    }
};

/// Immutable sample view for the audio thread (pointer is stable while published).
pub const SampleSlotRt = struct {
    pcm: [*]const f32 = undefined,
    frame_count: u64 = 0,
    channels: u8 = 0,
    sample_rate: u32 = 0,
    valid: bool = false,

    pub fn clear(self: *SampleSlotRt) void {
        self.* = .{};
    }
};

pub fn copyClipFromUi(dst: *ClipAudioRt, src: *const audio_clip_types.AudioClip) void {
    dst.clear();
    const id = src.sample_id orelse {
        // Still allow bake-only publish if somehow sample dropped but bake remains.
        if (!src.hasBaked()) return;
        fillClipMeta(dst, src);
        publishBaked(dst, src);
        return;
    };
    if (id >= max_rt_samples and !src.hasBaked()) return;

    if (id < max_rt_samples) dst.sample_id = id;
    fillClipMeta(dst, src);
    if (src.hasBaked()) {
        publishBaked(dst, src);
    } else {
        // Varispeed path: copy warps for RT mapping.
        const n = @min(src.warps.items.len, max_warp_points);
        dst.warp_count = @intCast(n);
        for (0..n) |i| {
            dst.warps[i] = .{
                .beat = src.warps.items[i].beat,
                .content_seconds = src.warps.items[i].content_seconds,
            };
        }
    }
}

fn fillClipMeta(dst: *ClipAudioRt, src: *const audio_clip_types.AudioClip) void {
    dst.length_beats = src.length_beats;
    dst.play_start_beats = src.play_start_beats;
    dst.loop_start_beats = src.loop_start_beats;
    dst.loop_end_beats = src.loop_end_beats;
    dst.fade_in_beats = src.fade_in_beats;
    dst.fade_out_beats = src.fade_out_beats;
}

fn publishBaked(dst: *ClipAudioRt, src: *const audio_clip_types.AudioClip) void {
    const pcm = src.baked_pcm orelse return;
    if (src.baked_frames == 0) return;
    dst.baked_pcm = pcm.ptr;
    dst.baked_frames = src.baked_frames;
    dst.baked_channels = 2;
    dst.use_baked = true;
    // Warps not needed for baked playback.
    dst.warp_count = 0;
}

pub fn publishSampleTable(
    table: *[max_rt_samples]SampleSlotRt,
    store: *const sample_store.SampleStore,
) void {
    for (table) |*slot| slot.clear();
    const count = @min(store.assets.items.len, max_rt_samples);
    for (0..count) |i| {
        const asset = store.assets.items[i] orelse continue;
        if (asset.pcm.len == 0 or asset.frame_count == 0 or asset.channels == 0) continue;
        table[i] = .{
            .pcm = asset.pcm.ptr,
            .frame_count = asset.frame_count,
            .channels = asset.channels,
            .sample_rate = asset.sample_rate,
            .valid = true,
        };
    }
}

/// Per-track RT player: clip-local beat → warps → sample frames → stereo out.
pub const AudioClipSource = struct {
    track_index: usize,
    current_beat: f64 = 0.0,
    last_playing: bool = false,
    last_scene: ?usize = null,

    pub fn init(track_index: usize) AudioClipSource {
        return .{ .track_index = track_index };
    }

    pub fn reset(self: *AudioClipSource) void {
        self.current_beat = 0.0;
        self.last_scene = null;
    }

    /// Render into left/right. Returns true if any non-silent audio was written.
    pub fn process(
        self: *AudioClipSource,
        snapshot: anytype,
        host_sample_rate: f32,
        frame_count: u32,
        left: []f32,
        right: []f32,
    ) bool {
        @memset(left[0..frame_count], 0);
        @memset(right[0..frame_count], 0);

        if (!snapshot.playing) {
            if (self.last_playing) self.reset();
            self.last_playing = false;
            return false;
        }

        const active_scene_i = snapshot.active_scene_by_track[self.track_index];
        if (active_scene_i < 0) {
            if (self.last_scene != null) self.reset();
            self.last_playing = true;
            return false;
        }

        const active_scene: usize = @intCast(active_scene_i);
        const clip = &snapshot.playing_audio[self.track_index];
        if (!clip.hasAudio()) {
            if (self.last_scene != null and self.last_scene.? == active_scene) {
                // Still on this scene but no audio content.
            } else {
                self.reset();
            }
            self.last_scene = active_scene;
            self.last_playing = true;
            return false;
        }

        const scene_changed = self.last_scene == null or self.last_scene.? != active_scene;
        if (scene_changed or !self.last_playing) {
            self.current_beat = @as(f64, clip.play_start_beats);
            self.last_scene = active_scene;
        }
        self.last_playing = true;

        const loop_start = @as(f64, clip.loop_start_beats);
        const loop_end = @as(f64, clip.loopEnd());
        var loop_len = loop_end - loop_start;
        if (loop_len <= 0.0) {
            loop_len = @as(f64, clip.length_beats);
        }
        if (loop_len <= 0.0) return false;

        const beats_per_second = @as(f64, snapshot.bpm) / 60.0;
        if (beats_per_second <= 0.0 or host_sample_rate <= 0.0) return false;
        const beats_per_sample = beats_per_second / @as(f64, host_sample_rate);

        const fade_in = @as(f64, clip.fade_in_beats);
        const fade_out = @as(f64, clip.fade_out_beats);
        const clip_len = @as(f64, clip.length_beats);

        // ── Pitch-preserving path: linear beat → baked frame ────────────────
        if (clip.use_baked) {
            const baked_ptr = clip.baked_pcm orelse return false;
            if (clip.baked_frames == 0) return false;
            const baked_ch: usize = if (clip.baked_channels == 0) 2 else clip.baked_channels;
            const max_frame_index = @as(f64, @floatFromInt(clip.baked_frames -| 1));

            var beat = self.current_beat;
            var wrote = false;
            for (0..frame_count) |i| {
                var local = beat;
                if (local < 0.0) local = 0.0;
                const clip_beat = if (local < loop_end)
                    local
                else
                    loop_start + @mod(local - loop_end, loop_len);

                // Map musical position across full clip length → baked frames.
                const frame_f = if (clip_len > 0.0)
                    (clip_beat / clip_len) * @as(f64, @floatFromInt(clip.baked_frames))
                else
                    0.0;

                if (frame_f >= 0.0 and frame_f <= max_frame_index) {
                    var gain: f32 = 1.0;
                    if (fade_in > 0.0 and clip_beat < fade_in) {
                        gain *= @floatCast(clip_beat / fade_in);
                    }
                    if (fade_out > 0.0 and clip_len > 0.0) {
                        const fade_start = clip_len - fade_out;
                        if (clip_beat > fade_start) {
                            const rem = clip_len - clip_beat;
                            gain *= @floatCast(@max(0.0, rem / fade_out));
                        }
                    }
                    const lr = sampleAt(baked_ptr, baked_ch, clip.baked_frames, frame_f);
                    left[i] = lr[0] * gain;
                    right[i] = lr[1] * gain;
                    if (gain != 0.0 and (lr[0] != 0.0 or lr[1] != 0.0)) wrote = true;
                }
                beat += beats_per_sample;
            }
            self.current_beat = beat;
            return wrote;
        }

        // ── Varispeed path (Phase 2): warps → content seconds → source frames ─
        const sample = if (clip.sample_id < max_rt_samples)
            snapshot.sample_table[clip.sample_id]
        else
            SampleSlotRt{};
        if (!sample.valid or sample.frame_count == 0 or sample.sample_rate == 0) {
            return false;
        }

        const channels: usize = sample.channels;
        const src_rate = @as(f64, @floatFromInt(sample.sample_rate));
        const max_frame_index = @as(f64, @floatFromInt(sample.frame_count -| 1));
        const pcm = sample.pcm;

        var beat = self.current_beat;
        var wrote = false;

        for (0..frame_count) |i| {
            var local = beat;
            if (local < 0.0) local = 0.0;
            const clip_beat = if (local < loop_end)
                local
            else
                loop_start + @mod(local - loop_end, loop_len);

            const content_sec = beatToContentSeconds(clip, clip_beat, sample);
            if (content_sec) |sec| {
                if (sec >= 0.0) {
                    const frame_f = sec * src_rate;
                    if (frame_f >= 0.0 and frame_f <= max_frame_index) {
                        var gain: f32 = 1.0;
                        if (fade_in > 0.0 and clip_beat < fade_in) {
                            gain *= @floatCast(clip_beat / fade_in);
                        }
                        if (fade_out > 0.0 and clip_len > 0.0) {
                            const fade_start = clip_len - fade_out;
                            if (clip_beat > fade_start) {
                                const rem = clip_len - clip_beat;
                                gain *= @floatCast(@max(0.0, rem / fade_out));
                            }
                        }

                        const lr = sampleAt(pcm, channels, sample.frame_count, frame_f);
                        left[i] = lr[0] * gain;
                        right[i] = lr[1] * gain;
                        if (gain != 0.0 and (lr[0] != 0.0 or lr[1] != 0.0)) wrote = true;
                    }
                }
            }

            beat += beats_per_sample;
        }

        self.current_beat = beat;
        return wrote;
    }
};

/// Piecewise-linear warp: clip beat → content seconds.
/// No warps: map [0, length_beats] → [0, duration] using sample duration.
pub fn beatToContentSeconds(clip: *const ClipAudioRt, beat: f64, sample: SampleSlotRt) ?f64 {
    if (clip.warp_count >= 2) {
        const warps = clip.warps[0..clip.warp_count];
        // Before first / after last: clamp to endpoint content.
        if (beat <= warps[0].beat) return @as(f64, warps[0].content_seconds);
        const last = warps[warps.len - 1];
        if (beat >= last.beat) return @as(f64, last.content_seconds);

        var i: usize = 0;
        while (i + 1 < warps.len) : (i += 1) {
            const a = warps[i];
            const b = warps[i + 1];
            if (beat >= a.beat and beat <= b.beat) {
                const span = @as(f64, b.beat) - @as(f64, a.beat);
                if (span <= 0.0) return @as(f64, a.content_seconds);
                const t = (beat - @as(f64, a.beat)) / span;
                return @as(f64, a.content_seconds) + t * (@as(f64, b.content_seconds) - @as(f64, a.content_seconds));
            }
        }
        return @as(f64, last.content_seconds);
    }

    if (clip.warp_count == 1) {
        // Single marker: offset only (identity rate from beat 0).
        const w = clip.warps[0];
        const bpm_sec_per_beat = 1.0; // content advances 1:1 with beat offset from marker
        _ = bpm_sec_per_beat;
        // Without a second point, treat content = content_seconds + (beat - warp.beat) * (duration/length)
        const length = @as(f64, clip.length_beats);
        if (length <= 0.0 or sample.sample_rate == 0) return null;
        const duration = @as(f64, @floatFromInt(sample.frame_count)) / @as(f64, @floatFromInt(sample.sample_rate));
        const rel = beat - @as(f64, w.beat);
        return @as(f64, w.content_seconds) + rel * (duration / length);
    }

    // No warps: linear map full clip to full sample.
    const length = @as(f64, clip.length_beats);
    if (length <= 0.0 or sample.sample_rate == 0) return null;
    const duration = @as(f64, @floatFromInt(sample.frame_count)) / @as(f64, @floatFromInt(sample.sample_rate));
    return (beat / length) * duration;
}

fn sampleAt(pcm: [*]const f32, channels: usize, frame_count: u64, frame_f: f64) [2]f32 {
    if (frame_count == 0 or channels == 0) return .{ 0, 0 };

    const max_idx = frame_count - 1;
    const floor_f = @floor(frame_f);
    var idx0: u64 = @intFromFloat(floor_f);
    if (idx0 > max_idx) idx0 = max_idx;
    var idx1 = idx0 + 1;
    if (idx1 > max_idx) idx1 = max_idx;
    const frac: f32 = @floatCast(frame_f - floor_f);

    if (channels == 1) {
        const s0 = pcm[idx0];
        const s1 = pcm[idx1];
        const s = s0 + (s1 - s0) * frac;
        return .{ s, s };
    }

    // Stereo (or multi): use first two channels, linear interp.
    const base0 = idx0 * channels;
    const base1 = idx1 * channels;
    const l0 = pcm[base0];
    const r0 = pcm[base0 + 1];
    const l1 = pcm[base1];
    const r1 = pcm[base1 + 1];
    return .{
        l0 + (l1 - l0) * frac,
        r0 + (r1 - r0) * frac,
    };
}

// ── unit tests (warp / interpolation; no audio device) ──────────────────────

test "beatToContentSeconds linear warps" {
    var clip: ClipAudioRt = .{
        .sample_id = 0,
        .length_beats = 4,
        .warp_count = 2,
        .warps = undefined,
    };
    clip.warps[0] = .{ .beat = 0, .content_seconds = 0 };
    clip.warps[1] = .{ .beat = 4, .content_seconds = 2 };
    const sample = SampleSlotRt{
        .pcm = undefined,
        .frame_count = 96000,
        .channels = 2,
        .sample_rate = 48000,
        .valid = true,
    };
    const mid = beatToContentSeconds(&clip, 2.0, sample).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), mid, 1e-9);
    const start = beatToContentSeconds(&clip, 0.0, sample).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), start, 1e-9);
    const end = beatToContentSeconds(&clip, 4.0, sample).?;
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), end, 1e-9);
}

test "beatToContentSeconds no warps uses full duration" {
    var clip: ClipAudioRt = .{
        .sample_id = 0,
        .length_beats = 4,
        .warp_count = 0,
    };
    const sample = SampleSlotRt{
        .pcm = undefined,
        .frame_count = 48000,
        .channels = 1,
        .sample_rate = 48000,
        .valid = true,
    };
    // 1 second sample, 4 beats → beat 2 = 0.5s
    const mid = beatToContentSeconds(&clip, 2.0, sample).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), mid, 1e-9);
}

test "sampleAt mono upmix" {
    const pcm = [_]f32{ 0.0, 1.0, 0.5 };
    const lr = sampleAt(&pcm, 1, 3, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), lr[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), lr[1], 1e-6);
}
