const std = @import("std");
const zgui = @import("zgui");
const zsynth = @import("zsynth-core");
const clap = @import("clap-bindings");
const zsynth_view = zsynth.View;

// Import UI modules
pub const ui = @import("ui/root.zig");

// Import undo system
pub const undo = @import("undo/root.zig");
pub const Colors = ui.Colors;
pub const SessionView = ui.SessionView;
pub const PianoRollClip = ui.PianoRollClip;
pub const PianoRollState = ui.PianoRollState;
pub const Note = ui.Note;
pub const ClipState = ui.ClipState;
pub const ClipSlot = ui.ClipSlot;
pub const Track = ui.Track;

// Re-export constants for compatibility
pub const track_count = ui.max_tracks;
pub const scene_count = ui.max_scenes;
pub const beats_per_bar = ui.beats_per_bar;
pub const default_clip_bars = ui.default_clip_bars;
pub const total_pitches = ui.total_pitches;
pub const quantizeIndexToBeats = ui.quantizeIndexToBeats;

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
    builtin,
    clap,
};

pub const TrackPluginUI = struct {
    choice_index: i32,
    gui_open: bool,
    last_valid_choice: i32,
};

const keyboard_base_pitch: u8 = 60; // Middle C (C4)

pub const State = struct {
    allocator: std.mem.Allocator,
    playing: bool,
    bpm: f32,
    quantize_index: i32,
    bottom_mode: BottomMode,
    bottom_panel_height: f32,
    splitter_drag_start: f32,
    zsynth: ?*zsynth.Plugin,
    device_kind: DeviceKind,
    device_clap_plugin: ?*const clap.Plugin,
    device_clap_name: []const u8,
    playhead_beat: f32,
    focused_pane: FocusedPane,

    // Session view
    session: SessionView,

    // Piano roll state
    piano_state: PianoRollState,

    // Piano clips storage (separate from session view's clip metadata)
    piano_clips: [ui.max_tracks][ui.max_scenes]PianoRollClip,

    // Track plugin UI state
    track_plugins: [ui.max_tracks]TrackPluginUI,
    plugin_items: [:0]const u8,
    plugin_divider_index: ?i32,
    live_key_states: [ui.max_tracks][128]bool,
    previous_key_states: [ui.max_tracks][128]bool,
    keyboard_octave: i8,

    // Project file requests (handled by main.zig)
    load_project_request: bool,
    save_project_request: bool,

    // Undo/redo history
    undo_history: undo.UndoHistory,

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

    pub fn init(allocator: std.mem.Allocator) State {
        var track_plugins_data: [ui.max_tracks]TrackPluginUI = undefined;
        for (&track_plugins_data) |*plugin| {
            plugin.* = .{
                .choice_index = 0,
                .gui_open = false,
                .last_valid_choice = 0,
            };
        }

        var piano_clips_data: [ui.max_tracks][ui.max_scenes]PianoRollClip = undefined;
        for (&piano_clips_data) |*track_clips| {
            for (track_clips) |*clip| {
                clip.* = PianoRollClip.init(allocator);
            }
        }

        return .{
            .allocator = allocator,
            .playing = false,
            .bpm = 120.0,
            .quantize_index = 2,
            .bottom_mode = .device,
            .bottom_panel_height = 300.0,
            .splitter_drag_start = 0.0,
            .zsynth = null,
            .device_kind = .none,
            .device_clap_plugin = null,
            .device_clap_name = "",
            .playhead_beat = 0,
            .focused_pane = .session,
            .session = SessionView.init(allocator),
            .piano_state = PianoRollState.init(allocator),
            .piano_clips = piano_clips_data,
            .track_plugins = track_plugins_data,
            .plugin_items = plugin_items,
            .plugin_divider_index = null,
            .live_key_states = [_][128]bool{[_]bool{false} ** 128} ** ui.max_tracks,
            .previous_key_states = [_][128]bool{[_]bool{false} ** 128} ** ui.max_tracks,
            .keyboard_octave = 0,
            .load_project_request = false,
            .save_project_request = false,
            .undo_history = undo.UndoHistory.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.undo_history.deinit();
        for (&self.piano_clips) |*track_clips| {
            for (track_clips) |*clip| {
                clip.deinit();
            }
        }
        self.session.deinit();
        self.piano_state.deinit();
    }

    pub fn selectedTrack(self: *const State) usize {
        return self.session.primary_track;
    }

    pub fn selectedScene(self: *const State) usize {
        return self.session.primary_scene;
    }

    pub fn currentClip(self: *State) *PianoRollClip {
        return &self.piano_clips[self.selectedTrack()][self.selectedScene()];
    }

    pub fn currentClipLabel(self: *const State) []const u8 {
        return self.session.scenes[self.selectedScene()].getName();
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
                self.session.tracks[c.track_index].name_len = c.old_len;
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
                self.session.scenes[c.scene_index].name_len = c.old_len;
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
                    self.piano_clips[m.dst_track][m.dst_scene] = ui.piano_roll.PianoRollClip.init(self.allocator);
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
            // Complex commands not yet implemented
            .track_delete, .scene_delete => {},
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
                if (self.session.track_count < ui.max_tracks) {
                    self.session.tracks[self.session.track_count] = .{};
                    self.session.tracks[self.session.track_count].name = c.name;
                    self.session.tracks[self.session.track_count].name_len = c.name_len;
                    self.session.track_count += 1;
                }
            },
            .track_rename => |c| {
                // Redo rename = apply new name
                self.session.tracks[c.track_index].name = c.new_name;
                self.session.tracks[c.track_index].name_len = c.new_len;
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
                if (self.session.scene_count < ui.max_scenes) {
                    self.session.scenes[self.session.scene_count] = .{};
                    self.session.scenes[self.session.scene_count].name = c.name;
                    self.session.scenes[self.session.scene_count].name_len = c.name_len;
                    self.session.scene_count += 1;
                }
            },
            .scene_rename => |c| {
                // Redo rename = apply new name
                self.session.scenes[c.scene_index].name = c.new_name;
                self.session.scenes[c.scene_index].name_len = c.new_len;
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
                    self.piano_clips[m.src_track][m.src_scene] = ui.piano_roll.PianoRollClip.init(self.allocator);
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
            // Complex commands not yet implemented
            .track_delete, .scene_delete => {},
        }
    }
};

const quantize_items: [:0]const u8 = "1/4\x001/2\x001\x002\x004\x00";
const plugin_items: [:0]const u8 = "None\x00ZSynth\x00";

pub fn draw(state: *State, ui_scale: f32) void {
    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = display[1], .cond = .always });

    pushAbletonStyle();
    defer popAbletonStyle();

    if (zgui.begin("flux##root", .{ .flags = .{
        .no_collapse = true,
        .no_resize = true,
        .no_move = true,
        .no_title_bar = true,
        .no_scrollbar = true,
        .no_scroll_with_mouse = true,
    } })) {
        // Tab key toggles between Device and Clip views
        if (zgui.isKeyPressed(.tab, false)) {
            state.bottom_mode = switch (state.bottom_mode) {
                .device => .sequencer,
                .sequencer => .device,
            };
        }

        drawTransport(state, ui_scale);
        zgui.spacing();
        const avail = zgui.getContentRegionAvail();
        const splitter_h = 6.0 * ui_scale;
        const min_bottom = 100.0 * ui_scale;
        const max_bottom = avail[1] - 100.0 * ui_scale;
        const bottom_height = std.math.clamp(state.bottom_panel_height * ui_scale, min_bottom, max_bottom);
        const top_height = @max(0.0, avail[1] - bottom_height - splitter_h);

        // Clip grid area
        if (zgui.beginChild("clip_area##root", .{ .w = 0, .h = top_height, .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
            // Track focus
            if (zgui.isWindowHovered(.{ .child_windows = true }) and zgui.isMouseClicked(.left)) {
                state.focused_pane = .session;
            }
            drawClipGrid(state, ui_scale);
        }
        zgui.endChild();

        // Splitter handle
        const splitter_pos = zgui.getCursorScreenPos();
        const avail_w = zgui.getContentRegionAvail()[0];
        const draw_list = zgui.getWindowDrawList();

        _ = zgui.invisibleButton("##splitter", .{ .w = avail_w, .h = splitter_h });
        const is_hovered = zgui.isItemHovered(.{});
        const is_active = zgui.isItemActive();

        if (is_hovered or is_active) {
            zgui.setMouseCursor(.resize_ns);
        }

        const splitter_color = if (is_active)
            Colors.accent
        else if (is_hovered)
            Colors.accent_dim
        else
            Colors.border;
        draw_list.addRectFilled(.{
            .pmin = splitter_pos,
            .pmax = .{ splitter_pos[0] + avail_w, splitter_pos[1] + splitter_h },
            .col = zgui.colorConvertFloat4ToU32(splitter_color),
        });

        if (zgui.isItemActivated()) {
            state.splitter_drag_start = state.bottom_panel_height;
        }
        if (is_active) {
            const drag_delta = zgui.getMouseDragDelta(.left, .{});
            state.bottom_panel_height = std.math.clamp(state.splitter_drag_start - drag_delta[1] / ui_scale, 100.0, 800.0);
        }

        // Bottom panel
        if (zgui.beginChild("bottom_panel##root", .{ .w = 0, .h = bottom_height, .child_flags = .{ .border = true }, .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
            // Track focus
            if (zgui.isWindowHovered(.{ .child_windows = true }) and zgui.isMouseClicked(.left)) {
                state.focused_pane = .bottom;
            }
            drawBottomPanel(state, ui_scale);
        }
        zgui.endChild();
    }

    // Undo/Redo shortcuts (Cmd+Z / Cmd+Shift+Z on Mac, Ctrl+Z / Ctrl+Shift+Z on other platforms)
    // Placed at end of frame so undo requests from this frame are already processed
    const mod_down = ui.selection.isModifierDown();
    if (mod_down and zgui.isKeyPressed(.z, false)) {
        if (ui.selection.isShiftDown()) {
            _ = state.performRedo();
        } else {
            _ = state.performUndo();
        }
    }

    zgui.end();
}

fn pushAbletonStyle() void {
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = Colors.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = Colors.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .popup_bg, .c = Colors.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = Colors.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = .{ 0.22, 0.22, 0.22, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = .{ 0.25, 0.25, 0.25, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .header, .c = Colors.bg_header });
    zgui.pushStyleColor4f(.{ .idx = .header_hovered, .c = .{ 0.18, 0.18, 0.18, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .header_active, .c = Colors.accent_dim });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = Colors.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ 0.25, 0.25, 0.25, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.accent_dim });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab, .c = Colors.accent });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab_active, .c = Colors.accent });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_bright });
    zgui.pushStyleColor4f(.{ .idx = .text_disabled, .c = Colors.text_dim });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = Colors.border });
    zgui.pushStyleColor4f(.{ .idx = .separator, .c = Colors.border });
    zgui.pushStyleColor4f(.{ .idx = .table_header_bg, .c = Colors.bg_header });
    zgui.pushStyleColor4f(.{ .idx = .table_row_bg, .c = Colors.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .table_row_bg_alt, .c = Colors.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .table_border_strong, .c = Colors.border });
    zgui.pushStyleColor4f(.{ .idx = .table_border_light, .c = .{ 0.20, 0.20, 0.20, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_bg, .c = Colors.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab, .c = .{ 0.30, 0.30, 0.30, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab_hovered, .c = .{ 0.40, 0.40, 0.40, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab_active, .c = Colors.accent_dim });
}

fn popAbletonStyle() void {
    zgui.popStyleColor(.{ .count = 27 });
}

pub fn tick(state: *State, dt: f64) void {
    // Handle playhead reset request (for immediate recording start)
    if (state.session.reset_playhead_request) {
        state.session.reset_playhead_request = false;
        state.playhead_beat = 0;
    }

    // Handle recording finalization request (when manually stopping recording)
    if (state.session.finalize_recording_track) |track| {
        if (state.session.finalize_recording_scene) |scene| {
            // Finalize held notes to the specified clip
            const piano_clip = &state.piano_clips[track][scene];
            const rec = &state.session.recording;
            const clip_length = state.session.clips[track][scene].length_beats;

            // Calculate current position relative to recording start
            const current_beat = @mod(state.playhead_beat - rec.start_beat + clip_length, clip_length);

            for (0..128) |pitch| {
                if (rec.note_start_beats[pitch]) |start_beat| {
                    const p: u8 = @intCast(pitch);
                    var duration = current_beat - start_beat;
                    // Handle wrap-around
                    if (duration < 0) {
                        duration = duration + clip_length;
                    }
                    if (duration > 0.01) {
                        piano_clip.addNote(p, start_beat, duration) catch {};
                    }
                }
            }
        }
        // Clear the request and reset recording state
        state.session.finalize_recording_track = null;
        state.session.finalize_recording_scene = null;
        state.session.recording.reset();
    }

    if (!state.playing) {
        // Update previous_key_states even when not playing
        state.previous_key_states = state.live_key_states;
        return;
    }

    const beats_per_second = state.bpm / 60.0;
    const prev_beat = state.playhead_beat;
    state.playhead_beat += @as(f32, @floatCast(dt)) * @as(f32, @floatCast(beats_per_second));

    // Check quantize boundary for scene switches
    const quantize_beats = quantizeIndexToBeats(state.quantize_index);
    const prev_quantize = @floor(prev_beat / quantize_beats);
    const curr_quantize = @floor(state.playhead_beat / quantize_beats);

    if (curr_quantize > prev_quantize) {
        state.session.processQuantizedSwitches();

        // Start queued recording at quantize boundary (not waiting for loop)
        if (state.session.hasQueuedRecording()) {
            // Calculate the beat position at the quantize boundary
            const quantize_boundary = curr_quantize * quantize_beats;
            state.session.processRecordingQuantize(quantize_boundary);
        }
    }

    // Determine loop length (use recording clip if recording, otherwise current clip)
    const loop_length = if (state.session.recording.track) |t|
        if (state.session.recording.scene) |s|
            state.session.clips[t][s].length_beats
        else
            state.currentClip().length_beats
    else
        state.currentClip().length_beats;

    // Check if playhead is about to loop
    const will_loop = state.playhead_beat >= loop_length;

    // Process MIDI recording (before loop so we can finalize held notes at loop point)
    if (state.session.isActivelyRecording()) {
        // If about to loop, finalize any held notes at the end of the clip
        if (will_loop) {
            finalizeHeldNotesAtPosition(state, loop_length);
        }
        processRecordingMidi(state);
    }

    // Update previous_key_states at end of frame
    state.previous_key_states = state.live_key_states;

    // Handle playhead looping
    if (will_loop) {
        // At clip loop boundary, start queued recording BEFORE wrapping
        if (state.session.hasQueuedRecording()) {
            state.session.processRecordingQuantize(0);
        }

        state.playhead_beat = @mod(state.playhead_beat, loop_length);

        // If actively recording and we just looped
        if (state.session.recording.track) |track| {
            if (state.session.recording.scene) |scene| {
                // Transition from recording to playing (overdub mode)
                // This allows the clip to play back recorded notes while continuing to record
                if (state.session.clips[track][scene].state == .recording) {
                    state.session.clips[track][scene].state = .playing;
                }

                // Reset recording start beat to 0 for subsequent passes
                // This ensures notes are recorded at correct positions after the first loop
                state.session.recording.start_beat = 0;

                // Reset note tracking for new pass - held notes start fresh from beat 0
                const rec = &state.session.recording;
                for (0..128) |pitch| {
                    if (rec.note_start_beats[pitch] != null) {
                        rec.note_start_beats[pitch] = 0;
                    }
                }
            }
        }
    }
}

/// Process MIDI note recording from keyboard input
fn processRecordingMidi(state: *State) void {
    const rec = &state.session.recording;
    const track = rec.track orelse return;
    const scene = rec.scene orelse return;

    const piano_clip = &state.piano_clips[track][scene];
    const clip_length = state.session.clips[track][scene].length_beats;

    // Calculate position within the clip (relative to recording start)
    // This ensures notes are placed at the beginning of the clip, not at absolute playhead position
    const current_beat = @mod(state.playhead_beat - rec.start_beat + clip_length, clip_length);

    // Compare current and previous key states
    for (0..128) |pitch| {
        const p: u8 = @intCast(pitch);
        const is_pressed = state.live_key_states[track][pitch];
        const was_pressed = state.previous_key_states[track][pitch];

        if (is_pressed and !was_pressed) {
            // Note on: store start beat (using position within clip)
            rec.note_start_beats[pitch] = current_beat;
        } else if (!is_pressed and was_pressed) {
            // Note off: create note
            if (rec.note_start_beats[pitch]) |start_beat| {
                var duration = current_beat - start_beat;
                // Handle wrap-around (note started near end of clip, ended after loop)
                if (duration < 0) {
                    duration = duration + clip_length;
                }
                if (duration > 0.01) { // Minimum note duration
                    piano_clip.addNote(p, start_beat, duration) catch {};
                }
                rec.note_start_beats[pitch] = null;
            }
        }
    }
}

/// Finalize held notes at a specific position (used at loop boundary)
fn finalizeHeldNotesAtPosition(state: *State, end_beat: f32) void {
    const rec = &state.session.recording;
    const track = rec.track orelse return;
    const scene = rec.scene orelse return;

    const piano_clip = &state.piano_clips[track][scene];
    const clip_length = state.session.clips[track][scene].length_beats;

    // Calculate end position relative to recording start
    const relative_end = @mod(end_beat - rec.start_beat + clip_length, clip_length);

    // Finalize all held notes at the specified position
    for (0..128) |pitch| {
        if (rec.note_start_beats[pitch]) |start_beat| {
            const p: u8 = @intCast(pitch);
            var duration = relative_end - start_beat;
            // Handle wrap-around
            if (duration < 0) {
                duration = duration + clip_length;
            }
            if (duration > 0.01) {
                piano_clip.addNote(p, start_beat, duration) catch {};
            }
            // Don't clear note_start_beats here - the loop handler will reset them to 0
        }
    }
}

/// Finalize any notes that are still held when recording stops
fn finalizeHeldNotes(state: *State) void {
    const rec = &state.session.recording;
    const track = rec.track orelse return;
    const scene = rec.scene orelse return;

    const piano_clip = &state.piano_clips[track][scene];
    const clip_length = state.session.clips[track][scene].length_beats;

    // Calculate current position relative to recording start
    const current_beat = @mod(state.playhead_beat - rec.start_beat + clip_length, clip_length);

    // Finalize all held notes at current position
    for (0..128) |pitch| {
        if (rec.note_start_beats[pitch]) |start_beat| {
            const p: u8 = @intCast(pitch);
            var duration = current_beat - start_beat;
            // Handle wrap-around
            if (duration < 0) {
                duration = duration + clip_length;
            }
            if (duration > 0.01) {
                piano_clip.addNote(p, start_beat, duration) catch {};
            }
            rec.note_start_beats[pitch] = null;
        }
    }
}

pub fn updateKeyboardMidi(state: *State) void {
    // Handle octave change with z/x keys (edge detection, no repeat)
    if (zgui.isKeyPressed(.z, false)) {
        state.keyboard_octave = @max(state.keyboard_octave - 1, -5);
    }
    if (zgui.isKeyPressed(.x, false)) {
        state.keyboard_octave = @min(state.keyboard_octave + 1, 5);
    }

    const KeyMapping = struct {
        key: zgui.Key,
        offset: u8, // Offset from base pitch
    };
    const mappings = [_]KeyMapping{
        .{ .key = .a, .offset = 0 }, // C
        .{ .key = .s, .offset = 2 }, // D
        .{ .key = .d, .offset = 4 }, // E
        .{ .key = .f, .offset = 5 }, // F
        .{ .key = .g, .offset = 7 }, // G
        .{ .key = .h, .offset = 9 }, // A
        .{ .key = .j, .offset = 11 }, // B
        .{ .key = .k, .offset = 12 }, // C (octave up)
        .{ .key = .l, .offset = 14 }, // D
        .{ .key = .semicolon, .offset = 16 }, // E
        .{ .key = .w, .offset = 1 }, // C#
        .{ .key = .e, .offset = 3 }, // D#
        .{ .key = .t, .offset = 6 }, // F#
        .{ .key = .y, .offset = 8 }, // G#
        .{ .key = .u, .offset = 10 }, // A#
    };

    const octave_offset: i16 = @as(i16, state.keyboard_octave) * 12;

    var pressed = [_]bool{false} ** 128;
    for (mappings) |mapping| {
        if (zgui.isKeyDown(mapping.key)) {
            const pitch: i16 = @as(i16, keyboard_base_pitch) + @as(i16, mapping.offset) + octave_offset;
            if (pitch >= 0 and pitch <= 127) {
                pressed[@intCast(pitch)] = true;
            }
        }
    }

    // Route keyboard to armed track if one is armed, otherwise to selected track
    const target_track = state.session.armed_track orelse state.selectedTrack();
    for (0..ui.max_tracks) |track_index| {
        if (track_index == target_track) {
            state.live_key_states[track_index] = pressed;
        } else {
            state.live_key_states[track_index] = [_]bool{false} ** 128;
        }
    }
}

fn drawTransport(state: *State, ui_scale: f32) void {
    const transport_h = 52.0 * ui_scale;
    const btn_size = 36.0 * ui_scale;
    const spacing = 20.0 * ui_scale;

    const draw_list = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    const avail_w = zgui.getContentRegionAvail()[0];
    draw_list.addRectFilled(.{
        .pmin = .{ pos[0], pos[1] },
        .pmax = .{ pos[0] + avail_w, pos[1] + transport_h },
        .col = zgui.colorConvertFloat4ToU32(Colors.bg_header),
    });

    zgui.setCursorPosY(zgui.getCursorPosY() + 6.0 * ui_scale);
    zgui.setCursorPosX(zgui.getCursorPosX() + 8.0 * ui_scale);

    const play_color = if (state.playing) Colors.transport_play else Colors.text_dim;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = Colors.bg_header });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ 0.20, 0.20, 0.20, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = .{ 0.25, 0.25, 0.25, 1.0 } });
    defer zgui.popStyleColor(.{ .count = 3 });

    const btn_pos = zgui.getCursorScreenPos();
    if (zgui.button("##play_btn", .{ .w = btn_size, .h = btn_size })) {
        state.playing = !state.playing;
        state.playhead_beat = 0;
    }

    if (state.playing) {
        const sq_size = 14.0 * ui_scale;
        const cx = btn_pos[0] + btn_size / 2.0;
        const cy = btn_pos[1] + btn_size / 2.0;
        draw_list.addRectFilled(.{
            .pmin = .{ cx - sq_size / 2.0, cy - sq_size / 2.0 },
            .pmax = .{ cx + sq_size / 2.0, cy + sq_size / 2.0 },
            .col = zgui.colorConvertFloat4ToU32(play_color),
        });
    } else {
        const tri_size = 16.0 * ui_scale;
        const cx = btn_pos[0] + btn_size / 2.0 + 2.0 * ui_scale;
        const cy = btn_pos[1] + btn_size / 2.0;
        draw_list.addTriangleFilled(.{
            .p1 = .{ cx - tri_size / 2.0, cy - tri_size / 2.0 },
            .p2 = .{ cx - tri_size / 2.0, cy + tri_size / 2.0 },
            .p3 = .{ cx + tri_size / 2.0, cy },
            .col = zgui.colorConvertFloat4ToU32(play_color),
        });
    }

    zgui.sameLine(.{ .spacing = spacing });

    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
    zgui.textUnformatted("BPM");
    zgui.popStyleColor(.{ .count = 1 });
    zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
    zgui.setNextItemWidth(100.0 * ui_scale);
    const bpm_before = state.bpm;
    _ = zgui.sliderFloat("##transport_bpm", .{
        .v = &state.bpm,
        .min = 40.0,
        .max = 200.0,
        .cfmt = "%.0f",
    });

    // Track BPM drag for undo
    if (zgui.isItemActive()) {
        if (!state.bpm_drag_active) {
            state.bpm_drag_active = true;
            state.bpm_drag_start = bpm_before;
        }
    } else if (state.bpm_drag_active) {
        // Drag ended - emit undo if changed
        if (state.bpm != state.bpm_drag_start) {
            state.undo_history.push(.{
                .bpm_change = .{
                    .old_bpm = state.bpm_drag_start,
                    .new_bpm = state.bpm,
                },
            });
        }
        state.bpm_drag_active = false;
    }

    zgui.sameLine(.{ .spacing = spacing });

    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
    zgui.textUnformatted("Quantize");
    zgui.popStyleColor(.{ .count = 1 });
    zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
    zgui.setNextItemWidth(80.0 * ui_scale);
    _ = zgui.combo("##transport_quantize", .{
        .current_item = &state.quantize_index,
        .items_separated_by_zeros = quantize_items,
    });

    // Track quantize change for undo
    if (state.quantize_index != state.quantize_last) {
        state.undo_history.push(.{
            .quantize_change = .{
                .old_index = state.quantize_last,
                .new_index = state.quantize_index,
            },
        });
        state.quantize_last = state.quantize_index;
    }

    // Load/Save buttons (right-aligned, centered vertically)
    zgui.sameLine(.{ .spacing = spacing * 2.0 });

    // Move buttons up to center in transport bar
    const save_y = zgui.getCursorPosY();
    zgui.setCursorPosY(save_y - 4.0 * ui_scale);

    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 16.0 * ui_scale, 8.0 * ui_scale } });
    if (zgui.button("Load", .{})) {
        state.load_project_request = true;
    }

    zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
    zgui.setCursorPosY(save_y - 4.0 * ui_scale);

    if (zgui.button("Save", .{})) {
        state.save_project_request = true;
    }
    zgui.popStyleVar(.{ .count = 1 });

    zgui.setCursorPosY(save_y + transport_h - 6.0 * ui_scale);
}

fn drawClipGrid(state: *State, ui_scale: f32) void {
    // Draw session view
    const is_focused = state.focused_pane == .session;
    state.session.draw(ui_scale, state.playing, is_focused, state.playhead_beat);
    if (state.session.open_clip_request) |req| {
        state.session.open_clip_request = null;
        state.session.primary_track = req.track;
        state.session.primary_scene = req.scene;
        state.bottom_mode = .sequencer;
        state.focused_pane = .bottom;
    }
    // Handle request to clear piano clip (when starting new recording on empty slot)
    if (state.session.clear_piano_clip_request) |req| {
        state.session.clear_piano_clip_request = null;
        state.piano_clips[req.track][req.scene].clear();
    }
    if (state.session.start_playback_request) {
        state.session.start_playback_request = false;
        state.playing = true;
    }

    // Process undo requests from session view and piano roll operations
    processUndoRequests(state);
    processPianoRollUndoRequests(state);
}

fn processUndoRequests(state: *State) void {
    for (state.session.undo_requests[0..state.session.undo_request_count]) |req| {
        switch (req.kind) {
            .clip_create => {
                state.undo_history.push(.{
                    .clip_create = .{
                        .track = req.track,
                        .scene = req.scene,
                        .length_beats = req.length_beats,
                    },
                });
            },
            .clip_delete => {
                // Capture notes before they're lost (they may already be cleared)
                const notes = state.allocator.dupe(
                    undo.Note,
                    state.piano_clips[req.track][req.scene].notes.items,
                ) catch &.{};
                state.undo_history.push(.{
                    .clip_delete = .{
                        .track = req.track,
                        .scene = req.scene,
                        .length_beats = req.length_beats,
                        .notes = notes,
                    },
                });
                // Clear the piano clip notes
                state.piano_clips[req.track][req.scene].clear();
            },
            .track_add => {
                const track = &state.session.tracks[req.track];
                state.undo_history.push(.{
                    .track_add = .{
                        .track_index = req.track,
                        .name = track.name,
                        .name_len = track.name_len,
                    },
                });
            },
            .scene_add => {
                const scene = &state.session.scenes[req.scene];
                state.undo_history.push(.{
                    .scene_add = .{
                        .scene_index = req.scene,
                        .name = scene.name,
                        .name_len = scene.name_len,
                    },
                });
            },
            .track_volume => {
                state.undo_history.push(.{
                    .track_volume = .{
                        .track_index = req.track,
                        .old_volume = req.old_volume,
                        .new_volume = req.new_volume,
                    },
                });
            },
        }
    }
    state.session.undo_request_count = 0; // Clear processed requests

    // Process clip move requests (separate since it involves multiple clips)
    if (state.session.clip_move_count > 0) {
        // First, move the piano clips (session_view already moved the clip slots)
        if (state.session.pending_piano_moves) {
            for (state.session.clip_move_requests[0..state.session.clip_move_count]) |req| {
                // Swap piano clips from src to dst
                const temp = state.piano_clips[req.src_track][req.src_scene];
                state.piano_clips[req.dst_track][req.dst_scene] = temp;
                state.piano_clips[req.src_track][req.src_scene] = ui.piano_roll.PianoRollClip.init(state.allocator);
            }
            state.session.pending_piano_moves = false;
        }

        // Allocate and copy the moves for undo
        if (state.allocator.alloc(undo.command.ClipMoveCmd.ClipMove, state.session.clip_move_count)) |moves| {
            for (state.session.clip_move_requests[0..state.session.clip_move_count], 0..) |req, i| {
                moves[i] = .{
                    .src_track = req.src_track,
                    .src_scene = req.src_scene,
                    .dst_track = req.dst_track,
                    .dst_scene = req.dst_scene,
                };
            }
            state.undo_history.push(.{
                .clip_move = .{
                    .moves = moves,
                },
            });
        } else |_| {}
        state.session.clip_move_count = 0;
    }
}

fn processPianoRollUndoRequests(state: *State) void {
    for (state.piano_state.undo_requests[0..state.piano_state.undo_request_count]) |req| {
        switch (req.kind) {
            .note_add => {
                state.undo_history.push(.{
                    .note_add = .{
                        .track = req.track,
                        .scene = req.scene,
                        .note = req.note,
                        .note_index = req.note_index,
                    },
                });
            },
            .note_remove => {
                state.undo_history.push(.{
                    .note_remove = .{
                        .track = req.track,
                        .scene = req.scene,
                        .note = req.note,
                        .note_index = req.note_index,
                    },
                });
            },
            .note_move => {
                state.undo_history.push(.{
                    .note_move = .{
                        .track = req.track,
                        .scene = req.scene,
                        .note_index = req.note_index,
                        .old_start = req.old_start,
                        .old_pitch = req.old_pitch,
                        .new_start = req.new_start,
                        .new_pitch = req.new_pitch,
                    },
                });
            },
            .note_resize => {
                state.undo_history.push(.{
                    .note_resize = .{
                        .track = req.track,
                        .scene = req.scene,
                        .note_index = req.note_index,
                        .old_duration = req.old_duration,
                        .new_duration = req.new_duration,
                    },
                });
            },
            .clip_resize => {
                // Also sync the session clip length
                state.session.clips[req.track][req.scene].length_beats = req.new_duration;
                state.undo_history.push(.{
                    .clip_resize = .{
                        .track = req.track,
                        .scene = req.scene,
                        .old_length = req.old_duration,
                        .new_length = req.new_duration,
                    },
                });
            },
        }
    }
    state.piano_state.undo_request_count = 0; // Clear processed requests
}

fn drawBottomPanel(state: *State, ui_scale: f32) void {
    // Device tab
    const device_active = state.bottom_mode == .device;
    const device_color = if (device_active) Colors.accent else Colors.bg_header;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = device_color });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (device_active) Colors.accent else .{ 0.20, 0.20, 0.20, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.accent_dim });
    if (zgui.button("Device", .{})) {
        state.bottom_mode = .device;
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.sameLine(.{});

    // Clip tab
    const seq_active = state.bottom_mode == .sequencer;
    const seq_color = if (seq_active) Colors.accent else Colors.bg_header;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = seq_color });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (seq_active) Colors.accent else .{ 0.20, 0.20, 0.20, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.accent_dim });
    if (zgui.button("Clip", .{})) {
        state.bottom_mode = .sequencer;
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.sameLine(.{});
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
    var track_buf: [64]u8 = undefined;
    const track_info = std.fmt.bufPrintZ(&track_buf, "  Track {d} / Scene {d}", .{ state.selectedTrack() + 1, state.selectedScene() + 1 }) catch "";
    zgui.textUnformatted(track_info);
    zgui.popStyleColor(.{ .count = 1 });

    zgui.separator();

    switch (state.bottom_mode) {
        .device => {
            drawDevicePanel(state, ui_scale);
        },
        .sequencer => {
            // Only show piano roll if there's a clip at this position
            const clip_slot = state.session.clips[state.selectedTrack()][state.selectedScene()];
            if (clip_slot.state == .empty) {
                zgui.spacing();
                zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
                zgui.textUnformatted("No clip. Double-click in session view to create one.");
                zgui.popStyleColor(.{ .count = 1 });
            } else {
                const is_focused = state.focused_pane == .bottom;
                ui.piano_roll.drawSequencer(
                    &state.piano_state,
                    state.currentClip(),
                    state.currentClipLabel(),
                    state.playhead_beat,
                    state.playing,
                    state.quantize_index,
                    ui_scale,
                    is_focused,
                    state.selectedTrack(),
                    state.selectedScene(),
                );
            }
        },
    }
}

fn drawDevicePanel(state: *State, ui_scale: f32) void {
    // Track device selector
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
    zgui.textUnformatted("Device:");
    zgui.popStyleColor(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
    zgui.setNextItemWidth(200.0 * ui_scale);

    const track_idx = state.selectedTrack();
    const track_plugin = &state.track_plugins[track_idx];

    if (zgui.combo("##device_select", .{
        .current_item = &track_plugin.choice_index,
        .items_separated_by_zeros = state.plugin_items,
    })) {
        // Selection changed
        track_plugin.gui_open = false;
    }

    zgui.sameLine(.{ .spacing = 20.0 * ui_scale });
    zgui.separator();

    switch (state.device_kind) {
        .builtin => {
            if (state.zsynth) |plugin| {
                if (zgui.beginChild("zsynth_embed##device", .{ .w = 0, .h = 0 })) {
                    zsynth_view.drawEmbedded(plugin, .{ .notify_host = false });
                }
                zgui.endChild();
            } else {
                drawNoDevice();
            }
        },
        .clap => {
            drawClapDevice(state, ui_scale);
        },
        .none => {
            drawNoDevice();
        },
    }
}

fn drawNoDevice() void {
    zgui.spacing();
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
    zgui.textUnformatted("No device loaded. Select a plugin from the track header.");
    zgui.popStyleColor(.{ .count = 1 });
}

fn drawClapDevice(state: *State, ui_scale: f32) void {
    const plugin = state.device_clap_plugin orelse {
        drawNoDevice();
        return;
    };

    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_bright });
    zgui.text("CLAP: {s}", .{state.device_clap_name});
    zgui.popStyleColor(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = 12.0 * ui_scale });
    const track = &state.track_plugins[state.selectedTrack()];
    const button_label = if (track.gui_open) "Close Window" else "Open Window";
    if (zgui.button(button_label, .{ .w = 0, .h = 0 })) {
        track.gui_open = !track.gui_open;
    }

    zgui.separator();
    drawClapParamDump(plugin);
}

fn drawClapParamDump(plugin: *const clap.Plugin) void {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse {
        zgui.textUnformatted("No CLAP parameters exposed.");
        return;
    };
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const count = params.count(plugin);
    if (count == 0) {
        zgui.textUnformatted("No CLAP parameters exposed.");
        return;
    }

    if (!zgui.beginChild("clap_param_dump##device", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
        return;
    }
    defer zgui.endChild();

    if (!zgui.beginTable("clap_param_table##device", .{
        .column = 4,
        .flags = .{ .row_bg = true, .borders = .{ .inner_v = true, .inner_h = true } },
    })) {
        return;
    }
    defer zgui.endTable();

    zgui.tableSetupColumn("Parameter", .{});
    zgui.tableSetupColumn("ID", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 80 });
    zgui.tableSetupColumn("Default", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 110 });
    zgui.tableSetupColumn("Range", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 160 });
    zgui.tableHeadersRow();

    for (0..count) |i| {
        var info: clap.ext.params.Info = undefined;
        if (!params.getInfo(plugin, @intCast(i), &info)) continue;

        const name = sliceToNull(info.name[0..]);
        const module = sliceToNull(info.module[0..]);

        zgui.tableNextRow(.{});
        _ = zgui.tableNextColumn();
        if (module.len > 0) {
            var label_buf: [256]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{s}/{s}", .{ module, name }) catch "";
            zgui.textUnformatted(label);
        } else {
            zgui.textUnformatted(name);
        }

        _ = zgui.tableNextColumn();
        zgui.text("{d}", .{info.id});

        _ = zgui.tableNextColumn();
        zgui.text("{d:.4}", .{info.default_value});

        _ = zgui.tableNextColumn();
        zgui.text("{d:.4} .. {d:.4}", .{ info.min_value, info.max_value });
    }
}

fn sliceToNull(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}
