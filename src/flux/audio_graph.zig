const std = @import("std");
const clap = @import("clap-bindings");
const ui = @import("ui.zig");
const audio_engine = @import("audio_engine.zig");

pub const NodeId = u32;
pub const max_clip_notes = 256;

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
    tracks: [ui.track_count]ui.Track,
    clips: [ui.track_count][ui.scene_count]ui.ClipSlot,
    piano_clips: [ui.track_count][ui.scene_count]ClipNotes,
    track_plugins: [ui.track_count]?*const clap.Plugin,
    live_key_states: [ui.track_count][128]bool,
};

pub const ClipNotes = struct {
    length_beats: f32 = ui.default_clip_bars * ui.beats_per_bar,
    count: u16 = 0,
    notes: [max_clip_notes]ui.Note = [_]ui.Note{
        .{ .pitch = 0, .start = 0, .duration = 0 },
    } ** max_clip_notes,
};

const max_note_events = 128;

const EventList = struct {
    events: [max_note_events]clap.events.Note = undefined,
    count: u32 = 0,

    fn reset(self: *EventList) void {
        self.count = 0;
    }

    fn pushNote(self: *EventList, event: clap.events.Note) void {
        if (self.count >= max_note_events) {
            return;
        }
        self.events[self.count] = event;
        self.count += 1;
    }
};

fn inputEventsSize(list: *const clap.events.InputEvents) callconv(.c) u32 {
    const ctx: *const EventList = @ptrCast(@alignCast(list.context));
    return ctx.count;
}

fn inputEventsGet(list: *const clap.events.InputEvents, index: u32) callconv(.c) *const clap.events.Header {
    const ctx: *const EventList = @ptrCast(@alignCast(list.context));
    return &ctx.events[index].header;
}

const OutputEventList = struct {
    events: [max_note_events]clap.events.Note = undefined,
    count: u32 = 0,
};

fn outputEventsTryPush(list: *const clap.events.OutputEvents, event: *const clap.events.Header) callconv(.c) bool {
    const ctx: *OutputEventList = @ptrCast(@alignCast(list.context));
    if (ctx.count >= max_note_events) {
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

    pub fn init(track_index: usize) NoteSource {
        return NoteSource{ .track_index = track_index };
    }

    fn resetSequencer(self: *NoteSource) void {
        self.current_beat = 0.0;
        self.last_scene = null;
    }

    fn emitNoteOn(self: *NoteSource, pitch: u8, sample_offset: u32) void {
        self.event_list.pushNote(.{
            .header = .{
                .size = @sizeOf(clap.events.Note),
                .sample_offset = sample_offset,
                .space_id = clap.events.core_space_id,
                .type = .note_on,
                .flags = .{},
            },
            .note_id = .unspecified,
            .port_index = .unspecified,
            .channel = .unspecified,
            .key = @enumFromInt(@as(i16, @intCast(pitch))),
            .velocity = 1.0,
        });
        self.active_pitches[pitch] = true;
    }

    fn emitNoteOff(self: *NoteSource, pitch: u8, sample_offset: u32) void {
        self.event_list.pushNote(.{
            .header = .{
                .size = @sizeOf(clap.events.Note),
                .sample_offset = sample_offset,
                .space_id = clap.events.core_space_id,
                .type = .note_off,
                .flags = .{},
            },
            .note_id = .unspecified,
            .port_index = .unspecified,
            .channel = .unspecified,
            .key = @enumFromInt(@as(i16, @intCast(pitch))),
            .velocity = 0.0,
        });
        self.active_pitches[pitch] = false;
    }

    fn updateCombined(self: *NoteSource, desired: *const [128]bool, sample_offset: u32) void {
        for (0..128) |pitch| {
            if (self.active_pitches[pitch] and !desired[pitch]) {
                self.emitNoteOff(@intCast(pitch), sample_offset);
            } else if (!self.active_pitches[pitch] and desired[pitch]) {
                self.emitNoteOn(@intCast(pitch), sample_offset);
            }
        }
    }

    fn updateNotesAtBeat(
        self: *NoteSource,
        clip: *const ClipNotes,
        beat: f32,
        sample_offset: u32,
        live_should: *const [128]bool,
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
        self.updateCombined(&should_be_active, sample_offset);
    }

    fn process(self: *NoteSource, snapshot: *const StateSnapshot, sample_rate: f32, frame_count: u32) *const clap.events.InputEvents {
        self.event_list.reset();
        self.input_events.context = &self.event_list;
        const live_should = &snapshot.live_key_states[self.track_index];

        if (!snapshot.playing) {
            self.resetSequencer();
            self.updateCombined(live_should, 0);
            return &self.input_events;
        }

        var active_scene: ?usize = null;
        const scene_count = @min(snapshot.scene_count, ui.scene_count);
        for (0..scene_count) |scene_index| {
            const slot = snapshot.clips[self.track_index][scene_index];
            if (slot.state == .playing) {
                active_scene = scene_index;
                break;
            }
        }

        if (active_scene == null) {
            self.resetSequencer();
            self.updateCombined(live_should, 0);
            return &self.input_events;
        }

        const clip = &snapshot.piano_clips[self.track_index][active_scene.?];

        if (self.last_scene == null or self.last_scene.? != active_scene.?) {
            self.current_beat = 0.0;
            self.last_scene = active_scene;
        }

        const clip_len = @as(f64, clip.length_beats);
        if (clip_len <= 0.0) {
            self.updateCombined(live_should, 0);
            return &self.input_events;
        }

        const beats_per_second = @as(f64, snapshot.bpm) / 60.0;
        const beats_per_sample = beats_per_second / @as(f64, sample_rate);
        const block_beats = beats_per_sample * @as(f64, frame_count);
        const beat_start = self.current_beat;
        const beat_end = beat_start + block_beats;

        self.updateNotesAtBeat(clip, @floatCast(beat_start), 0, live_should);

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
        for (clip.notes[0..clip.count]) |note| {
            const note_start = @as(f64, note.start);
            const note_end = note_start + @as(f64, note.duration);

            if (note_end <= clip_len) {
                self.emitNoteEvents(note.pitch, note_start, note_end, seg_start, seg_end, base_sample_offset, beats_per_sample);
            } else {
                const wrapped_end = note_end - clip_len;
                self.emitNoteEvents(note.pitch, note_start, clip_len, seg_start, seg_end, base_sample_offset, beats_per_sample);
                self.emitNoteEvents(note.pitch, 0.0, wrapped_end, seg_start, seg_end, base_sample_offset, beats_per_sample);
            }
        }
    }

    fn emitNoteEvents(
        self: *NoteSource,
        pitch: u8,
        note_start: f64,
        note_end: f64,
        seg_start: f64,
        seg_end: f64,
        base_sample_offset: u32,
        beats_per_sample: f64,
    ) void {
        if (note_start > seg_start and note_start < seg_end) {
            const offset = base_sample_offset + @as(u32, @intFromFloat(@floor((note_start - seg_start) / beats_per_sample)));
            self.emitNoteOn(pitch, offset);
        }
        if (note_end > seg_start and note_end < seg_end) {
            const offset = base_sample_offset + @as(u32, @intFromFloat(@floor((note_end - seg_start) / beats_per_sample)));
            self.emitNoteOff(pitch, offset);
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

    pub fn init(track_index: usize) SynthNode {
        return SynthNode{ .track_index = track_index };
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

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .connections = .empty,
            .render_order = .empty,
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.nodes.items) |*node| {
            switch (node.kind) {
                .synth => {
                    self.allocator.free(node.data.synth.output_left);
                    self.allocator.free(node.data.synth.output_right);
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
            .gain => .{ .left = node.data.gain.output_left, .right = node.data.gain.output_right },
            .mixer => .{ .left = node.data.mixer.output_left, .right = node.data.mixer.output_right },
            .master => .{ .left = node.data.master.output_left, .right = node.data.master.output_right },
            .note_source => .{ .left = &.{}, .right = &.{} },
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

    fn getMainPortChannelCount(_: *Graph, plugin: *const clap.Plugin, is_input: bool) ?u32 {
        const ext_raw = plugin.getExtension(plugin, clap.ext.audio_ports.id) orelse return null;
        const ext: *const clap.ext.audio_ports.Plugin = @ptrCast(@alignCast(ext_raw));
        if (ext.count(plugin, is_input) == 0) {
            return 0;
        }
        var info: clap.ext.audio_ports.Info = undefined;
        if (!ext.get(plugin, 0, is_input, &info)) {
            return null;
        }
        return info.channel_count;
    }

    pub fn process(self: *Graph, snapshot: *const StateSnapshot, shared: *audio_engine.SharedState, frame_count: u32, steady_time: u64) void {
        var solo_active = false;
        const track_count = @min(snapshot.track_count, ui.track_count);
        for (0..track_count) |t| {
            const track = snapshot.tracks[t];
            if (track.solo) {
                solo_active = true;
                break;
            }
        }

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

        for (self.render_order.items) |node_id| {
            var node = &self.nodes.items[node_id];
            switch (node.kind) {
                .note_source => {
                    _ = node.data.note_source.process(snapshot, self.sample_rate, frame_count);
                },
                .synth => {
                    node.data.synth.out_events.context = &node.data.synth.out_events_list;
                    const outputs = self.getAudioOutput(node_id);
                    @memset(outputs.left[0..frame_count], 0);
                    @memset(outputs.right[0..frame_count], 0);

                    const plugin = snapshot.track_plugins[node.data.synth.track_index] orelse continue;
                    const output_channels = self.getMainPortChannelCount(plugin, false) orelse 2;
                    const input_channels = self.getMainPortChannelCount(plugin, true) orelse 0;
                    const output_channel_count: u32 = @min(if (output_channels == 0) 2 else output_channels, 2);
                    const input_channel_count: u32 = if (input_channels == 0) 0 else @min(input_channels, 2);

                    var input_ptrs: [2][*]f32 = undefined;
                    var audio_in: clap.AudioBuffer = undefined;
                    if (input_channel_count > 0) {
                        @memset(self.scratch_input_left[0..frame_count], 0);
                        if (input_channel_count > 1) {
                            @memset(self.scratch_input_right[0..frame_count], 0);
                        }
                        input_ptrs = [2][*]f32{ self.scratch_input_left.ptr, self.scratch_input_right.ptr };
                        audio_in = clap.AudioBuffer{
                            .data32 = &input_ptrs,
                            .data64 = null,
                            .channel_count = input_channel_count,
                            .latency = 0,
                            .constant_mask = 0,
                        };
                    }
                    var channel_ptrs = [2][*]f32{ outputs.left.ptr, outputs.right.ptr };
                    var audio_out = clap.AudioBuffer{
                        .data32 = &channel_ptrs,
                        .data64 = null,
                        .channel_count = output_channel_count,
                        .latency = 0,
                        .constant_mask = 0,
                    };

                    const input_events = self.findEventInput(node_id) orelse &empty_input_events;
                    node.data.synth.out_events_list.count = 0;
                    const process_inputs: [*]const clap.AudioBuffer = if (input_channel_count == 0)
                        @as([*]const clap.AudioBuffer, @ptrCast(&empty_input))
                    else
                        @as([*]const clap.AudioBuffer, @ptrCast(&audio_in));
                    const process_input_count: u32 = if (input_channel_count == 0) 0 else 1;
                    const process_output_count: u32 = 1;
                    const process_outputs_ptr: [*]clap.AudioBuffer = @as([*]clap.AudioBuffer, @ptrCast(&audio_out));
                    const tempo = @as(f64, snapshot.bpm);
                    const beats = @as(f64, snapshot.playhead_beat);
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
                            .is_playing = snapshot.playing,
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
                        .steady_time = @enumFromInt(@as(i64, @intCast(steady_time))),
                        .frames_count = frame_count,
                        .transport = &transport,
                        .audio_inputs = process_inputs,
                        .audio_outputs = process_outputs_ptr,
                        .audio_inputs_count = process_input_count,
                        .audio_outputs_count = process_output_count,
                        .in_events = input_events,
                        .out_events = &node.data.synth.out_events,
                    };
                    shared.current_processing_plugin.store(plugin, .release);
                    _ = plugin.process(plugin, &clap_process);
                    shared.current_processing_plugin.store(null, .release);
                },
                .gain => {
                    const outputs = self.getAudioOutput(node_id);
                    self.sumAudioInputs(node_id, frame_count, outputs.left, outputs.right);
                    const track = snapshot.tracks[node.data.gain.track_index];
                    const mute = track.mute or (solo_active and !track.solo);
                    const gain = if (mute) 0.0 else track.volume;
                    for (0..frame_count) |i| {
                        outputs.left[i] *= gain;
                        outputs.right[i] *= gain;
                    }
                },
                .mixer => {
                    const outputs = self.getAudioOutput(node_id);
                    self.sumAudioInputs(node_id, frame_count, outputs.left, outputs.right);
                },
                .master => {
                    const outputs = self.getAudioOutput(node_id);
                    self.sumAudioInputs(node_id, frame_count, outputs.left, outputs.right);
                },
            }
        }
    }
};
