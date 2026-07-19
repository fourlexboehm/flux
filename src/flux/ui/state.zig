const std = @import("std");
const clap = @import("clap-bindings");
const presets = @import("../plugin/presets.zig");

const undo = @import("../undo/root.zig");
const session_view = @import("../session/types.zig");
const session_constants = @import("../session/constants.zig");
const session_ops = @import("../session/ops.zig");
const piano_roll_types = @import("../session/notes.zig");
const audio_clip_types = @import("../session/audio_clip.zig");
const sample_store_mod = @import("../audio/sample_store.zig");
const arr_types = @import("../arrangement/types.zig");
const arr_undo = @import("../arrangement/undo.zig");
const arr_ops = @import("../arrangement/ops.zig");
const arr_draw = @import("views/arrangement/draw.zig");

const SessionView = session_view.SessionView;
const max_tracks = session_constants.max_tracks;
const max_scenes = session_constants.max_scenes;
const SampleStore = sample_store_mod.SampleStore;
const AudioClip = audio_clip_types.AudioClip;

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

    // Piano clips storage (separate from session view's clip metadata)
    piano_clips: [max_tracks][max_scenes]piano_roll_types.PianoRollClip,

    // Audio clips (parallel to piano_clips; one content type per slot preferred)
    audio_clips: [max_tracks][max_scenes]AudioClip,
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

    // Undo/redo history
    undo_history: undo.UndoHistory,
    preset_catalog: ?*const presets.PresetCatalog = null,
    instrument_search_buf: [64:0]u8 = @splat(0),
    preset_search_buf: [128:0]u8 = @splat(0),

    // Preset load request (handled by main.zig)
    preset_load_request: ?PresetLoadRequest = null,

    // BPM drag tracking for undo
    bpm_drag_active: bool = false,
    bpm_drag_start: f32 = 0,

    // Quantize tracking for undo
    quantize_last: i32 = 2,

    // Plugin state restore request (processed by main.zig)
    plugin_state_restore_request: ?PluginStateRestoreRequest = null,

    pub const PluginStateRestoreRequest = struct {
        track_index: usize,
        /// null = instrument; Some = FX slot index
        fx_index: ?usize = null,
        state_data: []const u8,
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
        var piano_clips_data: [max_tracks][max_scenes]piano_roll_types.PianoRollClip = undefined;
        for (&piano_clips_data) |*track_clips| {
            for (track_clips) |*clip| {
                clip.* = piano_roll_types.PianoRollClip.init(allocator);
            }
        }
        var audio_clips_data: [max_tracks][max_scenes]AudioClip = undefined;
        for (&audio_clips_data) |*track_clips| {
            for (track_clips) |*clip| {
                clip.* = AudioClip.init(allocator);
            }
        }

        return .{
            .allocator = allocator,
            .playing = false,
            .metronome_enabled = false,
            .bpm = 120.0,
            .time_signature_numerator = 4,
            .time_signature_denominator = 4,
            .quantize_index = 2,
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
            .piano_clips = piano_clips_data,
            .audio_clips = audio_clips_data,
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
        self.undo_history.deinit();
        for (&self.piano_clips) |*track_clips| {
            for (track_clips) |*clip| {
                clip.deinit();
            }
        }
        for (&self.audio_clips) |*track_clips| {
            for (track_clips) |*clip| {
                clip.deinit(&self.sample_store);
            }
        }
        self.sample_store.deinit();
        session_ops.deinit(&self.session);
        self.piano_state.deinit();
        self.arrangement.deinit();
    }

    pub fn clearAllAudioClips(self: *State) void {
        for (&self.audio_clips) |*track_clips| {
            for (track_clips) |*clip| {
                clip.clear(&self.sample_store);
            }
        }
    }

    pub fn selectedTrack(self: *const State) usize {
        return self.session.primary_track;
    }

    pub fn selectedScene(self: *const State) usize {
        return self.session.primary_scene;
    }

    pub fn currentClip(self: *State) *piano_roll_types.PianoRollClip {
        return &self.piano_clips[self.selectedTrack()][self.selectedScene()];
    }

    pub fn currentClipLabel(self: *const State) []const u8 {
        return self.session.scenes[self.selectedScene()].getName();
    }

    /// True if any scene on this track holds an audio sample.
    pub fn trackHasAudio(self: *const State, track: usize) bool {
        if (track >= max_tracks) return false;
        const scene_count = @min(self.session.scene_count, max_scenes);
        for (0..scene_count) |s| {
            if (self.audio_clips[track][s].hasAudio()) return true;
        }
        return false;
    }

    /// True if any scene holds MIDI notes or a non-empty non-audio slot.
    pub fn trackHasNotes(self: *const State, track: usize) bool {
        if (track >= max_tracks) return false;
        const scene_count = @min(self.session.scene_count, max_scenes);
        for (0..scene_count) |s| {
            if (self.audio_clips[track][s].hasAudio()) continue;
            if (self.piano_clips[track][s].notes.items.len > 0) return true;
            if (self.session.clips[track][s].state != .empty) return true;
        }
        return false;
    }

    /// Hybrid track, exclusive slot: claim cell for audio (drops MIDI notes).
    pub fn claimSlotForAudio(self: *State, track: usize, scene: usize) void {
        if (track >= max_tracks or scene >= max_scenes) return;
        var piano = &self.piano_clips[track][scene];
        piano.notes.clearRetainingCapacity();
        // Keep length/automation; audio clip owns musical length when playing samples.
    }

    /// Hybrid track, exclusive slot: claim cell for MIDI (drops sample).
    pub fn claimSlotForMidi(self: *State, track: usize, scene: usize) void {
        if (track >= max_tracks or scene >= max_scenes) return;
        self.audio_clips[track][scene].clear(&self.sample_store);
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

    fn executeCommand(self: *State, cmd: *const undo.Command, comptime direction: UndoDirection) void {
        switch (cmd.*) {
            .clip_create => |c| {
                if (direction == .undo) {
                    self.session.clips[c.track][c.scene] = .{};
                    self.piano_clips[c.track][c.scene].clear();
                    self.audio_clips[c.track][c.scene].clear(&self.sample_store);
                } else {
                    self.session.clips[c.track][c.scene] = .{
                        .state = .stopped,
                        .length_beats = c.length_beats,
                    };
                }
            },
            .clip_delete => |c| {
                if (direction == .undo) {
                    self.session.clips[c.track][c.scene] = .{
                        .state = .stopped,
                        .length_beats = c.length_beats,
                        .name = c.name,
                    };
                    self.piano_clips[c.track][c.scene].notes.clearRetainingCapacity();
                    for (c.notes) |note| {
                        self.piano_clips[c.track][c.scene].addNote(note.pitch, note.start, note.duration) catch {};
                    }
                    c.audio.apply(&self.audio_clips[c.track][c.scene]) catch {};
                } else {
                    self.session.clips[c.track][c.scene] = .{};
                    self.piano_clips[c.track][c.scene].clear();
                    self.audio_clips[c.track][c.scene].clear(&self.sample_store);
                }
            },
            .clip_paste => |c| {
                const slot = if (direction == .undo) c.old_clip else c.new_clip;
                const notes = if (direction == .undo) c.old_notes else c.new_notes;
                const audio = if (direction == .undo) &c.old_audio else &c.new_audio;
                if (slot.has_clip) {
                    self.session.clips[c.track][c.scene] = .{
                        .state = .stopped,
                        .length_beats = slot.length_beats,
                        .name = slot.name,
                    };
                    const clip = &self.piano_clips[c.track][c.scene];
                    clip.notes.clearRetainingCapacity();
                    for (notes) |note| {
                        clip.addNote(note.pitch, note.start, note.duration) catch {};
                    }
                } else {
                    self.session.clips[c.track][c.scene] = .{};
                    self.piano_clips[c.track][c.scene].clear();
                    self.audio_clips[c.track][c.scene].clear(&self.sample_store);
                }
                audio.apply(&self.audio_clips[c.track][c.scene]) catch {};
            },
            .note_add => |c| {
                if (direction == .undo) {
                    const clip = &self.piano_clips[c.track][c.scene];
                    if (c.note_index < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(c.note_index);
                    }
                } else {
                    const clip = &self.piano_clips[c.track][c.scene];
                    clip.addNote(c.note.pitch, c.note.start, c.note.duration) catch {};
                }
            },
            .note_remove => |c| {
                if (direction == .undo) {
                    const clip = &self.piano_clips[c.track][c.scene];
                    clip.notes.insert(clip.allocator, c.note_index, c.note) catch {
                        clip.addNote(c.note.pitch, c.note.start, c.note.duration) catch {};
                    };
                } else {
                    const clip = &self.piano_clips[c.track][c.scene];
                    if (c.note_index < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(c.note_index);
                    }
                }
            },
            .note_move => |c| {
                const clip = &self.piano_clips[c.track][c.scene];
                if (c.note_index < clip.notes.items.len) {
                    clip.notes.items[c.note_index].start = if (direction == .undo) c.old_start else c.new_start;
                    clip.notes.items[c.note_index].pitch = if (direction == .undo) c.old_pitch else c.new_pitch;
                }
            },
            .note_resize => |c| {
                const clip = &self.piano_clips[c.track][c.scene];
                if (c.note_index < clip.notes.items.len) {
                    clip.notes.items[c.note_index].duration = if (direction == .undo) c.old_duration else c.new_duration;
                }
            },
            .note_batch => |c| {
                if (direction == .undo) {
                    const clip = &self.piano_clips[c.track][c.scene];
                    const remove_count = @min(c.notes.len, clip.notes.items.len);
                    clip.notes.shrinkRetainingCapacity(clip.notes.items.len - remove_count);
                } else {
                    const clip = &self.piano_clips[c.track][c.scene];
                    for (c.notes) |note| {
                        clip.addNote(note.pitch, note.start, note.duration) catch {};
                    }
                }
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
                self.session.clips[c.track][c.scene].name = name;
                self.audio_clips[c.track][c.scene].name = name;
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
                self.session.clips[c.track][c.scene].length_beats = length;
                self.piano_clips[c.track][c.scene].length_beats = length;
                self.audio_clips[c.track][c.scene].length_beats = length;
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
        var slots: [max_tracks * max_scenes]@TypeOf(self.session.clips[0][0]) = undefined;
        var piano: [max_tracks * max_scenes]piano_roll_types.PianoRollClip = undefined;
        var audio: [max_tracks * max_scenes]AudioClip = undefined;

        for (moves, 0..) |move, i| {
            const src_track = if (reverse) move.dst_track else move.src_track;
            const src_scene = if (reverse) move.dst_scene else move.src_scene;
            slots[i] = self.session.clips[src_track][src_scene];
            self.session.clips[src_track][src_scene] = .{};
            piano[i] = self.piano_clips[src_track][src_scene];
            self.piano_clips[src_track][src_scene] = piano_roll_types.PianoRollClip.init(self.allocator);
            audio[i] = self.audio_clips[src_track][src_scene];
            self.audio_clips[src_track][src_scene] = AudioClip.init(self.allocator);
        }

        for (moves, 0..) |move, i| {
            const dst_track = if (reverse) move.src_track else move.dst_track;
            const dst_scene = if (reverse) move.src_scene else move.dst_scene;
            self.session.clips[dst_track][dst_scene] = slots[i];
            self.piano_clips[dst_track][dst_scene].deinit();
            self.piano_clips[dst_track][dst_scene] = piano[i];
            self.audio_clips[dst_track][dst_scene].takeFrom(&audio[i], &self.sample_store);
        }
    }

    pub fn deleteTrackPianoClips(self: *State, track: usize, old_track_count: usize) void {
        if (track >= old_track_count) return;
        for (0..max_scenes) |s| {
            self.piano_clips[track][s].deinit();
            self.audio_clips[track][s].clear(&self.sample_store);
        }
        if (track + 1 > old_track_count - 1) return;
        for (track..old_track_count - 1) |t| {
            for (0..max_scenes) |s| {
                self.piano_clips[t][s] = self.piano_clips[t + 1][s];
                self.piano_clips[t + 1][s] = piano_roll_types.PianoRollClip.init(self.allocator);
                self.audio_clips[t][s].takeFrom(&self.audio_clips[t + 1][s], &self.sample_store);
            }
        }
    }

    pub fn deleteScenePianoClips(self: *State, scene: usize, old_scene_count: usize) void {
        if (scene >= old_scene_count) return;
        for (0..max_tracks) |t| {
            self.piano_clips[t][scene].deinit();
            self.audio_clips[t][scene].clear(&self.sample_store);
        }
        if (scene + 1 > old_scene_count - 1) return;
        for (0..max_tracks) |t| {
            for (scene..old_scene_count - 1) |s| {
                self.piano_clips[t][s] = self.piano_clips[t][s + 1];
                self.piano_clips[t][s + 1] = piano_roll_types.PianoRollClip.init(self.allocator);
                self.audio_clips[t][s].takeFrom(&self.audio_clips[t][s + 1], &self.sample_store);
            }
        }
    }

    fn deleteTrackInState(self: *State, track: usize) void {
        if (self.session.track_count <= 1) return;
        if (track >= self.session.track_count) return;

        const old_track_count = self.session.track_count;
        for (0..self.session.scene_count) |s| {
            session_ops.deselectClip(&self.session, track, s);
        }
        for (track..self.session.track_count - 1) |t| {
            self.session.tracks[t] = self.session.tracks[t + 1];
            for (0..max_scenes) |s| {
                self.session.clips[t][s] = self.session.clips[t + 1][s];
                self.session.clip_selected[t][s] = self.session.clip_selected[t + 1][s];
            }
        }
        for (0..max_scenes) |s| {
            self.session.clips[self.session.track_count - 1][s] = .{};
            self.session.clip_selected[self.session.track_count - 1][s] = false;
        }
        self.session.track_count -= 1;
        if (self.session.primary_track >= self.session.track_count) {
            self.session.primary_track = self.session.track_count - 1;
        }

        self.deleteTrackPianoClips(track, old_track_count);
    }

    fn deleteSceneInState(self: *State, scene: usize) void {
        if (self.session.scene_count <= 1) return;
        if (scene >= self.session.scene_count) return;

        const old_scene_count = self.session.scene_count;
        for (0..self.session.track_count) |t| {
            session_ops.deselectClip(&self.session, t, scene);
        }
        for (scene..self.session.scene_count - 1) |s| {
            self.session.scenes[s] = self.session.scenes[s + 1];
            for (0..max_tracks) |t| {
                self.session.clips[t][s] = self.session.clips[t][s + 1];
                self.session.clip_selected[t][s] = self.session.clip_selected[t][s + 1];
            }
        }
        for (0..max_tracks) |t| {
            self.session.clips[t][self.session.scene_count - 1] = .{};
            self.session.clip_selected[t][self.session.scene_count - 1] = false;
        }
        self.session.scene_count -= 1;
        if (self.session.primary_scene >= self.session.scene_count) {
            self.session.primary_scene = self.session.scene_count - 1;
        }

        self.deleteScenePianoClips(scene, old_scene_count);
    }

    fn insertTrackInState(self: *State, cmd: *const undo.command.TrackDeleteCmd) void {
        if (self.session.track_count >= max_tracks) return;

        var t = self.session.track_count;
        while (t > cmd.track_index) : (t -= 1) {
            self.session.tracks[t] = self.session.tracks[t - 1];
            for (0..max_scenes) |s| {
                self.session.clips[t][s] = self.session.clips[t - 1][s];
                self.session.clip_selected[t][s] = self.session.clip_selected[t - 1][s];
                self.piano_clips[t][s] = self.piano_clips[t - 1][s];
                self.piano_clips[t - 1][s] = piano_roll_types.PianoRollClip.init(self.allocator);
                self.audio_clips[t][s].takeFrom(&self.audio_clips[t - 1][s], &self.sample_store);
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
            self.session.clips[cmd.track_index][s] = if (slot.has_clip) .{
                .state = .stopped,
                .length_beats = slot.length_beats,
            } else .{};
            self.session.clip_selected[cmd.track_index][s] = false;
            self.piano_clips[cmd.track_index][s].clear();
            self.audio_clips[cmd.track_index][s].clear(&self.sample_store);
            cmd.audio[s].apply(&self.audio_clips[cmd.track_index][s]) catch {};
            if (slot.has_clip) {
                self.piano_clips[cmd.track_index][s].length_beats = slot.length_beats;
                if (s < cmd.notes.len) {
                    for (cmd.notes[s]) |note| {
                        self.piano_clips[cmd.track_index][s].addNote(note.pitch, note.start, note.duration) catch {};
                    }
                }
            }
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
                self.piano_clips[t][s] = self.piano_clips[t][s - 1];
                self.piano_clips[t][s - 1] = piano_roll_types.PianoRollClip.init(self.allocator);
                self.audio_clips[t][s].takeFrom(&self.audio_clips[t][s - 1], &self.sample_store);
            }
        }

        self.session.scenes[cmd.scene_index] = .{
            .name = cmd.scene_data.name,
        };
        for (0..max_tracks) |t| {
            const slot = cmd.clips[t];
            self.session.clips[t][cmd.scene_index] = if (slot.has_clip) .{
                .state = .stopped,
                .length_beats = slot.length_beats,
            } else .{};
            self.session.clip_selected[t][cmd.scene_index] = false;
            self.piano_clips[t][cmd.scene_index].clear();
            self.audio_clips[t][cmd.scene_index].clear(&self.sample_store);
            cmd.audio[t].apply(&self.audio_clips[t][cmd.scene_index]) catch {};
            if (slot.has_clip) {
                self.piano_clips[t][cmd.scene_index].length_beats = slot.length_beats;
                if (t < cmd.notes.len) {
                    for (cmd.notes[t]) |note| {
                        self.piano_clips[t][cmd.scene_index].addNote(note.pitch, note.start, note.duration) catch {};
                    }
                }
            }
        }

        self.session.scene_count += 1;
        if (self.session.primary_scene >= self.session.scene_count) {
            self.session.primary_scene = self.session.scene_count - 1;
        }
    }
};

const plugin_items: [:0]const u8 = "None\x00ZSynth\x00";
