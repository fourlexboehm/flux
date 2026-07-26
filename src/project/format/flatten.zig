//! Flatten nested DAWproject clip timelines into a single audio + warp map.
//!
//! Bitwig and other exporters often nest:
//!   Clip → Clips → Clip → Warps → Audio + Warp*
//! Flux stores one audio region per session slot; this module walks nested
//! structure and returns the first usable audio payload.

const std = @import("std");
const types = @import("types.zig");
const parse = @import("parse.zig");
const xml_writer = @import("xml_writer.zig");

const Clip = types.Clip;
const Audio = types.Audio;
const WarpPoint = types.WarpPoint;
const Warps = types.Warps;
const TimeUnit = types.TimeUnit;
const Project = types.Project;
const toXml = xml_writer.toXml;

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

// ── unit tests ────────────────────────────────────────────────────────────

test "bitwig nested clips flatten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const xml =
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Project version="1.0">
        \\  <Application name="Bitwig Studio" version="5.0"/>
        \\  <Transport>
        \\    <Tempo unit="bpm" value="149.000000" id="id0" name="Tempo"/>
        \\    <TimeSignature denominator="4" numerator="4" id="id1"/>
        \\  </Transport>
        \\  <Structure>
        \\    <Track contentType="audio" loaded="true" id="id9" name="Drumloop">
        \\      <Channel audioChannels="2" role="regular" solo="false" id="id10"/>
        \\    </Track>
        \\  </Structure>
        \\  <Arrangement id="id19">
        \\    <Lanes timeUnit="beats" id="id20">
        \\      <Lanes track="id9" id="id24">
        \\        <Clips id="id25">
        \\          <Clip time="0.0" duration="8.00003433227539" playStart="0.0" loopStart="0.0" loopEnd="8.00003433227539" fadeTimeUnit="beats" fadeInTime="0.0" fadeOutTime="0.0" name="Drumfunk3 170bpm">
        \\            <Clips id="id26">
        \\              <Clip time="0.0" duration="8.00003433227539" contentTimeUnit="beats" playStart="0.0" fadeTimeUnit="beats" fadeInTime="0.0" fadeOutTime="0.0">
        \\                <Warps contentTimeUnit="seconds" timeUnit="beats" id="id28">
        \\                  <Audio algorithm="stretch" channels="2" duration="2.823541666666667" sampleRate="48000" id="id27">
        \\                    <File path="audio/Drumfunk3 170bpm.wav"/>
        \\                  </Audio>
        \\                  <Warp time="0.0" contentTime="0.0"/>
        \\                  <Warp time="8.00003433227539" contentTime="2.823541666666667"/>
        \\                </Warps>
        \\              </Clip>
        \\            </Clips>
        \\          </Clip>
        \\        </Clips>
        \\      </Lanes>
        \\    </Lanes>
        \\  </Arrangement>
        \\  <Scenes/>
        \\</Project>
    ;

    const parsed = try parse.parseProjectXml(allocator, xml);
    const clip = parsed.arrangement.?.lanes.?.children[0].clips.?.clips[0];
    try std.testing.expect(clip.nested_clips != null);
    try std.testing.expectEqual(@as(usize, 1), clip.nested_clips.?.clips.len);
    try std.testing.expect(clip.nested_clips.?.clips[0].warps != null);

    const flat = try flattenClipAudio(allocator, &clip);
    try std.testing.expect(flat != null);
    const f = flat.?;
    try std.testing.expectEqualStrings("audio/Drumfunk3 170bpm.wav", f.audio.file.path);
    try std.testing.expectEqual(@as(i32, 48000), f.audio.sample_rate);
    try std.testing.expectEqualStrings("stretch", f.algorithm.?);
    try std.testing.expectEqual(@as(usize, 2), f.warps.len);
    try std.testing.expectApproxEqAbs(@as(f64, 8.00003433227539), f.duration, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.823541666666667), f.audio.duration, 1e-9);
    try std.testing.expectEqualStrings("Drumfunk3 170bpm", f.name.?);
}

test "session clip slot audio round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const warps_pts = [_]WarpPoint{
        .{ .time = 0.0, .content_time = 0.0 },
        .{ .time = 4.0, .content_time = 2.0 },
    };
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1.0" },
        .tracks = &.{
            .{
                .id = "track0",
                .name = "Audio 1",
                .content_type = .audio,
                .channel = .{ .id = "ch0" },
            },
        },
        .scenes = &.{
            .{
                .id = "scene0",
                .name = "Scene 1",
                .lanes_id = "slanes0",
                .clip_slots = &.{
                    .{
                        .id = "slot0",
                        .track = "track0",
                        .has_stop = true,
                        .clip = .{
                            .time = 0.0,
                            .duration = 4.0,
                            .play_start = 0.0,
                            .loop_start = 0.0,
                            .loop_end = 4.0,
                            .name = "kick",
                            .warps = .{
                                .id = "w0",
                                .time_unit = .beats,
                                .content_time_unit = .seconds,
                                .audio = .{
                                    .id = "a0",
                                    .file = .{ .path = "audio/kick.wav" },
                                    .duration = 2.0,
                                    .sample_rate = 44100,
                                    .channels = 1,
                                    .algorithm = "stretch",
                                },
                                .warps = &warps_pts,
                            },
                        },
                    },
                },
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    const parsed = try parse.parseProjectXml(allocator, xml);
    try std.testing.expectEqual(@as(usize, 1), parsed.scenes.len);
    const slot = parsed.scenes[0].clip_slots[0];
    try std.testing.expect(slot.clip != null);
    const flat = try flattenClipAudio(allocator, &slot.clip.?);
    try std.testing.expect(flat != null);
    try std.testing.expectEqualStrings("audio/kick.wav", flat.?.audio.file.path);
    try std.testing.expectEqual(@as(i32, 1), flat.?.audio.channels);
    try std.testing.expectEqual(@as(usize, 2), flat.?.warps.len);
}

test "identity warps when audio has no warp points" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const clip: Clip = .{
        .time = 0,
        .duration = 4.0,
        .audio = .{
            .file = .{ .path = "audio/raw.wav" },
            .duration = 1.5,
            .sample_rate = 44100,
            .channels = 2,
        },
    };
    const flat = try flattenClipAudio(allocator, &clip);
    try std.testing.expect(flat != null);
    try std.testing.expectEqual(@as(usize, 2), flat.?.warps.len);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), flat.?.warps[1].time, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), flat.?.warps[1].content_time, 1e-9);
}

test "collect audio paths from nested clip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const clip: Clip = .{
        .time = 0,
        .duration = 8,
        .nested_clips = .{
            .id = "inner",
            .clips = &.{
                .{
                    .time = 0,
                    .duration = 8,
                    .warps = .{
                        .content_time_unit = .seconds,
                        .audio = .{
                            .file = .{ .path = "audio/nested.wav" },
                            .duration = 3.0,
                            .sample_rate = 48000,
                            .channels = 2,
                        },
                        .warps = &.{
                            .{ .time = 0, .content_time = 0 },
                            .{ .time = 8, .content_time = 3 },
                        },
                    },
                },
            },
        },
    };

    var paths: std.ArrayList([]const u8) = .empty;
    try collectAudioPaths(allocator, &clip, &paths);
    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
    try std.testing.expectEqualStrings("audio/nested.wav", paths.items[0]);
}
