const std = @import("std");
const zaudio = @import("zaudio");
const clap = @import("clap-bindings");

const ui_state = @import("../ui/state.zig");
const session_constants = @import("../session/constants.zig");
const session_view = @import("../session/types.zig");
const audio_graph = @import("audio_graph.zig");
const clip_bake = @import("clip_bake.zig");
const audio_constants = @import("audio_constants.zig");

const max_tracks = session_constants.max_tracks;
const max_scenes = session_constants.max_scenes;
const beats_per_bar = session_constants.beats_per_bar;
const default_clip_bars = session_constants.default_clip_bars;
const master_track_index = session_view.master_track_index;

const Channels = 2;
const interleave_lanes = 4;
const F32xN = @Vector(interleave_lanes, f32);
pub const dsp_meter_interval: u8 = 16;

pub const SharedState = struct {
    processing: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    active_index: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    process_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    suspend_processing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    snapshots: []audio_graph.StateSnapshot,
    track_plugins: [max_tracks]?*const clap.Plugin = @splat(null),
    track_fx_plugins: [max_tracks][ui_state.max_fx_slots]?*const clap.Plugin =
        @splat(@splat(null)),
    /// Tracks which plugins need startProcessing called (done from audio thread)
    plugins_need_start: [max_tracks]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
    /// Tracks which plugins have had startProcessing called (for stopProcessing on cleanup)
    plugins_started: [max_tracks]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
    plugins_need_start_fx: [max_tracks][ui_state.max_fx_slots]std.atomic.Value(bool) =
        @splat(@splat(std.atomic.Value(bool).init(false))),
    plugins_started_fx: [max_tracks][ui_state.max_fx_slots]std.atomic.Value(bool) =
        @splat(@splat(std.atomic.Value(bool).init(false))),
    track_peak_left: [max_tracks]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(0)),
    track_peak_right: [max_tracks]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(0)),

    pub fn setTrackPeak(self: *SharedState, track: usize, left: f32, right: f32) void {
        self.track_peak_left[track].store(@bitCast(left), .release);
        self.track_peak_right[track].store(@bitCast(right), .release);
    }

    pub fn getTrackPeak(self: *const SharedState, track: usize) [2]f32 {
        return .{
            @bitCast(self.track_peak_left[track].load(.acquire)),
            @bitCast(self.track_peak_right[track].load(.acquire)),
        };
    }

    pub fn init(allocator: std.mem.Allocator) !SharedState {
        var snapshots = try allocator.alloc(audio_graph.StateSnapshot, 2);
        initSnapshot(&snapshots[0]);
        initSnapshot(&snapshots[1]);
        return .{
            .snapshots = snapshots,
        };
    }

    pub fn deinit(self: *SharedState, allocator: std.mem.Allocator) void {
        allocator.free(self.snapshots);
    }

    pub fn updateFromUi(self: *SharedState, state: *ui_state.State) void {
        // Offline stretch bake before publishing RT snapshot (can allocate / CPU).
        // Only dirty *playing/queued* clips recompute — keeps load/idle frames cheap.
        clip_bake.bakeDirtyClips(
            &state.audio_clips,
            &state.sample_store,
            &state.session.clips,
            state.session.track_count,
            state.session.scene_count,
            state.bpm,
            audio_constants.sample_rate,
            true,
        );

        // Double-buffer publish: write the inactive snapshot while the audio thread
        // keeps reading the active one. Do NOT suspend/silence here — that caused
        // buffer-sized dropouts (pops/xruns) every UI frame during continuous sample playback.
        const current = self.active_index.load(.acquire);
        const next: u32 = 1 - current;
        var back = &self.snapshots[next];
        back.playing = state.playing;
        back.metronome_enabled = state.metronome_enabled;
        back.bpm = state.bpm;
        back.time_signature_numerator = state.time_signature_numerator;
        back.time_signature_denominator = state.time_signature_denominator;
        back.playhead_beat = state.playhead_beat;
        back.track_count = state.session.track_count;
        back.scene_count = state.session.scene_count;
        back.tracks = state.session.tracks;
        back.clips = state.session.clips;
        back.track_plugins = self.track_plugins;
        back.track_fx_plugins = self.track_fx_plugins;
        back.live_key_states = state.live_key_states;
        back.live_key_velocities = state.live_key_velocities;
        back.controller_param_write_count = state.controller_param_write_count;
        if (state.controller_param_write_count > 0) {
            @memcpy(
                back.controller_param_writes[0..state.controller_param_write_count],
                state.controller_param_writes[0..state.controller_param_write_count],
            );
        }

        // Sample table: immutable views; only fully loaded assets, never touch store on RT.
        audio_graph.publishSampleTableFromStore(&back.sample_table, &state.sample_store);

        for (0..max_tracks) |t| {
            back.active_scene_by_track[t] = -1;
            back.playing_audio[t].clear();
            const active_scene_count = @min(state.session.scene_count, max_scenes);
            for (0..active_scene_count) |scene_index| {
                const slot = state.session.clips[t][scene_index];
                if (slot.state == .playing) {
                    back.active_scene_by_track[t] = @intCast(scene_index);
                    const audio = &state.audio_clips[t][scene_index];
                    if (audio.hasAudio()) {
                        audio_graph.copyPlayingAudioClip(&back.playing_audio[t], audio);
                    }
                    break;
                }
            }
            for (0..max_scenes) |s| {
                const src = &state.piano_clips[t][s];
                var dst = &back.piano_clips[t][s];
                dst.length_beats = src.length_beats;
                dst.play_start_beats = src.play_start_beats;
                dst.loop_start_beats = src.loop_start_beats;
                dst.loop_end_beats = src.loop_end_beats;
                const note_count = @min(src.notes.items.len, audio_graph.max_clip_notes);
                dst.count = @intCast(note_count);
                if (note_count > 0) {
                    @memcpy(dst.notes[0..note_count], src.notes.items[0..note_count]);
                }
                dst.automation_lane_count = 0;
                for (src.automation.lanes.items) |lane| {
                    if (dst.automation_lane_count >= audio_graph.max_automation_lanes) break;
                    if (lane.target_kind != .parameter) continue;
                    const param_id_str = lane.param_id orelse continue;
                    const param_id_int = std.fmt.parseInt(u32, param_id_str, 10) catch continue;

                    var dst_lane = &dst.automation_lanes[dst.automation_lane_count];
                    dst_lane.* = .{};
                    dst_lane.target_kind = .parameter;
                    dst_lane.param_id = @enumFromInt(param_id_int);
                    dst_lane.target_fx_index = -1;
                    if (lane.target_id.len > 0) {
                        if (std.mem.eql(u8, lane.target_id, "instrument")) {
                            dst_lane.target_fx_index = -1;
                        } else if (std.mem.startsWith(u8, lane.target_id, "fx")) {
                            var idx_str = lane.target_id["fx".len..];
                            if (std.mem.startsWith(u8, idx_str, ":")) {
                                idx_str = idx_str[1..];
                            }
                            const fx_idx = std.fmt.parseInt(i8, idx_str, 10) catch -1;
                            dst_lane.target_fx_index = fx_idx;
                        }
                    }

                    const point_count = @min(lane.points.items.len, audio_graph.max_automation_points);
                    dst_lane.point_count = @intCast(point_count);
                    for (0..point_count) |idx| {
                        const point = lane.points.items[idx];
                        dst_lane.points[idx] = .{ .time = point.time, .value = point.value };
                    }
                    dst.automation_lane_count += 1;
                }
            }
        }
        self.active_index.store(next, .release);

        // After publish, wait until any in-flight callback finishes so no reader
        // still holds the previous snapshot, then free retired sample/bake buffers.
        while (self.processing.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
        }
        state.sample_store.flushDeferredFrees();
        for (&state.audio_clips) |*track_clips| {
            for (track_clips) |*clip| {
                clip.flushDeferredBakeFrees();
            }
        }
    }

    pub fn updatePlugins(
        self: *SharedState,
        plugins: [max_tracks]?*const clap.Plugin,
        fx_plugins: [max_tracks][ui_state.max_fx_slots]?*const clap.Plugin,
    ) void {
        self.track_plugins = plugins;
        self.track_fx_plugins = fx_plugins;
    }

    pub fn setTrackPlugin(self: *SharedState, track_index: usize, plugin: ?*const clap.Plugin) void {
        self.track_plugins[track_index] = plugin;
        const current = self.active_index.load(.acquire);
        const next: u32 = 1 - current;
        self.snapshots[next] = self.snapshots[current];
        self.snapshots[next].track_plugins[track_index] = plugin;
        self.active_index.store(next, .release);
    }

    pub fn setTrackFxPlugin(self: *SharedState, track_index: usize, fx_index: usize, plugin: ?*const clap.Plugin) void {
        self.track_fx_plugins[track_index][fx_index] = plugin;
        const current = self.active_index.load(.acquire);
        const next: u32 = 1 - current;
        self.snapshots[next] = self.snapshots[current];
        self.snapshots[next].track_fx_plugins[track_index][fx_index] = plugin;
        self.active_index.store(next, .release);
    }

    /// Request that startProcessing be called for a track plugin from the audio thread
    pub fn requestStartProcessing(self: *SharedState, track_index: usize) void {
        self.plugins_need_start[track_index].store(true, .release);
    }

    /// Check and clear the start processing flag (called from audio thread)
    pub fn checkAndClearStartProcessing(self: *SharedState, track_index: usize) bool {
        return self.plugins_need_start[track_index].swap(false, .acq_rel);
    }

    /// Mark a plugin as started (called from audio thread after successful startProcessing)
    pub fn markPluginStarted(self: *SharedState, track_index: usize) void {
        self.plugins_started[track_index].store(true, .release);
    }

    /// Check if a plugin was started (for calling stopProcessing on cleanup)
    pub fn isPluginStarted(self: *SharedState, track_index: usize) bool {
        return self.plugins_started[track_index].load(.acquire);
    }

    /// Clear the started flag when unloading a plugin
    pub fn clearPluginStarted(self: *SharedState, track_index: usize) void {
        self.plugins_started[track_index].store(false, .release);
    }

    pub fn requestStartProcessingFx(self: *SharedState, track_index: usize, fx_index: usize) void {
        self.plugins_need_start_fx[track_index][fx_index].store(true, .release);
    }

    pub fn checkAndClearStartProcessingFx(self: *SharedState, track_index: usize, fx_index: usize) bool {
        return self.plugins_need_start_fx[track_index][fx_index].swap(false, .acq_rel);
    }

    pub fn markFxPluginStarted(self: *SharedState, track_index: usize, fx_index: usize) void {
        self.plugins_started_fx[track_index][fx_index].store(true, .release);
    }

    pub fn isFxPluginStarted(self: *SharedState, track_index: usize, fx_index: usize) bool {
        return self.plugins_started_fx[track_index][fx_index].load(.acquire);
    }

    pub fn clearFxPluginStarted(self: *SharedState, track_index: usize, fx_index: usize) void {
        self.plugins_started_fx[track_index][fx_index].store(false, .release);
    }

    pub fn snapshot(self: *SharedState) *const audio_graph.StateSnapshot {
        const current = self.active_index.load(.acquire);
        return &self.snapshots[current];
    }

    pub fn beginProcess(self: *SharedState) void {
        _ = self.processing.fetchAdd(1, .monotonic);
    }

    pub fn endProcess(self: *SharedState) void {
        _ = self.processing.fetchSub(1, .monotonic);
    }

    pub fn waitForIdle(self: *SharedState, io: std.Io) void {
        while (self.processing.load(.acquire) != 0) {
            _ = io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
    }

    pub fn setSuspendProcessing(self: *SharedState, should_suspend: bool) void {
        self.suspend_processing.store(should_suspend, .release);
    }

    pub fn isProcessingSuspended(self: *SharedState) bool {
        return self.suspend_processing.load(.acquire);
    }
};

pub const AudioEngine = struct {
    allocator: std.mem.Allocator,
    graph: audio_graph.Graph,
    shared: SharedState,
    steady_time: u64 = 0,
    sample_rate: f32,
    max_frames: u32,
    track_count: usize,
    rebuilding: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    dsp_load_pct: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    dsp_meter_count: u8 = 0,
    jobs: ?*audio_graph.JobQueue = null,
    metronome_beat_phase: f64 = 0,
    metronome_click_phase: f32 = 0,
    metronome_click_phase_step: f32 = 0,
    metronome_click_frames: u32 = 0,
    metronome_beat: u8 = 0,
    metronome_was_playing: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: f32,
        max_frames: u32,
    ) !AudioEngine {
        const shared = try SharedState.init(allocator);
        const graph = try buildGraph(allocator, max_tracks, sample_rate, max_frames);
        return .{
            .allocator = allocator,
            .graph = graph,
            .shared = shared,
            .sample_rate = sample_rate,
            .max_frames = max_frames,
            .track_count = max_tracks,
        };
    }

    pub fn deinit(self: *AudioEngine) void {
        self.graph.deinit();
        self.shared.deinit(self.allocator);
    }

    pub fn updateFromUi(self: *AudioEngine, state: *ui_state.State) void {
        if (state.session.track_count != self.track_count) {
            self.rebuildGraph(state.session.track_count, false) catch |err| {
                std.log.warn("Failed to rebuild graph: {}", .{err});
            };
        }
        self.shared.updateFromUi(state);
    }

    pub fn setMaxFrames(self: *AudioEngine, max_frames: u32) !void {
        if (max_frames == self.max_frames) return;
        self.max_frames = max_frames;
        try self.rebuildGraph(self.track_count, true);
    }

    pub fn updatePlugins(
        self: *AudioEngine,
        plugins: [max_tracks]?*const clap.Plugin,
        fx_plugins: [max_tracks][ui_state.max_fx_slots]?*const clap.Plugin,
    ) void {
        self.shared.updatePlugins(plugins, fx_plugins);
    }

    pub fn render(self: *AudioEngine, device: *zaudio.Device, output: ?*anyopaque, frame_count: u32) void {
        if (output == null) return;
        const out_ptr: [*]align(1) f32 = @ptrCast(output.?);
        const sample_count: usize = @as(usize, frame_count) * Channels;
        @memset(out_ptr[0..sample_count], 0);

        self.shared.beginProcess();
        defer self.shared.endProcess();
        if (self.shared.isProcessingSuspended()) return;

        if (self.rebuilding.load(.acquire) != 0) return;
        if (frame_count == 0) return;
        const snapshot = self.shared.snapshot();
        var frames_left = frame_count;
        var frame_offset: usize = 0;
        while (frames_left > 0) {
            const chunk: u32 = @min(frames_left, self.max_frames);
            self.graph.process(snapshot, &self.shared, self.jobs, chunk, self.steady_time);
            self.steady_time += chunk;

            const outputs = self.graph.getMasterOutput() orelse break;
            interleaveStereo(out_ptr, frame_offset, outputs.left, outputs.right, chunk);
            self.mixMetronome(out_ptr, frame_offset, chunk, snapshot);
            frame_offset += chunk;
            frames_left -= chunk;
        }

        _ = device;
    }

    fn mixMetronome(self: *AudioEngine, out_ptr: [*]align(1) f32, frame_offset: usize, frame_count: u32, snapshot: *const audio_graph.StateSnapshot) void {
        if (!snapshot.playing) {
            self.metronome_beat_phase = 0;
            self.metronome_click_frames = 0;
            self.metronome_beat = 0;
            self.metronome_was_playing = false;
            return;
        }

        if (!self.metronome_was_playing) {
            self.metronome_beat_phase = 0;
            self.metronome_click_phase = 0;
            self.metronome_click_phase_step = 2.0 * std.math.pi * 2400.0 / self.sample_rate;
            self.metronome_click_frames = if (snapshot.metronome_enabled) @intFromFloat(self.sample_rate * 0.025) else 0;
            self.metronome_beat = 0;
            self.metronome_was_playing = true;
        }

        const pulse_step = @as(f64, snapshot.bpm) / (60.0 * @as(f64, self.sample_rate)) *
            @as(f64, @floatFromInt(snapshot.time_signature_denominator)) / 4.0;
        const click_length = self.sample_rate * 0.025;
        for (0..frame_count) |i| {
            if (snapshot.metronome_enabled and self.metronome_click_frames > 0) {
                const envelope = @as(f32, @floatFromInt(self.metronome_click_frames)) / click_length;
                const click = @sin(self.metronome_click_phase) * envelope * 0.18;
                const idx = (frame_offset + i) * Channels;
                out_ptr[idx] += click;
                out_ptr[idx + 1] += click;
                self.metronome_click_phase += self.metronome_click_phase_step;
                self.metronome_click_frames -= 1;
            }

            self.metronome_beat_phase += pulse_step;
            if (self.metronome_beat_phase >= 1.0) {
                self.metronome_beat_phase -= 1.0;
                self.metronome_beat = (self.metronome_beat + 1) % snapshot.time_signature_numerator;
                if (snapshot.metronome_enabled) {
                    self.metronome_click_phase = 0;
                    const frequency: f32 = if (self.metronome_beat == 0) 2400.0 else 1600.0;
                    self.metronome_click_phase_step = 2.0 * std.math.pi * frequency / self.sample_rate;
                    self.metronome_click_frames = @intFromFloat(click_length);
                }
            }
        }
    }

    inline fn interleaveStereo(out_ptr: [*]align(1) f32, frame_offset: usize, left: []const f32, right: []const f32, chunk: u32) void {
        const frame_count: usize = @intCast(chunk);
        var i: usize = 0;
        const vec_end = frame_count - (frame_count % interleave_lanes);
        while (i < vec_end) : (i += interleave_lanes) {
            const l_vec = @as(F32xN, left[i..][0..interleave_lanes].*);
            const r_vec = @as(F32xN, right[i..][0..interleave_lanes].*);
            const l_arr = @as([interleave_lanes]f32, l_vec);
            const r_arr = @as([interleave_lanes]f32, r_vec);
            const base = (frame_offset + i) * Channels;
            out_ptr[base + 0] = l_arr[0];
            out_ptr[base + 1] = r_arr[0];
            out_ptr[base + 2] = l_arr[1];
            out_ptr[base + 3] = r_arr[1];
            out_ptr[base + 4] = l_arr[2];
            out_ptr[base + 5] = r_arr[2];
            out_ptr[base + 6] = l_arr[3];
            out_ptr[base + 7] = r_arr[3];
        }
        while (i < frame_count) : (i += 1) {
            const idx = (frame_offset + i) * Channels;
            out_ptr[idx] = left[i];
            out_ptr[idx + 1] = right[i];
        }
    }

    fn rebuildGraph(self: *AudioEngine, track_count_in: usize, force: bool) !void {
        if (!force and track_count_in == self.track_count) return;
        self.rebuilding.store(1, .release);
        while (self.shared.processing.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
        }
        const new_graph = try buildGraph(self.allocator, track_count_in, self.sample_rate, self.max_frames);
        self.graph.deinit();
        self.graph = new_graph;
        self.track_count = track_count_in;
        self.rebuilding.store(0, .release);
    }
};

fn buildGraph(
    allocator: std.mem.Allocator,
    track_count_in: usize,
    sample_rate: f32,
    max_frames: u32,
) !audio_graph.Graph {
    var graph = audio_graph.Graph.init(allocator);

    var synth_nodes: [max_tracks]audio_graph.NodeId = undefined;
    var gain_nodes: [max_tracks]audio_graph.NodeId = undefined;
    const count = @min(track_count_in, max_tracks);

    for (0..count) |track_index| {
        const note_id = try graph.addNoteSource(track_index, true, -1);
        synth_nodes[track_index] = try graph.addSynth(track_index);
        // Audio clips feed the same FX chain as the instrument (instrument silenced when audio plays).
        const audio_clip_id = try graph.addAudioClipSource(track_index);

        var prev_node = synth_nodes[track_index];
        for (0..ui_state.max_fx_slots) |fx_index| {
            const fx_note_id = try graph.addNoteSource(track_index, false, @intCast(fx_index));
            const fx_id = try graph.addFx(track_index, fx_index);
            try graph.connect(fx_note_id, 0, fx_id, 0, .events);
            try graph.connect(prev_node, 0, fx_id, 0, .audio);
            if (fx_index == 0) {
                // Sum audio clip into first FX input alongside synth.
                try graph.connect(audio_clip_id, 0, fx_id, 0, .audio);
            }
            prev_node = fx_id;
        }

        gain_nodes[track_index] = try graph.addGain(track_index);

        try graph.connect(note_id, 0, synth_nodes[track_index], 0, .events);
        try graph.connect(prev_node, 0, gain_nodes[track_index], 0, .audio);
    }

    const mixer_id = try graph.addMixer();

    for (0..count) |track_index| {
        try graph.connect(gain_nodes[track_index], 0, mixer_id, 0, .audio);
    }

    var prev_master_node = mixer_id;
    for (0..ui_state.max_fx_slots) |fx_index| {
        const master_fx_id = try graph.addFx(master_track_index, fx_index);
        try graph.connect(prev_master_node, 0, master_fx_id, 0, .audio);
        prev_master_node = master_fx_id;
    }

    const master_id = try graph.addMaster();
    try graph.connect(prev_master_node, 0, master_id, 0, .audio);

    try graph.prepare(sample_rate, max_frames);
    return graph;
}
fn initSnapshot(snapshot: *audio_graph.StateSnapshot) void {
    const bytes: [*]u8 = @ptrCast(snapshot);
    @memset(bytes[0..@sizeOf(audio_graph.StateSnapshot)], 0);
    snapshot.time_signature_numerator = 4;
    snapshot.time_signature_denominator = 4;
    snapshot.track_count = max_tracks;
    snapshot.scene_count = max_scenes;
    for (0..max_tracks) |t| {
        snapshot.active_scene_by_track[t] = -1;
        // sample_id 0 is valid; zero-fill would falsely mark audio present.
        snapshot.playing_audio[t].clear();
        for (0..max_scenes) |s| {
            snapshot.clips[t][s].length_beats = default_clip_bars * beats_per_bar;
            snapshot.piano_clips[t][s].length_beats = default_clip_bars * beats_per_bar;
            snapshot.piano_clips[t][s].count = 0;
        }
    }
}
