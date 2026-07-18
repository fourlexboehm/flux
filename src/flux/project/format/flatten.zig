//! Flatten nested DAWproject clip timelines into a single audio + warp map.
//!
//! Bitwig and other exporters often nest:
//!   Clip → Clips → Clip → Warps → Audio + Warp*
//! Flux stores one audio region per session slot; this module walks nested
//! structure and returns the first usable audio payload.

const std = @import("std");
const types = @import("types.zig");

const Clip = types.Clip;
const Audio = types.Audio;
const WarpPoint = types.WarpPoint;
const Warps = types.Warps;
const TimeUnit = types.TimeUnit;

/// Flattened audio content for a clip (session or arrangement).
pub const FlattenedAudio = struct {
    /// Placement on the outermost clip (parent timeline units, usually beats).
    time: f64,
    duration: f64,
    play_start: f64 = 0.0,
    play_stop: ?f64 = null,
    loop_start: ?f64 = null,
    loop_end: ?f64 = null,
    fade_in_time: ?f64 = null,
    fade_out_time: ?f64 = null,
    fade_time_unit: ?TimeUnit = null,
    name: ?[]const u8 = null,
    enable: bool = true,
    content_time_unit: TimeUnit = .beats,
    audio: Audio,
    /// Outer time unit for warp points (usually beats).
    warp_time_unit: TimeUnit = .beats,
    /// Content time unit for warp points (usually seconds).
    warp_content_time_unit: TimeUnit = .seconds,
    warps: []const WarpPoint,
    algorithm: ?[]const u8 = null,
};

/// Walk clip (and nested clips) and extract the first audio + warp map found.
/// Allocator is used only if synthetic identity warps must be allocated.
pub fn flattenClipAudio(allocator: std.mem.Allocator, clip: *const Clip) !?FlattenedAudio {
    return try flattenClipAudioRec(allocator, clip, clip.time, 0);
}

fn flattenClipAudioRec(
    allocator: std.mem.Allocator,
    clip: *const Clip,
    outer_time: f64,
    depth: usize,
) !?FlattenedAudio {
    if (depth > 8) return null;

    // Direct Warps under this clip
    if (clip.warps) |warps| {
        if (warps.audio) |audio| {
            const points = try ensureWarpPoints(allocator, &warps, clip.duration, audio.duration);
            return .{
                .time = outer_time,
                .duration = clip.duration,
                .play_start = clip.play_start,
                .play_stop = clip.play_stop,
                .loop_start = clip.loop_start,
                .loop_end = clip.loop_end,
                .fade_in_time = clip.fade_in_time,
                .fade_out_time = clip.fade_out_time,
                .fade_time_unit = clip.fade_time_unit,
                .name = clip.name,
                .enable = clip.enable,
                .content_time_unit = clip.content_time_unit orelse .beats,
                .audio = audio,
                .warp_time_unit = warps.time_unit orelse .beats,
                .warp_content_time_unit = warps.content_time_unit,
                .warps = points,
                .algorithm = audio.algorithm,
            };
        }
    }

    // Direct Audio under this clip (no warps) → identity map
    if (clip.audio) |audio| {
        const points = try identityWarps(allocator, clip.duration, audio.duration);
        return .{
            .time = outer_time,
            .duration = clip.duration,
            .play_start = clip.play_start,
            .play_stop = clip.play_stop,
            .loop_start = clip.loop_start,
            .loop_end = clip.loop_end,
            .fade_in_time = clip.fade_in_time,
            .fade_out_time = clip.fade_out_time,
            .fade_time_unit = clip.fade_time_unit,
            .name = clip.name,
            .enable = clip.enable,
            .content_time_unit = clip.content_time_unit orelse .beats,
            .audio = audio,
            .warp_time_unit = .beats,
            .warp_content_time_unit = .seconds,
            .warps = points,
            .algorithm = audio.algorithm,
        };
    }

    // Nested Clips timeline (Bitwig audio events inside a clip)
    if (clip.nested_clips) |nested| {
        for (nested.clips) |inner| {
            // Prefer outer clip placement for session length; offset by inner.time for arrangement.
            const child_time = outer_time + inner.time;
            if (try flattenClipAudioRec(allocator, &inner, child_time, depth + 1)) |found| {
                // Keep outer clip's duration/name/loop when nested is an event timeline.
                return .{
                    .time = outer_time,
                    .duration = clip.duration,
                    .play_start = clip.play_start,
                    .play_stop = clip.play_stop,
                    .loop_start = clip.loop_start,
                    .loop_end = clip.loop_end,
                    .fade_in_time = clip.fade_in_time orelse found.fade_in_time,
                    .fade_out_time = clip.fade_out_time orelse found.fade_out_time,
                    .fade_time_unit = clip.fade_time_unit orelse found.fade_time_unit,
                    .name = clip.name orelse found.name,
                    .enable = clip.enable and found.enable,
                    .content_time_unit = clip.content_time_unit orelse found.content_time_unit,
                    .audio = found.audio,
                    .warp_time_unit = found.warp_time_unit,
                    .warp_content_time_unit = found.warp_content_time_unit,
                    // Shift warp outer times by inner placement so they align to outer clip
                    .warps = try shiftWarpTimes(allocator, found.warps, inner.time),
                    .algorithm = found.algorithm,
                };
            }
        }
    }

    return null;
}

fn ensureWarpPoints(
    allocator: std.mem.Allocator,
    warps: *const Warps,
    clip_duration: f64,
    audio_duration: f64,
) ![]const WarpPoint {
    if (warps.warps.len >= 2) return warps.warps;
    return identityWarps(allocator, clip_duration, audio_duration);
}

fn identityWarps(allocator: std.mem.Allocator, clip_duration: f64, audio_duration: f64) ![]const WarpPoint {
    const points = try allocator.alloc(WarpPoint, 2);
    points[0] = .{ .time = 0.0, .content_time = 0.0 };
    points[1] = .{ .time = clip_duration, .content_time = audio_duration };
    return points;
}

fn shiftWarpTimes(allocator: std.mem.Allocator, warps: []const WarpPoint, offset: f64) ![]const WarpPoint {
    if (offset == 0.0) return warps;
    const out = try allocator.alloc(WarpPoint, warps.len);
    for (warps, 0..) |wp, i| {
        out[i] = .{ .time = wp.time + offset, .content_time = wp.content_time };
    }
    return out;
}

/// Collect all file paths referenced by audio under a clip tree (for media packing).
pub fn collectAudioPaths(allocator: std.mem.Allocator, clip: *const Clip, out: *std.ArrayList([]const u8)) !void {
    if (clip.warps) |warps| {
        if (warps.audio) |audio| {
            if (audio.file.path.len > 0) try out.append(allocator, audio.file.path);
        }
    }
    if (clip.audio) |audio| {
        if (audio.file.path.len > 0) try out.append(allocator, audio.file.path);
    }
    if (clip.nested_clips) |nested| {
        for (nested.clips) |inner| {
            try collectAudioPaths(allocator, &inner, out);
        }
    }
}

/// Build a simple Flux export clip: placement + Warps(Audio + 2+ warp points).
pub fn makeAudioClip(
    time: f64,
    duration: f64,
    name: ?[]const u8,
    audio: Audio,
    warps: []const WarpPoint,
    time_unit: TimeUnit,
    content_time_unit: TimeUnit,
    warps_id: []const u8,
) Clip {
    return .{
        .time = time,
        .duration = duration,
        .play_start = 0.0,
        .loop_start = 0.0,
        .loop_end = duration,
        .name = name,
        .enable = true,
        .warps = .{
            .id = warps_id,
            .time_unit = time_unit,
            .content_time_unit = content_time_unit,
            .audio = audio,
            .warps = warps,
        },
    };
}
