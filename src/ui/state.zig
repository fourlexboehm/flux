const std = @import("std");
const clap = @import("clap-bindings");
const presets = @import("../plugin/presets.zig");

const undo = @import("../undo/root.zig");
const session_view = @import("../session/types.zig");
const session_constants = @import("../session/constants.zig");
const session_ops = @import("../session/ops.zig");
const piano_roll_types = @import("../session/notes.zig");
const audio_clip_types = @import("../session/audio_clip.zig");
const clip_pool_mod = @import("../session/clip_pool.zig");
const sample_store_mod = @import("../audio/sample_store.zig");
const arr_types = @import("../arrangement/types.zig");
const arr_undo = @import("../arrangement/undo.zig");
const arr_ops = @import("../arrangement/ops.zig");
const arr_draw = @import("views/arrangement/draw.zig");
const browser = @import("panels/browser.zig");

const SessionView = session_view.SessionView;
const max_tracks = session_constants.max_tracks;
const max_scenes = session_constants.max_scenes;
const SampleStore = sample_store_mod.SampleStore;
const AudioClip = audio_clip_types.AudioClip;
const ClipPool = clip_pool_mod.ClipPool;
const ClipId = clip_pool_mod.ClipId;
const PianoRollClip = piano_roll_types.PianoRollClip;

// Constants for audio buffer options.
pub const max_fx_slots = 4;
pub const buffer_frame_options = [_]u32{ 16, 32, 64, 128, 256, 512, 1024 };
pub const default_buffer_frames: u32 = buffer_frame_options[3];
pub const controller_smart_slots = 8;
pub const max_controller_param_writes = 64;
pub const max_controller_smart_params = 256;

pub const BottomMode = enum {
    device,
    sequencer,
};

pub const ViewMode = enum {
    session,
    arrangement,
};

pub const FocusedPane = enum {
    session,
    bottom,
};

pub const DeviceKind = enum {
    none,
    plugin, // Unified: any loaded plugin (builtin or external CLAP)
};

pub const DeviceTargetKind = enum {
    instrument,
    fx,
};

pub const TrackPluginUI = struct {
    choice_index: i32,
    gui_open: bool,
    last_valid_choice: i32,
    preset_choice_index: ?usize = null,
    /// Device bypass: audio thread skips processing when false.
    enabled: bool = true,
};

/// Structural edit of a track's FX chain. Handled in main.zig by
/// `plugin_runtime.applyChainOpRequest` so live plugin instances move with
/// their slots instead of being reloaded (which would drop plugin state).
pub const ChainOpRequest = union(enum) {
    move_fx: struct { track: usize, from: usize, to: usize },
    remove_fx: struct { track: usize, fx_index: usize },
    duplicate_fx: struct { track: usize, fx_index: usize },
};

pub const MissingPluginRole = enum {
    instrument,
    note_fx,
    audio_fx,
    analyzer,
};

pub const MissingPluginParameter = struct {
    id: u32,
    name: []u8,
    value: f64,
    min: f64,
    max: f64,
};

pub const MissingPlugin = struct {
    device_id: []u8,
    device_name: []u8,
    role: MissingPluginRole,
    loaded: bool,
    parameters: []MissingPluginParameter,
    state_data: ?[]u8,

    pub fn deinit(self: *MissingPlugin, allocator: std.mem.Allocator) void {
        allocator.free(self.device_id);
        allocator.free(self.device_name);
        for (self.parameters) |param| allocator.free(param.name);
        allocator.free(self.parameters);
        if (self.state_data) |data| allocator.free(data);
        self.* = undefined;
    }
};

pub const ControllerParamWrite = struct {
    track_index: u8,
    target_fx_index: i8, // -1 for instrument
    param_id: u32,
    value: f64,
};

pub const ControllerSmartParam = struct {
    param_id: u32 = 0,
    min_value: f64 = 0.0,
    max_value: f64 = 1.0,
    label: [96]u8 = @splat(0),
    label_len: usize = 0,
};

pub const ControllerProfile = enum {
    axiom_49_g2,
};

pub const ControllerState = struct {
    profile: ControllerProfile = .axiom_49_g2,
    smart_page: usize = 0,
    smart_param_count: usize = 0,
    smart_params: [max_controller_smart_params]ControllerSmartParam = @splat(.{}),
    smart_target_track: usize = 0,
    smart_target_kind: DeviceTargetKind = .instrument,
    smart_target_fx: usize = 0,
    smart_target_plugin: ?*const clap.Plugin = null,
    cc_button_down: [128]bool = @splat(false),
    last_cc_values: [128]u8 = @splat(0),
};

pub const State = struct {
    allocator: std.mem.Allocator,
    playing: bool,
    metronome_enabled: bool,
    bpm: f32,
    time_signature_numerator: u8,
    time_signature_denominator: u8,
    quantize_index: i32,
    buffer_frames: u32,
    buffer_frames_requested: bool,
    dsp_load_pct: u32,
    track_levels: [max_tracks][2]f32,
    bottom_mode: BottomMode,
    bottom_panel_height: f32,
    splitter_drag_start: f32,
    // View mode: session grid vs arrangement timeline
    view_mode: ViewMode,
    arrangement: arr_types.ArrangementView,
    arrangement_scroll: arr_draw.ArrangementScroll,
    // Device state - unified for builtin and external CLAP plugins
    device_kind: DeviceKind,
    device_clap_plugin: ?*const clap.Plugin, // Current plugin (builtin or external)
    device_clap_name: []const u8, // Name for display
    device_target_kind: DeviceTargetKind,
    device_target_track: usize,
    device_target_fx: usize,
    playhead_beat: f32,
    focused_pane: FocusedPane,

    // Session view
    session: SessionView,

    // Piano roll state
    piano_state: piano_roll_types.PianoRollState,

    // Shared clip pool: session slots (and, from Phase 3, arrangement
    // placements) reference clip content by `ClipId` handle. Replaces the old
    // parallel `piano_clips` / `audio_clips` arrays.
    clip_pool: ClipPool,
    // Read-only fallback returned by `currentClip` for empty slots so callers
    // always get a valid, non-persisted pointer.
    scratch_clip: PianoRollClip,
    sample_store: SampleStore,

    // Track plugin UI state
    track_plugins: [max_tracks]TrackPluginUI,
    track_fx: [max_tracks][max_fx_slots]TrackPluginUI,
    track_fx_slot_count: [max_tracks]usize,
    plugin_items: [:0]const u8,
    plugin_fx_items: [:0]const u8,
    plugin_fx_indices: []i32,
    plugin_instrument_items: [:0]const u8,
    plugin_instrument_indices: []i32,
    instrument_filter_items_z: [:0]const u8,
    instrument_filter_indices: []i32,
    preset_filter_items_z: [:0]const u8,
    preset_filter_indices: []i32,
    preset_filter_choice_index: i32 = -1,
    preset_combo_width: f32 = 260.0,
    plugin_divider_index: ?i32,
    track_plugin_ptrs: [max_tracks]?*const clap.Plugin,
    track_fx_plugin_ptrs: [max_tracks][max_fx_slots]?*const clap.Plugin,
    missing_track_plugins: [max_tracks]?MissingPlugin,
    missing_track_fx: [max_tracks][max_fx_slots]?MissingPlugin,
    live_key_states: [max_tracks][128]bool,
    previous_key_states: [max_tracks][128]bool,
    live_key_velocities: [max_tracks][128]f32,
    midi_note_states: [128]bool,
    midi_note_velocities: [128]f32,
    keyboard_octave: i8,
    controller: ControllerState,
    controller_param_writes: [max_controller_param_writes]ControllerParamWrite,
    controller_param_write_count: usize,

    // Project file requests (handled by main.zig)
    load_project_request: bool,
    save_project_request: bool,
    save_project_as_request: bool,
    pack_project_request: bool,
    project_path: ?[]u8,
    /// Packed/Bitwig open hydrated to external layout; needs thin Save even if undo clean.
    needs_thin_save: bool,

    // Browser sidebar
    browser_open: bool = true,
    browser_width: f32 = 600.0,
    browser_search: [64:0]u8 = @splat(0),
    browser_sort_asc: bool = true,
    browser_active_tab: browser.BrowserTab = .sounds,
    browser_folders: std.ArrayListUnmanaged([]u8) = .empty,
    browser_file_selected_buf: [1024]u8 = @splat(0),
    browser_file_selected_len: usize = 0,

    // Pending OS file drops (populated by native drop handler, consumed each frame)
    dropped_files: [8][1024]u8 = @splat(@splat(0)),
    dropped_file_lens: [8]usize = @splat(0),
    dropped_file_count: usize = 0,

    // Undo/redo history
    undo_history: undo.UndoHistory,
    preset_catalog: ?*presets.PresetCatalog = null,
    instrument_search_buf: [64:0]u8 = @splat(0),
    preset_search_buf: [128:0]u8 = @splat(0),
    fx_search_buf: [64:0]u8 = @splat(0),

    // Preset load request (handled by main.zig)
    preset_load_request: ?PresetLoadRequest = null,

    // BPM drag tracking for undo
    bpm_drag_active: bool = false,
    bpm_drag_start: f32 = 0,

    // Quantize tracking for undo
    quantize_last: i32 = piano_roll_types.default_quantize_index,

    // Plugin state restore request (processed by main.zig)
    plugin_state_restore_request: ?PluginStateRestoreRequest = null,

    // Device chain structural edit (processed by main.zig)
    chain_op_request: ?ChainOpRequest = null,

    pub const PluginStateRestoreRequest = struct {
        track_index: usize,
        /// null = instrument; Some = FX slot index
        fx_index: ?usize = null,
        state_data: []const u8,
        /// True when state_data was allocated for this request (e.g. device
        /// duplication) and must be freed after applying. Undo commands keep
        /// ownership of their buffers and leave this false.
        free_after_use: bool = false,
    };

    pub const PresetLoadRequest = struct {
        track_index: usize,
        plugin_id: []const u8,
        location_kind: clap.preset_discovery.Location.Kind,
        location: [:0]const u8,
        load_key: ?[:0]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) State {
        var track_plugins_data: [max_tracks]TrackPluginUI = undefined;
        for (&track_plugins_data) |*plugin| {
            plugin.* = .{
                .choice_index = 0,
                .gui_open = false,
                .last_valid_choice = 0,
            };
        }
        var track_fx_data: [max_tracks][max_fx_slots]TrackPluginUI = undefined;
        for (&track_fx_data) |*track| {
            for (track) |*plugin| {
                plugin.* = .{
                    .choice_index = 0,
                    .gui_open = false,
                    .last_valid_choice = 0,
                };
            }
        }
        return .{
            .allocator = allocator,
            .playing = false,
            .metronome_enabled = false,
            .bpm = 120.0,
            .time_signature_numerator = 4,
            .time_signature_denominator = 4,
            .quantize_index = piano_roll_types.default_quantize_index,
            .buffer_frames = default_buffer_frames,
            .buffer_frames_requested = false,
            .dsp_load_pct = 0,
            .track_levels = @splat(.{ 0, 0 }),
            .bottom_mode = .device,
            .bottom_panel_height = 300.0,
            .splitter_drag_start = 0.0,
            .view_mode = .session,
            .arrangement = arr_types.ArrangementView.init(allocator),
            .arrangement_scroll = .{},
            .device_kind = .none,
            .device_clap_plugin = null,
            .device_clap_name = "",
            .device_target_kind = .instrument,
            .device_target_track = 0,
            .device_target_fx = 0,
            .playhead_beat = 0,
            .focused_pane = .session,
            .session = session_ops.init(allocator),
            .piano_state = piano_roll_types.PianoRollState.init(allocator),
            .clip_pool = ClipPool.init(allocator),
            .scratch_clip = PianoRollClip.init(allocator),
            .sample_store = SampleStore.init(allocator),
            .track_plugins = track_plugins_data,
            .track_fx = track_fx_data,
            .track_fx_slot_count = @splat(1),
            .plugin_items = plugin_items,
            .plugin_fx_items = &[_:0]u8{},
            .plugin_fx_indices = &[_]i32{},
            .plugin_instrument_items = &[_:0]u8{},
            .plugin_instrument_indices = &[_]i32{},
            .instrument_filter_items_z = &[_:0]u8{},
            .instrument_filter_indices = &[_]i32{},
            .preset_filter_items_z = &[_:0]u8{},
            .preset_filter_indices = &[_]i32{},
            .plugin_divider_index = null,
            .track_plugin_ptrs = @splat(null),
            .track_fx_plugin_ptrs = @splat(@splat(null)),
            .missing_track_plugins = @splat(null),
            .missing_track_fx = @splat(@splat(null)),
            .live_key_states = @splat(@splat(false)),
            .previous_key_states = @splat(@splat(false)),
            .live_key_velocities = @splat(@splat(0.0)),
            .midi_note_states = @splat(false),
            .midi_note_velocities = @splat(0.0),
            .keyboard_octave = 0,
            .controller = .{},
            .controller_param_writes = @splat(.{
                .track_index = 0,
                .target_fx_index = -1,
                .param_id = 0,
                .value = 0.0,
            }),
            .controller_param_write_count = 0,
            .load_project_request = false,
            .save_project_request = false,
            .save_project_as_request = false,
            .pack_project_request = false,
            .project_path = null,
            .needs_thin_save = false,
            .undo_history = undo.UndoHistory.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        if (self.project_path) |path| {
            self.allocator.free(path);
        }
        if (self.instrument_filter_items_z.len > 0) {
            self.allocator.free(self.instrument_filter_items_z);
        }
        if (self.instrument_filter_indices.len > 0) {
            self.allocator.free(self.instrument_filter_indices);
        }
        if (self.preset_filter_items_z.len > 0) {
            self.allocator.free(self.preset_filter_items_z);
        }
        if (self.preset_filter_indices.len > 0) {
            self.allocator.free(self.preset_filter_indices);
        }
        self.clearMissingPlugins();
        // Order matters: undo history holds audio snapshots that free samples
        // into the store; the clipboard releases dupes into the pool; the pool
        // frees remaining clip content (and its samples) — all before the
        // sample store and scratch clip go away.
        self.undo_history.deinit();
        session_ops.deinit(&self.session);
        // Arrangement placements hold pool references; release them before the
        // pool frees remaining clip content (and its samples).
        self.arrangement.deinit();
        self.clip_pool.deinit(&self.sample_store);
        self.scratch_clip.deinit();
        self.sample_store.deinit();
        self.piano_state.deinit();
        for (self.browser_folders.items) |f| self.allocator.free(f);
        self.browser_folders.deinit(self.allocator);
    }

    /// Wire back-references from sub-structs into this State. Must be called
    /// once after `State` reaches its final address (see main.zig), because
    /// `init` returns by value and any address taken during it would dangle.
    pub fn wireInternalRefs(self: *State) void {
        self.session.clip_pool = &self.clip_pool;
        self.session.sample_store = &self.sample_store;
        self.arrangement.clip_pool = &self.clip_pool;
        self.arrangement.sample_store = &self.sample_store;
    }

    // ── Clip-pool slot accessors ────────────────────────────────────────
    // A session slot references at most one pooled clip (midi OR audio).

    /// The pooled clip a slot references, or null when empty/stale.
    pub fn slotClip(self: *State, track: usize, scene: usize) ?*clip_pool_mod.Clip {
        return self.clip_pool.get(self.session.clips[track][scene].clip);
    }

    /// The slot's MIDI content, or null if the slot is empty or holds audio.
    pub fn slotPiano(self: *State, track: usize, scene: usize) ?*PianoRollClip {
        if (self.slotClip(track, scene)) |c| {
            if (c.content == .midi) return &c.content.midi;
        }
        return null;
    }

    /// The slot's audio content, or null if the slot is empty or holds MIDI.
    pub fn slotAudio(self: *State, track: usize, scene: usize) ?*AudioClip {
        if (self.slotClip(track, scene)) |c| {
            if (c.content == .audio) return &c.content.audio;
        }
        return null;
    }

    /// Const accessors mirroring `slotClip`/`slotPiano`/`slotAudio` for
    /// read-only callers such as project save.
    pub fn slotClipConst(self: *const State, track: usize, scene: usize) ?*const clip_pool_mod.Clip {
        return self.clip_pool.getConst(self.session.clips[track][scene].clip);
    }
    pub fn slotPianoConst(self: *const State, track: usize, scene: usize) ?*const PianoRollClip {
        if (self.slotClipConst(track, scene)) |c| {
            if (c.content == .midi) return &c.content.midi;
        }
        return null;
    }
    pub fn slotAudioConst(self: *const State, track: usize, scene: usize) ?*const AudioClip {
        if (self.slotClipConst(track, scene)) |c| {
            if (c.content == .audio) return &c.content.audio;
        }
        return null;
    }

    /// Intrinsic length (beats) of the clip a slot references, or the default
    /// when empty.
    pub fn slotLengthBeats(self: *State, track: usize, scene: usize) f32 {
        if (self.slotClip(track, scene)) |c| return c.lengthBeats();
        return session_constants.default_clip_bars * self.beatsPerBar();
    }

    /// True when the slot holds an audio clip with a loaded sample.
    pub fn slotHasAudio(self: *State, track: usize, scene: usize) bool {
        if (self.slotAudio(track, scene)) |a| return a.hasAudio();
        return false;
    }

    /// Drop a slot's reference to its pooled clip and mark it empty. Callers
    /// that need the old content for undo must capture it before calling.
    pub fn releaseSlotClip(self: *State, track: usize, scene: usize) void {
        const slot = &self.session.clips[track][scene];
        if (!slot.clip.isNone()) {
            self.clip_pool.release(slot.clip, &self.sample_store);
        }
        slot.* = .{};
    }

    /// Create a fresh MIDI clip in the pool (refcount 1) of the given length,
    /// or `.none` on allocation failure.
    fn makeMidiClip(self: *State, length_beats: f32) ClipId {
        var pc = PianoRollClip.init(self.allocator);
        if (length_beats > 0) pc.length_beats = length_beats;
        const id = self.clip_pool.addMidi(pc) catch {
            pc.deinit();
            return ClipId.none;
        };
        self.clip_pool.retain(id);
        return id;
    }

    /// Resolve (or materialize) the slot's MIDI content, converting a prior
    /// audio clip to MIDI. Falls back to a scratch clip on allocation failure.
    pub fn ensureSlotPiano(self: *State, track: usize, scene: usize) *PianoRollClip {
        if (self.slotClip(track, scene)) |c| {
            if (c.content == .midi) return &c.content.midi;
        }
        // Empty or wrong kind: replace with a fresh MIDI clip.
        const prev_len = if (self.slotClip(track, scene)) |c| c.lengthBeats() else 0;
        self.releaseSlotClip(track, scene);
        const id = self.makeMidiClip(prev_len);
        if (id.isNone()) {
            self.scratch_clip.clear();
            return &self.scratch_clip;
        }
        self.session.clips[track][scene].clip = id;
        if (self.session.clips[track][scene].state == .empty) {
            self.session.clips[track][scene].state = .stopped;
        }
        return &self.clip_pool.get(id).?.content.midi;
    }

    /// Resolve (or materialize) the slot's audio content, converting a prior
    /// MIDI clip to audio. Returns null on allocation failure.
    pub fn ensureSlotAudio(self: *State, track: usize, scene: usize) ?*AudioClip {
        if (self.slotClip(track, scene)) |c| {
            if (c.content == .audio) return &c.content.audio;
        }
        const prev_len = if (self.slotClip(track, scene)) |c| c.lengthBeats() else 0;
        self.releaseSlotClip(track, scene);
        var ac = AudioClip.init(self.allocator);
        if (prev_len > 0) ac.length_beats = prev_len;
        const id = self.clip_pool.addAudio(ac) catch {
            ac.deinit(&self.sample_store);
            return null;
        };
        self.clip_pool.retain(id);
        self.session.clips[track][scene].clip = id;
        if (self.session.clips[track][scene].state == .empty) {
            self.session.clips[track][scene].state = .stopped;
        }
        return &self.clip_pool.get(id).?.content.audio;
    }

    /// Release every session slot's pooled clip and mark it empty. Used on a
    /// fresh project load to reset all clip content in one pass.
    pub fn resetSessionClips(self: *State) void {
        for (0..max_tracks) |t| {
            for (0..max_scenes) |s| self.releaseSlotClip(t, s);
        }
    }

    /// Release every audio-kind slot's clip (used on project (re)load).
    pub fn clearAllAudioClips(self: *State) void {
        for (0..max_tracks) |t| {
            for (0..max_scenes) |s| {
                if (self.slotAudio(t, s) != null) self.releaseSlotClip(t, s);
            }
        }
    }

    pub fn selectedTrack(self: *const State) usize {
        return self.session.primary_track;
    }

    pub fn selectedScene(self: *const State) usize {
        return self.session.primary_scene;
    }

    pub fn currentClip(self: *State) *PianoRollClip {
        const track = self.selectedTrack();
        const scene = self.selectedScene();
        // Empty slots have no clip to edit; return a cleared scratch clip so
        // callers always get a valid, non-persisted pointer (the piano roll is
        // only shown for non-empty MIDI slots, see ui/draw.zig).
        if (self.session.clips[track][scene].state == .empty) {
            self.scratch_clip.clear();
            return &self.scratch_clip;
        }
        return self.ensureSlotPiano(track, scene);
    }

    pub fn currentClipLabel(self: *const State) []const u8 {
        return self.session.scenes[self.selectedScene()].getName();
    }

    /// True if any scene on this track holds an audio sample.
    pub fn trackHasAudio(self: *const State, track: usize) bool {
        if (track >= max_tracks) return false;
        const scene_count = @min(self.session.scene_count, max_scenes);
        for (0..scene_count) |s| {
            if (self.slotAudioConst(track, s)) |a| {
                if (a.hasAudio()) return true;
            }
        }
        return false;
    }

    /// True if any scene holds MIDI notes or a non-empty non-audio slot.
    pub fn trackHasNotes(self: *const State, track: usize) bool {
        if (track >= max_tracks) return false;
        const scene_count = @min(self.session.scene_count, max_scenes);
        for (0..scene_count) |s| {
            if (self.slotAudioConst(track, s)) |a| {
                if (a.hasAudio()) continue;
            }
            if (self.slotPianoConst(track, s)) |p| {
                if (p.notes.items.len > 0) return true;
            }
            if (self.session.clips[track][s].state != .empty) return true;
        }
        return false;
    }

    /// Exclusive slot: make the cell an audio clip (drops any MIDI content).
    pub fn claimSlotForAudio(self: *State, track: usize, scene: usize) void {
        if (track >= max_tracks or scene >= max_scenes) return;
        _ = self.ensureSlotAudio(track, scene);
    }

    /// Exclusive slot: make the cell a MIDI clip (drops any sample).
    pub fn claimSlotForMidi(self: *State, track: usize, scene: usize) void {
        if (track >= max_tracks or scene >= max_scenes) return;
        _ = self.ensureSlotPiano(track, scene);
    }

    pub fn beatsPerBar(self: *const State) f32 {
        return @as(f32, @floatFromInt(self.time_signature_numerator)) * 4.0 /
            @as(f32, @floatFromInt(self.time_signature_denominator));
    }

    pub fn clearControllerParamWrites(self: *State) void {
        self.controller_param_write_count = 0;
    }

    pub fn pushControllerParamWrite(self: *State, write: ControllerParamWrite) void {
        var i: usize = 0;
        while (i < self.controller_param_write_count) : (i += 1) {
            var existing = &self.controller_param_writes[i];
            if (existing.track_index == write.track_index and
                existing.target_fx_index == write.target_fx_index and
                existing.param_id == write.param_id)
            {
                existing.value = write.value;
                return;
            }
        }
        if (self.controller_param_write_count >= self.controller_param_writes.len) return;
        self.controller_param_writes[self.controller_param_write_count] = write;
        self.controller_param_write_count += 1;
    }

    pub fn setProjectPath(self: *State, path: []const u8) !void {
        if (self.project_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.project_path = try self.allocator.dupe(u8, path);
    }

    /// Dirty = undo past save point, or opened packed project not yet thin-saved.
    pub fn isProjectDirty(self: *const State) bool {
        return self.needs_thin_save or self.undo_history.hasUnsavedChanges();
    }

    pub fn clearProjectDirty(self: *State) void {
        self.needs_thin_save = false;
        self.undo_history.markSavePoint();
    }

    pub fn markProjectDirty(self: *State) void {
        self.needs_thin_save = true;
    }

    pub fn clearMissingTrackPlugin(self: *State, track_index: usize) void {
        if (self.missing_track_plugins[track_index]) |*plugin| {
            plugin.deinit(self.allocator);
            self.missing_track_plugins[track_index] = null;
        }
    }

    pub fn clearMissingTrackFx(self: *State, track_index: usize, fx_index: usize) void {
        if (self.missing_track_fx[track_index][fx_index]) |*plugin| {
            plugin.deinit(self.allocator);
            self.missing_track_fx[track_index][fx_index] = null;
        }
    }

    pub fn clearMissingPlugins(self: *State) void {
        for (0..max_tracks) |track_index| {
            self.clearMissingTrackPlugin(track_index);
            for (0..max_fx_slots) |fx_index| {
                self.clearMissingTrackFx(track_index, fx_index);
            }
        }
    }

    /// Perform undo operation
    pub fn performUndo(self: *State) bool {
        const cmd = self.undo_history.popForUndo() orelse return false;
        self.executeCommand(cmd, .undo);
        self.undo_history.confirmUndo();
        return true;
    }

    /// Perform redo operation
    pub fn performRedo(self: *State) bool {
        const cmd = self.undo_history.popForRedo() orelse return false;
        self.executeCommand(cmd, .redo);
        self.undo_history.confirmRedo();
        return true;
    }

    const UndoDirection = enum { undo, redo };

    /// Rebuild a session slot's pooled content from an undo snapshot. The
    /// snapshot's audio payload determines the kind: a loaded sample restores
    /// an audio clip, otherwise a MIDI clip with the captured notes.
    fn restoreSlotFromSnapshot(
        self: *State,
        track: usize,
        scene: usize,
        has_clip: bool,
        length_beats: f32,
        name: session_view.NameField,
        notes: []const piano_roll_types.Note,
        audio: *const audio_clip_types.AudioClipSnapshot,
    ) void {
        self.releaseSlotClip(track, scene);
        if (!has_clip) return;
        if (audio.clip.hasAudio()) {
            const a = self.ensureSlotAudio(track, scene) orelse return;
            audio.apply(a) catch {};
            if (length_beats > 0) a.length_beats = length_beats;
        } else {
            const p = self.ensureSlotPiano(track, scene);
            p.clear();
            for (notes) |note| p.addNote(note.pitch, note.start, note.duration) catch {};
            if (length_beats > 0) p.length_beats = length_beats;
        }
        if (self.slotClip(track, scene)) |c| c.name = name;
    }

    fn executeCommand(self: *State, cmd: *const undo.Command, comptime direction: UndoDirection) void {
        switch (cmd.*) {
            .clip_create => |c| {
                if (direction == .undo) {
                    self.releaseSlotClip(c.track, c.scene);
                } else {
                    self.releaseSlotClip(c.track, c.scene);
                    const id = self.makeMidiClip(c.length_beats);
                    if (!id.isNone()) {
                        self.session.clips[c.track][c.scene] = .{ .state = .stopped, .clip = id };
                    }
                }
            },
            .clip_delete => |c| {
                if (direction == .undo) {
                    self.restoreSlotFromSnapshot(c.track, c.scene, true, c.length_beats, c.name, c.notes, &c.audio);
                } else {
                    self.releaseSlotClip(c.track, c.scene);
                }
            },
            .clip_paste => |c| {
                const slot = if (direction == .undo) c.old_clip else c.new_clip;
                const notes = if (direction == .undo) c.old_notes else c.new_notes;
                const audio = if (direction == .undo) &c.old_audio else &c.new_audio;
                self.restoreSlotFromSnapshot(c.track, c.scene, slot.has_clip, slot.length_beats, slot.name, notes, audio);
            },
            .note_add => |c| {
                if (direction == .undo) {
                    const clip = self.ensureSlotPiano(c.track, c.scene);
                    if (c.note_index < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(c.note_index);
                    }
                } else {
                    const clip = self.ensureSlotPiano(c.track, c.scene);
                    if (c.note_index <= clip.notes.items.len) {
                        clip.notes.insert(clip.allocator, c.note_index, c.note) catch {
                            clip.addFullNote(c.note) catch {};
                        };
                    } else {
                        clip.addFullNote(c.note) catch {};
                    }
                }
            },
            .note_remove => |c| {
                if (direction == .undo) {
                    const clip = self.ensureSlotPiano(c.track, c.scene);
                    clip.notes.insert(clip.allocator, c.note_index, c.note) catch {
                        clip.addFullNote(c.note) catch {};
                    };
                } else {
                    const clip = self.ensureSlotPiano(c.track, c.scene);
                    if (c.note_index < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(c.note_index);
                    }
                }
            },
            .note_move => |c| {
                const clip = self.ensureSlotPiano(c.track, c.scene);
                if (c.note_index < clip.notes.items.len) {
                    clip.notes.items[c.note_index].start = if (direction == .undo) c.old_start else c.new_start;
                    clip.notes.items[c.note_index].pitch = if (direction == .undo) c.old_pitch else c.new_pitch;
                }
            },
            .note_resize => |c| {
                const clip = self.ensureSlotPiano(c.track, c.scene);
                if (c.note_index < clip.notes.items.len) {
                    clip.notes.items[c.note_index].duration = if (direction == .undo) c.old_duration else c.new_duration;
                }
            },
            .note_batch => |c| {
                if (direction == .undo) {
                    const clip = self.ensureSlotPiano(c.track, c.scene);
                    const remove_count = @min(c.notes.len, clip.notes.items.len);
                    clip.notes.shrinkRetainingCapacity(clip.notes.items.len - remove_count);
                } else {
                    const clip = self.ensureSlotPiano(c.track, c.scene);
                    for (c.notes) |note| {
                        clip.addFullNote(note) catch {};
                    }
                }
            },
            .notes_replace => |c| {
                const clip = self.ensureSlotPiano(c.track, c.scene);
                const notes = if (direction == .undo) c.old_notes else c.new_notes;
                clip.notes.clearRetainingCapacity();
                for (notes) |note| {
                    clip.addFullNote(note) catch {};
                }
                const timing = if (direction == .undo) c.old_timing else c.new_timing;
                clip.length_beats = timing.length;
                clip.play_start_beats = timing.play_start;
                clip.loop_start_beats = timing.loop_start;
                clip.loop_end_beats = timing.loop_end;
            },
            .track_add => |c| {
                if (direction == .undo) {
                    if (self.session.track_count > 1) {
                        self.session.track_count -= 1;
                    }
                } else {
                    if (self.session.track_count < max_tracks) {
                        self.session.tracks[self.session.track_count] = .{};
                        self.session.tracks[self.session.track_count].name = c.name;
                        self.session.track_count += 1;
                    }
                }
            },
            .track_rename => |c| {
                self.session.tracks[c.track_index].name = if (direction == .undo) c.old_name else c.new_name;
            },
            .track_volume => |c| {
                self.session.tracks[c.track_index].volume = if (direction == .undo) c.old_volume else c.new_volume;
            },
            .track_mute => |c| {
                self.session.tracks[c.track_index].mute = if (direction == .undo) c.old_mute else c.new_mute;
            },
            .track_solo => |c| {
                self.session.tracks[c.track_index].solo = if (direction == .undo) c.old_solo else c.new_solo;
            },
            .scene_add => |c| {
                if (direction == .undo) {
                    if (self.session.scene_count > 1) {
                        self.session.scene_count -= 1;
                    }
                } else {
                    if (self.session.scene_count < max_scenes) {
                        self.session.scenes[self.session.scene_count] = .{};
                        self.session.scenes[self.session.scene_count].name = c.name;
                        self.session.scene_count += 1;
                    }
                }
            },
            .scene_rename => |c| {
                self.session.scenes[c.scene_index].name = if (direction == .undo) c.old_name else c.new_name;
            },
            .clip_rename => |c| {
                const name = if (direction == .undo) c.old_name else c.new_name;
                if (self.slotClip(c.track, c.scene)) |clip| clip.name = name;
            },
            .bpm_change => |c| {
                self.bpm = if (direction == .undo) c.old_bpm else c.new_bpm;
            },
            .quantize_change => |c| {
                self.quantize_index = if (direction == .undo) c.old_index else c.new_index;
                self.quantize_last = if (direction == .undo) c.old_index else c.new_index;
            },
            .clip_move => |c| {
                self.moveClipPayloads(c.moves, direction == .undo);
            },
            .clip_resize => |c| {
                const length = if (direction == .undo) c.old_length else c.new_length;
                if (self.slotClip(c.track, c.scene)) |clip| {
                    switch (clip.content) {
                        .midi => |*m| m.length_beats = length,
                        .audio => |*a| a.length_beats = length,
                    }
                }
            },
            .plugin_state => |c| {
                self.plugin_state_restore_request = .{
                    .track_index = c.track_index,
                    .fx_index = c.fx_index,
                    .state_data = if (direction == .undo) c.old_state else c.new_state,
                };
            },
            .arrangement_edit => |*c| {
                arr_undo.execute(&self.arrangement, c, if (direction == .undo) .undo else .redo);
            },
            .arrangement_track_add => |c| {
                arr_undo.executeTrackAdd(&self.arrangement, c, if (direction == .undo) .undo else .redo);
            },
            .arrangement_track_reorder => |c| {
                if (direction == .undo) {
                    arr_ops.reorderTrack(&self.arrangement, c.to, c.from);
                } else {
                    arr_ops.reorderTrack(&self.arrangement, c.from, c.to);
                }
            },
            .track_delete => |c| {
                if (direction == .undo) {
                    self.insertTrackInState(&c);
                } else {
                    self.deleteTrackInState(c.track_index);
                }
            },
            .scene_delete => |c| {
                if (direction == .undo) {
                    self.insertSceneInState(&c);
                } else {
                    self.deleteSceneInState(c.scene_index);
                }
            },
        }
    }

    fn moveClipPayloads(self: *State, moves: []const undo.command.ClipMoveCmd.ClipMove, reverse: bool) void {
        // Content travels with each slot's ClipId, so a move is just moving the
        // ClipSlot value. Lift all sources first (in case source and dest sets
        // overlap), then drop them at their destinations.
        var slots: [max_tracks * max_scenes]@TypeOf(self.session.clips[0][0]) = undefined;

        for (moves, 0..) |move, i| {
            const src_track = if (reverse) move.dst_track else move.src_track;
            const src_scene = if (reverse) move.dst_scene else move.src_scene;
            slots[i] = self.session.clips[src_track][src_scene];
            self.session.clips[src_track][src_scene] = .{}; // move out (handle carried in `slots[i]`)
        }

        for (moves, 0..) |move, i| {
            const dst_track = if (reverse) move.src_track else move.dst_track;
            const dst_scene = if (reverse) move.src_scene else move.dst_scene;
            self.releaseSlotClip(dst_track, dst_scene); // free any clip displaced at the destination
            self.session.clips[dst_track][dst_scene] = slots[i];
        }
    }

    fn deleteTrackInState(self: *State, track: usize) void {
        if (self.session.track_count <= 1) return;
        if (track >= self.session.track_count) return;

        for (0..self.session.scene_count) |s| {
            session_ops.deselectClip(&self.session, track, s);
        }
        // Release the deleted track's pooled clips before the shift overwrites
        // them (content lives in the pool, referenced by ClipId in each slot).
        for (0..max_scenes) |s| self.releaseSlotClip(track, s);
        for (track..self.session.track_count - 1) |t| {
            self.session.tracks[t] = self.session.tracks[t + 1];
            for (0..max_scenes) |s| {
                self.session.clips[t][s] = self.session.clips[t + 1][s];
                self.session.clip_selected[t][s] = self.session.clip_selected[t + 1][s];
            }
        }
        for (0..max_scenes) |s| {
            self.session.clips[self.session.track_count - 1][s] = .{}; // moved out by shift
            self.session.clip_selected[self.session.track_count - 1][s] = false;
        }
        self.session.track_count -= 1;
        if (self.session.primary_track >= self.session.track_count) {
            self.session.primary_track = self.session.track_count - 1;
        }
    }

    fn deleteSceneInState(self: *State, scene: usize) void {
        if (self.session.scene_count <= 1) return;
        if (scene >= self.session.scene_count) return;

        for (0..self.session.track_count) |t| {
            session_ops.deselectClip(&self.session, t, scene);
        }
        for (0..max_tracks) |t| self.releaseSlotClip(t, scene);
        for (scene..self.session.scene_count - 1) |s| {
            self.session.scenes[s] = self.session.scenes[s + 1];
            for (0..max_tracks) |t| {
                self.session.clips[t][s] = self.session.clips[t][s + 1];
                self.session.clip_selected[t][s] = self.session.clip_selected[t][s + 1];
            }
        }
        for (0..max_tracks) |t| {
            self.session.clips[t][self.session.scene_count - 1] = .{}; // moved out by shift
            self.session.clip_selected[t][self.session.scene_count - 1] = false;
        }
        self.session.scene_count -= 1;
        if (self.session.primary_scene >= self.session.scene_count) {
            self.session.primary_scene = self.session.scene_count - 1;
        }
    }

    fn insertTrackInState(self: *State, cmd: *const undo.command.TrackDeleteCmd) void {
        if (self.session.track_count >= max_tracks) return;

        var t = self.session.track_count;
        while (t > cmd.track_index) : (t -= 1) {
            self.session.tracks[t] = self.session.tracks[t - 1];
            for (0..max_scenes) |s| {
                // ClipId carries content, so shifting the slot shifts the clip.
                self.session.clips[t][s] = self.session.clips[t - 1][s];
                self.session.clip_selected[t][s] = self.session.clip_selected[t - 1][s];
                self.session.clips[t - 1][s] = .{}; // moved out
            }
        }

        self.session.tracks[cmd.track_index] = .{
            .name = cmd.track_data.name,
            .volume = cmd.track_data.volume,
            .pan = cmd.track_data.pan,
            .mute = cmd.track_data.mute,
            .solo = cmd.track_data.solo,
        };
        for (0..max_scenes) |s| {
            const slot = cmd.clips[s];
            self.session.clip_selected[cmd.track_index][s] = false;
            const notes: []const piano_roll_types.Note = if (s < cmd.notes.len) cmd.notes[s] else &.{};
            self.restoreSlotFromSnapshot(cmd.track_index, s, slot.has_clip, slot.length_beats, slot.name, notes, &cmd.audio[s]);
        }

        self.session.track_count += 1;
        if (self.session.primary_track >= self.session.track_count) {
            self.session.primary_track = self.session.track_count - 1;
        }
    }

    fn insertSceneInState(self: *State, cmd: *const undo.command.SceneDeleteCmd) void {
        if (self.session.scene_count >= max_scenes) return;

        var s = self.session.scene_count;
        while (s > cmd.scene_index) : (s -= 1) {
            self.session.scenes[s] = self.session.scenes[s - 1];
            for (0..max_tracks) |t| {
                self.session.clips[t][s] = self.session.clips[t][s - 1];
                self.session.clip_selected[t][s] = self.session.clip_selected[t][s - 1];
                self.session.clips[t][s - 1] = .{}; // moved out
            }
        }

        self.session.scenes[cmd.scene_index] = .{
            .name = cmd.scene_data.name,
        };
        for (0..max_tracks) |t| {
            const slot = cmd.clips[t];
            self.session.clip_selected[t][cmd.scene_index] = false;
            const notes: []const piano_roll_types.Note = if (t < cmd.notes.len) cmd.notes[t] else &.{};
            self.restoreSlotFromSnapshot(t, cmd.scene_index, slot.has_clip, slot.length_beats, slot.name, notes, &cmd.audio[t]);
        }

        self.session.scene_count += 1;
        if (self.session.primary_scene >= self.session.scene_count) {
            self.session.primary_scene = self.session.scene_count - 1;
        }
    }
};

const plugin_items: [:0]const u8 = "None\x00ZSynth\x00";
