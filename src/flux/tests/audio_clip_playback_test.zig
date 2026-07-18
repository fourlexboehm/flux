//! Offline unit tests for Phase 2/3 audio clip playback (no device, no RT alloc).
const std = @import("std");
const audio_clip_source = @import("../audio/audio_clip_source.zig");
const clip_bake = @import("../audio/clip_bake.zig");
const sample_store = @import("../audio/sample_store.zig");
const audio_clip_types = @import("../session/audio_clip.zig");
const session_constants = @import("../session/constants.zig");

const max_tracks = session_constants.max_tracks;
const ClipAudioRt = audio_clip_source.ClipAudioRt;
const SampleSlotRt = audio_clip_source.SampleSlotRt;
const max_rt_samples = audio_clip_source.max_rt_samples;
const AudioClipSource = audio_clip_source.AudioClipSource;

/// Minimal snapshot shape matching what AudioClipSource.process reads.
const TestSnapshot = struct {
    playing: bool = true,
    bpm: f32 = 120,
    active_scene_by_track: [max_tracks]i16 = @splat(-1),
    playing_audio: [max_tracks]ClipAudioRt = @splat(.{}),
    sample_table: [max_rt_samples]SampleSlotRt = @splat(.{}),
};

test {
    _ = @import("../audio/audio_clip_source.zig");
    _ = @import("../session/peaks.zig");
}

test "player: sine sample loops with energy" {
    const sr: u32 = 48000;
    const frames: usize = sr; // 1 second
    var pcm: [48000]f32 = undefined;
    for (&pcm, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr));
        s.* = 0.5 * @sin(2.0 * std.math.pi * 440.0 * t);
    }

    var snap: TestSnapshot = .{};
    snap.active_scene_by_track[0] = 0;
    snap.playing_audio[0] = .{
        .sample_id = 0,
        .length_beats = 4,
        .loop_start_beats = 0,
        .loop_end_beats = 4,
        .warp_count = 2,
        .warps = undefined,
    };
    snap.playing_audio[0].warps[0] = .{ .beat = 0, .content_seconds = 0 };
    snap.playing_audio[0].warps[1] = .{ .beat = 4, .content_seconds = 1 };
    snap.sample_table[0] = .{
        .pcm = &pcm,
        .frame_count = frames,
        .channels = 1,
        .sample_rate = sr,
        .valid = true,
    };

    var player = AudioClipSource.init(0);
    var left: [128]f32 = undefined;
    var right: [128]f32 = undefined;

    const wrote = player.process(&snap, @floatFromInt(sr), 128, &left, &right);
    try std.testing.expect(wrote);

    var peak: f32 = 0;
    for (left) |s| peak = @max(peak, @abs(s));
    for (right) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.05);

    // Second block continues (loop phase advances)
    const beat_after = player.current_beat;
    _ = player.process(&snap, @floatFromInt(sr), 128, &left, &right);
    try std.testing.expect(player.current_beat > beat_after);
}

test "player: silence when not playing" {
    var pcm = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    var snap: TestSnapshot = .{ .playing = false };
    snap.active_scene_by_track[0] = 0;
    snap.playing_audio[0] = .{
        .sample_id = 0,
        .length_beats = 4,
        .warp_count = 0,
    };
    snap.sample_table[0] = .{
        .pcm = &pcm,
        .frame_count = 4,
        .channels = 1,
        .sample_rate = 48000,
        .valid = true,
    };

    var player = AudioClipSource.init(0);
    var left: [32]f32 = undefined;
    var right: [32]f32 = undefined;
    const wrote = player.process(&snap, 48000, 32, &left, &right);
    try std.testing.expect(!wrote);
    for (left) |s| try std.testing.expect(s == 0);
}

test "player: invalid sample id produces silence" {
    var snap: TestSnapshot = .{};
    snap.active_scene_by_track[0] = 0;
    snap.playing_audio[0] = .{
        .sample_id = 0,
        .length_beats = 4,
        .warp_count = 0,
    };
    // sample_table[0].valid == false

    var player = AudioClipSource.init(0);
    var left: [16]f32 = undefined;
    var right: [16]f32 = undefined;
    const wrote = player.process(&snap, 48000, 16, &left, &right);
    try std.testing.expect(!wrote);
}

test "player: playStart offsets first rendered sample" {
    var pcm = [_]f32{ 0.0, 0.25, 0.5, 0.75 };
    var snap: TestSnapshot = .{ .bpm = 60 };
    snap.active_scene_by_track[0] = 0;
    snap.playing_audio[0] = .{
        .sample_id = 0,
        .length_beats = 4,
        .play_start_beats = 2,
        .loop_end_beats = 4,
    };
    snap.sample_table[0] = .{
        .pcm = &pcm,
        .frame_count = pcm.len,
        .channels = 1,
        .sample_rate = 4,
        .valid = true,
    };

    var player = AudioClipSource.init(0);
    var left: [1]f32 = undefined;
    var right: [1]f32 = undefined;
    try std.testing.expect(player.process(&snap, 4, 1, &left, &right));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), left[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), right[0], 1e-6);
}

test "warp varispeed: shorter content window raises playback rate" {
    // 4 beats map to 0.5s content → faster than 4 beats → 1s
    const sr: u32 = 48000;
    var pcm: [24000]f32 = undefined; // 0.5s
    for (&pcm, 0..) |*s, i| {
        s.* = if (i % 2 == 0) 1.0 else -1.0;
    }

    var snap: TestSnapshot = .{};
    snap.active_scene_by_track[0] = 0;
    snap.playing_audio[0] = .{
        .sample_id = 0,
        .length_beats = 4,
        .loop_end_beats = 4,
        .warp_count = 2,
        .warps = undefined,
    };
    snap.playing_audio[0].warps[0] = .{ .beat = 0, .content_seconds = 0 };
    snap.playing_audio[0].warps[1] = .{ .beat = 4, .content_seconds = 0.5 };
    snap.sample_table[0] = .{
        .pcm = &pcm,
        .frame_count = pcm.len,
        .channels = 1,
        .sample_rate = sr,
        .valid = true,
    };

    var player = AudioClipSource.init(0);
    var left: [256]f32 = undefined;
    var right: [256]f32 = undefined;
    _ = player.process(&snap, @floatFromInt(sr), 256, &left, &right);

    // At 120 BPM, 256 frames ≈ 256/48000 s ≈ 0.00533 s ≈ 0.0107 beats.
    // Content rate = 0.5s / 4 beats = 0.125 s/beat → ~0.00133 s content in block.
    // Frame advance ≈ 0.00133 * 48000 ≈ 64 frames of source — we should have non-zero.
    var energy: f32 = 0;
    for (left) |s| energy += s * s;
    try std.testing.expect(energy > 0.01);
}

test "init playing_audio clear does not claim sample 0" {
    var clip: ClipAudioRt = .{};
    // Zero-init would make sample_id==0 which is a valid id; default must be invalid.
    try std.testing.expect(!clip.hasAudio());
    clip.clear();
    try std.testing.expect(!clip.hasAudio());
}

test "wantsStretch defaults and overrides" {
    try std.testing.expect(clip_bake.wantsStretch(null));
    try std.testing.expect(clip_bake.wantsStretch("stretch"));
    try std.testing.expect(clip_bake.wantsStretch("STRETCH"));
    try std.testing.expect(!clip_bake.wantsStretch("varispeed"));
    try std.testing.expect(!clip_bake.wantsStretch("repitch"));
}

test "player: baked path linear beat mapping" {
    // 4 beats baked into 100 frames of constant stereo.
    var pcm: [200]f32 = undefined;
    for (0..100) |i| {
        pcm[i * 2] = 0.5;
        pcm[i * 2 + 1] = -0.5;
    }

    var snap: TestSnapshot = .{};
    snap.active_scene_by_track[0] = 0;
    snap.playing_audio[0] = .{
        .sample_id = 0,
        .length_beats = 4,
        .loop_end_beats = 4,
        .use_baked = true,
        .baked_pcm = &pcm,
        .baked_frames = 100,
        .baked_channels = 2,
    };

    var player = AudioClipSource.init(0);
    var left: [64]f32 = undefined;
    var right: [64]f32 = undefined;
    const wrote = player.process(&snap, 44100, 64, &left, &right);
    try std.testing.expect(wrote);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), left[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), right[0], 1e-5);
}

test "stretchExact doubles duration with energy" {
    const allocator = std.testing.allocator;
    const ch: u8 = 2;
    const in_frames: usize = 8000;
    const out_frames: usize = 16000;
    const in = try allocator.alloc(f32, in_frames * ch);
    defer allocator.free(in);
    const out = try allocator.alloc(f32, out_frames * ch);
    defer allocator.free(out);
    for (0..in_frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        const s = 0.25 * @sin(2.0 * std.math.pi * 440.0 * t);
        in[i * 2] = s;
        in[i * 2 + 1] = s;
    }
    @memset(out, 0);

    const stretch_abi = @import("../audio/stretch_abi.zig");
    try stretch_abi.stretchExact(allocator, ch, 44100, in, out);

    var energy: f64 = 0;
    for (out) |s| energy += @as(f64, s) * @as(f64, s);
    try std.testing.expect(energy > 1.0);
}

test "offline bake: inject asset and stretch to musical length" {
    const allocator = std.testing.allocator;
    const host_sr: u32 = 44100;
    const src_frames: usize = 8000; // short for fast test

    // Inject a synthetic sample asset without zaudio.
    var store = sample_store.SampleStore.init(allocator);
    defer store.deinit();

    const pcm = try allocator.alloc(f32, src_frames);
    errdefer allocator.free(pcm);
    for (0..src_frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        pcm[i] = 0.25 * @sin(2.0 * std.math.pi * 220.0 * t);
    }
    const path = try allocator.dupe(u8, "test/inject.wav");
    errdefer allocator.free(path);
    const source = try allocator.dupe(u8, "dummy");
    errdefer allocator.free(source);

    try store.assets.append(allocator, .{
        .refcount = 1,
        .path_in_project = path,
        .pcm = pcm,
        .channels = 1,
        .sample_rate = 44100,
        .frame_count = src_frames,
        .duration_seconds = @as(f64, @floatFromInt(src_frames)) / 44100.0,
        .original_sample_rate = 44100,
        .original_channels = 1,
        .source_bytes = source,
    });
    try store.path_to_id.put(path, 0);
    const id: sample_store.SampleId = 0;

    var clip = audio_clip_types.AudioClip.init(allocator);
    defer clip.deinit(&store);
    // Musical length 4 beats @ 120 BPM = 2s → ~88200 frames if full; use shorter content map.
    // Map 4 beats → content duration (~0.181s) so out is 2s stretch of short sample.
    clip.length_beats = 4;
    try clip.setAlgorithm("stretch");
    try clip.setWarps(&.{
        .{ .beat = 0, .content_seconds = 0 },
        .{ .beat = 4, .content_seconds = @as(f32, @floatFromInt(src_frames)) / 44100.0 },
    });
    clip.setSample(&store, id);
    // setSample assumes caller owns ref — we already have refcount 1 on the asset.

    try clip_bake.ensureBaked(&clip, &store, 120, host_sr);
    try std.testing.expect(clip.hasBaked());
    try std.testing.expect(@abs(@as(i64, @intCast(clip.baked_frames)) - 88200) < 50);

    const ptr_before = clip.baked_pcm.?.ptr;
    try clip_bake.ensureBaked(&clip, &store, 120, host_sr);
    try std.testing.expect(clip.baked_pcm.?.ptr == ptr_before);

    try clip_bake.ensureBaked(&clip, &store, 140, host_sr);
    try std.testing.expect(clip.hasBaked());
    const expected_140: i64 = @intFromFloat(4.0 * 60.0 / 140.0 * 44100.0);
    try std.testing.expect(@abs(@as(i64, @intCast(clip.baked_frames)) - expected_140) < 50);
}
