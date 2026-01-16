const std = @import("std");
const zaudio = @import("zaudio");
const clap = @import("clap-bindings");

const ui = @import("ui.zig");
const audio_graph = @import("audio_graph.zig");

const Channels = 2;

pub const SharedState = struct {
    mutex: std.Thread.Mutex = .{},
    processing: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    playing: bool = false,
    bpm: f32 = 120.0,
    playhead_beat: f32 = 0,
    tracks: [ui.track_count]ui.Track = undefined,
    clips: [ui.track_count][ui.scene_count]ui.ClipSlot = undefined,
    piano_clips_ptr: ?*const [ui.track_count][ui.scene_count]ui.PianoRollClip = null,
    track_plugins: [ui.track_count]?*const clap.Plugin = [_]?*const clap.Plugin{null} ** ui.track_count,

    pub fn init() SharedState {
        return .{};
    }

    pub fn updateFromUi(self: *SharedState, state: *const ui.State) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.playing = state.playing;
        self.bpm = state.bpm;
        self.playhead_beat = state.playhead_beat;
        self.tracks = state.session.tracks;
        self.clips = state.session.clips;
        self.piano_clips_ptr = &state.piano_clips;
    }

    pub fn updatePlugins(self: *SharedState, plugins: [ui.track_count]?*const clap.Plugin) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.track_plugins = plugins;
    }

    pub fn setTrackPlugin(self: *SharedState, track_index: usize, plugin: ?*const clap.Plugin) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.track_plugins[track_index] = plugin;
    }

    pub fn snapshot(self: *SharedState) ?audio_graph.StateSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.piano_clips_ptr == null) return null;
        return .{
            .playing = self.playing,
            .bpm = self.bpm,
            .playhead_beat = self.playhead_beat,
            .tracks = self.tracks,
            .clips = self.clips,
            .piano_clips_ptr = self.piano_clips_ptr.?,
            .track_plugins = self.track_plugins,
        };
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
};

pub const AudioEngine = struct {
    allocator: std.mem.Allocator,
    graph: audio_graph.Graph,
    shared: SharedState,
    steady_time: u64 = 0,
    sample_rate: f32,
    max_frames: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: f32,
        max_frames: u32,
    ) !AudioEngine {
        var graph = audio_graph.Graph.init(allocator);

        var note_nodes: [ui.track_count]audio_graph.NodeId = undefined;
        var synth_nodes: [ui.track_count]audio_graph.NodeId = undefined;
        var gain_nodes: [ui.track_count]audio_graph.NodeId = undefined;

        for (0..ui.track_count) |track_index| {
            var note_node = audio_graph.Node{
                .id = 0,
                .kind = .note_source,
                .data = .{ .note_source = audio_graph.NoteSource.init(track_index) },
            };
            note_node.addOutput(.events);
            note_nodes[track_index] = try graph.addNode(note_node);

            var synth_node = audio_graph.Node{
                .id = 0,
                .kind = .synth,
                .data = .{ .synth = audio_graph.SynthNode.init(track_index) },
            };
            synth_node.addInput(.events);
            synth_node.addOutput(.audio);
            synth_nodes[track_index] = try graph.addNode(synth_node);

            var gain_node = audio_graph.Node{
                .id = 0,
                .kind = .gain,
                .data = .{ .gain = .{ .track_index = track_index } },
            };
            gain_node.addInput(.audio);
            gain_node.addOutput(.audio);
            gain_nodes[track_index] = try graph.addNode(gain_node);

            try graph.connect(note_nodes[track_index], 0, synth_nodes[track_index], 0, .events);
            try graph.connect(synth_nodes[track_index], 0, gain_nodes[track_index], 0, .audio);
        }

        var mixer_node = audio_graph.Node{
            .id = 0,
            .kind = .mixer,
            .data = .{ .mixer = .{} },
        };
        mixer_node.addInput(.audio);
        mixer_node.addOutput(.audio);
        const mixer_id = try graph.addNode(mixer_node);

        for (0..ui.track_count) |track_index| {
            try graph.connect(gain_nodes[track_index], 0, mixer_id, 0, .audio);
        }

        var master_node = audio_graph.Node{
            .id = 0,
            .kind = .master,
            .data = .{ .master = .{} },
        };
        master_node.addInput(.audio);
        master_node.addOutput(.audio);
        const master_id = try graph.addNode(master_node);
        try graph.connect(mixer_id, 0, master_id, 0, .audio);
        graph.master_node = master_id;

        try graph.prepare(sample_rate, max_frames);

        const shared = SharedState.init();
        return .{
            .allocator = allocator,
            .graph = graph,
            .shared = shared,
            .sample_rate = sample_rate,
            .max_frames = max_frames,
        };
    }

    pub fn deinit(self: *AudioEngine) void {
        self.graph.deinit();
    }

    pub fn updateFromUi(self: *AudioEngine, state: *const ui.State) void {
        self.shared.updateFromUi(state);
    }

    pub fn updatePlugins(self: *AudioEngine, plugins: [ui.track_count]?*const clap.Plugin) void {
        self.shared.updatePlugins(plugins);
    }

    pub fn render(self: *AudioEngine, device: *zaudio.Device, output: ?*anyopaque, frame_count: u32) void {
        if (output == null) return;
        self.shared.beginProcess();
        defer self.shared.endProcess();
        const out_ptr: [*]f32 = @ptrCast(@alignCast(output.?));
        const sample_count: usize = @as(usize, frame_count) * Channels;
        @memset(out_ptr[0..sample_count], 0);

        if (frame_count == 0) return;
        const snapshot = self.shared.snapshot() orelse return;
        var frames_left = frame_count;
        var frame_offset: usize = 0;
        while (frames_left > 0) {
            const chunk: u32 = @min(frames_left, self.max_frames);
            self.graph.process(&snapshot, chunk, self.steady_time);
            self.steady_time += chunk;

            const master_id = self.graph.master_node orelse break;
            const outputs = self.graph.getAudioOutput(master_id);
            for (0..chunk) |i| {
                const idx = (frame_offset + i) * Channels;
                out_ptr[idx] = outputs.left[i];
                out_ptr[idx + 1] = outputs.right[i];
            }
            frame_offset += chunk;
            frames_left -= chunk;
        }

        _ = device;
    }
};
