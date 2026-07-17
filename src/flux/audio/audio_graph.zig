const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");
const ui_state = @import("../ui/state.zig");
const session_view = @import("../ui/session_view.zig");
const session_constants = @import("../ui/session_view/constants.zig");
const audio_engine = @import("audio_engine.zig");
const libz_jobs = @import("libz_jobs");
const audio_events = @import("audio_events.zig");
const audio_mix = @import("audio_mix.zig");
const note_source = @import("note_source.zig");

const max_tracks = session_constants.max_tracks;
const max_scenes = session_constants.max_scenes;
const max_controller_param_writes = ui_state.max_controller_param_writes;
const master_track_index = session_view.master_track_index;

pub const JobQueue = libz_jobs.JobQueue(.{
    .max_jobs_per_thread = 64,
    .max_threads = 16,
    .idle_sleep_ns = 1_500_000,
});

var parallel_threshold_cfg: std.atomic.Value(u32) = std.atomic.Value(u32).init(3);

pub fn setParallelThreshold(threshold: u32) void {
    parallel_threshold_cfg.store(@max(threshold, 1), .release);
}

pub threadlocal var current_processing_plugin: ?*const clap.Plugin = null;

pub const NodeId = u32;
pub const SynthId = u16;
pub const FxId = u16;
pub const GainId = u16;
pub const MixerId = u16;
pub const NoteSourceId = u16;
pub const BufferId = u16;
pub const invalid_id = std.math.maxInt(u16);

pub const ClipNotes = note_source.ClipNotes;
pub const AutomationTargetKind = note_source.AutomationTargetKind;
pub const AutomationPoint = note_source.AutomationPoint;
pub const AutomationLane = note_source.AutomationLane;
pub const max_clip_notes = note_source.max_clip_notes;
pub const max_automation_lanes = note_source.max_automation_lanes;
pub const max_automation_points = note_source.max_automation_points;

pub const PortKind = enum {
    audio,
    events,
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
    metronome_enabled: bool,
    bpm: f32,
    time_signature_numerator: u8,
    time_signature_denominator: u8,
    playhead_beat: f32,
    track_count: usize,
    scene_count: usize,
    active_scene_by_track: [max_tracks]i16,
    tracks: [max_tracks]session_view.Track,
    clips: [max_tracks][max_scenes]session_view.ClipSlot,
    piano_clips: [max_tracks][max_scenes]ClipNotes,
    track_plugins: [max_tracks]?*const clap.Plugin,
    track_fx_plugins: [max_tracks][ui_state.max_fx_slots]?*const clap.Plugin,
    live_key_states: [max_tracks][128]bool,
    live_key_velocities: [max_tracks][128]f32,
    controller_param_writes: [max_controller_param_writes]ui_state.ControllerParamWrite,
    controller_param_write_count: usize,
};

const NodeKind = enum(u8) {
    note_source,
    synth,
    fx,
    gain,
    mixer,
    master,
};

const NodeRef = struct {
    kind: NodeKind,
    index: u16,
};

const AudioInputRef = struct {
    buffer: BufferId,
};

const InputRange = struct {
    start: u32 = 0,
    count: u16 = 0,
};

const StereoBuffer = struct {
    left: []f32 = &.{},
    right: []f32 = &.{},
    zeroed_frames: u32 = 0,
    active: bool = false,
};

const SynthRuntime = struct {
    track_index: u8,
    out: BufferId,
    event_source: NoteSourceId = invalid_id,
    sleeping: bool = false,
    removed: bool = false,
    out_events_list: audio_events.OutputEventList = .{},
    out_events: clap.events.OutputEvents = .{
        .context = undefined,
        .tryPush = audio_events.outputEventsTryPush,
    },
};

const FxPolicy = enum(u8) {
    track_fx_fast_skip,
    master_fx_always_consider,
};

const FxRuntime = struct {
    track_index: u8,
    fx_index: u8,
    inputs: InputRange = .{},
    out: BufferId,
    event_source: NoteSourceId = invalid_id,
    policy: FxPolicy = .track_fx_fast_skip,
    sleeping: bool = false,
    removed: bool = false,
};

const GainRuntime = struct {
    track_index: u8,
    inputs: InputRange = .{},
    out: BufferId,
};

const MixerRuntime = struct {
    inputs: InputRange = .{},
    out: BufferId,
};

const MasterRuntime = struct {
    inputs: InputRange = .{},
    out: BufferId,
};

const AudioOutput = struct {
    left: []f32,
    right: []f32,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    node_refs: std.ArrayList(NodeRef),
    connections: std.ArrayList(Connection),
    render_order: std.ArrayList(NodeId),
    master_node: ?NodeId = null,
    sample_rate: f32 = 0.0,
    max_frames: u32 = 0,

    note_sources: std.ArrayList(note_source.NoteSource),
    synths: std.ArrayList(SynthRuntime),
    fx: std.ArrayList(FxRuntime),
    gains: std.ArrayList(GainRuntime),
    mixers: std.ArrayList(MixerRuntime),
    master: ?MasterRuntime = null,

    note_source_order: std.ArrayList(NoteSourceId),
    synth_order: std.ArrayList(SynthId),
    fx_order: std.ArrayList(FxId),
    gain_order: std.ArrayList(GainId),
    mixer_order: std.ArrayList(MixerId),

    buffers: std.ArrayList(StereoBuffer),
    audio_inputs: std.ArrayList(AudioInputRef),
    scratch_input_left: []f32 = &.{},
    scratch_input_right: []f32 = &.{},

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .node_refs = .empty,
            .connections = .empty,
            .render_order = .empty,
            .note_sources = .empty,
            .synths = .empty,
            .fx = .empty,
            .gains = .empty,
            .mixers = .empty,
            .note_source_order = .empty,
            .synth_order = .empty,
            .fx_order = .empty,
            .gain_order = .empty,
            .mixer_order = .empty,
            .buffers = .empty,
            .audio_inputs = .empty,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.freeAudioStorage();
        self.node_refs.deinit(self.allocator);
        self.connections.deinit(self.allocator);
        self.render_order.deinit(self.allocator);
        self.note_sources.deinit(self.allocator);
        self.synths.deinit(self.allocator);
        self.fx.deinit(self.allocator);
        self.gains.deinit(self.allocator);
        self.mixers.deinit(self.allocator);
        self.note_source_order.deinit(self.allocator);
        self.synth_order.deinit(self.allocator);
        self.fx_order.deinit(self.allocator);
        self.gain_order.deinit(self.allocator);
        self.mixer_order.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        self.audio_inputs.deinit(self.allocator);
    }

    pub fn addNoteSource(self: *Graph, track_index: usize, emit_notes: bool, target_fx_index: i8) !NodeId {
        const id: NoteSourceId = @intCast(self.note_sources.items.len);
        try self.note_sources.append(self.allocator, note_source.NoteSource.init(track_index, emit_notes, target_fx_index));
        return self.appendNodeRef(.{ .kind = .note_source, .index = id });
    }

    pub fn addSynth(self: *Graph, track_index: usize) !NodeId {
        const out = try self.addStereoBuffer();
        const id: SynthId = @intCast(self.synths.items.len);
        try self.synths.append(self.allocator, .{
            .track_index = @intCast(track_index),
            .out = out,
        });
        return self.appendNodeRef(.{ .kind = .synth, .index = id });
    }

    pub fn addFx(self: *Graph, track_index: usize, fx_index: usize) !NodeId {
        const out = try self.addStereoBuffer();
        const id: FxId = @intCast(self.fx.items.len);
        try self.fx.append(self.allocator, .{
            .track_index = @intCast(track_index),
            .fx_index = @intCast(fx_index),
            .out = out,
            .policy = if (track_index == master_track_index) .master_fx_always_consider else .track_fx_fast_skip,
        });
        return self.appendNodeRef(.{ .kind = .fx, .index = id });
    }

    pub fn addGain(self: *Graph, track_index: usize) !NodeId {
        const out = try self.addStereoBuffer();
        const id: GainId = @intCast(self.gains.items.len);
        try self.gains.append(self.allocator, .{
            .track_index = @intCast(track_index),
            .out = out,
        });
        return self.appendNodeRef(.{ .kind = .gain, .index = id });
    }

    pub fn addMixer(self: *Graph) !NodeId {
        const out = try self.addStereoBuffer();
        const id: MixerId = @intCast(self.mixers.items.len);
        try self.mixers.append(self.allocator, .{ .out = out });
        return self.appendNodeRef(.{ .kind = .mixer, .index = id });
    }

    pub fn addMaster(self: *Graph) !NodeId {
        const out = try self.addStereoBuffer();
        self.master = .{ .out = out };
        const node_id = try self.appendNodeRef(.{ .kind = .master, .index = 0 });
        self.master_node = node_id;
        return node_id;
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
        self.freeAudioStorage();

        self.scratch_input_left = try self.allocator.alloc(f32, max_frames);
        self.scratch_input_right = try self.allocator.alloc(f32, max_frames);
        for (self.buffers.items) |*buffer| {
            buffer.left = try self.allocator.alloc(f32, max_frames);
            buffer.right = try self.allocator.alloc(f32, max_frames);
            buffer.zeroed_frames = 0;
            buffer.active = false;
        }

        try self.buildRenderOrder();
        try self.compileEventInputs();
        try self.compileAudioInputs();
    }

    pub fn getMasterOutput(self: *Graph) ?AudioOutput {
        const master = self.master orelse return null;
        return self.outputForBuffer(master.out);
    }

    pub fn getAudioOutput(self: *Graph, node_id: NodeId) AudioOutput {
        const buffer_id = self.outputBufferForNode(node_id) orelse return .{ .left = &.{}, .right = &.{} };
        return self.outputForBuffer(buffer_id);
    }

    pub fn markNodeRemoved(self: *Graph, node_id: NodeId) void {
        const ref = self.node_refs.items[node_id];
        switch (ref.kind) {
            .synth => self.synths.items[ref.index].removed = true,
            .fx => self.fx.items[ref.index].removed = true,
            else => {},
        }
    }

    pub fn isNodeRemoved(self: *const Graph, node_id: NodeId) bool {
        const ref = self.node_refs.items[node_id];
        return switch (ref.kind) {
            .synth => self.synths.items[ref.index].removed,
            .fx => self.fx.items[ref.index].removed,
            else => false,
        };
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

    pub fn process(
        self: *Graph,
        snapshot: *const StateSnapshot,
        shared: *audio_engine.SharedState,
        jobs: ?*JobQueue,
        frame_count: u32,
        steady_time: u64,
    ) void {
        const zone = tracy.ZoneN(@src(), "Graph.process");
        defer zone.End();

        for (self.buffers.items) |*buffer| {
            buffer.active = false;
        }

        var ctx = ProcessContext{
            .graph = self,
            .snapshot = snapshot,
            .shared = shared,
            .frame_count = frame_count,
            .steady_time = steady_time,
            .solo_active = computeSoloActive(snapshot),
            .wake_requested = shared.process_requested.swap(false, .acq_rel),
        };

        self.processNoteSources(snapshot, frame_count);
        self.processSynths(&ctx, jobs);
        self.processFx(&ctx);
        self.processGains(&ctx);
        self.processMixers(&ctx);
        self.processMaster(&ctx);
    }

    fn processNoteSources(self: *Graph, snapshot: *const StateSnapshot, frame_count: u32) void {
        const zone = tracy.ZoneN(@src(), "Note sources");
        defer zone.End();
        for (self.note_source_order.items) |source_id| {
            _ = self.note_sources.items[source_id].process(snapshot, self.sample_rate, frame_count);
        }
    }

    fn processSynths(self: *Graph, ctx: *ProcessContext, jobs: ?*JobQueue) void {
        const zone = tracy.ZoneN(@src(), "Synths");
        defer zone.End();

        var active_synths: [max_tracks]SynthId = undefined;
        var active_count: usize = 0;
        for (self.synth_order.items) |synth_id| {
            var synth = &self.synths.items[synth_id];
            if (synth.removed) {
                self.zeroBufferOnce(synth.out, ctx.frame_count);
                continue;
            }

            const plugin = ctx.snapshot.track_plugins[synth.track_index];
            if (plugin == null) {
                self.zeroBufferOnce(synth.out, ctx.frame_count);
                synth.sleeping = false;
                continue;
            }

            if (ctx.wake_requested or self.hasInputEvents(synth.event_source) or !synth.sleeping) {
                active_synths[active_count] = synth_id;
                active_count += 1;
            } else {
                self.zeroBufferOnce(synth.out, ctx.frame_count);
            }
        }

        if (active_count == 0) return;

        const configured_threshold = parallel_threshold_cfg.load(.acquire);
        const parallel_threshold: usize = @intCast(if (ctx.frame_count <= 128)
            @max(@as(u32, 2), configured_threshold -| 1)
        else
            configured_threshold);

        if (jobs != null and active_count >= parallel_threshold) {
            const jq = jobs.?;
            const RootJob = struct {
                pub fn exec(_: *@This()) void {}
            };
            const root = jq.allocate(RootJob{});

            for (active_synths[0..active_count]) |synth_id| {
                const SynthJob = struct {
                    ctx: *ProcessContext,
                    synth_id: SynthId,
                    pub fn exec(job: *@This()) void {
                        processSynthDirect(job.ctx, job.synth_id);
                    }
                };
                const synth_job = jq.allocate(SynthJob{ .ctx = ctx, .synth_id = synth_id });
                jq.finishWith(synth_job, root);
                jq.schedule(synth_job);
            }

            jq.schedule(root);
            jq.wait(root);
        } else {
            for (active_synths[0..active_count]) |synth_id| {
                processSynthDirect(ctx, synth_id);
            }
        }
    }

    fn processFx(self: *Graph, ctx: *const ProcessContext) void {
        const zone = tracy.ZoneN(@src(), "Audio FX");
        defer zone.End();
        for (self.fx_order.items) |fx_id| {
            _ = self.processFxNode(ctx, fx_id);
        }
    }

    fn processGains(self: *Graph, ctx: *const ProcessContext) void {
        const zone = tracy.ZoneN(@src(), "Gains");
        defer zone.End();
        for (self.gain_order.items) |gain_id| {
            const gain_node = &self.gains.items[gain_id];
            const track = ctx.snapshot.tracks[gain_node.track_index];
            const muted = track.mute or (ctx.solo_active and !track.solo);
            const gain = if (muted) 0.0 else track.volume;
            if (gain == 0.0 or !self.hasActiveInput(gain_node.inputs)) {
                self.zeroBufferOnce(gain_node.out, ctx.frame_count);
                continue;
            }
            _ = self.sumInputsScaled(gain_node.inputs, gain_node.out, ctx.frame_count, gain, true);
        }
    }

    fn processMixers(self: *Graph, ctx: *const ProcessContext) void {
        const zone = tracy.ZoneN(@src(), "Mixers");
        defer zone.End();
        for (self.mixer_order.items) |mixer_id| {
            const mixer = &self.mixers.items[mixer_id];
            if (!self.hasActiveInput(mixer.inputs)) {
                self.zeroBufferOnce(mixer.out, ctx.frame_count);
                continue;
            }
            _ = self.sumInputs(mixer.inputs, mixer.out, ctx.frame_count, true);
        }
    }

    fn processMaster(self: *Graph, ctx: *const ProcessContext) void {
        const zone = tracy.ZoneN(@src(), "Master");
        defer zone.End();
        const master = if (self.master) |*master| master else return;
        if (!self.hasActiveInput(master.inputs)) {
            self.zeroBufferOnce(master.out, ctx.frame_count);
            return;
        }

        if (!self.sumInputs(master.inputs, master.out, ctx.frame_count, true)) {
            return;
        }

        const master_track = ctx.snapshot.tracks[master_track_index];
        const gain = if (master_track.mute) 0.0 else master_track.volume;
        if (gain == 0.0) {
            self.zeroBufferOnce(master.out, ctx.frame_count);
            return;
        }
        if (gain != 1.0) {
            audio_mix.mulStereo(self.buffers.items[master.out].left, self.buffers.items[master.out].right, @intCast(ctx.frame_count), gain);
        }
    }

    fn processFxNode(self: *Graph, ctx: *const ProcessContext, fx_id: FxId) bool {
        var fx = &self.fx.items[fx_id];
        if (fx.removed) {
            self.zeroBufferOnce(fx.out, ctx.frame_count);
            return false;
        }

        const allow_fast_skip = fx.policy == .track_fx_fast_skip;
        const has_active_audio = if (allow_fast_skip) self.hasActiveInput(fx.inputs) else true;
        const plugin = ctx.snapshot.track_fx_plugins[fx.track_index][fx.fx_index] orelse {
            if (allow_fast_skip and !has_active_audio) {
                self.zeroBufferOnce(fx.out, ctx.frame_count);
                fx.sleeping = false;
                return false;
            }
            fx.sleeping = false;
            return self.sumInputs(fx.inputs, fx.out, ctx.frame_count, allow_fast_skip);
        };

        if (ctx.shared.checkAndClearStartProcessingFx(fx.track_index, fx.fx_index)) {
            if (!ctx.shared.isFxPluginStarted(fx.track_index, fx.fx_index)) {
                if (plugin.startProcessing(plugin)) {
                    ctx.shared.markFxPluginStarted(fx.track_index, fx.fx_index);
                }
            }
        }

        const empty_event_list = audio_events.EventList{};
        var empty_input_events = audio_events.emptyInputEvents(&empty_event_list);
        const input_events = self.inputEventsFor(fx.event_source, &empty_input_events);
        const has_input_events = input_events.size(input_events) > 0;
        if (allow_fast_skip and !has_active_audio and fx.sleeping and !has_input_events) {
            self.zeroBufferOnce(fx.out, ctx.frame_count);
            return false;
        }

        const input_left = self.scratch_input_left[0..ctx.frame_count];
        const input_right = self.scratch_input_right[0..ctx.frame_count];
        if (has_active_audio) {
            _ = self.sumInputsToSlices(fx.inputs, ctx.frame_count, input_left, input_right, allow_fast_skip);
        } else {
            @memset(input_left, 0);
            @memset(input_right, 0);
        }

        var input_ptrs = [2][*]f32{ input_left.ptr, input_right.ptr };
        const output = &self.buffers.items[fx.out];
        var output_ptrs = [2][*]f32{ output.left.ptr, output.right.ptr };
        var audio_in = clap.AudioBuffer{
            .data32 = &input_ptrs,
            .data64 = null,
            .channel_count = 2,
            .latency = 0,
            .constant_mask = 0,
        };
        var audio_out = clap.AudioBuffer{
            .data32 = &output_ptrs,
            .data64 = null,
            .channel_count = 2,
            .latency = 0,
            .constant_mask = 0,
        };

        var out_events_list = audio_events.OutputEventList{};
        var out_events = clap.events.OutputEvents{
            .context = &out_events_list,
            .tryPush = audio_events.outputEventsTryPush,
        };
        var transport = makeTransport(ctx);
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
        const status = plugin.process(plugin, &clap_process);
        current_processing_plugin = null;
        fx.sleeping = status == .sleep;
        self.markBufferWritten(fx.out);
        return true;
    }

    fn processSynthDirect(ctx: *ProcessContext, synth_id: SynthId) void {
        const thread_context = @import("../thread_context.zig");
        thread_context.is_audio_thread = true;
        thread_context.in_jobs_worker = true;
        defer thread_context.in_jobs_worker = false;

        const zone = tracy.ZoneN(@src(), "Synth task");
        defer zone.End();

        var synth = &ctx.graph.synths.items[synth_id];
        var output = &ctx.graph.buffers.items[synth.out];
        @memset(output.left[0..ctx.frame_count], 0);
        @memset(output.right[0..ctx.frame_count], 0);

        const plugin = ctx.snapshot.track_plugins[synth.track_index] orelse {
            ctx.graph.zeroBufferOnce(synth.out, ctx.frame_count);
            return;
        };

        synth.out_events.context = &synth.out_events_list;
        var channel_ptrs = [2][*]f32{ output.left.ptr, output.right.ptr };
        var audio_out = clap.AudioBuffer{
            .data32 = &channel_ptrs,
            .data64 = null,
            .channel_count = 2,
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

        const empty_event_list = audio_events.EventList{};
        var empty_input_events = audio_events.emptyInputEvents(&empty_event_list);
        const input_events = ctx.graph.inputEventsFor(synth.event_source, &empty_input_events);
        const has_input_events = input_events.size(input_events) > 0;

        if (ctx.shared.checkAndClearStartProcessing(synth.track_index)) {
            if (!ctx.shared.isPluginStarted(synth.track_index)) {
                if (plugin.startProcessing(plugin)) {
                    ctx.shared.markPluginStarted(synth.track_index);
                }
            }
        }

        if (has_input_events or ctx.wake_requested) {
            synth.sleeping = false;
        } else if (synth.sleeping) {
            ctx.graph.zeroBufferOnce(synth.out, ctx.frame_count);
            return;
        }

        synth.out_events_list.count = 0;
        var transport = makeTransport(ctx);
        var clap_process = clap.Process{
            .steady_time = @enumFromInt(@as(i64, @intCast(ctx.steady_time))),
            .frames_count = ctx.frame_count,
            .transport = &transport,
            .audio_inputs = @as([*]const clap.AudioBuffer, @ptrCast(&empty_input)),
            .audio_outputs = @as([*]clap.AudioBuffer, @ptrCast(&audio_out)),
            .audio_inputs_count = 0,
            .audio_outputs_count = 1,
            .in_events = input_events,
            .out_events = &synth.out_events,
        };

        current_processing_plugin = plugin;
        const status = plugin.process(plugin, &clap_process);
        current_processing_plugin = null;
        synth.sleeping = status == .sleep;
        ctx.graph.markBufferWritten(synth.out);
    }

    fn appendNodeRef(self: *Graph, ref: NodeRef) !NodeId {
        const node_id: NodeId = @intCast(self.node_refs.items.len);
        try self.node_refs.append(self.allocator, ref);
        return node_id;
    }

    fn addStereoBuffer(self: *Graph) !BufferId {
        const id: BufferId = @intCast(self.buffers.items.len);
        try self.buffers.append(self.allocator, .{});
        return id;
    }

    fn freeAudioStorage(self: *Graph) void {
        if (self.scratch_input_left.len > 0) {
            self.allocator.free(self.scratch_input_left);
            self.scratch_input_left = &.{};
        }
        if (self.scratch_input_right.len > 0) {
            self.allocator.free(self.scratch_input_right);
            self.scratch_input_right = &.{};
        }
        for (self.buffers.items) |*buffer| {
            if (buffer.left.len > 0) self.allocator.free(buffer.left);
            if (buffer.right.len > 0) self.allocator.free(buffer.right);
            buffer.left = &.{};
            buffer.right = &.{};
            buffer.zeroed_frames = 0;
            buffer.active = false;
        }
    }

    fn buildRenderOrder(self: *Graph) !void {
        self.render_order.clearRetainingCapacity();
        self.note_source_order.clearRetainingCapacity();
        self.synth_order.clearRetainingCapacity();
        self.fx_order.clearRetainingCapacity();
        self.gain_order.clearRetainingCapacity();
        self.mixer_order.clearRetainingCapacity();

        const node_count = self.node_refs.items.len;
        var indegree = try self.allocator.alloc(u32, node_count);
        defer self.allocator.free(indegree);
        @memset(indegree, 0);

        for (self.connections.items) |conn| {
            indegree[conn.to] += 1;
        }

        var queue = std.ArrayList(NodeId).empty;
        defer queue.deinit(self.allocator);
        for (0..node_count) |idx| {
            if (indegree[idx] == 0) try queue.append(self.allocator, @intCast(idx));
        }

        while (queue.items.len > 0) {
            const node_id = queue.orderedRemove(0);
            try self.render_order.append(self.allocator, node_id);
            const ref = self.node_refs.items[node_id];
            switch (ref.kind) {
                .note_source => try self.note_source_order.append(self.allocator, ref.index),
                .synth => try self.synth_order.append(self.allocator, ref.index),
                .fx => try self.fx_order.append(self.allocator, ref.index),
                .gain => try self.gain_order.append(self.allocator, ref.index),
                .mixer => try self.mixer_order.append(self.allocator, ref.index),
                .master => {},
            }

            for (self.connections.items) |conn| {
                if (conn.from == node_id) {
                    indegree[conn.to] -= 1;
                    if (indegree[conn.to] == 0) try queue.append(self.allocator, conn.to);
                }
            }
        }
    }

    fn compileEventInputs(self: *Graph) !void {
        for (self.synths.items) |*synth| synth.event_source = invalid_id;
        for (self.fx.items) |*fx| fx.event_source = invalid_id;

        for (self.connections.items) |conn| {
            if (conn.kind != .events) continue;
            const source = self.node_refs.items[conn.from];
            if (source.kind != .note_source) continue;

            const dest = self.node_refs.items[conn.to];
            switch (dest.kind) {
                .synth => self.synths.items[dest.index].event_source = source.index,
                .fx => self.fx.items[dest.index].event_source = source.index,
                else => {},
            }
        }
    }

    fn compileAudioInputs(self: *Graph) !void {
        self.audio_inputs.clearRetainingCapacity();

        for (self.node_refs.items, 0..) |ref, node_id| {
            const range = try self.compileInputRangeForNode(@intCast(node_id));
            switch (ref.kind) {
                .fx => self.fx.items[ref.index].inputs = range,
                .gain => self.gains.items[ref.index].inputs = range,
                .mixer => self.mixers.items[ref.index].inputs = range,
                .master => {
                    if (self.master) |*master| master.inputs = range;
                },
                else => {},
            }
        }
    }

    fn compileInputRangeForNode(self: *Graph, node_id: NodeId) !InputRange {
        const start: u32 = @intCast(self.audio_inputs.items.len);
        var count: u16 = 0;
        for (self.connections.items) |conn| {
            if (conn.kind != .audio or conn.to != node_id) continue;
            if (self.outputBufferForNode(conn.from)) |buffer| {
                try self.audio_inputs.append(self.allocator, .{ .buffer = buffer });
                count += 1;
            }
        }
        return .{ .start = start, .count = count };
    }

    fn outputBufferForNode(self: *const Graph, node_id: NodeId) ?BufferId {
        const ref = self.node_refs.items[node_id];
        return switch (ref.kind) {
            .synth => self.synths.items[ref.index].out,
            .fx => self.fx.items[ref.index].out,
            .gain => self.gains.items[ref.index].out,
            .mixer => self.mixers.items[ref.index].out,
            .master => if (self.master) |master| master.out else null,
            .note_source => null,
        };
    }

    fn outputForBuffer(self: *Graph, buffer_id: BufferId) AudioOutput {
        const buffer = &self.buffers.items[buffer_id];
        return .{ .left = buffer.left, .right = buffer.right };
    }

    fn zeroBufferOnce(self: *Graph, buffer_id: BufferId, frame_count: u32) void {
        var buffer = &self.buffers.items[buffer_id];
        if (buffer.zeroed_frames < frame_count) {
            @memset(buffer.left[0..frame_count], 0);
            @memset(buffer.right[0..frame_count], 0);
            buffer.zeroed_frames = frame_count;
        }
        buffer.active = false;
    }

    fn markBufferWritten(self: *Graph, buffer_id: BufferId) void {
        var buffer = &self.buffers.items[buffer_id];
        buffer.zeroed_frames = 0;
        buffer.active = true;
    }

    fn inputEventsFor(
        self: *Graph,
        event_source: NoteSourceId,
        empty: *const clap.events.InputEvents,
    ) *const clap.events.InputEvents {
        if (event_source == invalid_id) return empty;
        return &self.note_sources.items[event_source].input_events;
    }

    fn hasInputEvents(self: *Graph, event_source: NoteSourceId) bool {
        if (event_source == invalid_id) return false;
        const input_events = &self.note_sources.items[event_source].input_events;
        return input_events.size(input_events) > 0;
    }

    fn hasActiveInput(self: *const Graph, range: InputRange) bool {
        const inputs = self.audio_inputs.items[range.start..][0..range.count];
        for (inputs) |input| {
            if (self.buffers.items[input.buffer].active) return true;
        }
        return false;
    }

    fn sumInputsScaled(
        self: *Graph,
        range: InputRange,
        out_id: BufferId,
        frame_count: u32,
        gain: f32,
        active_only: bool,
    ) bool {
        if (gain == 1.0) {
            return self.sumInputs(range, out_id, frame_count, active_only);
        }
        const out = &self.buffers.items[out_id];
        const any = self.sumInputsToSlicesScaled(range, frame_count, out.left, out.right, active_only, gain);
        if (!any) {
            self.zeroBufferOnce(out_id, frame_count);
            return false;
        }
        self.markBufferWritten(out_id);
        return true;
    }

    fn sumInputs(
        self: *Graph,
        range: InputRange,
        out_id: BufferId,
        frame_count: u32,
        active_only: bool,
    ) bool {
        const out = &self.buffers.items[out_id];
        const any = self.sumInputsToSlices(range, frame_count, out.left, out.right, active_only);
        if (!any) {
            self.zeroBufferOnce(out_id, frame_count);
            return false;
        }
        self.markBufferWritten(out_id);
        return true;
    }

    fn sumInputsToSlices(
        self: *Graph,
        range: InputRange,
        frame_count: u32,
        out_left: []f32,
        out_right: []f32,
        active_only: bool,
    ) bool {
        const frames: usize = @intCast(frame_count);
        const inputs = self.audio_inputs.items[range.start..][0..range.count];
        var any = false;
        for (inputs) |input| {
            const src = &self.buffers.items[input.buffer];
            if (active_only and !src.active) continue;
            if (!any) {
                audio_mix.copyStereo(out_left, out_right, src.left, src.right, frames);
                any = true;
            } else {
                audio_mix.addStereo(out_left, out_right, src.left, src.right, frames);
            }
        }
        if (!any) {
            @memset(out_left[0..frame_count], 0);
            @memset(out_right[0..frame_count], 0);
        }
        return any;
    }

    fn sumInputsToSlicesScaled(
        self: *Graph,
        range: InputRange,
        frame_count: u32,
        out_left: []f32,
        out_right: []f32,
        active_only: bool,
        gain: f32,
    ) bool {
        if (gain == 1.0) {
            return self.sumInputsToSlices(range, frame_count, out_left, out_right, active_only);
        }
        const frames: usize = @intCast(frame_count);
        const inputs = self.audio_inputs.items[range.start..][0..range.count];
        var any = false;
        for (inputs) |input| {
            const src = &self.buffers.items[input.buffer];
            if (active_only and !src.active) continue;
            if (!any) {
                audio_mix.copyScaledStereo(out_left, out_right, src.left, src.right, frames, gain);
                any = true;
            } else {
                audio_mix.addScaledStereo(out_left, out_right, src.left, src.right, frames, gain);
            }
        }
        if (!any) {
            @memset(out_left[0..frame_count], 0);
            @memset(out_right[0..frame_count], 0);
        }
        return any;
    }
};

fn computeSoloActive(snapshot: *const StateSnapshot) bool {
    const active_track_count = @min(snapshot.track_count, max_tracks);
    for (0..active_track_count) |track_index| {
        if (snapshot.tracks[track_index].solo) return true;
    }
    return false;
}

fn makeTransport(ctx: anytype) clap.events.Transport {
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
