const std = @import("std");
const clap = @import("clap-bindings");
const presets = @import("../presets.zig");

const undo = @import("../undo/root.zig");
const session_view = @import("session_view.zig");
const session_constants = @import("session_view/constants.zig");
const session_ops = @import("session_view/ops.zig");
const piano_roll_types = @import("piano_roll/types.zig");

const SessionView = session_view.SessionView;
const max_tracks = session_constants.max_tracks;
const max_scenes = session_constants.max_scenes;

// Constants for audio buffer options.
pub const max_fx_slots = 4;
pub const buffer_frame_options = [_]u32{ 64, 128, 256, 512, 1024 };
pub const default_buffer_frames: u32 = buffer_frame_options[1];

pub const BottomMode = enum {
    device,
    sequencer,
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

pub const State = struct {
    allocator: std.mem.Allocator,
    playing: bool,
    bpm: f32,
    quantize_index: i32,
    buffer_frames: u32,
    buffer_frames_requested: bool,
    dsp_load_pct: u32,
    bottom_mode: BottomMode,
    bottom_panel_height: f32,
    splitter_drag_start: f32,
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
    live_key_states: [max_tracks][128]bool,
    previous_key_states: [max_tracks][128]bool,
    live_key_velocities: [max_tracks][128]f32,
    midi_note_states: [128]bool,
    midi_note_velocities: [128]f32,
    keyboard_octave: i8,

    // Project file requests (handled by main.zig)
    load_project_request: bool,
    save_project_request: bool,
    save_project_as_request: bool,
    project_path: ?[]u8,

    // Undo/redo history
    undo_history: undo.UndoHistory,
    preset_catalog: ?*const presets.PresetCatalog = null,
    instrument_search_buf: [64:0]u8 = [_:0]u8{0} ** 64,
    preset_search_buf: [128:0]u8 = [_:0]u8{0} ** 128,

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

        return .{
            .allocator = allocator,
            .playing = false,
            .bpm = 120.0,
            .quantize_index = 2,
            .buffer_frames = default_buffer_frames,
            .buffer_frames_requested = false,
            .dsp_load_pct = 0,
            .bottom_mode = .device,
            .bottom_panel_height = 300.0,
            .splitter_drag_start = 0.0,
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
            .track_plugins = track_plugins_data,
            .track_fx = track_fx_data,
            .track_fx_slot_count = [_]usize{1} ** max_tracks,
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
            .track_plugin_ptrs = [_]?*const clap.Plugin{null} ** max_tracks,
            .track_fx_plugin_ptrs = [_][max_fx_slots]?*const clap.Plugin{
                [_]?*const clap.Plugin{null} ** max_fx_slots,
            } ** max_tracks,
            .live_key_states = [_][128]bool{[_]bool{false} ** 128} ** max_tracks,
            .previous_key_states = [_][128]bool{[_]bool{false} ** 128} ** max_tracks,
            .live_key_velocities = [_][128]f32{[_]f32{0.0} ** 128} ** max_tracks,
            .midi_note_states = [_]bool{false} ** 128,
            .midi_note_velocities = [_]f32{0.0} ** 128,
            .keyboard_octave = 0,
            .load_project_request = false,
            .save_project_request = false,
            .save_project_as_request = false,
            .project_path = null,
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
        self.undo_history.deinit();
        for (&self.piano_clips) |*track_clips| {
            for (track_clips) |*clip| {
                clip.deinit();
            }
        }
        session_ops.deinit(&self.session);
        self.piano_state.deinit();
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

    pub fn setProjectPath(self: *State, path: []const u8) !void {
        if (self.project_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.project_path = try self.allocator.dupe(u8, path);
    }

    /// Perform undo operation
    pub fn performUndo(self: *State) bool {
        const cmd = self.undo_history.popForUndo() orelse return false;
        self.executeUndo(cmd);
        self.undo_history.confirmUndo();
        return true;
    }

    /// Perform redo operation
    pub fn performRedo(self: *State) bool {
        const cmd = self.undo_history.popForRedo() orelse return false;
        self.executeRedo(cmd);
        self.undo_history.confirmRedo();
        return true;
    }

    /// Execute the undo action for a command
    fn executeUndo(self: *State, cmd: *const undo.Command) void {
        switch (cmd.*) {
            .clip_create => |c| {
                // Undo create = delete
                self.session.clips[c.track][c.scene] = .{};
                self.piano_clips[c.track][c.scene].clear();
            },
            .clip_delete => |c| {
                // Undo delete = restore
                self.session.clips[c.track][c.scene] = .{
                    .state = .stopped,
                    .length_beats = c.length_beats,
                };
                self.piano_clips[c.track][c.scene].notes.clearRetainingCapacity();
                for (c.notes) |note| {
                    self.piano_clips[c.track][c.scene].addNote(note.pitch, note.start, note.duration) catch {};
                }
            },
            .clip_paste => |c| {
                if (c.old_clip.has_clip) {
                    self.session.clips[c.track][c.scene] = .{
                        .state = .stopped,
                        .length_beats = c.old_clip.length_beats,
                    };
                    const clip = &self.piano_clips[c.track][c.scene];
                    clip.notes.clearRetainingCapacity();
                    for (c.old_notes) |note| {
                        clip.addNote(note.pitch, note.start, note.duration) catch {};
                    }
                } else {
                    self.session.clips[c.track][c.scene] = .{};
                    self.piano_clips[c.track][c.scene].clear();
                }
            },
            .note_add => |c| {
                // Undo add = remove
                const clip = &self.piano_clips[c.track][c.scene];
                if (c.note_index < clip.notes.items.len) {
                    _ = clip.notes.orderedRemove(c.note_index);
                }
            },
            .note_remove => |c| {
                // Undo remove = add back
                const clip = &self.piano_clips[c.track][c.scene];
                clip.notes.insert(clip.allocator, c.note_index, c.note) catch {
                    clip.addNote(c.note.pitch, c.note.start, c.note.duration) catch {};
                };
            },
            .note_move => |c| {
                // Undo move = restore old position
                const clip = &self.piano_clips[c.track][c.scene];
                if (c.note_index < clip.notes.items.len) {
                    clip.notes.items[c.note_index].start = c.old_start;
                    clip.notes.items[c.note_index].pitch = c.old_pitch;
                }
            },
            .note_resize => |c| {
                // Undo resize = restore old duration
                const clip = &self.piano_clips[c.track][c.scene];
                if (c.note_index < clip.notes.items.len) {
                    clip.notes.items[c.note_index].duration = c.old_duration;
                }
            },
            .note_batch => |c| {
                // Undo batch = remove added notes
                const clip = &self.piano_clips[c.track][c.scene];
                const remove_count = @min(c.notes.len, clip.notes.items.len);
                clip.notes.shrinkRetainingCapacity(clip.notes.items.len - remove_count);
            },
            .track_add => {
                // Undo add = remove last track
                if (self.session.track_count > 1) {
                    self.session.track_count -= 1;
                }
            },
            .track_rename => |c| {
                // Undo rename = restore old name
                self.session.tracks[c.track_index].name = c.old_name;
            },
            .track_volume => |c| {
                self.session.tracks[c.track_index].volume = c.old_volume;
            },
            .track_mute => |c| {
                self.session.tracks[c.track_index].mute = c.old_mute;
            },
            .track_solo => |c| {
                self.session.tracks[c.track_index].solo = c.old_solo;
            },
            .scene_add => {
                // Undo add = remove last scene
                if (self.session.scene_count > 1) {
                    self.session.scene_count -= 1;
                }
            },
            .scene_rename => |c| {
                // Undo rename = restore old name
                self.session.scenes[c.scene_index].name = c.old_name;
            },
            .bpm_change => |c| {
                self.bpm = c.old_bpm;
            },
            .quantize_change => |c| {
                self.quantize_index = c.old_index;
                self.quantize_last = c.old_index;
            },
            .clip_move => |c| {
                // Undo move = move back from dst to src (in reverse order)
                var i = c.moves.len;
                while (i > 0) {
                    i -= 1;
                    const m = c.moves[i];
                    // Move clip back
                    self.session.clips[m.src_track][m.src_scene] = self.session.clips[m.dst_track][m.dst_scene];
                    self.session.clips[m.dst_track][m.dst_scene] = .{};
                    // Move piano notes back
                    const temp_notes = self.piano_clips[m.dst_track][m.dst_scene];
                    self.piano_clips[m.src_track][m.src_scene] = temp_notes;
                    self.piano_clips[m.dst_track][m.dst_scene] = piano_roll_types.PianoRollClip.init(self.allocator);
                }
            },
            .clip_resize => |c| {
                // Undo resize = restore old length
                self.session.clips[c.track][c.scene].length_beats = c.old_length;
                self.piano_clips[c.track][c.scene].length_beats = c.old_length;
            },
            .plugin_state => |c| {
                // Undo plugin change = restore old state
                self.plugin_state_restore_request = .{
                    .track_index = c.track_index,
                    .state_data = c.old_state,
                };
            },
            .track_delete => |c| {
                self.insertTrackInState(&c);
            },
            .scene_delete => |c| {
                self.insertSceneInState(&c);
            },
        }
    }

    /// Execute the redo action for a command
    fn executeRedo(self: *State, cmd: *const undo.Command) void {
        switch (cmd.*) {
            .clip_create => |c| {
                // Redo create
                self.session.clips[c.track][c.scene] = .{
                    .state = .stopped,
                    .length_beats = c.length_beats,
                };
            },
            .clip_delete => |c| {
                // Redo delete
                self.session.clips[c.track][c.scene] = .{};
                self.piano_clips[c.track][c.scene].clear();
            },
            .clip_paste => |c| {
                if (c.new_clip.has_clip) {
                    self.session.clips[c.track][c.scene] = .{
                        .state = .stopped,
                        .length_beats = c.new_clip.length_beats,
                    };
                    const clip = &self.piano_clips[c.track][c.scene];
                    clip.notes.clearRetainingCapacity();
                    for (c.new_notes) |note| {
                        clip.addNote(note.pitch, note.start, note.duration) catch {};
                    }
                } else {
                    self.session.clips[c.track][c.scene] = .{};
                    self.piano_clips[c.track][c.scene].clear();
                }
            },
            .note_add => |c| {
                // Redo add
                const clip = &self.piano_clips[c.track][c.scene];
                clip.addNote(c.note.pitch, c.note.start, c.note.duration) catch {};
            },
            .note_remove => |c| {
                // Redo remove
                const clip = &self.piano_clips[c.track][c.scene];
                if (c.note_index < clip.notes.items.len) {
                    _ = clip.notes.orderedRemove(c.note_index);
                }
            },
            .note_move => |c| {
                // Redo move = apply new position
                const clip = &self.piano_clips[c.track][c.scene];
                if (c.note_index < clip.notes.items.len) {
                    clip.notes.items[c.note_index].start = c.new_start;
                    clip.notes.items[c.note_index].pitch = c.new_pitch;
                }
            },
            .note_resize => |c| {
                // Redo resize = apply new duration
                const clip = &self.piano_clips[c.track][c.scene];
                if (c.note_index < clip.notes.items.len) {
                    clip.notes.items[c.note_index].duration = c.new_duration;
                }
            },
            .note_batch => |c| {
                // Redo batch = add notes again
                const clip = &self.piano_clips[c.track][c.scene];
                for (c.notes) |note| {
                    clip.addNote(note.pitch, note.start, note.duration) catch {};
                }
            },
            .track_add => |c| {
                // Redo add track
                if (self.session.track_count < max_tracks) {
                    self.session.tracks[self.session.track_count] = .{};
                    self.session.tracks[self.session.track_count].name = c.name;
                    self.session.track_count += 1;
                }
            },
            .track_rename => |c| {
                // Redo rename = apply new name
                self.session.tracks[c.track_index].name = c.new_name;
            },
            .track_volume => |c| {
                self.session.tracks[c.track_index].volume = c.new_volume;
            },
            .track_mute => |c| {
                self.session.tracks[c.track_index].mute = c.new_mute;
            },
            .track_solo => |c| {
                self.session.tracks[c.track_index].solo = c.new_solo;
            },
            .scene_add => |c| {
                // Redo add scene
                if (self.session.scene_count < max_scenes) {
                    self.session.scenes[self.session.scene_count] = .{};
                    self.session.scenes[self.session.scene_count].name = c.name;
                    self.session.scene_count += 1;
                }
            },
            .scene_rename => |c| {
                // Redo rename = apply new name
                self.session.scenes[c.scene_index].name = c.new_name;
            },
            .bpm_change => |c| {
                self.bpm = c.new_bpm;
            },
            .quantize_change => |c| {
                self.quantize_index = c.new_index;
                self.quantize_last = c.new_index;
            },
            .clip_move => |c| {
                // Redo move = move from src to dst (in forward order)
                for (c.moves) |m| {
                    // Move clip
                    self.session.clips[m.dst_track][m.dst_scene] = self.session.clips[m.src_track][m.src_scene];
                    self.session.clips[m.src_track][m.src_scene] = .{};
                    // Move piano notes
                    const temp_notes = self.piano_clips[m.src_track][m.src_scene];
                    self.piano_clips[m.dst_track][m.dst_scene] = temp_notes;
                    self.piano_clips[m.src_track][m.src_scene] = piano_roll_types.PianoRollClip.init(self.allocator);
                }
            },
            .clip_resize => |c| {
                // Redo resize = apply new length
                self.session.clips[c.track][c.scene].length_beats = c.new_length;
                self.piano_clips[c.track][c.scene].length_beats = c.new_length;
            },
            .plugin_state => |c| {
                // Redo plugin change = restore new state
                self.plugin_state_restore_request = .{
                    .track_index = c.track_index,
                    .state_data = c.new_state,
                };
            },
            .track_delete => |c| {
                self.deleteTrackInState(c.track_index);
            },
            .scene_delete => |c| {
                self.deleteSceneInState(c.scene_index);
            },
        }
    }

    pub fn deleteTrackPianoClips(self: *State, track: usize, old_track_count: usize) void {
        if (track >= old_track_count) return;
        for (0..max_scenes) |s| {
            self.piano_clips[track][s].deinit();
        }
        if (track + 1 > old_track_count - 1) return;
        for (track..old_track_count - 1) |t| {
            for (0..max_scenes) |s| {
                self.piano_clips[t][s] = self.piano_clips[t + 1][s];
                self.piano_clips[t + 1][s] = piano_roll_types.PianoRollClip.init(self.allocator);
            }
        }
    }

    pub fn deleteScenePianoClips(self: *State, scene: usize, old_scene_count: usize) void {
        if (scene >= old_scene_count) return;
        for (0..max_tracks) |t| {
            self.piano_clips[t][scene].deinit();
        }
        if (scene + 1 > old_scene_count - 1) return;
        for (0..max_tracks) |t| {
            for (scene..old_scene_count - 1) |s| {
                self.piano_clips[t][s] = self.piano_clips[t][s + 1];
                self.piano_clips[t][s + 1] = piano_roll_types.PianoRollClip.init(self.allocator);
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
            }
        }

        self.session.tracks[cmd.track_index] = .{
            .name = cmd.track_data.name,
            .volume = cmd.track_data.volume,
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
