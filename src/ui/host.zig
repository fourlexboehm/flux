//! Document host for the DVUI shell: real session + arrangement + clip pool.
//!
//! Starts empty like zgui (`session_ops.init` + arrangement lanes matching
//! session tracks). No demo seed.
//!
//! Transport audio / engine lives in `ui/audio_runtime.zig` (full `AudioEngine`
//! via chrome adapter → `audio/engine_ui.EngineUiView`). CLAP catalog/load lives
//! in `ui/plugin_host.zig` (projects device names here each frame).
//!
//! Chrome (`state.zig`) remains draw-facing; this module owns domain data and
//! projects a snapshot into chrome each frame (or after mutations).

const std = @import("std");
const session_types = @import("../session/types.zig");
const session_ops = @import("../session/ops.zig");
const session_playback = @import("../session/playback.zig");
const session_constants = @import("../session/constants.zig");
const clip_pool_mod = @import("../session/clip_pool.zig");
const sample_store_mod = @import("../audio/sample_store.zig");
const arr_types = @import("../arrangement/types.zig");
const arr_ops = @import("../arrangement/ops.zig");
const arr_timeline = @import("../arrangement/timeline.zig");
const chrome = @import("state.zig");

const SessionView = session_types.SessionView;
const ClipPool = clip_pool_mod.ClipPool;
const SampleStore = sample_store_mod.SampleStore;
const ArrangementView = arr_types.ArrangementView;

/// Default lane colors (same palette theme uses for track stripes).
const track_colors = [_][4]f32{
    .{ 0.85, 0.35, 0.30, 1 },
    .{ 0.35, 0.55, 0.90, 1 },
    .{ 0.40, 0.75, 0.45, 1 },
    .{ 0.90, 0.70, 0.30, 1 },
    .{ 0.65, 0.45, 0.85, 1 },
    .{ 0.40, 0.80, 0.80, 1 },
    .{ 0.90, 0.50, 0.65, 1 },
    .{ 0.55, 0.55, 0.60, 1 },
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    clip_pool: ClipPool,
    sample_store: SampleStore,
    session: SessionView,
    arrangement: ArrangementView,
    /// Device-chain display until CLAP plugin runtime is wired (empty = no device).
    instrument_names: [chrome.max_tracks][]const u8 = @splat(""),
    instrument_enabled: [chrome.max_tracks]bool = @splat(true),
    fx_names: [chrome.max_tracks][chrome.max_fx_slots][]const u8 = undefined,
    fx_enabled: [chrome.max_tracks][chrome.max_fx_slots]bool = undefined,
    fx_counts: [chrome.max_tracks]usize = @splat(0),

    pub fn init(allocator: std.mem.Allocator) Host {
        var h = Host{
            .allocator = allocator,
            .clip_pool = ClipPool.init(allocator),
            .sample_store = SampleStore.init(allocator),
            // Same empty grid as zgui: Inst 1..N, numbered scenes, empty slots.
            .session = session_ops.init(allocator),
            .arrangement = ArrangementView.init(allocator),
        };
        for (&h.fx_names) |*row| {
            for (row) |*n| n.* = "";
        }
        for (&h.fx_enabled) |*row| {
            @memset(row, true);
        }
        return h;
    }

    pub fn deinit(self: *Host) void {
        session_ops.deinit(&self.session);
        self.arrangement.deinit();
        self.clip_pool.deinit(&self.sample_store);
        self.sample_store.deinit();
        self.* = undefined;
    }

    /// Wire pool/store back-refs after `Host` is at its final address, then
    /// align arrangement lanes with the empty session (no clips).
    pub fn wireInternalRefs(self: *Host) void {
        self.session.clip_pool = &self.clip_pool;
        self.session.sample_store = &self.sample_store;
        self.arrangement.clip_pool = &self.clip_pool;
        self.arrangement.sample_store = &self.sample_store;
        self.syncArrangementTracksFromSession();
    }

    /// Rebuild arrangement track list from session (names/count); keeps no
    /// placements. Called after init and whenever track layout is reset.
    pub fn syncArrangementTracksFromSession(self: *Host) void {
        self.arrangement.clearTracks();
        for (0..self.session.track_count) |t| {
            const name = self.session.tracks[t].getName();
            const col = track_colors[t % track_colors.len];
            arr_ops.createTrack(&self.arrangement, t, name, col) catch {};
        }
    }

    // ── Mutations (session domain) ─────────────────────────────────────────

    pub fn createClipAt(self: *Host, track: usize, scene: usize, beats_per_bar: f32) void {
        session_ops.createClip(&self.session, track, scene, beats_per_bar);
        session_ops.selectOnly(&self.session, track, scene);
    }

    pub fn toggleSlotPlay(self: *Host, track: usize, scene: usize, transport_playing: bool) void {
        session_playback.toggleClipPlayback(&self.session, track, scene, transport_playing);
    }

    pub fn launchScene(self: *Host, scene: usize, transport_playing: bool) void {
        session_playback.launchScene(&self.session, scene, transport_playing);
    }

    pub fn selectSlot(self: *Host, track: usize, scene: usize) void {
        if (track < self.session.track_count and scene < self.session.scene_count) {
            session_ops.selectOnly(&self.session, track, scene);
        }
    }

    /// Apply session requests raised by playback ops (start play, reset playhead).
    pub fn drainPlaybackRequests(self: *Host, state: *chrome.State) void {
        if (self.session.start_playback_request) {
            self.session.start_playback_request = false;
            if (!state.playing) {
                state.playing = true;
                state.playhead_beat = 0;
            }
        }
        if (self.session.reset_playhead_request) {
            self.session.reset_playhead_request = false;
            state.playhead_beat = 0;
        }
        if (state.playing) {
            const bpb = state.beatsPerBar();
            if (bpb > 0) {
                const beat_in_bar = @mod(state.playhead_beat, bpb);
                if (beat_in_bar < 0.05) {
                    session_playback.processQuantizedSwitches(&self.session);
                }
            }
        }
    }

    // ── Chrome projection ──────────────────────────────────────────────────

    /// Copy domain → chrome so existing DVUI views keep working.
    pub fn projectChrome(self: *Host, state: *chrome.State) void {
        state.track_count = @min(self.session.track_count, chrome.max_tracks);
        state.scene_count = @min(self.session.scene_count, chrome.max_scenes);

        if (state.track_count > 0 and state.selected_track >= state.track_count) {
            state.selected_track = state.track_count - 1;
        }
        if (state.scene_count > 0 and state.selected_scene >= state.scene_count) {
            state.selected_scene = state.scene_count - 1;
        }

        for (0..chrome.max_tracks) |t| {
            state.track_name_lens[t] = 0;
            state.instrument_names[t] = "";
            state.instrument_enabled[t] = true;
            state.fx_counts[t] = 0;
            for (0..chrome.max_fx_slots) |fx| {
                state.fx_names[t][fx] = "";
                state.fx_enabled[t][fx] = true;
            }
            for (0..chrome.max_scenes) |s| {
                state.slots[t][s] = .{};
            }
        }
        for (0..chrome.max_scenes) |s| {
            state.scene_name_lens[s] = 0;
        }
        state.arr_clip_count = 0;

        for (0..state.track_count) |t| {
            const tn = self.session.tracks[t].getName();
            const n = @min(tn.len, state.track_names[t].len);
            @memcpy(state.track_names[t][0..n], tn[0..n]);
            state.track_name_lens[t] = n;

            state.instrument_names[t] = self.instrument_names[t];
            state.instrument_enabled[t] = self.instrument_enabled[t];
            state.fx_counts[t] = self.fx_counts[t];
            for (0..self.fx_counts[t]) |fx| {
                state.fx_names[t][fx] = self.fx_names[t][fx];
                state.fx_enabled[t][fx] = self.fx_enabled[t][fx];
            }
        }
        for (0..state.scene_count) |s| {
            const sn = self.session.scenes[s].getName();
            const n = @min(sn.len, state.scene_names[s].len);
            @memcpy(state.scene_names[s][0..n], sn[0..n]);
            state.scene_name_lens[s] = n;
        }

        const bpb = state.beatsPerBar();
        for (0..state.track_count) |t| {
            for (0..state.scene_count) |s| {
                state.slots[t][s] = projectSlot(self, t, s, bpb);
            }
        }

        var global_i: usize = 0;
        for (self.arrangement.tracks.items, 0..) |*atrack, ti| {
            for (atrack.clips.items) |*placement| {
                if (global_i >= chrome.max_arr_clips) break;
                const pooled = self.arrangement.placementClip(placement);
                const kind: chrome.ClipKind = blk: {
                    if (pooled) |c| {
                        break :blk switch (c.content) {
                            .midi => .midi,
                            .audio => .audio,
                        };
                    }
                    break :blk .midi;
                };
                const name: []const u8 = if (pooled) |c| c.name.get() else "";
                const start_beat = @as(f32, @floatFromInt(placement.start_tick)) /
                    @as(f32, @floatFromInt(arr_timeline.ppq));
                const length_beats = @as(f32, @floatFromInt(placement.duration_ticks)) /
                    @as(f32, @floatFromInt(arr_timeline.ppq));
                state.arr_clips[global_i] = .{
                    .track = ti,
                    .start_beat = start_beat,
                    .length_beats = length_beats,
                    .kind = kind,
                    .name = name,
                };
                global_i += 1;
            }
        }
        state.arr_clip_count = global_i;
    }

    fn projectSlot(self: *Host, track: usize, scene: usize, beats_per_bar: f32) chrome.ClipSlot {
        const slot = self.session.clips[track][scene];
        if (slot.state == .empty or slot.clip.isNone()) {
            return .{};
        }
        const pooled = self.clip_pool.get(slot.clip);
        const kind: chrome.ClipKind = blk: {
            if (pooled) |c| {
                break :blk switch (c.content) {
                    .midi => .midi,
                    .audio => .audio,
                };
            }
            break :blk .midi;
        };
        const name: []const u8 = if (pooled) |c| c.name.get() else "";
        const length = if (pooled) |c| c.lengthBeats() else session_constants.default_clip_bars * beats_per_bar;
        const bars = if (beats_per_bar > 0) length / beats_per_bar else length / 4.0;
        const play: chrome.SlotPlayState = switch (slot.state) {
            .empty => .empty,
            .stopped => .stopped,
            .queued, .record_queued => .queued,
            .playing, .recording => .playing,
        };
        return .{
            .kind = kind,
            .play = play,
            .name = name,
            .bars = bars,
        };
    }

    pub fn syncSelectionFromChrome(self: *Host, state: *const chrome.State) void {
        if (state.selected_track < self.session.track_count) {
            self.session.primary_track = state.selected_track;
        }
        if (state.selected_scene < self.session.scene_count) {
            self.session.primary_scene = state.selected_scene;
        }
    }

    pub fn toggleDeviceEnabled(self: *Host, state: *chrome.State) void {
        const t = state.selected_track;
        if (t >= chrome.max_tracks) return;
        switch (state.device_target_kind) {
            .instrument => {
                self.instrument_enabled[t] = !self.instrument_enabled[t];
                state.instrument_enabled[t] = self.instrument_enabled[t];
            },
            .fx => {
                if (state.device_target_fx < self.fx_counts[t]) {
                    const fx = state.device_target_fx;
                    self.fx_enabled[t][fx] = !self.fx_enabled[t][fx];
                    state.fx_enabled[t][fx] = self.fx_enabled[t][fx];
                }
            },
        }
        // Keep plugin_host enable flags in lockstep (engine bypass source).
        const plugin_host_mod = @import("plugin_host.zig");
        const ph = @import("../plugin/handle.zig");
        if (plugin_host_mod.ready() and t < ph.track_count) {
            switch (state.device_target_kind) {
                .instrument => plugin_host_mod.g.instrument_choice[t].enabled = self.instrument_enabled[t],
                .fx => {
                    if (state.device_target_fx < ph.max_fx_slots) {
                        plugin_host_mod.g.fx_choice[t][state.device_target_fx].enabled =
                            self.fx_enabled[t][state.device_target_fx];
                    }
                },
            }
        }
    }
};

/// Process-wide host for the DVUI app binary.
pub var g: Host = undefined;
pub var g_ready: bool = false;

pub fn initGlobal(allocator: std.mem.Allocator) void {
    g = Host.init(allocator);
    g.wireInternalRefs();
    g_ready = true;
}

pub fn deinitGlobal() void {
    if (!g_ready) return;
    g.deinit();
    g_ready = false;
}

pub fn ready() bool {
    return g_ready;
}

// ── Unit tests ─────────────────────────────────────────────────────────────

test "host starts empty like zgui session_ops.init" {
    var h = Host.init(std.testing.allocator);
    defer h.deinit();
    h.wireInternalRefs();

    try std.testing.expectEqual(@as(usize, 4), h.session.track_count);
    try std.testing.expectEqual(@as(usize, 8), h.session.scene_count);
    try std.testing.expectEqualStrings("Inst 1", h.session.tracks[0].getName());
    try std.testing.expectEqualStrings("1", h.session.scenes[0].getName());
    try std.testing.expect(h.session.clips[0][0].state == .empty);
    try std.testing.expect(h.session.clips[0][0].clip.isNone());
    try std.testing.expectEqual(h.session.track_count, h.arrangement.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.arrangement.tracks.items[0].clips.items.len);
    try std.testing.expectEqualStrings("", h.instrument_names[0]);
    try std.testing.expectEqual(@as(usize, 0), h.fx_counts[0]);
}

test "host projectChrome projects empty grid" {
    var h = Host.init(std.testing.allocator);
    defer h.deinit();
    h.wireInternalRefs();

    var s: chrome.State = .{};
    h.projectChrome(&s);
    try std.testing.expectEqual(@as(usize, 4), s.track_count);
    try std.testing.expectEqual(@as(usize, 8), s.scene_count);
    try std.testing.expectEqualStrings("Inst 1", s.trackName(0));
    try std.testing.expectEqualStrings("1", s.sceneName(0));
    try std.testing.expect(s.slot(0, 0).kind == .empty);
    try std.testing.expectEqual(@as(usize, 0), s.arr_clip_count);
}

test "host createClipAt adds pooled midi clip on empty project" {
    var h = Host.init(std.testing.allocator);
    defer h.deinit();
    h.wireInternalRefs();

    try std.testing.expect(h.session.clips[0][0].state == .empty);
    h.createClipAt(0, 0, 4.0);
    try std.testing.expect(h.session.clips[0][0].state == .stopped);
    try std.testing.expect(!h.session.clips[0][0].clip.isNone());

    var s: chrome.State = .{};
    h.projectChrome(&s);
    try std.testing.expect(s.slot(0, 0).kind == .midi);
    try std.testing.expect(s.slot(0, 0).play == .stopped);
}
