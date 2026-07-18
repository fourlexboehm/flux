const std = @import("std");

const sample_store = @import("../../audio/sample_store.zig");
const audio_clip_types = @import("../../session/audio_clip.zig");
const piano_roll_types = @import("../../session/notes.zig");
const session_constants = @import("../../session/constants.zig");
const ui_state = @import("../../ui/state.zig");

const flatten = @import("../format/flatten.zig");
const types = @import("../format/types.zig");
const project_io = @import("../io.zig");
const media_layout = @import("../media/layout.zig");
const time_mod = @import("time.zig");

const track_count = session_constants.max_tracks;
const scene_count = session_constants.max_scenes;

pub fn applyLanes(
    state: *ui_state.State,
    loaded: *const project_io.LoadedProject,
    io: std.Io,
    lanes: *const types.Lanes,
    tracks: []const types.Track,
    instrument_device_ids: *const [track_count]?[]const u8,
    fx_device_ids: *const [track_count][ui_state.max_fx_slots]?[]const u8,
) !void {
    // Find track index for this lane
    var track_idx: ?usize = null;
    if (lanes.track) |track_id| {
        for (tracks, 0..) |track, t| {
            if (std.mem.eql(u8, track.id, track_id)) {
                track_idx = t;
                break;
            }
        }
    }

    // Process clips in this lane
    if (lanes.clips) |clips| {
        if (track_idx) |t| {
            if (t < track_count) {
                // Ensure scene count covers arrangement clips mapped to scenes
                if (clips.clips.len > state.session.scene_count) {
                    state.session.scene_count = @min(clips.clips.len, scene_count);
                }
                for (clips.clips, 0..) |clip, s| {
                    if (s >= scene_count) break;
                    state.session.clips[t][s] = .{
                        .state = .stopped,
                        .length_beats = @floatCast(clip.duration),
                    };
                    try applyClipContent(state, loaded, io, t, s, &clip, tracks, instrument_device_ids, fx_device_ids);
                }
            }
        }
    }

    // Recurse into child lanes
    for (lanes.children) |child| {
        try applyLanes(state, loaded, io, &child, tracks, instrument_device_ids, fx_device_ids);
    }
}

pub fn applyScenes(
    state: *ui_state.State,
    loaded: *const project_io.LoadedProject,
    io: std.Io,
    scenes: []const types.Scene,
    tracks: []const types.Track,
    master_track: ?types.Track,
    instrument_device_ids: *const [track_count]?[]const u8,
    fx_device_ids: *const [track_count][ui_state.max_fx_slots]?[]const u8,
) !void {
    const project_scene_count = @min(scenes.len, scene_count);
    for (0..project_scene_count) |s| {
        const scene = scenes[s];
        for (scene.clip_slots) |slot| {
            var track_idx: ?usize = null;
            for (tracks, 0..) |track, t| {
                if (std.mem.eql(u8, track.id, slot.track)) {
                    track_idx = t;
                    break;
                }
            }
            if (track_idx == null and master_track != null) {
                if (std.mem.eql(u8, master_track.?.id, slot.track)) {
                    continue;
                }
            }
            if (track_idx) |t| {
                if (t >= track_count) continue;
                if (slot.clip) |clip| {
                    state.session.clips[t][s] = .{
                        .state = .stopped,
                        .length_beats = @floatCast(clip.duration),
                    };
                    try applyClipContent(state, loaded, io, t, s, &clip, tracks, instrument_device_ids, fx_device_ids);
                }
            }
        }
    }
}

fn applyClipContent(
    state: *ui_state.State,
    loaded: *const project_io.LoadedProject,
    io: std.Io,
    track_idx: usize,
    scene_idx: usize,
    clip: *const types.Clip,
    tracks: []const types.Track,
    instrument_device_ids: *const [track_count]?[]const u8,
    fx_device_ids: *const [track_count][ui_state.max_fx_slots]?[]const u8,
) !void {
    // Try audio first (flatten nested Bitwig-style clips).
    // Arena frees any synthetic identity/shifted warp buffers from flatten.
    var applied_audio = false;
    {
        var flat_arena = std.heap.ArenaAllocator.init(state.allocator);
        defer flat_arena.deinit();
        if (try flatten.flattenClipAudio(flat_arena.allocator(), clip)) |flat| {
            try applyFlattenedAudio(state, loaded, io, track_idx, scene_idx, flat);
            applied_audio = state.audio_clips[track_idx][scene_idx].hasAudio();
        }
    }

    var piano = &state.piano_clips[track_idx][scene_idx];
    piano.length_beats = @floatCast(clip.duration);
    piano.notes.clearRetainingCapacity();

    // One content type per slot: skip notes when audio was applied
    if (!applied_audio) {
        if (clip.notes) |notes| {
            for (notes.notes) |note| {
                if (note.key < 0 or note.key > 127) continue;
                piano.addNoteWithVelocity(
                    @intCast(note.key),
                    @floatCast(note.time),
                    @floatCast(note.duration),
                    @floatCast(note.vel),
                    @floatCast(note.rel),
                ) catch continue;
            }
        }
        if (clip.lanes) |lanes| {
            if (lanes.notes) |notes| {
                for (notes.notes) |note| {
                    if (note.key < 0 or note.key > 127) continue;
                    piano.addNoteWithVelocity(
                        @intCast(note.key),
                        @floatCast(note.time),
                        @floatCast(note.duration),
                        @floatCast(note.vel),
                        @floatCast(note.rel),
                    ) catch continue;
                }
            }
        }
    }

    if (track_idx < tracks.len) {
        piano.automation.clear(state.allocator);
        const track = tracks[track_idx];
        const channel = track.channel;
        const vol_id = if (channel) |ch| if (ch.volume) |vol| vol.id else null else null;
        const pan_id = if (channel) |ch| if (ch.pan) |pan| pan.id else null else null;
        try applyAutomationToClip(
            state.allocator,
            piano,
            clip.points,
            instrument_device_ids[track_idx],
            &fx_device_ids[track_idx],
            vol_id,
            pan_id,
        );
        if (clip.lanes) |lanes| {
            try applyAutomationToClip(
                state.allocator,
                piano,
                lanes.points,
                instrument_device_ids[track_idx],
                &fx_device_ids[track_idx],
                vol_id,
                pan_id,
            );
        }
    }
}

fn applyFlattenedAudio(
    state: *ui_state.State,
    loaded: *const project_io.LoadedProject,
    io: std.Io,
    track_idx: usize,
    scene_idx: usize,
    flat: flatten.FlattenedAudio,
) !void {
    const raw_xml_path = flat.audio.file.path;
    if (raw_xml_path.len == 0) return;
    const xml_path = try state.allocator.dupe(u8, raw_xml_path);
    defer state.allocator.free(xml_path);
    for (xml_path) |*c| {
        if (c.* == '\\') c.* = '/';
    }

    // Project-relative key for SampleStore (prefer hydrated samples/… path).
    const path_in_project = loaded.media_rel_paths.get(xml_path) orelse xml_path;

    // Prefer external/hydrated media so packed projects become disk-backed.
    // Embedded bytes remain a fallback when hydration was not possible.
    // Never bail after a single failed strategy.
    const sample_id = loadSampleForClip(state, loaded, io, xml_path, path_in_project) orelse {
        std.log.warn("Audio media missing: {s}", .{xml_path});
        return;
    };
    var sample_owned = true;
    defer if (sample_owned) state.sample_store.release(sample_id);

    // Hybrid exclusive slot: sample owns this cell (drop MIDI notes)
    state.claimSlotForAudio(track_idx, scene_idx);

    var audio = &state.audio_clips[track_idx][scene_idx];
    audio.clear(&state.sample_store);
    audio.length_beats = @floatCast(flat.duration);
    audio.play_start_beats = @floatCast(time_mod.timeToBeats(flat.play_start, flat.content_time_unit, state.bpm));
    audio.loop_start_beats = @floatCast(time_mod.timeToBeats(flat.loop_start orelse 0, flat.content_time_unit, state.bpm));
    audio.loop_end_beats = if (flat.loop_end) |end|
        @floatCast(time_mod.timeToBeats(end, flat.content_time_unit, state.bpm))
    else
        audio.length_beats;
    const fade_unit = flat.fade_time_unit orelse .beats;
    audio.fade_in_beats = @floatCast(time_mod.timeToBeats(flat.fade_in_time orelse 0, fade_unit, state.bpm));
    audio.fade_out_beats = @floatCast(time_mod.timeToBeats(flat.fade_out_time orelse 0, fade_unit, state.bpm));
    if (flat.name) |n| audio.name.set(n);
    try audio.setAlgorithm(flat.algorithm);

    var markers = try state.allocator.alloc(audio_clip_types.WarpMarker, flat.warps.len);
    defer state.allocator.free(markers);
    for (flat.warps, 0..) |wp, i| {
        markers[i] = .{
            .beat = @floatCast(time_mod.timeToBeats(wp.time, flat.warp_time_unit, state.bpm)),
            .content_seconds = @floatCast(time_mod.timeToSeconds(wp.content_time, flat.warp_content_time_unit, state.bpm)),
        };
    }
    try audio.setWarps(markers);
    audio.setSample(&state.sample_store, sample_id);
    sample_owned = false;
}

/// Load sample the way Flux always did (zip memory first), plus thin external disk.
fn loadSampleForClip(
    state: *ui_state.State,
    loaded: *const project_io.LoadedProject,
    io: std.Io,
    xml_path: []const u8,
    path_in_project: []const u8,
) ?sample_store.SampleId {
    const store = &state.sample_store;
    // 1) Pre-resolved absolute path from load().
    if (loaded.media_abs_paths.get(xml_path)) |abs| {
        if (store.loadFromPath(path_in_project, abs, io)) |id| return id else |_| {}
    }
    // 2) External relative to project dir (thin save layout).
    if (media_layout.isSafeRelativePath(xml_path)) {
        if (media_layout.joinRel(state.allocator, loaded.project_dir, xml_path)) |abs| {
            defer state.allocator.free(abs);
            if (store.loadFromPath(path_in_project, abs, io)) |id| return id else |_| {}
        } else |_| {}
    }
    // 3) Embedded archive bytes when disk resolution/hydration failed.
    if (loaded.embedded_media.get(xml_path)) |bytes| {
        if (store.loadFromMemory(path_in_project, bytes)) |id| return id else |_| {}
    }
    return null;
}

fn applyAutomationToClip(
    allocator: std.mem.Allocator,
    piano: *piano_roll_types.PianoRollClip,
    points_list: []const types.Points,
    instrument_device_id: ?[]const u8,
    fx_device_ids: *const [ui_state.max_fx_slots]?[]const u8,
    track_volume_param_id: ?[]const u8,
    track_pan_param_id: ?[]const u8,
) !void {
    for (points_list) |points| {
        var new_lane = piano_roll_types.AutomationLane{
            .target_kind = .parameter,
            .target_id = "",
            .param_id = null,
            .unit = if (points.unit) |unit| try allocator.dupe(u8, unit.toString()) else null,
            .points = .empty,
        };
        if (points.target.parameter) |param_id| {
            if (track_volume_param_id != null and std.mem.eql(u8, param_id, track_volume_param_id.?)) {
                new_lane.target_kind = .track;
                new_lane.target_id = try allocator.dupe(u8, "track");
                new_lane.param_id = try allocator.dupe(u8, "volume");
            } else if (track_pan_param_id != null and std.mem.eql(u8, param_id, track_pan_param_id.?)) {
                new_lane.target_kind = .track;
                new_lane.target_id = try allocator.dupe(u8, "track");
                new_lane.param_id = try allocator.dupe(u8, "pan");
            } else if (parseAutomationParamId(param_id, instrument_device_id, fx_device_ids)) |parsed| {
                if (parsed.fx_index) |fx_idx| {
                    new_lane.target_id = try std.fmt.allocPrint(allocator, "fx{d}", .{fx_idx});
                } else {
                    new_lane.target_id = try allocator.dupe(u8, "instrument");
                }
                new_lane.param_id = try allocator.dupe(u8, parsed.param_id);
            } else {
                new_lane.param_id = try allocator.dupe(u8, param_id);
            }
        }
        for (points.points) |point| {
            try new_lane.points.append(allocator, .{
                .time = @floatCast(point.time),
                .value = @floatCast(point.value),
            });
        }
        try piano.automation.lanes.append(allocator, new_lane);
    }
}

const ParsedAutomationParam = struct {
    fx_index: ?usize = null,
    param_id: []const u8,
};

fn parseAutomationParamId(
    param_id: []const u8,
    instrument_device_id: ?[]const u8,
    fx_device_ids: *const [ui_state.max_fx_slots]?[]const u8,
) ?ParsedAutomationParam {
    const marker = std.mem.indexOf(u8, param_id, "_p") orelse return null;
    const device_id = param_id[0..marker];
    const raw_param = param_id[marker + 2 ..];
    if (instrument_device_id) |inst_id| {
        if (std.mem.eql(u8, inst_id, device_id)) {
            return .{ .fx_index = null, .param_id = raw_param };
        }
    }
    for (fx_device_ids, 0..) |fx_id, idx| {
        if (fx_id) |id| {
            if (std.mem.eql(u8, id, device_id)) {
                return .{ .fx_index = idx, .param_id = raw_param };
            }
        }
    }
    return null;
}
