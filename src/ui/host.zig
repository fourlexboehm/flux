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
const session_constants = @import("../session/constants.zig");
const arr_timeline = @import("../arrangement/timeline.zig");
const chrome = @import("state.zig");
const document_model = @import("../document/model.zig");
const document_commands = @import("../document/commands.zig");

pub const Host = struct {
    allocator: std.mem.Allocator,
    document_store: *document_model.Store,
    projected_document_revision: u64 = std.math.maxInt(u64),
    projected_beats_per_bar: f32 = -1,
    document_projection_count: usize = 0,
    /// Device-chain display until CLAP plugin runtime is wired (empty = no device).
    instrument_names: [chrome.max_tracks][]const u8 = @splat(""),
    instrument_enabled: [chrome.max_tracks]bool = @splat(true),
    fx_names: [chrome.max_tracks][chrome.max_fx_slots][]const u8 = undefined,
    fx_enabled: [chrome.max_tracks][chrome.max_fx_slots]bool = undefined,
    fx_counts: [chrome.max_tracks]usize = @splat(0),

    pub fn init(store: *document_model.Store) Host {
        var h = Host{
            .allocator = store.allocator,
            .document_store = store,
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
        self.* = undefined;
    }

    /// Wire pool/store back-refs after `Host` is at its final address, then
    /// align arrangement lanes with the empty session (no clips).
    pub fn wireInternalRefs(self: *Host) void {
        self.document_store.wireInternalRefs();
        self.syncArrangementTracksFromSession();
    }

    /// UI-neutral document boundary for project/audio/runtime consumers.
    pub fn document(self: *Host) document_model.Model {
        return self.document_store.view();
    }

    /// Rebuild arrangement track list from session (names/count); keeps no
    /// placements. Called after init and whenever track layout is reset.
    pub fn syncArrangementTracksFromSession(self: *Host) void {
        document_commands.syncArrangementTracks(self.document_store);
    }

    /// Apply session requests raised by playback ops (start play, reset playhead).
    /// Quantize boundaries and recording finalization live in `ui/recording.tick`.
    pub fn drainPlaybackRequests(self: *Host, state: *chrome.State) void {
        const requests = document_commands.takePlaybackRequests(self.document_store);
        if (requests.start) {
            if (!state.playing) {
                state.playing = true;
                state.playhead_beat = 0;
            }
        }
        if (requests.reset_playhead) {
            state.playhead_beat = 0;
        }
    }

    // ── Chrome projection ──────────────────────────────────────────────────

    /// Project durable document data only when its generation (or a projection
    /// input such as beats-per-bar) changes. Runtime device chrome stays live.
    pub fn projectChrome(self: *Host, state: *chrome.State) void {
        const beats_per_bar = state.beatsPerBar();
        if (self.projected_document_revision != self.document_store.revision or
            self.projected_beats_per_bar != beats_per_bar)
        {
            self.projectDocumentChrome(state, beats_per_bar);
            self.projected_document_revision = self.document_store.revision;
            self.projected_beats_per_bar = beats_per_bar;
            self.document_projection_count += 1;
        }
        self.projectDeviceChrome(state);
    }

    fn projectDocumentChrome(self: *Host, state: *chrome.State, beats_per_bar: f32) void {
        const store = self.document_store;
        state.track_count = @min(store.session.track_count, chrome.max_tracks);
        state.scene_count = @min(store.session.scene_count, chrome.max_scenes);

        if (state.track_count > 0 and state.selected_track >= state.track_count) {
            state.selected_track = state.track_count - 1;
        }
        if (state.scene_count > 0 and state.selected_scene >= state.scene_count) {
            state.selected_scene = state.scene_count - 1;
        }

        for (0..chrome.max_tracks) |t| {
            state.track_name_lens[t] = 0;
            state.track_volume[t] = 0.8;
            state.track_pan[t] = 0;
            state.track_mute[t] = false;
            state.track_solo[t] = false;
            for (0..chrome.max_scenes) |s| {
                state.slots[t][s] = .{};
            }
        }
        for (0..chrome.max_scenes) |s| {
            state.scene_name_lens[s] = 0;
        }
        state.arr_clip_count = 0;
        state.armed_track = if (store.session.armed_track) |track|
            if (track < state.track_count) track else null
        else
            null;

        for (0..state.track_count) |t| {
            const tn = store.session.tracks[t].getName();
            const n = @min(tn.len, state.track_names[t].len);
            @memcpy(state.track_names[t][0..n], tn[0..n]);
            state.track_name_lens[t] = n;
            state.track_volume[t] = store.session.tracks[t].volume;
            state.track_pan[t] = store.session.tracks[t].pan;
            state.track_mute[t] = store.session.tracks[t].mute;
            state.track_solo[t] = store.session.tracks[t].solo;
        }

        const master = store.session.tracks[chrome.master_track_index];
        state.master_volume = master.volume;
        state.master_pan = master.pan;
        state.master_mute = master.mute;
        for (0..state.scene_count) |s| {
            const sn = store.session.scenes[s].getName();
            const n = @min(sn.len, state.scene_names[s].len);
            @memcpy(state.scene_names[s][0..n], sn[0..n]);
            state.scene_name_lens[s] = n;
        }

        for (0..state.track_count) |t| {
            for (0..state.scene_count) |s| {
                state.slots[t][s] = projectSlot(self, t, s, beats_per_bar);
            }
        }

        var global_i: usize = 0;
        for (store.arrangement.tracks.items, 0..) |*atrack, ti| {
            for (atrack.clips.items) |*placement| {
                if (global_i >= chrome.max_arr_clips) break;
                const pooled = store.arrangement.placementClip(placement);
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
                    .selected = placement.selected,
                };
                global_i += 1;
            }
        }
        state.arr_clip_count = global_i;
    }

    fn projectDeviceChrome(self: *const Host, state: *chrome.State) void {
        for (0..chrome.max_tracks) |track| {
            state.instrument_names[track] = "";
            state.instrument_enabled[track] = true;
            state.fx_counts[track] = 0;
            for (0..chrome.max_fx_slots) |fx| {
                state.fx_names[track][fx] = "";
                state.fx_enabled[track][fx] = true;
            }
        }
        for (0..state.track_count) |track| {
            state.instrument_names[track] = self.instrument_names[track];
            state.instrument_enabled[track] = self.instrument_enabled[track];
            state.fx_counts[track] = self.fx_counts[track];
            for (0..self.fx_counts[track]) |fx| {
                state.fx_names[track][fx] = self.fx_names[track][fx];
                state.fx_enabled[track][fx] = self.fx_enabled[track][fx];
            }
        }

        // Master bus FX live at master_track_index (outside track_count).
        const mi = chrome.master_track_index;
        state.instrument_names[mi] = "";
        state.instrument_enabled[mi] = true;
        state.fx_counts[mi] = self.fx_counts[mi];
        for (0..self.fx_counts[mi]) |fx| {
            state.fx_names[mi][fx] = self.fx_names[mi][fx];
            state.fx_enabled[mi][fx] = self.fx_enabled[mi][fx];
        }
    }

    fn projectSlot(self: *Host, track: usize, scene: usize, beats_per_bar: f32) chrome.ClipSlot {
        const slot = self.document_store.session.clips[track][scene];
        if (slot.state == .empty or slot.clip.isNone()) {
            return .{};
        }
        const pooled = self.document_store.clip_pool.get(slot.clip);
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
            .queued => .queued,
            .record_queued => .record_queued,
            .playing => .playing,
            .recording => .recording,
        };
        return .{
            .kind = kind,
            .play = play,
            .name = name,
            .bars = bars,
        };
    }

    pub fn toggleDeviceEnabled(self: *Host, state: *chrome.State) void {
        const t = state.deviceTrack();
        if (t >= chrome.max_tracks) return;
        switch (state.device_target_kind) {
            .instrument => {
                if (state.mixer_target == .master) return;
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
    std.debug.assert(document_model.ready());
    _ = allocator;
    g = Host.init(&document_model.g);
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
    var store = document_model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    var h = Host.init(&store);
    defer h.deinit();
    h.wireInternalRefs();

    try std.testing.expectEqual(@as(usize, 4), store.session.track_count);
    try std.testing.expectEqual(@as(usize, 8), store.session.scene_count);
    try std.testing.expectEqualStrings("Inst 1", store.session.tracks[0].getName());
    try std.testing.expectEqualStrings("1", store.session.scenes[0].getName());
    try std.testing.expect(store.session.clips[0][0].state == .empty);
    try std.testing.expect(store.session.clips[0][0].clip.isNone());
    try std.testing.expectEqual(store.session.track_count, store.arrangement.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.arrangement.tracks.items[0].clips.items.len);
    try std.testing.expectEqualStrings("", h.instrument_names[0]);
    try std.testing.expectEqual(@as(usize, 0), h.fx_counts[0]);
}

test "host projectChrome projects empty grid" {
    var store = document_model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    var h = Host.init(&store);
    defer h.deinit();
    h.wireInternalRefs();

    var s: chrome.State = .{};
    h.projectChrome(&s);
    try std.testing.expectEqual(@as(usize, 4), s.track_count);
    try std.testing.expectEqual(@as(usize, 8), s.scene_count);
    try std.testing.expectEqualStrings("Inst 1", s.trackName(0));
    try std.testing.expectEqualStrings("1", s.sceneName(0));
    try std.testing.expect(s.slot(0, 0).kind == .empty);
    try std.testing.expectEqual(@as(?usize, null), s.armed_track);
    try std.testing.expectEqual(@as(usize, 0), s.arr_clip_count);
    try std.testing.expectEqual(@as(usize, 1), h.document_projection_count);

    // Runtime projection still runs, but unchanged document chrome is skipped.
    h.projectChrome(&s);
    try std.testing.expectEqual(@as(usize, 1), h.document_projection_count);

    try std.testing.expect(document_commands.addScene(&store));
    h.projectChrome(&s);
    try std.testing.expectEqual(@as(usize, 2), h.document_projection_count);
    try std.testing.expectEqual(@as(usize, 9), s.scene_count);

    s.time_signature_numerator = 3;
    h.projectChrome(&s);
    try std.testing.expectEqual(@as(usize, 3), h.document_projection_count);

    document_commands.toggleTrackArm(&store, 2);
    h.projectChrome(&s);
    try std.testing.expectEqual(@as(?usize, 2), s.armed_track);
}

test "host createClipAt adds pooled midi clip on empty project" {
    var store = document_model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    var h = Host.init(&store);
    defer h.deinit();
    h.wireInternalRefs();

    try std.testing.expect(store.session.clips[0][0].state == .empty);
    document_commands.createClip(&store, 0, 0, 4.0);
    try std.testing.expect(store.session.clips[0][0].state == .stopped);
    try std.testing.expect(!store.session.clips[0][0].clip.isNone());

    var s: chrome.State = .{};
    h.projectChrome(&s);
    try std.testing.expect(s.slot(0, 0).kind == .midi);
    try std.testing.expect(s.slot(0, 0).play == .stopped);
}
