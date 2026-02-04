const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");
const ui_state = @import("../ui/state.zig");
const session_view = @import("../ui/session_view.zig");
const session_constants = @import("../ui/session_view/constants.zig");
const piano_roll_types = @import("../ui/piano_roll/types.zig");
const audio_engine = @import("audio_engine.zig");
const libz_jobs = @import("libz_jobs");
const PianoNote = piano_roll_types.Note;

const max_tracks = session_constants.max_tracks;
const max_scenes = session_constants.max_scenes;
const beats_per_bar = session_constants.beats_per_bar;
const default_clip_bars = session_constants.default_clip_bars;
const master_track_index = session_view.master_track_index;

pub const JobQueue = libz_jobs.JobQueue(.{
    .max_jobs_per_thread = 64, // Enough for tracks + root job
    .max_threads = 16, // Cap at 16, runtime uses min(this, cpu_count - 1)
    .idle_sleep_ns = 1_500_000,
});

/// Thread-local storage for tracking which plugin is currently being processed.
/// Used by the CLAP thread_pool extension to identify the calling plugin.
pub threadlocal var current_processing_plugin: ?*const clap.Plugin = null;

pub const NodeId = u32;
pub const max_clip_notes = 256;
pub const max_automation_lanes = 8;
pub const max_automation_points = 64;

pub const PortKind = enum {
    audio,
    events,
};

pub const Port = struct {
    kind: PortKind,
};

pub const Connection = struct {
    from: NodeId,
    from_port: u8,
    to: NodeId,
    to_port: u8,
    kind: PortKind,
};

pub const StateSnapshot = struct {
    playing: bool,
    bpm: f32,
    playhead_beat: f32,
    track_count: usize,
    scene_count: usize,
    tracks: [max_tracks]session_view.Track,
    clips: [max_tracks][max_scenes]session_view.ClipSlot,
    piano_clips: [max_tracks][max_scenes]ClipNotes,
    track_plugins: [max_tracks]?*const clap.Plugin,
    track_fx_plugins: [max_tracks][ui_state.max_fx_slots]?*const clap.Plugin,
    live_key_states: [max_tracks][128]bool,
    live_key_velocities: [max_tracks][128]f32,
};

pub const ClipNotes = struct {
    length_beats: f32 = default_clip_bars * beats_per_bar,
    count: u16 = 0,
    notes: [max_clip_notes]PianoNote = [_]PianoNote{
        .{ .pitch = 0, .start = 0, .duration = 0 },
    } ** max_clip_notes,
    automation_lane_count: u8 = 0,
    automation_lanes: [max_automation_lanes]AutomationLane = [_]AutomationLane{
        .{},
    } ** max_automation_lanes,
};

const max_input_events = 256;

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
    points: [max_automation_points]AutomationPoint = [_]AutomationPoint{
        .{ .time = 0, .value = 0 },
    } ** max_automation_points,
};

const EventList = struct {
    const max_event_size = @max(@sizeOf(clap.events.Note), @sizeOf(clap.events.ParamValue));
    const max_event_align = @max(@alignOf(clap.events.Note), @alignOf(clap.events.ParamValue));
    const EventStorage = struct {
        data: [max_event_size]u8 align(max_event_align) = undefined,
    };

    events: [max_input_events]EventStorage = undefined,
    count: u32 = 0,

    fn reset(self: *EventList) void {
        self.count = 0;
    }

    fn pushNote(self: *EventList, event: clap.events.Note) void {
        if (self.count >= max_input_events) {
            return;
        }
        const bytes = std.mem.asBytes(&event);
        @memcpy(self.events[self.count].data[0..bytes.len], bytes);
        self.count += 1;
    }

    fn pushParam(self: *EventList, event: clap.events.ParamValue) void {
        if (self.count >= max_input_events) {
            return;
        }
        const bytes = std.mem.asBytes(&event);
        @memcpy(self.events[self.count].data[0..bytes.len], bytes);
        self.count += 1;
    }
};

fn inputEventsSize(list: *const clap.events.InputEvents) callconv(.c) u32 {
    const ctx: *const EventList = @ptrCast(@alignCast(list.context));
    return ctx.count;
}

fn inputEventsGet(list: *const clap.events.InputEvents, index: u32) callconv(.c) *const clap.events.Header {
    const ctx: *const EventList = @ptrCast(@alignCast(list.context));
    return @ptrCast(@alignCast(&ctx.events[index].data));
}

const OutputEventList = struct {
    events: [max_input_events]clap.events.Note = undefined,
    count: u32 = 0,
};

fn outputEventsTryPush(list: *const clap.events.OutputEvents, event: *const clap.events.Header) callconv(.c) bool {
    const ctx: *OutputEventList = @ptrCast(@alignCast(list.context));
    if (ctx.count >= max_input_events) {
        return true;
    }
    switch (event.type) {
        .note_on, .note_off, .note_end, .note_choke => {
            const note: *const clap.events.Note = @ptrCast(@alignCast(event));
            ctx.events[ctx.count] = note.*;
            ctx.count += 1;
        },
        else => {},
    }
    return true;
}

const max_active_notes = 128;

pub const NoteSource = struct {
    track_index: usize,
    emit_notes: bool = true,
    target_fx_index: i8 = -1,
    current_beat: f64 = 0.0,
    // Track which pitches are currently sounding (by MIDI pitch 0-127)
    active_pitches: [128]bool = [_]bool{false} ** 128,
    last_scene: ?usize = null,
    event_list: EventList = .{},
    input_events: clap.events.InputEvents = .{
        .context = undefined,
        .size = inputEventsSize,
        .get = inputEventsGet,
    },

    pub fn init(track_index: usize, emit_notes: bool, target_fx_index: i8) NoteSource {
        return NoteSource{
            .track_index = track_index,
            .emit_notes = emit_notes,
            .target_fx_index = target_fx_index,
        };
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
        // Determine which pitches should be active at this beat
        var should_be_active: [128]bool = [_]bool{false} ** 128;
        const clip_len = clip.length_beats;

        for (clip.notes[0..clip.count]) |note| {
            const note_end = note.start + note.duration;
            if (note_end <= clip_len) {
                if (beat >= note.start and beat < note_end) {
                    should_be_active[note.pitch] = true;
                }
            } else {
                const wrapped_end = note_end - clip_len;
                if (beat >= note.start or beat < wrapped_end) {
                    should_be_active[note.pitch] = true;
                }
            }
        }

        for (0..128) |pitch| {
            should_be_active[pitch] = should_be_active[pitch] or live_should[pitch];
        }
        self.updateCombined(&should_be_active, live_should, live_velocities, sample_offset);
    }

    fn process(self: *NoteSource, snapshot: *const StateSnapshot, sample_rate: f32, frame_count: u32) *const clap.events.InputEvents {
        self.event_list.reset();
        self.input_events.context = &self.event_list;
        const live_should = &snapshot.live_key_states[self.track_index];
        const live_velocities = &snapshot.live_key_velocities[self.track_index];

        if (!snapshot.playing) {
            if (self.emit_notes) {
                self.resetSequencer();
                self.updateCombined(live_should, live_should, live_velocities, 0);
            }
            return &self.input_events;
        }

        var active_scene: ?usize = null;
        const active_scene_count = @min(snapshot.scene_count, max_scenes);
        for (0..active_scene_count) |scene_index| {
            const slot = snapshot.clips[self.track_index][scene_index];
            if (slot.state == .playing) {
                active_scene = scene_index;
                break;
            }
        }

        if (active_scene == null) {
            if (self.emit_notes) {
                self.resetSequencer();
                self.updateCombined(live_should, live_should, live_velocities, 0);
            }
            return &self.input_events;
        }

        const clip = &snapshot.piano_clips[self.track_index][active_scene.?];

        if (self.last_scene == null or self.last_scene.? != active_scene.?) {
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
        // Wrap current_beat to clip bounds in case clip was shortened while playing
        const beat_start = @mod(self.current_beat, clip_len);
        const beat_end = beat_start + block_beats;

        if (self.emit_notes) {
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

        if (beat_end >= clip_len) {
            self.current_beat = @mod(beat_end, clip_len);
        } else {
            self.current_beat = beat_end;
        }

        return &self.input_events;
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
                    self.emitNoteEvents(
                        note.pitch,
                        note.velocity,
                        note.release_velocity,
                        note_start,
                        note_end,
                        seg_start,
                        seg_end,
                        base_sample_offset,
                        beats_per_sample,
                    );
                } else {
                    const wrapped_end = note_end - clip_len;
                    self.emitNoteEvents(
                        note.pitch,
                        note.velocity,
                        note.release_velocity,
                        note_start,
                        clip_len,
                        seg_start,
                        seg_end,
                        base_sample_offset,
                        beats_per_sample,
                    );
                    self.emitNoteEvents(
                        note.pitch,
                        note.velocity,
                        note.release_velocity,
                        0.0,
                        wrapped_end,
                        seg_start,
                        seg_end,
                        base_sample_offset,
                        beats_per_sample,
                    );
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
            if (lane.target_kind != .parameter or lane.param_id == clap.Id.invalid_id) {
                continue;
            }
            if (lane.target_fx_index != self.target_fx_index) {
                continue;
            }
            var last_before: ?AutomationPoint = null;
            var first_after: ?AutomationPoint = null;
            var first_overall: ?AutomationPoint = null;
            var last_overall: ?AutomationPoint = null;
            var has_point_at_start = false;
            for (lane.points[0..lane.point_count]) |point| {
                const point_time = @as(f64, point.time);
                if (first_overall == null or point_time < @as(f64, first_overall.?.time)) {
                    first_overall = point;
                }
                if (last_overall == null or point_time > @as(f64, last_overall.?.time)) {
                    last_overall = point;
                }
                if (point_time < seg_start and (last_before == null or point_time > @as(f64, last_before.?.time))) {
                    last_before = point;
                }
                if (point_time >= seg_start and (first_after == null or point_time < @as(f64, first_after.?.time))) {
                    first_after = point;
                }
                if (std.math.approxEqAbs(f64, point_time, seg_start, 1e-9)) {
                    has_point_at_start = true;
                }
                if (point_time < seg_start or point_time >= seg_end) continue;
                const offset = base_sample_offset + @as(u32, @intFromFloat(@floor((point_time - seg_start) / beats_per_sample)));
                self.emitParamValue(lane.param_id, @as(f64, point.value), offset);
            }
            if (!has_point_at_start and first_overall != null and last_overall != null) {
                const prev = if (last_before) |point| point else last_overall.?;
                const next = if (first_after) |point| point else first_overall.?;
                var prev_time = @as(f64, prev.time);
                var next_time = @as(f64, next.time);
                if (last_before == null) {
                    prev_time -= clip_len;
                }
                if (first_after == null) {
                    next_time += clip_len;
                }
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

pub const SynthNode = struct {
    track_index: usize,
    output_left: []f32 = &.{},
    output_right: []f32 = &.{},
    out_events_list: OutputEventList = .{},
    out_events: clap.events.OutputEvents = .{
        .context = undefined,
        .tryPush = outputEventsTryPush,
    },
    /// Plugin requested sleep - skip processing until new events arrive
    sleeping: bool = false,
    /// Output buffers are already zeroed - skip redundant memset
    buffer_zeroed: bool = false,
    /// Node marked for removal - skip processing entirely
    removed: bool = false,

    pub fn init(track_index: usize) SynthNode {
        return SynthNode{ .track_index = track_index };
    }
};

pub const FxNode = struct {
    track_index: usize,
    fx_index: usize,
    output_left: []f32 = &.{},
    output_right: []f32 = &.{},
    sleeping: bool = false,
    /// Output buffers are already zeroed - skip redundant memset
    buffer_zeroed: bool = false,
    /// Node marked for removal - skip processing entirely
    removed: bool = false,

    pub fn init(track_index: usize, fx_index: usize) FxNode {
        return FxNode{
            .track_index = track_index,
            .fx_index = fx_index,
        };
    }
};

const GainNode = struct {
    track_index: usize,
    output_left: []f32 = &.{},
    output_right: []f32 = &.{},
};

const MixerNode = struct {
    output_left: []f32 = &.{},
    output_right: []f32 = &.{},
};

const MasterNode = struct {
    output_left: []f32 = &.{},
    output_right: []f32 = &.{},
};

pub const Node = struct {
    pub const Kind = enum {
        note_source,
        synth,
        fx,
        gain,
        mixer,
        master,
    };

    id: NodeId,
    kind: Kind,
    input_ports: [2]Port = undefined,
    input_count: u8 = 0,
    output_ports: [2]Port = undefined,
    output_count: u8 = 0,
    data: union(Kind) {
        note_source: NoteSource,
        synth: SynthNode,
        fx: FxNode,
        gain: GainNode,
        mixer: MixerNode,
        master: MasterNode,
    },

    pub fn addInput(self: *Node, kind: PortKind) void {
        self.input_ports[self.input_count] = .{ .kind = kind };
        self.input_count += 1;
    }

    pub fn addOutput(self: *Node, kind: PortKind) void {
        self.output_ports[self.output_count] = .{ .kind = kind };
        self.output_count += 1;
    }
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    connections: std.ArrayList(Connection),
    render_order: std.ArrayList(NodeId),
    master_node: ?NodeId = null,
    sample_rate: f32 = 0.0,
    max_frames: u32 = 0,
    scratch_input_left: []f32 = &.{},
    scratch_input_right: []f32 = &.{},
    synth_node_ids: std.ArrayList(NodeId),
    note_source_node_ids: std.ArrayList(NodeId),
    fx_node_ids: std.ArrayList(NodeId),
    gain_node_ids: std.ArrayList(NodeId),

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .connections = .empty,
            .render_order = .empty,
            .synth_node_ids = .empty,
            .note_source_node_ids = .empty,
            .fx_node_ids = .empty,
            .gain_node_ids = .empty,
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.nodes.items) |*node| {
            switch (node.kind) {
                .synth => {
                    self.allocator.free(node.data.synth.output_left);
                    self.allocator.free(node.data.synth.output_right);
                },
                .fx => {
                    self.allocator.free(node.data.fx.output_left);
                    self.allocator.free(node.data.fx.output_right);
                },
                .gain => {
                    self.allocator.free(node.data.gain.output_left);
                    self.allocator.free(node.data.gain.output_right);
                },
                .mixer => {
                    self.allocator.free(node.data.mixer.output_left);
                    self.allocator.free(node.data.mixer.output_right);
                },
                .master => {
                    self.allocator.free(node.data.master.output_left);
                    self.allocator.free(node.data.master.output_right);
                },
                .note_source => {},
            }
        }
        if (self.scratch_input_left.len > 0) {
            self.allocator.free(self.scratch_input_left);
        }
        if (self.scratch_input_right.len > 0) {
            self.allocator.free(self.scratch_input_right);
        }
        self.nodes.deinit(self.allocator);
        self.connections.deinit(self.allocator);
        self.render_order.deinit(self.allocator);
        self.synth_node_ids.deinit(self.allocator);
        self.note_source_node_ids.deinit(self.allocator);
        self.fx_node_ids.deinit(self.allocator);
        self.gain_node_ids.deinit(self.allocator);
    }

    pub fn addNode(self: *Graph, node: Node) !NodeId {
        const id: NodeId = @intCast(self.nodes.items.len);
        var new_node = node;
        new_node.id = id;
        try self.nodes.append(self.allocator, new_node);
        return id;
    }

    pub fn connect(self: *Graph, from: NodeId, from_port: u8, to: NodeId, to_port: u8, kind: PortKind) !void {
        try self.connections.append(self.allocator, .{
            .from = from,
            .from_port = from_port,
            .to = to,
            .to_port = to_port,
            .kind = kind,
        });
    }

    pub fn prepare(self: *Graph, sample_rate: f32, max_frames: u32) !void {
        self.sample_rate = sample_rate;
        self.max_frames = max_frames;
        self.scratch_input_left = try self.allocator.alloc(f32, max_frames);
        self.scratch_input_right = try self.allocator.alloc(f32, max_frames);
        for (self.nodes.items) |*node| {
            switch (node.kind) {
                .note_source => {},
                .synth => {
                    node.data.synth.output_left = try self.allocator.alloc(f32, max_frames);
                    node.data.synth.output_right = try self.allocator.alloc(f32, max_frames);
                },
                .fx => {
                    node.data.fx.output_left = try self.allocator.alloc(f32, max_frames);
                    node.data.fx.output_right = try self.allocator.alloc(f32, max_frames);
                },
                .gain => {
                    node.data.gain.output_left = try self.allocator.alloc(f32, max_frames);
                    node.data.gain.output_right = try self.allocator.alloc(f32, max_frames);
                },
                .mixer => {
                    node.data.mixer.output_left = try self.allocator.alloc(f32, max_frames);
                    node.data.mixer.output_right = try self.allocator.alloc(f32, max_frames);
                },
                .master => {
                    node.data.master.output_left = try self.allocator.alloc(f32, max_frames);
                    node.data.master.output_right = try self.allocator.alloc(f32, max_frames);
                },
            }
        }

        try self.buildRenderOrder();
    }

    fn buildRenderOrder(self: *Graph) !void {
        self.render_order.clearRetainingCapacity();
        self.synth_node_ids.clearRetainingCapacity();
        self.note_source_node_ids.clearRetainingCapacity();
        self.fx_node_ids.clearRetainingCapacity();
        self.gain_node_ids.clearRetainingCapacity();

        const node_count = self.nodes.items.len;
        var indegree = try self.allocator.alloc(u32, node_count);
        defer self.allocator.free(indegree);
        @memset(indegree, 0);

        for (self.connections.items) |conn| {
            indegree[conn.to] += 1;
        }

        var queue = std.ArrayList(NodeId).empty;
        defer queue.deinit(self.allocator);
        for (self.nodes.items, 0..) |_, idx| {
            if (indegree[idx] == 0) {
                try queue.append(self.allocator, @intCast(idx));
            }
        }

        while (queue.items.len > 0) {
            const id = queue.orderedRemove(0);
            try self.render_order.append(self.allocator, id);

            // Categorize by node type
            const node = &self.nodes.items[id];
            switch (node.kind) {
                .note_source => try self.note_source_node_ids.append(self.allocator, id),
                .synth => try self.synth_node_ids.append(self.allocator, id),
                .fx => try self.fx_node_ids.append(self.allocator, id),
                .gain => try self.gain_node_ids.append(self.allocator, id),
                .mixer, .master => {},
            }

            for (self.connections.items) |conn| {
                if (conn.from == id) {
                    indegree[conn.to] -= 1;
                    if (indegree[conn.to] == 0) {
                        try queue.append(self.allocator, conn.to);
                    }
                }
            }
        }
    }

    pub fn getAudioOutput(self: *Graph, node_id: NodeId) struct { left: []f32, right: []f32 } {
        const node = &self.nodes.items[node_id];
        return switch (node.kind) {
            .synth => .{ .left = node.data.synth.output_left, .right = node.data.synth.output_right },
            .fx => .{ .left = node.data.fx.output_left, .right = node.data.fx.output_right },
            .gain => .{ .left = node.data.gain.output_left, .right = node.data.gain.output_right },
            .mixer => .{ .left = node.data.mixer.output_left, .right = node.data.mixer.output_right },
            .master => .{ .left = node.data.master.output_left, .right = node.data.master.output_right },
            .note_source => .{ .left = &.{}, .right = &.{} },
        };
    }

    /// Mark a synth or fx node for soft removal. The node will be skipped during processing
    /// but remains in the graph until compactRemovedNodes() is called.
    pub fn markNodeRemoved(self: *Graph, node_id: NodeId) void {
        var node = &self.nodes.items[node_id];
        switch (node.kind) {
            .synth => node.data.synth.removed = true,
            .fx => node.data.fx.removed = true,
            else => {},
        }
    }

    /// Check if a node is marked for removal.
    pub fn isNodeRemoved(self: *const Graph, node_id: NodeId) bool {
        const node = &self.nodes.items[node_id];
        return switch (node.kind) {
            .synth => node.data.synth.removed,
            .fx => node.data.fx.removed,
            else => false,
        };
    }

    fn sumAudioInputs(self: *Graph, node_id: NodeId, frame_count: u32, out_left: []f32, out_right: []f32) void {
        @memset(out_left[0..frame_count], 0);
        @memset(out_right[0..frame_count], 0);
        for (self.connections.items) |conn| {
            if (conn.to != node_id or conn.kind != .audio) {
                continue;
            }
            const src = self.getAudioOutput(conn.from);
            for (0..frame_count) |i| {
                out_left[i] += src.left[i];
                out_right[i] += src.right[i];
            }
        }
    }

    fn findEventInput(self: *Graph, node_id: NodeId) ?*const clap.events.InputEvents {
        for (self.connections.items) |conn| {
            if (conn.to == node_id and conn.kind == .events) {
                const node = &self.nodes.items[conn.from];
                if (node.kind == .note_source) {
                    return &node.data.note_source.input_events;
                }
            }
        }
        return null;
    }

    const ProcessContext = struct {
        graph: *Graph,
        snapshot: *const StateSnapshot,
        shared: *audio_engine.SharedState,
        frame_count: u32,
        steady_time: u64,
        solo_active: bool,
        wake_requested: bool,
    };

    pub fn process(self: *Graph, snapshot: *const StateSnapshot, shared: *audio_engine.SharedState, jobs: *JobQueue, frame_count: u32, steady_time: u64) void {
        const zone = tracy.ZoneN(@src(), "Graph.process");
        defer zone.End();

        var solo_active = false;
        const active_track_count = @min(snapshot.track_count, max_tracks);
        for (0..active_track_count) |t| {
            const track = snapshot.tracks[t];
            if (track.solo) {
                solo_active = true;
                break;
            }
        }

        // Process note sources (lightweight, sequential)
        {
            const ns_zone = tracy.ZoneN(@src(), "Note sources");
            defer ns_zone.End();
            for (self.note_source_node_ids.items) |node_id| {
                var node = &self.nodes.items[node_id];
                _ = node.data.note_source.process(snapshot, self.sample_rate, frame_count);
            }
        }

        var ctx = ProcessContext{
            .graph = self,
            .snapshot = snapshot,
            .shared = shared,
            .frame_count = frame_count,
            .steady_time = steady_time,
            .solo_active = solo_active,
            .wake_requested = shared.process_requested.swap(false, .acq_rel),
        };

        // Process synths (heavy, parallel if job queue available)
        {
            const synth_zone = tracy.ZoneN(@src(), "Synths");
            defer synth_zone.End();

            const synth_count = self.synth_node_ids.items.len;
            if (synth_count > 0) {
                var active_tasks: [max_tracks]u32 = undefined;
                var active_count: usize = 0;

                for (self.synth_node_ids.items, 0..) |node_id, i| {
                    var node = &self.nodes.items[node_id];

                    // Skip removed nodes entirely
                    if (node.data.synth.removed) continue;

                    const plugin = snapshot.track_plugins[node.data.synth.track_index];
                    if (plugin == null) {
                        // Only zero buffers once when plugin becomes null
                        if (!node.data.synth.buffer_zeroed) {
                            const outputs = self.getAudioOutput(node_id);
                            @memset(outputs.left[0..frame_count], 0);
                            @memset(outputs.right[0..frame_count], 0);
                            node.data.synth.buffer_zeroed = true;
                        }
                        node.data.synth.sleeping = false;
                        continue;
                    }
                    // Reset flag when plugin is active
                    node.data.synth.buffer_zeroed = false;

                    if (ctx.wake_requested) {
                        active_tasks[active_count] = @intCast(i);
                        active_count += 1;
                        continue;
                    }

                    const input_events_opt = self.findEventInput(node_id);
                    const has_input_events = if (input_events_opt) |input_events| input_events.size(input_events) > 0 else false;
                    if (has_input_events or !node.data.synth.sleeping) {
                        active_tasks[active_count] = @intCast(i);
                        active_count += 1;
                    } else {
                        // Sleeping with no events - only zero once
                        if (!node.data.synth.buffer_zeroed) {
                            const outputs = self.getAudioOutput(node_id);
                            @memset(outputs.left[0..frame_count], 0);
                            @memset(outputs.right[0..frame_count], 0);
                            node.data.synth.buffer_zeroed = true;
                        }
                    }
                }

                if (active_count > 0) {
                    // Use libz_jobs work-stealing queue
                    const RootJob = struct {
                        pub fn exec(_: *@This()) void {}
                    };
                    const root = jobs.allocate(RootJob{});

                    // Allocate and schedule synth jobs
                    for (active_tasks[0..active_count]) |task_index| {
                        const SynthJob = struct {
                            ctx: *ProcessContext,
                            task_index: u32,
                            pub fn exec(job: *@This()) void {
                                processSynthTaskDirect(job.ctx, job.task_index);
                            }
                        };
                        const synth_job = jobs.allocate(SynthJob{
                            .ctx = &ctx,
                            .task_index = task_index,
                        });
                        jobs.finishWith(synth_job, root);
                        jobs.schedule(synth_job);
                    }

                    // Schedule root and wait - main thread helps process
                    jobs.schedule(root);
                    jobs.wait(root);
                }
            }
        }

        // Process audio FX (sequential, per node order)
        {
            const fx_zone = tracy.ZoneN(@src(), "Audio FX");
            defer fx_zone.End();
            for (self.fx_node_ids.items) |node_id| {
                self.processFxNode(&ctx, node_id);
            }
        }

        // Process gains (lightweight, sequential)
        {
            const gain_zone = tracy.ZoneN(@src(), "Gains");
            defer gain_zone.End();
            for (self.gain_node_ids.items) |node_id| {
                const node = &self.nodes.items[node_id];
                const outputs = self.getAudioOutput(node_id);
                self.sumAudioInputs(node_id, frame_count, outputs.left, outputs.right);
                const track = snapshot.tracks[node.data.gain.track_index];
                const mute = track.mute or (solo_active and !track.solo);
                const gain = if (mute) 0.0 else track.volume;
                for (0..frame_count) |i| {
                    outputs.left[i] *= gain;
                    outputs.right[i] *= gain;
                }
            }
        }

        // Process mixer and master (sequential)
        {
            const mix_zone = tracy.ZoneN(@src(), "Mixer/Master");
            defer mix_zone.End();
            for (self.render_order.items) |node_id| {
                const node = &self.nodes.items[node_id];
                switch (node.kind) {
                    .mixer, .master => {
                        const outputs = self.getAudioOutput(node_id);
                        self.sumAudioInputs(node_id, frame_count, outputs.left, outputs.right);
                        if (node.kind == .master) {
                            const master_track = snapshot.tracks[master_track_index];
                            const master_mute = master_track.mute;
                            const gain = if (master_mute) 0.0 else master_track.volume;
                            for (0..frame_count) |i| {
                                outputs.left[i] *= gain;
                                outputs.right[i] *= gain;
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn processFxNode(self: *Graph, ctx: *const ProcessContext, node_id: NodeId) void {
        var node = &self.nodes.items[node_id];
        const track_index = node.data.fx.track_index;
        const fx_index = node.data.fx.fx_index;
        // Skip removed nodes entirely
        if (node.data.fx.removed) return;

        const outputs = self.getAudioOutput(node_id);
        const input_left = self.scratch_input_left[0..ctx.frame_count];
        const input_right = self.scratch_input_right[0..ctx.frame_count];
        self.sumAudioInputs(node_id, ctx.frame_count, input_left, input_right);

        const plugin = ctx.snapshot.track_fx_plugins[track_index][fx_index] orelse {
            @memcpy(outputs.left[0..ctx.frame_count], input_left);
            @memcpy(outputs.right[0..ctx.frame_count], input_right);
            node.data.fx.sleeping = false;
            node.data.fx.buffer_zeroed = false; // Has input data, not zeroed
            return;
        };
        node.data.fx.buffer_zeroed = false; // Active plugin, not zeroed

        if (ctx.shared.checkAndClearStartProcessingFx(track_index, fx_index)) {
            if (!ctx.shared.isFxPluginStarted(track_index, fx_index)) {
                if (plugin.startProcessing(plugin)) {
                    ctx.shared.markFxPluginStarted(track_index, fx_index);
                } else {
                    std.log.warn("Failed to start processing for track {d} fx {d}", .{ track_index, fx_index });
                }
            }
        }

        const output_channel_count: u32 = 2;
        var input_ptrs = [2][*]f32{ input_left.ptr, input_right.ptr };
        var output_ptrs = [2][*]f32{ outputs.left.ptr, outputs.right.ptr };
        var audio_in = clap.AudioBuffer{
            .data32 = &input_ptrs,
            .data64 = null,
            .channel_count = output_channel_count,
            .latency = 0,
            .constant_mask = 0,
        };
        var audio_out = clap.AudioBuffer{
            .data32 = &output_ptrs,
            .data64 = null,
            .channel_count = output_channel_count,
            .latency = 0,
            .constant_mask = 0,
        };

        const empty_event_list = EventList{};
        var empty_input_events = clap.events.InputEvents{
            .context = @constCast(&empty_event_list),
            .size = inputEventsSize,
            .get = inputEventsGet,
        };
        const input_events = ctx.graph.findEventInput(node_id) orelse &empty_input_events;

        const tempo = @as(f64, ctx.snapshot.bpm);
        const beats = @as(f64, ctx.snapshot.playhead_beat);
        const seconds = if (tempo > 0.0) beats * 60.0 / tempo else 0.0;
        const bar_len = 4.0;
        const bar_index = @floor(beats / bar_len);

        var transport = clap.events.Transport{
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
            .time_signature_numerator = 4,
            .time_signature_denominator = 4,
        };

        var out_events_list = OutputEventList{};
        var out_events = clap.events.OutputEvents{
            .context = &out_events_list,
            .tryPush = outputEventsTryPush,
        };

        var clap_process = clap.Process{
            .steady_time = @enumFromInt(@as(i64, @intCast(ctx.steady_time))),
            .frames_count = ctx.frame_count,
            .transport = &transport,
            .audio_inputs = @as([*]const clap.AudioBuffer, @ptrCast(&audio_in)),
            .audio_outputs = @as([*]clap.AudioBuffer, @ptrCast(&audio_out)),
            .audio_inputs_count = 1,
            .audio_outputs_count = 1,
            .in_events = input_events,
            .out_events = &out_events,
        };

        current_processing_plugin = plugin;
        _ = plugin.process(plugin, &clap_process);
        current_processing_plugin = null;
    }

    fn processSynthTaskDirect(ctx: *ProcessContext, task_index: u32) void {
        const thread_context = @import("../thread_context.zig");
        thread_context.is_audio_thread = true;
        thread_context.in_jobs_worker = true;
        defer thread_context.in_jobs_worker = false;

        const zone = tracy.ZoneN(@src(), "Synth task");
        defer zone.End();
        const node_id = ctx.graph.synth_node_ids.items[task_index];
        var node = &ctx.graph.nodes.items[node_id];

        node.data.synth.out_events.context = &node.data.synth.out_events_list;
        const outputs = ctx.graph.getAudioOutput(node_id);
        @memset(outputs.left[0..ctx.frame_count], 0);
        @memset(outputs.right[0..ctx.frame_count], 0);

        const plugin = ctx.snapshot.track_plugins[node.data.synth.track_index] orelse return;
        // Use stereo output - querying audio_ports from audio thread is not allowed
        const output_channel_count: u32 = 2;

        var channel_ptrs = [2][*]f32{ outputs.left.ptr, outputs.right.ptr };
        var audio_out = clap.AudioBuffer{
            .data32 = &channel_ptrs,
            .data64 = null,
            .channel_count = output_channel_count,
            .latency = 0,
            .constant_mask = 0,
        };

        const empty_input = clap.AudioBuffer{
            .data32 = null,
            .data64 = null,
            .channel_count = 0,
            .latency = 0,
            .constant_mask = 0,
        };
        const empty_event_list = EventList{};
        var empty_input_events = clap.events.InputEvents{
            .context = @constCast(&empty_event_list),
            .size = inputEventsSize,
            .get = inputEventsGet,
        };

        const input_events = ctx.graph.findEventInput(node_id) orelse &empty_input_events;
        const has_input_events = input_events.size(input_events) > 0;

        // Check if plugin needs startProcessing called (must be done from audio thread)
        const track_index = node.data.synth.track_index;
        if (ctx.shared.checkAndClearStartProcessing(track_index)) {
            // Only call startProcessing if not already started
            if (!ctx.shared.isPluginStarted(track_index)) {
                if (plugin.startProcessing(plugin)) {
                    ctx.shared.markPluginStarted(track_index);
                } else {
                    std.log.warn("Failed to start processing for track {d} plugin", .{track_index});
                }
            }
        }

        // Wake plugin if it has new events, skip if sleeping with no events
        const was_sleeping = node.data.synth.sleeping;
        if (has_input_events) {
            node.data.synth.sleeping = false;
        } else if (ctx.wake_requested) {
            node.data.synth.sleeping = false;
        } else if (node.data.synth.sleeping) {
            // Plugin requested sleep and no new events - skip processing
            current_processing_plugin = null;
            return;
        }

        node.data.synth.out_events_list.count = 0;

        const tempo = @as(f64, ctx.snapshot.bpm);
        const beats = @as(f64, ctx.snapshot.playhead_beat);
        const seconds = if (tempo > 0.0) beats * 60.0 / tempo else 0.0;
        const bar_len = 4.0;
        const bar_index = @floor(beats / bar_len);

        var transport = clap.events.Transport{
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
            .time_signature_numerator = 4,
            .time_signature_denominator = 4,
        };

        var clap_process = clap.Process{
            .steady_time = @enumFromInt(@as(i64, @intCast(ctx.steady_time))),
            .frames_count = ctx.frame_count,
            .transport = &transport,
            .audio_inputs = @as([*]const clap.AudioBuffer, @ptrCast(&empty_input)),
            .audio_outputs = @as([*]clap.AudioBuffer, @ptrCast(&audio_out)),
            .audio_inputs_count = 0,
            .audio_outputs_count = 1,
            .in_events = input_events,
            .out_events = &node.data.synth.out_events,
        };

        current_processing_plugin = plugin;
        const status = plugin.process(plugin, &clap_process);
        current_processing_plugin = null;

        // If plugin requests sleep, skip future processing until new events
        if (status == .sleep and !was_sleeping) {
            node.data.synth.sleeping = true;
        } else if (status == .sleep) {
            node.data.synth.sleeping = true;
        }
    }
};
