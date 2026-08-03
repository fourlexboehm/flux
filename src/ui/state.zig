//! Canonical **host chrome state** for the DVUI shell.
//!
//! Draw-facing snapshot + transport/view chrome. Domain data (session slots,
//! arrangement placements) is exposed through `document/model.zig`, owned by
//! the application host, and projected here each frame. This module stays free of session/audio/plugin imports so pure
//! chrome unit tests keep compiling without the engine graph.
//!
//! Product path starts empty (host projects `session_ops.init`). No demo seed.
//! zgui's mega-`State` remains parked reference for full plugin/audio fields.

const std = @import("std");

// ── Chrome enums (mirror zgui chrome tags; no draw deps) ─────────────────────

pub const ViewMode = enum {
    session,
    arrangement,
};

pub const BottomMode = enum {
    device,
    sequencer,
};

/// Which main region owns keyboard focus (zgui had the same split).
pub const FocusedPane = enum {
    session,
    bottom,
};

pub const BrowserTab = enum {
    sounds,
    drums,
    bass,
    pad,
    lead,
    keys,
    noise,
    instruments,
    audio_effects,
};

/// Selected device in the bottom chain (zgui: `DeviceTargetKind`).
pub const DeviceTargetKind = enum {
    instrument,
    fx,
};

/// Which mixer strip owns the device chain (zgui: `session.mixer_target`).
pub const MixerTarget = enum {
    track,
    master,
};

/// In-flight browser drag payload (DVUI has drag names, not typed payloads).
pub const BrowserDragKind = enum {
    none,
    audio_file,
    plugin_instrument,
    plugin_fx,
};

/// Target kind when creating a piano-roll automation lane (zgui `AutomationAddTarget`).
pub const AutomationAddTarget = enum {
    track_volume,
    track_pan,
    instrument_param,
    fx_param,
};

// ── Session chrome snapshot types (projected from host; not domain ownership) ─

pub const ClipKind = enum {
    empty,
    midi,
    audio,
};

pub const SlotPlayState = enum {
    empty,
    stopped,
    queued,
    playing,
};

pub const max_tracks: usize = 16;
/// Matches session domain: master lives at the last track slot (not in `track_count`).
pub const master_track_index: usize = max_tracks - 1;
pub const max_scenes: usize = 16;
pub const max_fx_slots: usize = 8;
/// Dense arrangement chrome budget (was 32; raised for multi-clip projects).
pub const max_arr_clips: usize = 256;
/// Max user sample folders in the browser Places list.
pub const max_browser_folders: usize = 8;
/// Max path length for a browser drag payload / folder path.
pub const browser_path_cap: usize = 512;
pub const max_piano_notes: usize = 4096;

pub const ClipSlot = struct {
    kind: ClipKind = .empty,
    play: SlotPlayState = .empty,
    name: []const u8 = "",
    bars: f32 = 1.0,
};

pub const ArrClip = struct {
    track: usize,
    start_beat: f32,
    length_beats: f32,
    kind: ClipKind,
    name: []const u8,
    selected: bool = false,
};

pub const ArrDragMode = enum {
    none,
    move,
    resize_left,
    resize_right,
};

pub const PianoClipboardNote = struct {
    pitch: u8 = 60,
    start: f32 = 0,
    duration: f32 = 0.25,
    velocity: f32 = 0.8,
    release_velocity: f32 = 0.8,
};

pub const PianoMarkerDrag = enum { none, play_start, loop_start, loop_end };

// ── Transport constants (aligned with zgui transport chrome) ─────────────────

pub const time_signatures = [_][2]u8{
    .{ 2, 4 }, .{ 3, 4 }, .{ 4, 4 }, .{ 5, 4 },
    .{ 6, 8 }, .{ 7, 8 }, .{ 9, 8 }, .{ 12, 8 },
};
pub const time_signature_labels = [_][]const u8{
    "2/4", "3/4", "4/4", "5/4", "6/8", "7/8", "9/8", "12/8",
};

pub const quantize_labels = [_][]const u8{
    "1/32", "1/16", "1/8", "1/4", "1/2", "1 Bar", "2 Bar", "4 Bar", "8 Bar",
};

/// Matches zgui `buffer_frame_options` subset commonly offered in transport.
pub const buffer_frame_options = [_]u32{ 16, 32, 64, 128, 256, 512, 1024 };
pub const buffer_labels = [_][]const u8{ "16", "32", "64", "128", "256", "512", "1024" };
pub const default_buffer_frames: u32 = 128;
pub const default_quantize_index: usize = 3; // 1/4

// ── State ────────────────────────────────────────────────────────────────────

pub const State = struct {
    // Transport chrome
    playing: bool = false,
    playhead_beat: f32 = 0,
    metronome_enabled: bool = false,
    bpm: f32 = 120.0,
    time_signature_numerator: u8 = 4,
    time_signature_denominator: u8 = 4,
    quantize_index: usize = default_quantize_index,
    buffer_frames: u32 = default_buffer_frames,
    dsp_load_pct: u8 = 0,
    /// Stereo peak meters per track (decay applied in audio_runtime.pullToChrome).
    track_levels: [max_tracks][2]f32 = @splat(@splat(0)),

    // View chrome
    view_mode: ViewMode = .session,
    bottom_mode: BottomMode = .device,
    focused_pane: FocusedPane = .session,
    /// Vertical split: fraction of content height for the top (session) pane.
    /// Lower = more room for device/plugin bottom pane.
    top_split_ratio: f32 = 0.62,
    /// Horizontal split: fraction of top width for the browser (when open).
    browser_split_ratio: f32 = 0.28,
    browser_open: bool = true,
    browser_tab: BrowserTab = .sounds,
    browser_search: [64]u8 = @splat(0),
    browser_search_len: usize = 0,
    browser_sort_asc: bool = true,
    /// User-added Places folders (absolute paths).
    browser_folders: [max_browser_folders][browser_path_cap]u8 = @splat(@splat(0)),
    browser_folder_lens: [max_browser_folders]usize = @splat(0),
    browser_folder_count: usize = 0,
    /// Selected Places folder index, or null = show all folders' files.
    browser_folder_selected: ?usize = null,
    /// Drag payload while `dvui.dragName("browser_item")` is active.
    browser_drag_kind: BrowserDragKind = .none,
    browser_drag_path: [browser_path_cap]u8 = @splat(0),
    browser_drag_path_len: usize = 0,
    browser_drag_catalog_index: i32 = 0,

    // Selection chrome
    selected_track: usize = 0,
    selected_scene: usize = 0,
    selected_arr_clip: ?usize = null,
    /// Arrangement timeline zoom (natural pixels per beat).
    arr_pixels_per_beat: f32 = 12,
    arr_last_clip_click_ns: i128 = 0,
    arr_last_clip_click_index: ?usize = null,
    /// Live arrangement clip drag/resize (document mutated in place; revision on release).
    arr_drag_mode: ArrDragMode = .none,
    arr_drag_clip: ?usize = null,
    arr_drag_mouse_x: f32 = 0,
    arr_drag_mouse_y: f32 = 0,
    arr_drag_orig_start_tick: i64 = 0,
    arr_drag_orig_duration_ticks: i64 = 0,
    arr_drag_orig_track: usize = 0,
    arr_drag_changed: bool = false,
    arr_drag_ctrl: bool = false,
    arr_drag_duplicated: bool = false,
    /// Box multi-select on the arrangement timeline.
    arr_box_select: bool = false,
    arr_box_pending: bool = false,
    arr_box_additive: bool = false,
    arr_box_start_x: f32 = 0,
    arr_box_start_y: f32 = 0,
    arr_box_current_x: f32 = 0,
    arr_box_current_y: f32 = 0,
    /// Physical lane rects (x,y,w,h) for track hit-testing during cross-lane drag.
    arr_lane_rects: [max_tracks][4]f32 = @splat(@splat(0)),
    // Dense-canvas piano-roll interaction state. Notes remain in the document.
    piano_scroll_beat: f32 = 0,
    /// Pitch at the vertical center of the piano-roll viewport.
    piano_scroll_pitch: f32 = 60,
    piano_pixels_per_beat: f32 = 64,
    piano_row_height: f32 = 14,
    piano_selected_note: ?usize = null,
    piano_note_selected: [max_piano_notes]bool = @splat(false),
    piano_selection_track: usize = std.math.maxInt(usize),
    piano_selection_scene: usize = std.math.maxInt(usize),
    piano_drag_note: ?usize = null,
    piano_drag_mouse_x: f32 = 0,
    piano_drag_mouse_y: f32 = 0,
    piano_drag_start: f32 = 0,
    piano_drag_pitch: u8 = 0,
    piano_drag_duration: f32 = 0,
    piano_drag_resize: bool = false,
    piano_drag_changed: bool = false,
    piano_drag_original_start: [max_piano_notes]f32 = @splat(0),
    piano_drag_original_pitch: [max_piano_notes]u8 = @splat(0),
    piano_drag_original_duration: [max_piano_notes]f32 = @splat(0),
    piano_box_select: bool = false,
    piano_box_additive: bool = false,
    piano_box_start_x: f32 = 0,
    piano_box_start_y: f32 = 0,
    piano_box_current_x: f32 = 0,
    piano_box_current_y: f32 = 0,
    piano_velocity_drag: bool = false,
    piano_velocity_open: bool = false,
    piano_clip_resize: bool = false,
    piano_marker_drag: PianoMarkerDrag = .none,
    piano_nav_drag: bool = false,
    piano_nav_mouse_x: f32 = 0,
    piano_nav_mouse_y: f32 = 0,
    piano_nav_start_beat: f32 = 0,
    piano_nav_start_zoom: f32 = 64,
    piano_tools_open: bool = false,
    piano_last_grid_click_ns: i128 = 0,
    piano_last_grid_click_x: f32 = 0,
    piano_last_grid_click_y: f32 = 0,
    piano_clipboard: [512]PianoClipboardNote = @splat(.{}),
    piano_clipboard_len: usize = 0,
    /// Pitch auditioned while dragging notes or holding a keyboard key.
    piano_preview_pitch: ?u8 = null,
    /// Row under the pointer (grid or keyboard strip).
    piano_hover_pitch: ?u8 = null,
    /// Keyboard-strip press (click-to-play). Held until pointer release.
    piano_key_held: ?u8 = null,
    /// Piano-roll automation overlay (zgui `automation_*` chrome).
    piano_automation_edit: bool = false,
    piano_automation_lane_index: ?usize = null,
    piano_automation_selected_point: ?usize = null,
    piano_automation_drag_active: bool = false,
    piano_automation_drag_lane: usize = 0,
    piano_automation_drag_point: usize = 0,
    piano_automation_drag_changed: bool = false,
    piano_automation_add_open: bool = false,
    piano_automation_add_target: AutomationAddTarget = .instrument_param,
    piano_automation_add_fx_index: usize = 0,
    piano_automation_add_param_id: ?u32 = null,
    session_last_slot_click_ns: i128 = 0,
    session_last_slot_click_track: usize = std.math.maxInt(usize),
    session_last_slot_click_scene: usize = std.math.maxInt(usize),
    // Session drag state is a dense fixed-size overlay; document clips stay in
    // session storage and are only moved once on pointer release.
    session_drag_active: bool = false,
    session_drag_started: bool = false,
    session_drag_source_track: usize = 0,
    session_drag_source_scene: usize = 0,
    session_drag_target_track: usize = 0,
    session_drag_target_scene: usize = 0,
    session_drag_target_valid: bool = false,
    /// Physical x/y/w/h for hit-testing while the pointer is captured.
    session_slot_rects: [max_tracks][max_scenes][4]f32 = @splat(@splat(@splat(0))),
    /// Session box multi-select (empty-cell drag; zgui `drag_select` parity).
    session_box_select: bool = false,
    session_box_pending: bool = false,
    session_box_additive: bool = false,
    session_box_start_x: f32 = 0,
    session_box_start_y: f32 = 0,
    session_box_current_x: f32 = 0,
    session_box_current_y: f32 = 0,
    /// Defaults match `session_ops.init` (projected over by host each frame).
    track_count: usize = 4,
    scene_count: usize = 8,

    // Device chain target chrome
    device_target_kind: DeviceTargetKind = .instrument,
    device_target_fx: usize = 0,
    /// Master strip vs selected track (affects device rack + mixer highlight).
    mixer_target: MixerTarget = .track,

    // ── Projected domain snapshot (filled by host.projectChrome) ───────────
    slots: [max_tracks][max_scenes]ClipSlot = @splat(@splat(.{})),
    track_names: [max_tracks][24]u8 = undefined,
    track_name_lens: [max_tracks]usize = @splat(0),
    track_volume: [max_tracks]f32 = @splat(0.8),
    track_pan: [max_tracks]f32 = @splat(0),
    track_mute: [max_tracks]bool = @splat(false),
    track_solo: [max_tracks]bool = @splat(false),
    /// Master bus (session index `master_track_index`); not counted in `track_count`.
    master_volume: f32 = 0.9,
    master_pan: f32 = 0,
    master_mute: bool = false,
    armed_track: ?usize = null,
    scene_names: [max_scenes][24]u8 = undefined,
    scene_name_lens: [max_scenes]usize = @splat(0),
    instrument_names: [max_tracks][]const u8 = @splat(""),
    instrument_enabled: [max_tracks]bool = @splat(true),
    fx_names: [max_tracks][max_fx_slots][]const u8 = @splat(@splat("")),
    fx_enabled: [max_tracks][max_fx_slots]bool = @splat(@splat(true)),
    fx_counts: [max_tracks]usize = @splat(0),
    arr_clips: [max_arr_clips]ArrClip = undefined,
    arr_clip_count: usize = 0,
    /// Last arrangement draw cost (µs) and clips actually painted (viewport-culled).
    arr_draw_us: u32 = 0,
    arr_clips_drawn: u32 = 0,

    /// Last frame timestamp for playhead animation (ns); DVUI frame loop only.
    last_frame_time_ns: i128 = 0,

    // ── Project I/O requests (handled by ui/project_runtime.zig) ───────────
    load_project_request: bool = false,
    save_project_request: bool = false,
    save_project_as_request: bool = false,
    /// Absolute path of the open project (empty = untitled). Owned buffer.
    project_path: [512]u8 = @splat(0),
    project_path_len: usize = 0,

    /// Minimal names for pure chrome unit tests (not used by the product path).
    pub fn initEmptyChrome(self: *State) void {
        self.track_count = 4;
        self.scene_count = 8;
        for (0..self.track_count) |t| {
            var buf: [16]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "Inst {d}", .{t + 1}) catch "Inst";
            const n = @min(label.len, self.track_names[t].len);
            @memcpy(self.track_names[t][0..n], label[0..n]);
            self.track_name_lens[t] = n;
        }
        for (0..self.scene_count) |s| {
            var buf: [16]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{d}", .{s + 1}) catch "1";
            const n = @min(label.len, self.scene_names[s].len);
            @memcpy(self.scene_names[s][0..n], label[0..n]);
            self.scene_name_lens[s] = n;
        }
        for (&self.slots) |*row| {
            for (row) |*cell| cell.* = .{};
        }
        @memset(&self.fx_counts, 0);
        self.arr_clip_count = 0;
    }

    // ── Accessors ──────────────────────────────────────────────────────────

    pub fn trackName(self: *const State, t: usize) []const u8 {
        if (t >= max_tracks) return "Track";
        const len = self.track_name_lens[t];
        if (len == 0) return "Track";
        return self.track_names[t][0..len];
    }

    pub fn sceneName(self: *const State, s: usize) []const u8 {
        if (s >= max_scenes) return "Scene";
        const len = self.scene_name_lens[s];
        if (len == 0) return "Scene";
        return self.scene_names[s][0..len];
    }

    /// zgui-compatible alias for primary track selection.
    pub fn selectedTrack(self: *const State) usize {
        return self.selected_track;
    }

    /// Track index used by the device rack (master bus when mixer targets master).
    pub fn deviceTrack(self: *const State) usize {
        return if (self.mixer_target == .master) master_track_index else self.selected_track;
    }

    pub fn selectedScene(self: *const State) usize {
        return self.selected_scene;
    }

    pub fn slot(self: *const State, track: usize, scene: usize) ClipSlot {
        if (track >= max_tracks or scene >= max_scenes) return .{};
        return self.slots[track][scene];
    }

    pub fn slotPtr(self: *State, track: usize, scene: usize) *ClipSlot {
        return &self.slots[track][scene];
    }

    pub fn selectedSlot(self: *const State) ClipSlot {
        return self.slot(self.selected_track, self.selected_scene);
    }

    pub fn searchSlice(self: *const State) []const u8 {
        return self.browser_search[0..self.browser_search_len];
    }

    pub fn browserFolder(self: *const State, index: usize) []const u8 {
        if (index >= self.browser_folder_count) return "";
        return self.browser_folders[index][0..self.browser_folder_lens[index]];
    }

    pub fn addBrowserFolder(self: *State, path: []const u8) bool {
        if (path.len == 0 or self.browser_folder_count >= max_browser_folders) return false;
        for (0..self.browser_folder_count) |i| {
            if (std.mem.eql(u8, self.browserFolder(i), path)) return false;
        }
        const n = @min(path.len, browser_path_cap);
        @memcpy(self.browser_folders[self.browser_folder_count][0..n], path[0..n]);
        self.browser_folder_lens[self.browser_folder_count] = n;
        self.browser_folder_count += 1;
        return true;
    }

    pub fn clearBrowserDrag(self: *State) void {
        self.browser_drag_kind = .none;
        self.browser_drag_path_len = 0;
        self.browser_drag_catalog_index = 0;
    }

    pub fn setBrowserAudioDrag(self: *State, path: []const u8) void {
        const n = @min(path.len, browser_path_cap);
        @memcpy(self.browser_drag_path[0..n], path[0..n]);
        self.browser_drag_path_len = n;
        self.browser_drag_kind = .audio_file;
        self.browser_drag_catalog_index = 0;
    }

    pub fn setBrowserPluginDrag(self: *State, catalog_index: i32, is_fx: bool) void {
        self.browser_drag_kind = if (is_fx) .plugin_fx else .plugin_instrument;
        self.browser_drag_catalog_index = catalog_index;
        self.browser_drag_path_len = 0;
    }

    pub fn browserDragPath(self: *const State) []const u8 {
        return self.browser_drag_path[0..self.browser_drag_path_len];
    }

    /// Beats per bar from time signature (zgui transport helper parity).
    pub fn beatsPerBar(self: *const State) f32 {
        return @as(f32, @floatFromInt(self.time_signature_numerator)) * 4.0 /
            @as(f32, @floatFromInt(self.time_signature_denominator));
    }

    // ── Selection mutators ─────────────────────────────────────────────────

    pub fn selectSlot(self: *State, track: usize, scene: usize) void {
        if (track < self.track_count) {
            self.selected_track = track;
            self.mixer_target = .track;
        }
        if (scene < self.scene_count) self.selected_scene = scene;
        self.selectDeviceInstrument();
        self.focused_pane = .session;
    }

    pub fn selectTrack(self: *State, track: usize) void {
        if (track >= self.track_count) return;
        self.selected_track = track;
        self.mixer_target = .track;
        self.selectDeviceInstrument();
        self.selected_arr_clip = null;
        self.focused_pane = .session;
    }

    /// Select the master bus strip (device rack becomes master FX only).
    pub fn selectMaster(self: *State) void {
        self.mixer_target = .master;
        self.device_target_kind = .fx;
        self.device_target_fx = 0;
        self.selected_arr_clip = null;
        self.focused_pane = .session;
    }

    pub fn selectScene(self: *State, scene: usize) void {
        if (scene >= self.scene_count) return;
        self.selected_scene = scene;
        self.focused_pane = .session;
    }

    pub fn selectDeviceInstrument(self: *State) void {
        if (self.mixer_target == .master) {
            self.device_target_kind = .fx;
            self.device_target_fx = 0;
            self.focused_pane = .bottom;
            return;
        }
        self.device_target_kind = .instrument;
        self.device_target_fx = 0;
        self.focused_pane = .bottom;
    }

    pub fn selectDeviceFx(self: *State, fx_index: usize) void {
        self.device_target_kind = .fx;
        self.device_target_fx = fx_index;
        self.focused_pane = .bottom;
    }

    pub fn toggleDeviceEnabled(self: *State) void {
        const t = self.deviceTrack();
        if (t >= max_tracks) return;
        switch (self.device_target_kind) {
            .instrument => {
                if (self.mixer_target == .master) return;
                self.instrument_enabled[t] = !self.instrument_enabled[t];
            },
            .fx => {
                if (self.device_target_fx < self.fx_counts[t]) {
                    self.fx_enabled[t][self.device_target_fx] = !self.fx_enabled[t][self.device_target_fx];
                }
            },
        }
    }

    /// Chrome-only slot play toggle (product path uses host session playback).
    pub fn toggleSlotPlay(self: *State, track: usize, scene: usize) void {
        const s = self.slotPtr(track, scene);
        if (s.kind == .empty) return;
        s.play = switch (s.play) {
            .empty, .stopped => .playing,
            .playing => .stopped,
            .queued => .playing,
        };
        self.selectSlot(track, scene);
    }

    /// Chrome-only clip create (product path uses host `session_ops.createClip`).
    pub fn createClipAt(self: *State, track: usize, scene: usize) void {
        const s = self.slotPtr(track, scene);
        if (s.kind != .empty) return;
        s.* = .{
            .kind = .midi,
            .play = .stopped,
            .name = "",
            .bars = 4,
        };
        self.selectSlot(track, scene);
        self.bottom_mode = .sequencer;
    }

    // ── Transport / view mutators ──────────────────────────────────────────

    pub fn togglePlay(self: *State) void {
        self.playing = !self.playing;
        if (self.playing) self.playhead_beat = 0;
    }

    pub fn toggleViewMode(self: *State) void {
        self.view_mode = switch (self.view_mode) {
            .session => .arrangement,
            .arrangement => .session,
        };
        self.focused_pane = .session;
    }

    pub fn toggleBottomMode(self: *State) void {
        self.bottom_mode = switch (self.bottom_mode) {
            .device => .sequencer,
            .sequencer => .device,
        };
        self.focused_pane = .bottom;
    }

    pub fn toggleBrowser(self: *State) void {
        self.browser_open = !self.browser_open;
    }

    pub fn toggleMetronome(self: *State) void {
        self.metronome_enabled = !self.metronome_enabled;
    }

    pub fn setBrowserTab(self: *State, tab: BrowserTab) void {
        self.browser_tab = tab;
    }

    pub fn timeSignatureIndex(self: *const State) usize {
        for (time_signatures, 0..) |sig, i| {
            if (sig[0] == self.time_signature_numerator and sig[1] == self.time_signature_denominator) {
                return i;
            }
        }
        return 2; // 4/4 default
    }

    pub fn setTimeSignatureIndex(self: *State, index: usize) void {
        if (index >= time_signatures.len) return;
        const sig = time_signatures[index];
        self.time_signature_numerator = sig[0];
        self.time_signature_denominator = sig[1];
    }

    pub fn bufferIndex(self: *const State) usize {
        for (buffer_frame_options, 0..) |frames, i| {
            if (frames == self.buffer_frames) return i;
        }
        // default_buffer_frames = 128 is index 3
        return 3;
    }

    pub fn setBufferIndex(self: *State, index: usize) void {
        if (index >= buffer_frame_options.len) return;
        self.buffer_frames = buffer_frame_options[index];
    }

    pub fn setQuantizeIndex(self: *State, index: usize) void {
        if (index >= quantize_labels.len) return;
        self.quantize_index = index;
    }
};

/// Process-wide UI state for the DVUI host binary (immediate-mode frame).
pub var g: State = .{};

// ── Unit tests (pure chrome transitions; no DVUI/zgui) ───────────────────────

test "togglePlay flips and resets playhead" {
    var s: State = .{};
    s.playhead_beat = 12.5;
    try std.testing.expect(!s.playing);
    s.togglePlay();
    try std.testing.expect(s.playing);
    try std.testing.expectEqual(@as(f32, 0), s.playhead_beat);
    s.playhead_beat = 4;
    s.togglePlay();
    try std.testing.expect(!s.playing);
    try std.testing.expectEqual(@as(f32, 4), s.playhead_beat);
}

test "toggleViewMode and toggleBottomMode cycle" {
    var s: State = .{};
    try std.testing.expect(s.view_mode == .session);
    s.toggleViewMode();
    try std.testing.expect(s.view_mode == .arrangement);
    try std.testing.expect(s.focused_pane == .session);
    s.toggleViewMode();
    try std.testing.expect(s.view_mode == .session);

    try std.testing.expect(s.bottom_mode == .device);
    s.toggleBottomMode();
    try std.testing.expect(s.bottom_mode == .sequencer);
    try std.testing.expect(s.focused_pane == .bottom);
    s.toggleBottomMode();
    try std.testing.expect(s.bottom_mode == .device);
}

test "toggleBrowser and toggleMetronome" {
    var s: State = .{};
    try std.testing.expect(s.browser_open);
    s.toggleBrowser();
    try std.testing.expect(!s.browser_open);
    s.toggleBrowser();
    try std.testing.expect(s.browser_open);

    try std.testing.expect(!s.metronome_enabled);
    s.toggleMetronome();
    try std.testing.expect(s.metronome_enabled);
}

test "browser folders and drag payload chrome" {
    var s: State = .{};
    try std.testing.expect(s.addBrowserFolder("/tmp/samples"));
    try std.testing.expect(!s.addBrowserFolder("/tmp/samples")); // dedupe
    try std.testing.expectEqual(@as(usize, 1), s.browser_folder_count);
    try std.testing.expectEqualStrings("/tmp/samples", s.browserFolder(0));

    s.setBrowserAudioDrag("/tmp/samples/kick.wav");
    try std.testing.expect(s.browser_drag_kind == .audio_file);
    try std.testing.expectEqualStrings("/tmp/samples/kick.wav", s.browserDragPath());
    s.setBrowserPluginDrag(3, true);
    try std.testing.expect(s.browser_drag_kind == .plugin_fx);
    try std.testing.expectEqual(@as(i32, 3), s.browser_drag_catalog_index);
    s.clearBrowserDrag();
    try std.testing.expect(s.browser_drag_kind == .none);
}

test "selectTrack and selectScene clamp and reset device target" {
    var s: State = .{};
    s.initEmptyChrome();
    s.device_target_kind = .fx;
    s.device_target_fx = 2;
    s.selectTrack(3);
    try std.testing.expectEqual(@as(usize, 3), s.selectedTrack());
    try std.testing.expect(s.device_target_kind == .instrument);
    try std.testing.expectEqual(@as(usize, 0), s.device_target_fx);
    try std.testing.expect(s.selected_arr_clip == null);

    s.selectScene(5);
    try std.testing.expectEqual(@as(usize, 5), s.selectedScene());

    s.selectTrack(999); // out of range: no-op
    try std.testing.expectEqual(@as(usize, 3), s.selected_track);
}

test "selectSlot sets track scene and instrument target" {
    var s: State = .{};
    s.initEmptyChrome();
    s.selectSlot(1, 2);
    try std.testing.expectEqual(@as(usize, 1), s.selected_track);
    try std.testing.expectEqual(@as(usize, 2), s.selected_scene);
    try std.testing.expect(s.device_target_kind == .instrument);
}

test "selectDeviceInstrument and selectDeviceFx" {
    var s: State = .{};
    s.initEmptyChrome();
    s.selectDeviceFx(1);
    try std.testing.expect(s.device_target_kind == .fx);
    try std.testing.expectEqual(@as(usize, 1), s.device_target_fx);
    try std.testing.expect(s.focused_pane == .bottom);
    s.selectDeviceInstrument();
    try std.testing.expect(s.device_target_kind == .instrument);
    try std.testing.expectEqual(@as(usize, 0), s.device_target_fx);
}

test "setTimeSignatureIndex and setBufferIndex" {
    var s: State = .{};
    try std.testing.expectEqual(@as(usize, 2), s.timeSignatureIndex()); // 4/4
    s.setTimeSignatureIndex(0); // 2/4
    try std.testing.expectEqual(@as(u8, 2), s.time_signature_numerator);
    try std.testing.expectEqual(@as(u8, 4), s.time_signature_denominator);
    try std.testing.expectEqual(@as(usize, 0), s.timeSignatureIndex());

    s.setTimeSignatureIndex(99); // no-op
    try std.testing.expectEqual(@as(u8, 2), s.time_signature_numerator);

    try std.testing.expectEqual(@as(usize, 3), s.bufferIndex()); // 128
    s.setBufferIndex(0);
    try std.testing.expectEqual(@as(u32, 16), s.buffer_frames);
    s.setBufferIndex(6);
    try std.testing.expectEqual(@as(u32, 1024), s.buffer_frames);
    try std.testing.expectEqual(@as(usize, 6), s.bufferIndex());
}

test "setQuantizeIndex bounds" {
    var s: State = .{};
    s.setQuantizeIndex(0);
    try std.testing.expectEqual(@as(usize, 0), s.quantize_index);
    s.setQuantizeIndex(quantize_labels.len);
    try std.testing.expectEqual(@as(usize, 0), s.quantize_index);
}

test "createClipAt and toggleSlotPlay on empty chrome" {
    var s: State = .{};
    s.initEmptyChrome();
    try std.testing.expect(s.slot(0, 0).kind == .empty);
    s.createClipAt(0, 0);
    try std.testing.expect(s.slot(0, 0).kind == .midi);
    try std.testing.expect(s.slot(0, 0).play == .stopped);
    try std.testing.expectEqual(@as(usize, 0), s.selected_track);
    try std.testing.expect(s.bottom_mode == .sequencer);

    s.toggleSlotPlay(0, 0);
    try std.testing.expect(s.slot(0, 0).play == .playing);
    s.toggleSlotPlay(0, 0);
    try std.testing.expect(s.slot(0, 0).play == .stopped);
}

test "beatsPerBar from time signature" {
    var s: State = .{};
    try std.testing.expectEqual(@as(f32, 4.0), s.beatsPerBar());
    s.setTimeSignatureIndex(0); // 2/4
    try std.testing.expectEqual(@as(f32, 2.0), s.beatsPerBar());
    s.setTimeSignatureIndex(4); // 6/8 → 6 * 4 / 8 = 3
    try std.testing.expectEqual(@as(f32, 3.0), s.beatsPerBar());
}

test "initEmptyChrome matches session_ops defaults" {
    var s: State = .{};
    s.initEmptyChrome();
    try std.testing.expectEqual(@as(usize, 4), s.track_count);
    try std.testing.expectEqual(@as(usize, 8), s.scene_count);
    try std.testing.expectEqualStrings("Inst 1", s.trackName(0));
    try std.testing.expectEqualStrings("1", s.sceneName(0));
    try std.testing.expect(s.slot(0, 0).kind == .empty);
}

test "toggleDeviceEnabled flips instrument and fx" {
    var s: State = .{};
    s.initEmptyChrome();
    s.fx_counts[0] = 1;
    s.fx_enabled[0][0] = true;
    try std.testing.expect(s.instrument_enabled[0]);
    s.selectDeviceInstrument();
    s.selected_track = 0;
    s.toggleDeviceEnabled();
    try std.testing.expect(!s.instrument_enabled[0]);

    s.selectDeviceFx(0);
    try std.testing.expect(s.fx_enabled[0][0]);
    s.toggleDeviceEnabled();
    try std.testing.expect(!s.fx_enabled[0][0]);
}

test "chrome enums match zgui tag names" {
    // Structural parity: same tag names for shared chrome surface.
    try std.testing.expect(@hasField(ViewMode, "session"));
    try std.testing.expect(@hasField(ViewMode, "arrangement"));
    try std.testing.expect(@hasField(BottomMode, "device"));
    try std.testing.expect(@hasField(BottomMode, "sequencer"));
    try std.testing.expect(@hasField(DeviceTargetKind, "instrument"));
    try std.testing.expect(@hasField(DeviceTargetKind, "fx"));
    try std.testing.expect(@hasField(FocusedPane, "session"));
    try std.testing.expect(@hasField(FocusedPane, "bottom"));
}
