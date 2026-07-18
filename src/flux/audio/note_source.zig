const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");
const session_constants = @import("../session/constants.zig");
const piano_roll_types = @import("../session/notes.zig");
const audio_events = @import("audio_events.zig");

const PianoNote = piano_roll_types.Note;
const beats_per_bar = session_constants.beats_per_bar;
const default_clip_bars = session_constants.default_clip_bars;

pub const max_clip_notes = 256;
pub const max_automation_lanes = 8;
pub const max_automation_points = 64;

pub const AutomationTargetKind = enum(u8) {
    track,
    device,
    parameter,
};

pub const AutomationPoint = struct {
    time: f32,
    value: f32,
};

pub const AutomationLane = struct {
    target_kind: AutomationTargetKind = .parameter,
    target_fx_index: i8 = -1,
    param_id: clap.Id = clap.Id.invalid_id,
    point_count: u16 = 0,
    points: [max_automation_points]AutomationPoint = @splat(.{ .time = 0, .value = 0 }),
};

pub const ClipNotes = struct {
    length_beats: f32 = default_clip_bars * beats_per_bar,
    count: u16 = 0,
    notes: [max_clip_notes]PianoNote = @splat(.{ .pitch = 0, .start = 0, .duration = 0 }),
    automation_lane_count: u8 = 0,
    automation_lanes: [max_automation_lanes]AutomationLane = @splat(.{}),
};

pub const NoteSource = struct {
    track_index: usize,
    emit_notes: bool = true,
    target_fx_index: i8 = -1,
    current_beat: f64 = 0.0,
    active_pitches: [128]bool = @splat(false),
    last_live_should: [128]bool = @splat(false),
    live_cache_valid: bool = false,
    last_playing: bool = false,
    last_scene: ?usize = null,
    event_list: audio_events.EventList = .{},
    input_events: clap.events.InputEvents = .{
        .context = undefined,
        .size = audio_events.inputEventsSize,
        .get = audio_events.inputEventsGet,
    },

    pub fn init(track_index: usize, emit_notes: bool, target_fx_index: i8) NoteSource {
        return .{
            .track_index = track_index,
            .emit_notes = emit_notes,
            .target_fx_index = target_fx_index,
        };
    }

    pub fn process(self: *NoteSource, snapshot: anytype, sample_rate: f32, frame_count: u32) *const clap.events.InputEvents {
        const zone = tracy.ZoneN(@src(), "NoteSource.process");
        defer zone.End();

        self.event_list.reset();
        self.input_events.context = &self.event_list;
        self.processControllerParamWrites(snapshot, 0);

        const live_should = &snapshot.live_key_states[self.track_index];
        const live_velocities = &snapshot.live_key_velocities[self.track_index];
        const live_changed = !self.live_cache_valid or !std.mem.eql(bool, self.last_live_should[0..], live_should[0..]);
        defer {
            @memcpy(self.last_live_should[0..], live_should[0..]);
            self.live_cache_valid = true;
            self.last_playing = snapshot.playing;
        }

        if (!snapshot.playing) {
            if (self.emit_notes and (self.last_playing or live_changed)) {
                self.resetSequencer();
                self.updateCombined(live_should, live_should, live_velocities, 0);
            }
            return &self.input_events;
        }

        const active_scene_i = snapshot.active_scene_by_track[self.track_index];
        if (active_scene_i < 0) {
            if (self.emit_notes and (self.last_scene != null or live_changed or !self.last_playing)) {
                self.resetSequencer();
                self.updateCombined(live_should, live_should, live_velocities, 0);
            }
            return &self.input_events;
        }

        const active_scene: usize = @intCast(active_scene_i);
        const clip = &snapshot.piano_clips[self.track_index][active_scene];
        const scene_changed = self.last_scene == null or self.last_scene.? != active_scene;
        if (scene_changed) {
            self.current_beat = 0.0;
            self.last_scene = active_scene;
        }

        const clip_len = @as(f64, clip.length_beats);
        if (clip_len <= 0.0) {
            if (self.emit_notes) {
                self.updateCombined(live_should, live_should, live_velocities, 0);
            }
            return &self.input_events;
        }

        const beats_per_second = @as(f64, snapshot.bpm) / 60.0;
        const beats_per_sample = beats_per_second / @as(f64, sample_rate);
        const block_beats = beats_per_sample * @as(f64, frame_count);
        const beat_start = @mod(self.current_beat, clip_len);
        const beat_end = beat_start + block_beats;
        const near_clip_start = beat_start < block_beats;

        if (self.emit_notes and (scene_changed or live_changed or !self.last_playing or beat_end >= clip_len or near_clip_start)) {
            self.updateNotesAtBeat(clip, @floatCast(beat_start), 0, live_should, live_velocities);
        }

        if (beat_end < clip_len) {
            self.processSegment(clip, beat_start, beat_end, 0, beats_per_sample, clip_len);
        } else {
            const first_len = clip_len - beat_start;
            const wrap_offset = @as(u32, @intFromFloat(@floor(first_len / beats_per_sample)));
            self.processSegment(clip, beat_start, clip_len, 0, beats_per_sample, clip_len);
            self.processSegment(clip, 0.0, @mod(beat_end, clip_len), wrap_offset, beats_per_sample, clip_len);
        }

        self.current_beat = if (beat_end >= clip_len) @mod(beat_end, clip_len) else beat_end;
        return &self.input_events;
    }

    fn resetSequencer(self: *NoteSource) void {
        self.current_beat = 0.0;
        self.last_scene = null;
    }

    fn emitNoteOn(self: *NoteSource, pitch: u8, velocity: f32, sample_offset: u32) void {
        self.event_list.pushNote(.{
            .header = .{
                .size = @sizeOf(clap.events.Note),
                .sample_offset = sample_offset,
                .space_id = clap.events.core_space_id,
                .type = .note_on,
                .flags = .{},
            },
            .note_id = .unspecified,
            .port_index = @enumFromInt(0),
            .channel = @enumFromInt(0),
            .key = @enumFromInt(@as(i16, @intCast(pitch))),
            .velocity = velocity,
        });
        self.active_pitches[pitch] = true;
    }

    fn emitNoteOff(self: *NoteSource, pitch: u8, release_velocity: f32, sample_offset: u32) void {
        self.event_list.pushNote(.{
            .header = .{
                .size = @sizeOf(clap.events.Note),
                .sample_offset = sample_offset,
                .space_id = clap.events.core_space_id,
                .type = .note_off,
                .flags = .{},
            },
            .note_id = .unspecified,
            .port_index = @enumFromInt(0),
            .channel = @enumFromInt(0),
            .key = @enumFromInt(@as(i16, @intCast(pitch))),
            .velocity = release_velocity,
        });
        self.active_pitches[pitch] = false;
    }

    fn emitParamValue(self: *NoteSource, param_id: clap.Id, value: f64, sample_offset: u32) void {
        self.event_list.pushParam(.{
            .header = .{
                .size = @sizeOf(clap.events.ParamValue),
                .sample_offset = sample_offset,
                .space_id = clap.events.core_space_id,
                .type = .param_value,
                .flags = .{},
            },
            .param_id = param_id,
            .cookie = null,
            .note_id = .unspecified,
            .port_index = .unspecified,
            .channel = .unspecified,
            .key = .unspecified,
            .value = value,
        });
    }

    fn updateCombined(
        self: *NoteSource,
        desired: *const [128]bool,
        live_should: *const [128]bool,
        live_velocities: *const [128]f32,
        sample_offset: u32,
    ) void {
        for (0..128) |pitch| {
            if (self.active_pitches[pitch] and !desired[pitch]) {
                self.emitNoteOff(@intCast(pitch), 0.0, sample_offset);
            } else if (!self.active_pitches[pitch] and desired[pitch]) {
                const velocity = if (live_should[pitch]) live_velocities[pitch] else 1.0;
                self.emitNoteOn(@intCast(pitch), velocity, sample_offset);
            }
        }
    }

    fn updateNotesAtBeat(
        self: *NoteSource,
        clip: *const ClipNotes,
        beat: f32,
        sample_offset: u32,
        live_should: *const [128]bool,
        live_velocities: *const [128]f32,
    ) void {
        var should_be_active: [128]bool = @splat(false);
        const clip_len = clip.length_beats;

        for (clip.notes[0..clip.count]) |note| {
            const note_end = note.start + note.duration;
            if (note_end <= clip_len) {
                if (beat >= note.start and beat < note_end) should_be_active[note.pitch] = true;
            } else {
                const wrapped_end = note_end - clip_len;
                if (beat >= note.start or beat < wrapped_end) should_be_active[note.pitch] = true;
            }
        }

        for (0..128) |pitch| {
            should_be_active[pitch] = should_be_active[pitch] or live_should[pitch];
        }
        self.updateCombined(&should_be_active, live_should, live_velocities, sample_offset);
    }

    fn processControllerParamWrites(self: *NoteSource, snapshot: anytype, sample_offset: u32) void {
        var i: usize = 0;
        while (i < snapshot.controller_param_write_count) : (i += 1) {
            const write = snapshot.controller_param_writes[i];
            if (write.track_index != @as(u8, @intCast(self.track_index))) continue;
            if (write.target_fx_index != self.target_fx_index) continue;
            self.emitParamValue(@enumFromInt(write.param_id), write.value, sample_offset);
        }
    }

    fn processSegment(
        self: *NoteSource,
        clip: *const ClipNotes,
        seg_start: f64,
        seg_end: f64,
        base_sample_offset: u32,
        beats_per_sample: f64,
        clip_len: f64,
    ) void {
        if (seg_end <= seg_start) return;
        if (self.emit_notes) {
            for (clip.notes[0..clip.count]) |note| {
                const note_start = @as(f64, note.start);
                const note_end = note_start + @as(f64, note.duration);

                if (note_end <= clip_len) {
                    self.emitNoteEvents(note.pitch, note.velocity, note.release_velocity, note_start, note_end, seg_start, seg_end, base_sample_offset, beats_per_sample);
                } else {
                    const wrapped_end = note_end - clip_len;
                    self.emitNoteEvents(note.pitch, note.velocity, note.release_velocity, note_start, clip_len, seg_start, seg_end, base_sample_offset, beats_per_sample);
                    self.emitNoteEvents(note.pitch, note.velocity, note.release_velocity, 0.0, wrapped_end, seg_start, seg_end, base_sample_offset, beats_per_sample);
                }
            }
        }

        self.processAutomationSegment(clip, seg_start, seg_end, base_sample_offset, beats_per_sample, clip_len);
    }

    fn processAutomationSegment(
        self: *NoteSource,
        clip: *const ClipNotes,
        seg_start: f64,
        seg_end: f64,
        base_sample_offset: u32,
        beats_per_sample: f64,
        clip_len: f64,
    ) void {
        if (clip.automation_lane_count == 0) return;
        for (clip.automation_lanes[0..clip.automation_lane_count]) |lane| {
            if (lane.target_kind != .parameter or lane.param_id == clap.Id.invalid_id) continue;
            if (lane.target_fx_index != self.target_fx_index) continue;

            var last_before: ?AutomationPoint = null;
            var first_after: ?AutomationPoint = null;
            var first_overall: ?AutomationPoint = null;
            var last_overall: ?AutomationPoint = null;
            var has_point_at_start = false;
            for (lane.points[0..lane.point_count]) |point| {
                const point_time = @as(f64, point.time);
                if (first_overall == null or point_time < @as(f64, first_overall.?.time)) first_overall = point;
                if (last_overall == null or point_time > @as(f64, last_overall.?.time)) last_overall = point;
                if (point_time < seg_start and (last_before == null or point_time > @as(f64, last_before.?.time))) last_before = point;
                if (point_time >= seg_start and (first_after == null or point_time < @as(f64, first_after.?.time))) first_after = point;
                if (std.math.approxEqAbs(f64, point_time, seg_start, 1e-9)) has_point_at_start = true;
                if (point_time < seg_start or point_time >= seg_end) continue;
                const offset = base_sample_offset + @as(u32, @intFromFloat(@floor((point_time - seg_start) / beats_per_sample)));
                self.emitParamValue(lane.param_id, @as(f64, point.value), offset);
            }

            if (!has_point_at_start and first_overall != null and last_overall != null) {
                const prev = if (last_before) |point| point else last_overall.?;
                const next = if (first_after) |point| point else first_overall.?;
                var prev_time = @as(f64, prev.time);
                var next_time = @as(f64, next.time);
                if (last_before == null) prev_time -= clip_len;
                if (first_after == null) next_time += clip_len;
                const value = if (std.math.approxEqAbs(f64, prev_time, next_time, 1e-9))
                    @as(f64, prev.value)
                else
                    @as(f64, prev.value) + (seg_start - prev_time) * (@as(f64, next.value) - @as(f64, prev.value)) / (next_time - prev_time);
                self.emitParamValue(lane.param_id, value, base_sample_offset);
            }
        }
    }

    fn emitNoteEvents(
        self: *NoteSource,
        pitch: u8,
        velocity: f32,
        release_velocity: f32,
        note_start: f64,
        note_end: f64,
        seg_start: f64,
        seg_end: f64,
        base_sample_offset: u32,
        beats_per_sample: f64,
    ) void {
        if (note_start > seg_start and note_start < seg_end) {
            const offset = base_sample_offset + @as(u32, @intFromFloat(@floor((note_start - seg_start) / beats_per_sample)));
            self.emitNoteOn(pitch, velocity, offset);
        }
        if (note_end > seg_start and note_end < seg_end) {
            const offset = base_sample_offset + @as(u32, @intFromFloat(@floor((note_end - seg_start) / beats_per_sample)));
            self.emitNoteOff(pitch, release_velocity, offset);
        }
    }
};
