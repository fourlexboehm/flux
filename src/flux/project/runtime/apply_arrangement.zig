//! Apply DAWproject Arrangement → Flux ArrangementView.

const std = @import("std");

const arr_ops = @import("../../arrangement/ops.zig");
const arr_clip_mod = @import("../../arrangement/clip.zig");
const arr_timeline = @import("../../arrangement/timeline.zig");
const flatten = @import("../format/flatten.zig");
const types = @import("../format/types.zig");
const project_io = @import("../io.zig");
const media_layout = @import("../media/layout.zig");
const ui_state = @import("../../ui/state.zig");

/// Populate `state.arrangement` from parsed Arrangement XML (tracks, clips, colors, positions).
pub fn applyArrangement(
    state: *ui_state.State,
    loaded: *const project_io.LoadedProject,
    io: std.Io,
    arrangement: *const types.Arrangement,
    tracks: []const types.Track,
) !void {
    state.arrangement.clearTracks();
    state.arrangement.bpm = state.bpm;
    state.arrangement.beats_per_bar = state.time_signature_numerator;
    state.arrangement.current_tick = 0;

    const root = arrangement.lanes orelse return;
    // Child lanes are per-track; also accept clips on the root (rare).
    if (root.clips) |clips| {
        // No track binding — attach to a synthetic track 0 if we have session tracks.
        if (state.session.track_count > 0 and clips.clips.len > 0) {
            const color = trackColorOrDefault(tracks, 0, .{ 0.40, 0.62, 0.82, 1.0 });
            try arr_ops.createTrack(&state.arrangement, 0, trackName(tracks, 0), color);
            try applyClipsToTrack(state, loaded, io, 0, clips.clips);
        }
    }

    for (root.children) |lane| {
        const track_id = lane.track orelse continue;
        const session_idx = findTrackIndex(tracks, track_id) orelse continue;
        const name = trackName(tracks, session_idx);
        const color = trackColorOrDefault(tracks, session_idx, defaultTrackColor(session_idx));
        try arr_ops.createTrack(&state.arrangement, session_idx, name, color);

        const arr_track_idx = state.arrangement.tracks.items.len - 1;
        if (lane.clips) |clips| {
            try applyClipsToTrack(state, loaded, io, arr_track_idx, clips.clips);
        }
    }
}

fn applyClipsToTrack(
    state: *ui_state.State,
    loaded: *const project_io.LoadedProject,
    io: std.Io,
    arr_track_idx: usize,
    clips: []const types.Clip,
) !void {
    for (clips) |clip| {
        const start_tick = beatsToTicks(clip.time);
        const duration_ticks = beatsToTicks(clip.duration);
        if (duration_ticks <= 0) continue;

        const name = clip.name orelse "";
        const kind: arr_clip_mod.ClipKind = if (clipIsAudio(&clip)) .audio else .midi;
        const clip_idx = try arr_ops.createClip(
            &state.arrangement,
            arr_track_idx,
            kind,
            start_tick,
            duration_ticks,
            name,
        );
        var arr_clip = &state.arrangement.tracks.items[arr_track_idx].clips.items[clip_idx];
        arr_clip.enabled = clip.enable;
        if (clip.color) |hex| {
            arr_clip.color = parseHexColor(hex);
        }

        if (kind == .audio) {
            try applyAudioToArrangementClip(state, loaded, io, arr_clip, &clip);
        } else {
            try applyMidiToArrangementClip(state, arr_clip, &clip);
        }
    }
}

fn clipIsAudio(clip: *const types.Clip) bool {
    if (clip.warps != null or clip.audio != null) return true;
    if (clip.nested_clips) |nested| {
        for (nested.clips) |inner| {
            if (clipIsAudio(&inner)) return true;
        }
    }
    return false;
}

fn applyAudioToArrangementClip(
    state: *ui_state.State,
    loaded: *const project_io.LoadedProject,
    io: std.Io,
    arr_clip: *arr_clip_mod.ArrangementClip,
    clip: *const types.Clip,
) !void {
    var flat_arena = std.heap.ArenaAllocator.init(state.allocator);
    defer flat_arena.deinit();
    const flat = try flatten.flattenClipAudio(flat_arena.allocator(), clip) orelse return;
    const raw_path = flat.audio.file.path;
    if (raw_path.len == 0) return;

    const path_buf = try state.allocator.dupe(u8, raw_path);
    defer state.allocator.free(path_buf);
    for (path_buf) |*c| {
        if (c.* == '\\') c.* = '/';
    }

    const path_in_project = loaded.media_rel_paths.get(path_buf) orelse path_buf;

    // Ensure sample is in the store (shared with session clips when same path).
    _ = loadSample(state, loaded, io, path_buf, path_in_project);

    try arr_ops.setClipAudioPath(arr_clip, state.allocator, path_in_project);
}

fn applyMidiToArrangementClip(
    state: *ui_state.State,
    arr_clip: *arr_clip_mod.ArrangementClip,
    clip: *const types.Clip,
) !void {
    const midi = &(arr_clip.midi orelse return);
    midi.clear();
    midi.length_beats = @floatCast(clip.duration);
    midi.play_start_beats = @floatCast(clip.play_start);
    midi.loop_start_beats = @floatCast(clip.loop_start orelse 0);
    midi.loop_end_beats = @floatCast(clip.loop_end orelse clip.duration);

    const content_unit = clip.content_time_unit orelse .beats;
    const bpm = state.bpm;

    if (clip.notes) |notes| {
        for (notes.notes) |note| {
            if (note.key < 0 or note.key > 127) continue;
            midi.addNoteWithVelocity(
                @intCast(note.key),
                @floatCast(timeToBeats(note.time, content_unit, bpm)),
                @floatCast(timeToBeats(note.duration, content_unit, bpm)),
                @floatCast(note.vel),
                @floatCast(note.rel),
            ) catch continue;
        }
    }
    if (clip.lanes) |lanes| {
        if (lanes.notes) |notes| {
            for (notes.notes) |note| {
                if (note.key < 0 or note.key > 127) continue;
                midi.addNoteWithVelocity(
                    @intCast(note.key),
                    @floatCast(timeToBeats(note.time, content_unit, bpm)),
                    @floatCast(timeToBeats(note.duration, content_unit, bpm)),
                    @floatCast(note.vel),
                    @floatCast(note.rel),
                ) catch continue;
            }
        }
    }
}

fn loadSample(
    state: *ui_state.State,
    loaded: *const project_io.LoadedProject,
    io: std.Io,
    xml_path: []const u8,
    path_in_project: []const u8,
) ?u32 {
    const store = &state.sample_store;
    if (loaded.media_abs_paths.get(xml_path)) |abs| {
        if (store.loadFromPath(path_in_project, abs, io)) |id| return id else |_| {}
    }
    if (media_layout.isSafeRelativePath(xml_path)) {
        if (media_layout.joinRel(state.allocator, loaded.project_dir, xml_path)) |abs| {
            defer state.allocator.free(abs);
            if (store.loadFromPath(path_in_project, abs, io)) |id| return id else |_| {}
        } else |_| {}
    }
    if (loaded.embedded_media.get(xml_path)) |bytes| {
        if (store.loadFromMemory(path_in_project, bytes)) |id| return id else |_| {}
    }
    return null;
}

fn findTrackIndex(tracks: []const types.Track, track_id: []const u8) ?usize {
    for (tracks, 0..) |track, t| {
        if (std.mem.eql(u8, track.id, track_id)) return t;
    }
    return null;
}

fn trackName(tracks: []const types.Track, idx: usize) []const u8 {
    if (idx < tracks.len) return tracks[idx].name;
    return "Track";
}

fn trackColorOrDefault(tracks: []const types.Track, idx: usize, fallback: [4]f32) [4]f32 {
    if (idx < tracks.len) {
        if (tracks[idx].color) |hex| return parseHexColor(hex);
    }
    return fallback;
}

fn defaultTrackColor(idx: usize) [4]f32 {
    const palette = [_][4]f32{
        .{ 0.40, 0.62, 0.82, 1.0 },
        .{ 0.42, 0.72, 0.48, 1.0 },
        .{ 0.82, 0.55, 0.35, 1.0 },
        .{ 0.72, 0.45, 0.72, 1.0 },
    };
    return palette[idx % palette.len];
}

fn beatsToTicks(beats: f64) i64 {
    return @intFromFloat(@round(beats * @as(f64, @floatFromInt(arr_timeline.ppq))));
}

fn timeToBeats(value: f64, unit: types.TimeUnit, bpm: f32) f64 {
    return switch (unit) {
        .beats => value,
        .seconds => value * @as(f64, bpm) / 60.0,
    };
}

/// Parse `#rrggbb` or `#rrggbbaa` into linear RGB floats.
pub fn parseHexColor(hex: []const u8) [4]f32 {
    var s = hex;
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len < 6) return .{ 0.35, 0.35, 0.45, 1.0 };
    const r = std.fmt.parseInt(u8, s[0..2], 16) catch 0;
    const g = std.fmt.parseInt(u8, s[2..4], 16) catch 0;
    const b = std.fmt.parseInt(u8, s[4..6], 16) catch 0;
    const a: u8 = if (s.len >= 8)
        (std.fmt.parseInt(u8, s[6..8], 16) catch 255)
    else
        255;
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    };
}
