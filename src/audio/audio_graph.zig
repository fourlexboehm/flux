const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");
const engine_ui = @import("engine_ui.zig");
const session_view = @import("../session/types.zig");
const session_constants = @import("../session/constants.zig");
const audio_engine = @import("audio_engine.zig");
const libz_jobs = @import("libz_jobs");
const audio_events = @import("audio_events.zig");
const audio_mix = @import("audio_mix.zig");
const note_source = @import("note_source.zig");
const audio_clip_source = @import("audio_clip_source.zig");
const latency_compensation = @import("latency_compensation.zig");

const max_tracks = session_constants.max_tracks;
const max_scenes = session_constants.max_scenes;
const max_fx_slots = engine_ui.max_fx_slots;
const max_controller_param_writes = engine_ui.max_controller_param_writes;
const master_track_index = session_view.master_track_index;

pub const ClipAudioRt = audio_clip_source.ClipAudioRt;
pub const SampleSlotRt = audio_clip_source.SampleSlotRt;
pub const max_rt_samples = audio_clip_source.max_rt_samples;
pub const max_warp_points = audio_clip_source.max_warp_points;

pub const copyPlayingAudioClip = audio_clip_source.copyClipFromUi;
pub const publishSampleTableFromStore = audio_clip_source.publishSampleTable;

pub const JobQueue = libz_jobs.JobQueue(.{
    .max_jobs_per_thread = 64,
    .max_threads = 16,
    // Must stay << quantum budget. 1.5ms was half of a 128-frame period at 44.1k
    // and made parallel synth jobs late (workers still asleep when work landed).
    // Adaptive sleep in audio_runtime raises this when DSP load is low.
    .idle_sleep_ns = 50_000,
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
pub const AudioClipSourceId = u16;
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
    /// Playing audio clip per track (active scene only); empty when MIDI/empty.
    playing_audio: [max_tracks]ClipAudioRt,
    /// Sample PCM views indexed by SampleId; publish only after fully loaded.
    sample_table: [max_rt_samples]SampleSlotRt,
    track_plugins: [max_tracks]?*const clap.Plugin,
    track_fx_plugins: [max_tracks][max_fx_slots]?*const clap.Plugin,
    /// Device bypass: disabled instruments render silence, disabled FX pass through.
    track_instrument_enabled: [max_tracks]bool,
    track_fx_enabled: [max_tracks][max_fx_slots]bool,
    live_key_states: [max_tracks][128]bool,
    live_key_velocities: [max_tracks][128]f32,
    /// Bumped by the UI thread whenever live keys/velocities change. Lets
    /// NoteSource detect live-input changes without a 128-bool eql per
    /// quantum (80 sources x ~344 quanta/s at 128 frames was pure idle tax).
    live_key_generation: u64 = 0,
    controller_param_writes: [max_controller_param_writes]engine_ui.ControllerParamWrite,
    controller_param_write_count: usize,
    track_latency: [max_tracks]u32,
    max_track_latency: u32,
};

const graph_types = @import("audio_graph_types.zig");
const NodeKind = graph_types.NodeKind;
const NodeRef = graph_types.NodeRef;
const AudioInputRef = graph_types.AudioInputRef;
const InputRange = graph_types.InputRange;
const StereoBuffer = graph_types.StereoBuffer;
const SynthRuntime = graph_types.SynthRuntime;
const AudioClipSourceRuntime = graph_types.AudioClipSourceRuntime;
const FxPolicy = graph_types.FxPolicy;
const FxRuntime = graph_types.FxRuntime;
const GainRuntime = graph_types.GainRuntime;
const MixerRuntime = graph_types.MixerRuntime;
const MasterRuntime = graph_types.MasterRuntime;
const AudioOutput = graph_types.AudioOutput;

pub const Graph = struct {
    allocator: std.mem.Allocator,
    node_refs: std.ArrayList(NodeRef),
    connections: std.ArrayList(Connection),
    render_order: std.ArrayList(NodeId),
    master_node: ?NodeId = null,
    sample_rate: f32 = 0.0,
    max_frames: u32 = 0,

    note_sources: std.ArrayList(note_source.NoteSource),
    audio_clip_sources: std.ArrayList(AudioClipSourceRuntime),
    synths: std.ArrayList(SynthRuntime),
    fx: std.ArrayList(FxRuntime),
    gains: std.ArrayList(GainRuntime),
    mixers: std.ArrayList(MixerRuntime),
    master: ?MasterRuntime = null,

    note_source_order: std.ArrayList(NoteSourceId),
    audio_clip_source_order: std.ArrayList(AudioClipSourceId),
    synth_order: std.ArrayList(SynthId),
    fx_order: std.ArrayList(FxId),
    gain_order: std.ArrayList(GainId),
    mixer_order: std.ArrayList(MixerId),

    buffers: std.ArrayList(StereoBuffer),
    audio_inputs: std.ArrayList(AudioInputRef),
    scratch_input_left: []f32 = &.{},
    scratch_input_right: []f32 = &.{},
    /// Pre-allocated gather buffer for the fused mixer. Sized (at graph build) to
    /// the total input-edge count (an upper bound on any single node's fan-in)
    /// so summing a node's inputs never allocates on the audio thread and always
    /// fits in one pass. Safe to share: the mixing nodes run serially.
    sum_scratch: []audio_mix.StereoSpan = &.{},

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .node_refs = .empty,
            .connections = .empty,
            .render_order = .empty,
            .note_sources = .empty,
            .audio_clip_sources = .empty,
            .synths = .empty,
            .fx = .empty,
            .gains = .empty,
            .mixers = .empty,
            .note_source_order = .empty,
            .audio_clip_source_order = .empty,
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
        for (self.gains.items) |*gain| gain.compensation.deinit(self.allocator);
        self.node_refs.deinit(self.allocator);
        self.connections.deinit(self.allocator);
        self.render_order.deinit(self.allocator);
        self.note_sources.deinit(self.allocator);
        self.audio_clip_sources.deinit(self.allocator);
        self.synths.deinit(self.allocator);
        self.fx.deinit(self.allocator);
        self.gains.deinit(self.allocator);
        self.mixers.deinit(self.allocator);
        self.note_source_order.deinit(self.allocator);
        self.audio_clip_source_order.deinit(self.allocator);
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

    pub fn addAudioClipSource(self: *Graph, track_index: usize) !NodeId {
        const out = try self.addStereoBuffer();
        const id: AudioClipSourceId = @intCast(self.audio_clip_sources.items.len);
        try self.audio_clip_sources.append(self.allocator, .{
            .track_index = @intCast(track_index),
            .out = out,
            .player = audio_clip_source.AudioClipSource.init(track_index),
        });
        return self.appendNodeRef(.{ .kind = .audio_clip_source, .index = id });
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
            .policy = if (track_index == master_track_index) .master_fx_after_mixer else .track_fx_fast_skip,
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
        for (self.gains.items) |*gain| {
            if (gain.compensation.left.len == 0) gain.compensation = try .init(self.allocator);
        }
        for (self.buffers.items) |*buffer| {
            buffer.left = try self.allocator.alloc(f32, max_frames);
            buffer.right = try self.allocator.alloc(f32, max_frames);
            buffer.zeroed_frames = 0;
            buffer.active = false;
        }

        try self.buildRenderOrder();
        try self.compileEventInputs();
        try self.compileAudioInputs();

        // audio_inputs is now fully populated; size the fused-mix gather buffer to
        // the total edge count (>= any single node's fan-in). @max(_, 1) avoids a
        // zero-length allocation when the graph has no audio edges.
        self.sum_scratch = try self.allocator.alloc(audio_mix.StereoSpan, @max(self.audio_inputs.items.len, 1));
    }

    pub fn getMasterOutput(self: *Graph) ?AudioOutput {
        const master = self.master orelse return null;
        return self.outputForBuffer(master.out);
    }

    /// True when the master bus holds non-silent audio this quantum. Lets the
    /// device callback skip the interleave copy (the device buffer is already
    /// zeroed) when the whole graph rendered silence.
    pub fn masterActive(self: *const Graph) bool {
        const master = self.master orelse return false;
        return self.buffers.items[master.out].active;
    }

    pub fn getAudioOutput(self: *Graph, node_id: NodeId) AudioOutput {
        const buffer_id = self.outputBufferForNode(node_id) orelse return .{ .left = &.{}, .right = &.{} };
        return self.outputForBuffer(buffer_id);
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

    /// Optional per-stage wall times (ns) for serial RT profiling. Null = no timing.
    pub const StageNs = struct {
        clear_active: u64 = 0,
        notes: u64 = 0,
        clips: u64 = 0,
        synths: u64 = 0,
        fx: u64 = 0,
        gains: u64 = 0,
        mixers: u64 = 0,
        master: u64 = 0,
        total: u64 = 0,
    };

    pub fn process(
        self: *Graph,
        snapshot: *const StateSnapshot,
        shared: *audio_engine.SharedState,
        jobs: ?*JobQueue,
        frame_count: u32,
        steady_time: u64,
    ) void {
        self.processProfiled(snapshot, shared, jobs, frame_count, steady_time, null);
    }

    pub fn processProfiled(
        self: *Graph,
        snapshot: *const StateSnapshot,
        shared: *audio_engine.SharedState,
        jobs: ?*JobQueue,
        frame_count: u32,
        steady_time: u64,
        stage_ns: ?*StageNs,
    ) void {
        const zone = tracy.ZoneN(@src(), "Graph.process");
        defer zone.End();

        const profile = stage_ns != null;
        const io = std.Io.Threaded.global_single_threaded.io();
        var t0: std.Io.Timestamp = undefined;
        var t_stage: std.Io.Timestamp = undefined;
        if (profile) t0 = std.Io.Clock.awake.now(io);

        if (profile) t_stage = std.Io.Clock.awake.now(io);
        for (self.buffers.items) |*buffer| {
            buffer.active = false;
        }
        if (profile) stage_ns.?.clear_active = nsBetween(t_stage, io);

        var ctx = ProcessContext{
            .graph = self,
            .snapshot = snapshot,
            .shared = shared,
            .frame_count = frame_count,
            .steady_time = steady_time,
            .solo_active = graph_types.computeSoloActive(snapshot),
            .wake_requested = shared.process_requested.swap(false, .acq_rel),
        };

        if (profile) t_stage = std.Io.Clock.awake.now(io);
        self.processNoteSources(snapshot, frame_count);
        if (profile) stage_ns.?.notes = nsBetween(t_stage, io);

        if (profile) t_stage = std.Io.Clock.awake.now(io);
        self.processAudioClipSources(snapshot, frame_count);
        if (profile) stage_ns.?.clips = nsBetween(t_stage, io);

        if (profile) t_stage = std.Io.Clock.awake.now(io);
        self.processSynths(&ctx, jobs);
        if (profile) stage_ns.?.synths = nsBetween(t_stage, io);

        if (profile) t_stage = std.Io.Clock.awake.now(io);
        self.processFx(&ctx, false);
        if (profile) stage_ns.?.fx = nsBetween(t_stage, io);

        if (profile) t_stage = std.Io.Clock.awake.now(io);
        self.processGains(&ctx);
        if (profile) stage_ns.?.gains = nsBetween(t_stage, io);

        if (profile) t_stage = std.Io.Clock.awake.now(io);
        self.processMixers(&ctx);
        if (profile) stage_ns.?.mixers = nsBetween(t_stage, io);

        // Master FX observe this same quantum's mixer output, keeping the
        // silence fast-path exact (no stale flags, no blind summing).
        if (profile) t_stage = std.Io.Clock.awake.now(io);
        self.processFx(&ctx, true);
        if (profile) stage_ns.?.fx += nsBetween(t_stage, io);

        if (profile) t_stage = std.Io.Clock.awake.now(io);
        self.processMaster(&ctx);
        if (profile) stage_ns.?.master = nsBetween(t_stage, io);

        if (profile) stage_ns.?.total = nsBetween(t0, io);
    }

    fn nsBetween(from: std.Io.Timestamp, io: std.Io) u64 {
        const to = std.Io.Clock.awake.now(io);
        const ns = from.durationTo(to).toNanoseconds();
        return if (ns > 0) @intCast(ns) else 0;
    }

    fn processNoteSources(self: *Graph, snapshot: *const StateSnapshot, frame_count: u32) void {
        const zone = tracy.ZoneN(@src(), "Note sources");
        defer zone.End();
        for (self.note_source_order.items) |source_id| {
            _ = self.note_sources.items[source_id].process(snapshot, self.sample_rate, frame_count);
        }
    }

    fn processAudioClipSources(self: *Graph, snapshot: *const StateSnapshot, frame_count: u32) void {
        const zone = tracy.ZoneN(@src(), "Audio clip sources");
        defer zone.End();
        // Transport stopped: no clip can sound. Update player bookkeeping
        // without the per-source stereo memset; zeroBufferOnce below is a
        // no-op once the buffer is already zeroed.
        if (!snapshot.playing) {
            for (self.audio_clip_source_order.items) |src_id| {
                var runtime = &self.audio_clip_sources.items[src_id];
                runtime.player.markStopped();
                self.zeroBufferOnce(runtime.out, frame_count);
            }
            return;
        }
        for (self.audio_clip_source_order.items) |src_id| {
            var runtime = &self.audio_clip_sources.items[src_id];
            const out = &self.buffers.items[runtime.out];
            const wrote = runtime.player.process(
                snapshot,
                self.sample_rate,
                frame_count,
                out.left,
                out.right,
            );
            if (wrote) {
                self.markBufferWritten(runtime.out);
            } else {
                self.zeroBufferOnce(runtime.out, frame_count);
            }
        }
    }

    fn processSynths(self: *Graph, ctx: *ProcessContext, jobs: ?*JobQueue) void {
        const zone = tracy.ZoneN(@src(), "Synths");
        defer zone.End();

        var active_synths: [max_tracks]SynthId = undefined;
        var active_count: usize = 0;
        for (self.synth_order.items) |synth_id| {
            var synth = &self.synths.items[synth_id];

            // Audio clip on this track's active scene: silence instrument (Phase 2).
            if (ctx.snapshot.playing_audio[synth.track_index].hasAudio()) {
                self.zeroBufferOnce(synth.out, ctx.frame_count);
                synth.sleeping = false;
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
        // At ≤128 frames the job fan-out + steal latency often exceeds the
        // serial process cost for a few light instruments (see rt-bench). Require
        // more concurrent synths before parallelizing short quanta.
        const parallel_threshold: usize = @intCast(if (ctx.frame_count <= 128)
            @max(@as(u32, 4), configured_threshold + 1)
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
            jq.waitRealtime(root);
        } else {
            for (active_synths[0..active_count]) |synth_id| {
                processSynthDirect(ctx, synth_id);
            }
        }
    }

    fn processFx(self: *Graph, ctx: *const ProcessContext, master_pass: bool) void {
        const zone = tracy.ZoneN(@src(), "Audio FX");
        defer zone.End();
        // Track FX feed gains/the mixer and run before them; master FX run
        // after the mixer so they observe same-quantum activity flags. A
        // single pass left the master chain reading the mixer's *previous*
        // quantum (flags reset each quantum), which made exact silence
        // skipping impossible there.
        for (self.fx_order.items) |fx_id| {
            const is_master = self.fx.items[fx_id].policy == .master_fx_after_mixer;
            if (is_master != master_pass) continue;
            _ = self.processFxNode(ctx, fx_id);
        }
    }

    fn processGains(self: *Graph, ctx: *const ProcessContext) void {
        const zone = tracy.ZoneN(@src(), "Gains");
        defer zone.End();
        const max_latency = ctx.snapshot.max_track_latency;
        // Always run compensation (even delay 0) so the ring keeps continuous history.
        // Skipping when max==0 then re-enabling caused cold-start holes / clicks.
        for (self.gain_order.items) |gain_id| {
            const gain_node = &self.gains.items[gain_id];
            const track = ctx.snapshot.tracks[gain_node.track_index];
            const muted = track.mute or (ctx.solo_active and !track.solo);
            const gain = if (muted) 0.0 else track.volume;
            const comp_delay = max_latency -% ctx.snapshot.track_latency[gain_node.track_index];
            if (gain == 0.0 or !self.hasActiveInput(gain_node.inputs)) {
                self.zeroBufferOnce(gain_node.out, ctx.frame_count);
                const silent = &self.buffers.items[gain_node.out];
                gain_node.compensation.process(
                    silent.left[0..ctx.frame_count],
                    silent.right[0..ctx.frame_count],
                    comp_delay,
                );
                ctx.shared.setTrackPeak(gain_node.track_index, 0, 0);
                continue;
            }
            if (!self.sumInputsScaled(gain_node.inputs, gain_node.out, ctx.frame_count, gain, true)) continue;
            const pan = std.math.clamp(track.pan, -1.0, 1.0);
            const left_gain = if (pan > 0) 1.0 - pan else 1.0;
            const right_gain = if (pan < 0) 1.0 + pan else 1.0;
            const out = &self.buffers.items[gain_node.out];
            const frames: usize = @intCast(ctx.frame_count);
            const peak = audio_mix.applyStereoGainsAndPeak(out.left, out.right, frames, left_gain, right_gain);
            gain_node.compensation.process(
                out.left[0..frames],
                out.right[0..frames],
                comp_delay,
            );
            ctx.shared.setTrackPeak(gain_node.track_index, peak[0], peak[1]);
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

        const allow_fast_skip = fx.policy == .track_fx_fast_skip;
        // Exact input test on both passes: track FX run after their sources,
        // master FX after the mixer, so flags are always same-quantum fresh.
        const has_active_audio = self.hasActiveInput(fx.inputs);
        // Bypassed FX behaves like an empty slot: audio passes straight through.
        const slot_plugin = if (ctx.snapshot.track_fx_enabled[fx.track_index][fx.fx_index])
            ctx.snapshot.track_fx_plugins[fx.track_index][fx.fx_index]
        else
            null;
        if (fx.last_plugin != slot_plugin) {
            fx.sleeping = false;
            fx.last_plugin = slot_plugin;
        }
        const plugin = slot_plugin orelse {
            // Empty slot: silent in -> silent out, on track and master alike.
            if (!has_active_audio) {
                self.zeroBufferOnce(fx.out, ctx.frame_count);
                fx.sleeping = false;
                return false;
            }
            fx.sleeping = false;
            return self.sumInputs(fx.inputs, fx.out, ctx.frame_count, allow_fast_skip);
        };

        if (ctx.shared.checkAndClearStartProcessingFx(fx.track_index, fx.fx_index)) {
            // A new activation may reuse the previous instance's address.
            fx.sleeping = false;
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
        // A sleeping plugin fed silence with no events outputs silence by CLAP
        // contract — skip it on master too (track already did). Never skip a
        // host wake request.
        if (!ctx.wake_requested and !has_active_audio and fx.sleeping and !has_input_events) {
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
        var transport = graph_types.makeTransport(ctx);
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
        const thread_context = @import("../util/thread_context.zig");
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
        // Bypassed instrument renders silence (buffers already zeroed above).
        if (!ctx.snapshot.track_instrument_enabled[synth.track_index]) {
            ctx.graph.zeroBufferOnce(synth.out, ctx.frame_count);
            return;
        }

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
        var transport = graph_types.makeTransport(ctx);
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
        if (self.sum_scratch.len > 0) {
            self.allocator.free(self.sum_scratch);
            self.sum_scratch = &.{};
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
        self.audio_clip_source_order.clearRetainingCapacity();
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
                .audio_clip_source => try self.audio_clip_source_order.append(self.allocator, ref.index),
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
            .audio_clip_source => self.audio_clip_sources.items[ref.index].out,
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
        return self.sumInputsToSlicesScaled(range, frame_count, out_left, out_right, active_only, 1.0);
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
        const frames: usize = @intCast(frame_count);
        const inputs = self.audio_inputs.items[range.start..][0..range.count];

        // Gather this node's active inputs into the pre-allocated scratch, then
        // fold them all into the output with one fused pass.
        var count: usize = 0;
        for (inputs) |input| {
            const src = &self.buffers.items[input.buffer];
            if (active_only and !src.active) continue;
            self.sum_scratch[count] = .{ .left = src.left, .right = src.right };
            count += 1;
        }

        if (count == 0) {
            @memset(out_left[0..frame_count], 0);
            @memset(out_right[0..frame_count], 0);
            return false;
        }

        audio_mix.sumSpans(out_left, out_right, self.sum_scratch[0..count], frames, gain);
        return true;
    }
};
