//! Private graph node runtime types and RT transport helpers.
const std = @import("std");
const clap = @import("clap-bindings");
const engine_ui = @import("engine_ui.zig");
const session_view = @import("../session/types.zig");
const session_constants = @import("../session/constants.zig");
const audio_events = @import("audio_events.zig");
const audio_clip_source = @import("audio_clip_source.zig");
const latency_compensation = @import("latency_compensation.zig");
const note_source = @import("note_source.zig");

const max_tracks = session_constants.max_tracks;
const max_fx_slots = engine_ui.max_fx_slots;

pub const BufferId = u16;
pub const NoteSourceId = u16;
pub const invalid_id = std.math.maxInt(u16);

pub const NodeKind = enum(u8) {
    note_source,
    audio_clip_source,
    synth,
    fx,
    gain,
    mixer,
    master,
};

pub const NodeRef = struct {
    kind: NodeKind,
    index: u16,
};

pub const AudioInputRef = struct {
    buffer: BufferId,
};

pub const InputRange = struct {
    start: u32 = 0,
    count: u16 = 0,
};

pub const StereoBuffer = struct {
    left: []f32 = &.{},
    right: []f32 = &.{},
    zeroed_frames: u32 = 0,
    active: bool = false,
};

pub const SynthRuntime = struct {
    track_index: u8,
    out: BufferId,
    event_source: NoteSourceId = invalid_id,
    sleeping: bool = false,
    out_events_list: audio_events.OutputEventList = .{},
    out_events: clap.events.OutputEvents = .{
        .context = undefined,
        .tryPush = audio_events.outputEventsTryPush,
    },
};

pub const AudioClipSourceRuntime = struct {
    track_index: u8,
    out: BufferId,
    player: audio_clip_source.AudioClipSource,
};

pub const FxPolicy = enum(u8) {
    track_fx_fast_skip,
    master_fx_always_consider,
};

pub const FxRuntime = struct {
    track_index: u8,
    fx_index: u8,
    inputs: InputRange = .{},
    out: BufferId,
    event_source: NoteSourceId = invalid_id,
    policy: FxPolicy = .track_fx_fast_skip,
    sleeping: bool = false,
};

pub const GainRuntime = struct {
    track_index: u8,
    inputs: InputRange = .{},
    out: BufferId,
    compensation: latency_compensation.StereoDelay = .{},
};

pub const MixerRuntime = struct {
    inputs: InputRange = .{},
    out: BufferId,
};

pub const MasterRuntime = struct {
    inputs: InputRange = .{},
    out: BufferId,
};

pub const AudioOutput = struct {
    left: []f32,
    right: []f32,
};

pub fn computeSoloActive(snapshot: anytype) bool {
    const active_track_count = @min(snapshot.track_count, max_tracks);
    for (0..active_track_count) |track_index| {
        if (snapshot.tracks[track_index].solo) return true;
    }
    return false;
}

pub fn makeTransport(ctx: anytype) clap.events.Transport {
    const tempo = @as(f64, ctx.snapshot.bpm);
    const beats = @as(f64, ctx.snapshot.playhead_beat);
    const seconds = if (tempo > 0.0) beats * 60.0 / tempo else 0.0;
    const numerator = ctx.snapshot.time_signature_numerator;
    const denominator = ctx.snapshot.time_signature_denominator;
    const bar_len = @as(f64, @floatFromInt(numerator)) * 4.0 / @as(f64, @floatFromInt(denominator));
    const bar_index = @floor(beats / bar_len);

    return .{
        .header = .{
            .size = @sizeOf(clap.events.Transport),
            .sample_offset = 0,
            .space_id = clap.events.core_space_id,
            .type = .transport,
            .flags = .{},
        },
        .flags = .{
            .has_tempo = true,
            .has_beats_timeline = true,
            .has_seconds_timeline = true,
            .has_time_signature = true,
            .is_playing = ctx.snapshot.playing,
            .is_recording = false,
            .is_loop_active = false,
            .is_within_pre_roll = false,
        },
        .song_pos_beats = clap.BeatTime.fromBeats(beats),
        .song_pos_seconds = clap.SecTime.fromSecs(seconds),
        .tempo = tempo,
        .tempo_increment = 0,
        .loop_start_beats = clap.BeatTime.fromBeats(0),
        .loop_end_beats = clap.BeatTime.fromBeats(0),
        .loop_start_seconds = clap.SecTime.fromSecs(0),
        .loop_end_seconds = clap.SecTime.fromSecs(0),
        .bar_start = clap.BeatTime.fromBeats(bar_index * bar_len),
        .bar_number = @as(i32, @intFromFloat(bar_index)) + 1,
        .time_signature_numerator = numerator,
        .time_signature_denominator = denominator,
    };
}
