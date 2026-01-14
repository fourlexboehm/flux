const std = @import("std");
const clap = @import("clap-bindings");
const ui = @import("ui.zig");
const zsynth = @import("zsynth-core");

pub const NodeId = u32;

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
    tracks: [ui.track_count]ui.Track,
    clips: [ui.track_count][ui.scene_count]ui.ClipSlot,
    sequencer: [ui.track_count][ui.scene_count]ui.SequencerClip,
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

pub const NoteSource = struct {
    track_index: usize,
    samples_into_step: f64 = 0.0,
    current_step: u8 = 0,
    active_notes: [ui.seq_rows]bool = [_]bool{false} ** ui.seq_rows,
    last_scene: ?usize = null,
    needs_step_trigger: bool = true,
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
        self.samples_into_step = 0.0;
        self.current_step = 0;
        self.active_notes = [_]bool{false} ** ui.seq_rows;
        self.needs_step_trigger = true;
    }

    fn emitStepEvents(self: *NoteSource, clip: *const ui.SequencerClip, sample_offset: u32) void {
        const length_steps = @max(@as(u8, 1), @min(clip.length_steps, ui.seq_steps));
        const step_index: usize = @intCast(self.current_step % length_steps);
        for (0..ui.seq_rows) |row| {
            const now_active = noteIsActive(clip, row, step_index, length_steps);
            const was_active = self.active_notes[row];
            if (now_active and !was_active) {
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
                    .key = @enumFromInt(60 + @as(i16, @intCast(ui.seq_rows - 1 - row))),
                    .velocity = 1.0,
                });
            } else if (!now_active and was_active) {
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
                    .key = @enumFromInt(60 + @as(i16, @intCast(ui.seq_rows - 1 - row))),
                    .velocity = 0.0,
                });
            }
            self.active_notes[row] = now_active;
        }
    }

    fn emitAllNotesOff(self: *NoteSource) void {
        for (0..ui.seq_rows) |row| {
            if (!self.active_notes[row]) continue;
            self.event_list.pushNote(.{
                .header = .{
                    .size = @sizeOf(clap.events.Note),
                    .sample_offset = 0,
                    .space_id = clap.events.core_space_id,
                    .type = .note_off,
                    .flags = .{},
                },
                .note_id = .unspecified,
                .port_index = .unspecified,
                .channel = .unspecified,
                .key = @enumFromInt(60 + @as(i16, @intCast(ui.seq_rows - 1 - row))),
                .velocity = 0.0,
            });
            self.active_notes[row] = false;
        }
    }

    fn process(self: *NoteSource, snapshot: *const StateSnapshot, sample_rate: f32, frame_count: u32) *const clap.events.InputEvents {
        self.event_list.reset();
        self.input_events.context = &self.event_list;

        if (!snapshot.playing) {
            self.emitAllNotesOff();
            self.resetSequencer();
            return &self.input_events;
        }

        var active_scene: ?usize = null;
        for (snapshot.clips[self.track_index], 0..) |slot, scene_index| {
            if (slot.state == .playing) {
                active_scene = scene_index;
                break;
            }
        }

        if (active_scene == null) {
            self.emitAllNotesOff();
            self.resetSequencer();
            self.last_scene = null;
            return &self.input_events;
        }

        if (self.last_scene == null or self.last_scene.? != active_scene.?) {
            self.emitAllNotesOff();
            self.resetSequencer();
            self.last_scene = active_scene;
        }

        const clip = &snapshot.sequencer[self.track_index][active_scene.?];
        if (self.needs_step_trigger) {
            self.emitStepEvents(clip, 0);
            self.needs_step_trigger = false;
        }

        const samples_per_step = (@as(f64, sample_rate) * 60.0) / @as(f64, snapshot.bpm) / 4.0;
        var sample_index: u32 = 0;
        while (sample_index < frame_count) : (sample_index += 1) {
            self.samples_into_step += 1.0;
            if (self.samples_into_step >= samples_per_step) {
                self.samples_into_step -= samples_per_step;
                const length_steps = @max(@as(u8, 1), @min(clip.length_steps, ui.seq_steps));
                self.current_step = @intCast((self.current_step + 1) % length_steps);
                self.emitStepEvents(clip, sample_index);
            }
        }

        return &self.input_events;
    }
};

fn noteIsActive(clip: *const ui.SequencerClip, row: usize, step: usize, length_steps: u8) bool {
    var idx: i32 = @intCast(step);
    while (idx >= 0) : (idx -= 1) {
        const start: usize = @intCast(idx);
        const len = clip.notes[row][start];
        if (len == 0) continue;
        if (start >= length_steps) continue;
        const max_len: u8 = length_steps - @as(u8, @intCast(start));
        const clamped_len = if (len > max_len) max_len else len;
        if (step < start + clamped_len) {
            return true;
        }
    }
    return false;
}

pub const SynthNode = struct {
    plugin: *zsynth.Plugin,
    output_left: []f32 = &.{},
    output_right: []f32 = &.{},
    out_events_list: OutputEventList = .{},
    out_events: clap.events.OutputEvents = .{
        .context = undefined,
        .tryPush = outputEventsTryPush,
    },

    pub fn init(plugin: *zsynth.Plugin) SynthNode {
        return SynthNode{ .plugin = plugin };
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

    pub fn process(self: *Graph, snapshot: *const StateSnapshot, frame_count: u32, steady_time: u64) void {
        var solo_active = false;
        for (snapshot.tracks) |track| {
            if (track.solo) {
                solo_active = true;
                break;
            }
        }

        const empty_buffers: [0]clap.AudioBuffer = .{};
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

                    var channel_ptrs = [2][*]f32{ outputs.left.ptr, outputs.right.ptr };
                    var audio_out = clap.AudioBuffer{
                        .data32 = &channel_ptrs,
                        .data64 = null,
                        .channel_count = 2,
                        .latency = 0,
                        .constant_mask = 0,
                    };

                    const input_events = self.findEventInput(node_id) orelse &empty_input_events;
                    node.data.synth.out_events_list.count = 0;
                    var clap_process = clap.Process{
                        .steady_time = @enumFromInt(@as(i64, @intCast(steady_time))),
                        .frames_count = frame_count,
                        .transport = null,
                        .audio_inputs = &empty_buffers,
                        .audio_outputs = @ptrCast(&audio_out),
                        .audio_inputs_count = 0,
                        .audio_outputs_count = 1,
                        .in_events = input_events,
                        .out_events = &node.data.synth.out_events,
                    };
                    _ = node.data.synth.plugin.plugin.process(&node.data.synth.plugin.plugin, &clap_process);
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
