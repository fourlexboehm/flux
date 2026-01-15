const std = @import("std");
const zgui = @import("zgui");
const zsynth = @import("zsynth-core");
const clap = @import("clap-bindings");
const zsynth_view = zsynth.View;

pub const track_count = 4;
pub const scene_count = 8;

// Ableton-style color palette
const Colors = struct {
    // Backgrounds
    const bg_dark: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 };
    const bg_panel: [4]f32 = .{ 0.14, 0.14, 0.14, 1.0 };
    const bg_cell: [4]f32 = .{ 0.18, 0.18, 0.18, 1.0 };
    const bg_header: [4]f32 = .{ 0.12, 0.12, 0.12, 1.0 };

    // Clip states
    const clip_empty: [4]f32 = .{ 0.15, 0.15, 0.15, 1.0 };
    const clip_stopped: [4]f32 = .{ 0.22, 0.22, 0.22, 1.0 };
    const clip_queued: [4]f32 = .{ 0.90, 0.55, 0.10, 1.0 };
    const clip_playing: [4]f32 = .{ 0.35, 0.75, 0.35, 1.0 };

    // Accent & highlights
    const accent: [4]f32 = .{ 0.95, 0.50, 0.10, 1.0 };
    const accent_dim: [4]f32 = .{ 0.60, 0.35, 0.10, 1.0 };
    const selected: [4]f32 = .{ 0.30, 0.55, 0.80, 1.0 };
    const border: [4]f32 = .{ 0.25, 0.25, 0.25, 1.0 };

    // Text
    const text_bright: [4]f32 = .{ 0.90, 0.90, 0.90, 1.0 };
    const text_dim: [4]f32 = .{ 0.55, 0.55, 0.55, 1.0 };

    // Transport
    const transport_play: [4]f32 = .{ 0.35, 0.75, 0.35, 1.0 };
    const transport_stop: [4]f32 = .{ 0.75, 0.35, 0.35, 1.0 };

    // Sequencer
    const note_color: [4]f32 = .{ 0.40, 0.75, 0.50, 1.0 };
    const note_selected: [4]f32 = .{ 0.55, 0.85, 0.65, 1.0 };
    const playhead_bg: [4]f32 = .{ 0.25, 0.35, 0.45, 0.6 };
    const selection_rect: [4]f32 = .{ 0.4, 0.6, 0.9, 0.3 };
    const selection_rect_border: [4]f32 = .{ 0.5, 0.7, 1.0, 0.8 };
};

pub const ClipState = enum {
    empty,
    stopped,
    queued,
    playing,
};

pub const ClipSlot = struct {
    label: []const u8,
    state: ClipState,
};

pub const Track = struct {
    name: []const u8,
    volume: f32,
    mute: bool,
    solo: bool,
};

pub const BottomMode = enum {
    device,
    sequencer,
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

// Piano roll constants
pub const total_pitches = 128; // MIDI range C-1 to G9
pub const beats_per_bar = 4;
pub const default_clip_bars = 4;

pub const Note = struct {
    pitch: u8, // MIDI pitch 0-127
    start: f32, // Start time in beats
    duration: f32, // Duration in beats
};

pub const PianoRollClip = struct {
    allocator: std.mem.Allocator,
    length_beats: f32,
    notes: std.ArrayListUnmanaged(Note),

    pub fn init(allocator: std.mem.Allocator) PianoRollClip {
        return .{
            .allocator = allocator,
            .length_beats = default_clip_bars * beats_per_bar,
            .notes = .{},
        };
    }

    pub fn deinit(self: *PianoRollClip) void {
        self.notes.deinit(self.allocator);
    }

    pub fn addNote(self: *PianoRollClip, pitch: u8, start: f32, duration: f32) !void {
        try self.notes.append(self.allocator, .{ .pitch = pitch, .start = start, .duration = duration });
    }

    pub fn removeNoteAt(self: *PianoRollClip, index: usize) void {
        _ = self.notes.orderedRemove(index);
    }

    pub fn findNoteAt(self: *const PianoRollClip, pitch: u8, time: f32) ?usize {
        for (self.notes.items, 0..) |note, i| {
            if (note.pitch == pitch and time >= note.start and time < note.start + note.duration) {
                return i;
            }
        }
        return null;
    }
};

const ClipClipboardEntry = struct {
    track_offset: i32,
    scene_offset: i32,
    slot_state: ClipState,
    length_beats: f32,
    notes: std.ArrayListUnmanaged(Note),
};

fn quantizeIndexToBeats(index: i32) f32 {
    return switch (index) {
        0 => 0.25,
        1 => 0.5,
        2 => 1.0,
        3 => 2.0,
        4 => 4.0,
        else => 1.0,
    };
}

fn snapToStep(value: f32, step: f32) f32 {
    if (step <= 0) return value;
    return @floor(value / step) * step;
}

fn removeNoteWithSelection(clip: *PianoRollClip, selected_note_index: *?usize, index: usize) void {
    clip.removeNoteAt(index);
    if (selected_note_index.*) |selected| {
        if (selected == index) {
            selected_note_index.* = null;
        } else if (selected > index) {
            selected_note_index.* = selected - 1;
        }
    }
}

fn resetPianoClip(clip: *PianoRollClip) void {
    clip.length_beats = default_clip_bars * beats_per_bar;
    clip.notes.clearRetainingCapacity();
}

fn clearClipSelection(state: *State) void {
    for (&state.clip_selected) |*track_sel| {
        for (track_sel) |*sel| {
            sel.* = false;
        }
    }
}

fn anyClipSelected(state: *const State) bool {
    for (state.clip_selected) |track_sel| {
        for (track_sel) |sel| {
            if (sel) return true;
        }
    }
    return false;
}

fn clearClipClipboard(state: *State) void {
    for (state.clip_clipboard.items) |*entry| {
        entry.notes.deinit(state.allocator);
    }
    state.clip_clipboard.clearRetainingCapacity();
}

fn resetClipSlot(state: *State, track_index: usize, scene_index: usize) void {
    state.clips[track_index][scene_index].state = .empty;
    resetPianoClip(&state.piano_clips[track_index][scene_index]);
}

fn copySelectedClips(state: *State) void {
    var found_selection = false;
    var min_track: usize = track_count;
    var min_scene: usize = scene_count;
    for (0..track_count) |track_index| {
        for (0..scene_count) |scene_index| {
            if (state.clip_selected[track_index][scene_index]) {
                found_selection = true;
                min_track = @min(min_track, track_index);
                min_scene = @min(min_scene, scene_index);
            }
        }
    }

    if (!found_selection) return;

    clearClipClipboard(state);
    state.clip_clipboard_origin_track = min_track;
    state.clip_clipboard_origin_scene = min_scene;

    for (0..track_count) |track_index| {
        for (0..scene_count) |scene_index| {
            if (!state.clip_selected[track_index][scene_index]) continue;
            const slot = &state.clips[track_index][scene_index];
            const clip = &state.piano_clips[track_index][scene_index];
            if (slot.state == .empty and clip.notes.items.len == 0) continue;

            var notes_copy: std.ArrayListUnmanaged(Note) = .{};
            _ = notes_copy.appendSlice(state.allocator, clip.notes.items) catch {};
            const entry = ClipClipboardEntry{
                .track_offset = @as(i32, @intCast(track_index)) - @as(i32, @intCast(min_track)),
                .scene_offset = @as(i32, @intCast(scene_index)) - @as(i32, @intCast(min_scene)),
                .slot_state = if (slot.state == .playing) .stopped else slot.state,
                .length_beats = clip.length_beats,
                .notes = notes_copy,
            };
            _ = state.clip_clipboard.append(state.allocator, entry) catch {};
        }
    }
}

fn deleteSelectedClips(state: *State) void {
    var any_selected = false;
    for (0..track_count) |track_index| {
        for (0..scene_count) |scene_index| {
            if (state.clip_selected[track_index][scene_index]) {
                resetClipSlot(state, track_index, scene_index);
                any_selected = true;
            }
        }
    }
    if (any_selected) {
        clearClipSelection(state);
    }
}

const DragState = struct {
    active: bool,
    track: usize,
    scene: usize,
    start_len: u8,
};

const PianoRollDrag = struct {
    const Mode = enum {
        none,
        create,
        resize_right,
        move,
        resize_clip,
        select_rect, // Drag-to-select rectangle
    };

    mode: Mode,
    note_index: usize, // Index into clip.notes
    // For move: offset from note start to where mouse clicked (in beats)
    grab_offset_beats: f32,
    grab_offset_pitch: i32,
    // Original values for move (to allow snapping back)
    original_start: f32,
    original_pitch: u8,
    // For select_rect: start position of selection rectangle
    select_start_x: f32,
    select_start_y: f32,
};

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
    selected_track: usize,
    selected_scene: usize,
    playhead_beat: f32,
    clip_selected: [track_count][scene_count]bool,
    clip_clipboard: std.ArrayListUnmanaged(ClipClipboardEntry),
    clip_clipboard_origin_track: usize,
    clip_clipboard_origin_scene: usize,
    clip_drag_pending: bool,
    clip_drag_active: bool,
    clip_drag_additive: bool,
    clip_drag_start: [2]f32,
    clip_drag_current: [2]f32,
    drag: DragState,
    piano_drag: PianoRollDrag,
    selected_note_index: ?usize, // Primary selection for keyboard nav (last clicked)
    selected_notes: std.AutoArrayHashMapUnmanaged(usize, void), // All selected note indices
    piano_clipboard: std.ArrayListUnmanaged(Note), // Multiple notes for copy/paste
    piano_context_note_index: ?usize,
    piano_context_start: f32,
    piano_context_pitch: u8,
    piano_context_in_grid: bool,
    // Piano roll view state (continuous scroll)
    scroll_x: f32, // Horizontal scroll position (pixels)
    scroll_y: f32, // Vertical scroll position (pixels)
    beats_per_pixel: f32, // Horizontal zoom
    tracks: [track_count]Track,
    track_plugins: [track_count]TrackPluginUI,
    plugin_items: [:0]const u8,
    plugin_divider_index: ?i32,
    clips: [track_count][scene_count]ClipSlot,
    piano_clips: [track_count][scene_count]PianoRollClip,

    pub fn init(allocator: std.mem.Allocator) State {
        const tracks_data: [track_count]Track = .{
            .{ .name = "Track 1", .volume = 0.8, .mute = false, .solo = false },
            .{ .name = "Track 2", .volume = 0.8, .mute = false, .solo = false },
            .{ .name = "Track 3", .volume = 0.8, .mute = false, .solo = false },
            .{ .name = "Track 4", .volume = 0.8, .mute = false, .solo = false },
        };
        var clips_data: [track_count][scene_count]ClipSlot = undefined;
        for (&clips_data, 0..) |*track_clips, t| {
            for (track_clips, 0..) |*slot, s| {
                slot.* = .{
                    .label = switch (s) {
                        0 => "Intro",
                        1 => "Verse",
                        2 => "Build",
                        3 => "Chorus",
                        4 => "Bridge",
                        5 => "Drop",
                        6 => "Outro",
                        else => "Clip",
                    },
                    .state = if (t == 0 and s == 0) .playing else .stopped,
                };
            }
        }
        var track_plugins_data: [track_count]TrackPluginUI = undefined;
        for (&track_plugins_data) |*plugin| {
            plugin.* = .{
                .choice_index = 0,
                .gui_open = false,
                .last_valid_choice = 0,
            };
        }
        var piano_clips_data: [track_count][scene_count]PianoRollClip = undefined;
        for (&piano_clips_data) |*track_clips| {
            for (track_clips) |*clip| {
                clip.* = PianoRollClip.init(allocator);
            }
        }
        var clip_selected_data: [track_count][scene_count]bool = undefined;
        for (&clip_selected_data) |*track_sel| {
            for (track_sel) |*sel| {
                sel.* = false;
            }
        }

        return .{
            .allocator = allocator,
            .playing = true,
            .bpm = 120.0,
            .quantize_index = 2,
            .bottom_mode = .device,
            .bottom_panel_height = 300.0,
            .splitter_drag_start = 0.0,
            .zsynth = null,
            .device_kind = .none,
            .device_clap_plugin = null,
            .device_clap_name = "",
            .selected_track = 0,
            .selected_scene = 0,
            .playhead_beat = 0,
            .clip_selected = clip_selected_data,
            .clip_clipboard = .{},
            .clip_clipboard_origin_track = 0,
            .clip_clipboard_origin_scene = 0,
            .clip_drag_pending = false,
            .clip_drag_active = false,
            .clip_drag_additive = false,
            .clip_drag_start = .{ 0, 0 },
            .clip_drag_current = .{ 0, 0 },
            .drag = .{
                .active = false,
                .track = 0,
                .scene = 0,
                .start_len = 16,
            },
            .piano_drag = .{
                .mode = .none,
                .note_index = 0,
                .grab_offset_beats = 0,
                .grab_offset_pitch = 0,
                .original_start = 0,
                .original_pitch = 0,
                .select_start_x = 0,
                .select_start_y = 0,
            },
            .selected_note_index = null,
            .selected_notes = .{},
            .piano_clipboard = .{},
            .piano_context_note_index = null,
            .piano_context_start = 0,
            .piano_context_pitch = 60,
            .piano_context_in_grid = false,
            .scroll_x = 0, // Start at beat 0
            .scroll_y = 50 * 20.0, // Start around C4 area (row 50 * 20px row height)
            .beats_per_pixel = 0.02, // ~50 pixels per beat
            .tracks = tracks_data,
            .track_plugins = track_plugins_data,
            .plugin_items = plugin_items,
            .plugin_divider_index = null,
            .clips = clips_data,
            .piano_clips = piano_clips_data,
        };
    }

    pub fn deinit(self: *State) void {
        for (&self.piano_clips) |*track_clips| {
            for (track_clips) |*clip| {
                clip.deinit();
            }
        }
        clearClipClipboard(self);
        self.selected_notes.deinit(self.allocator);
        self.piano_clipboard.deinit(self.allocator);
    }
};

const quantize_items: [:0]const u8 = "1/4\x001/2\x001\x002\x004\x00";
const plugin_items: [:0]const u8 = "None\x00ZSynth\x00";

pub fn draw(state: *State, ui_scale: f32) void {
    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = display[1], .cond = .always });

    // Apply Ableton dark theme
    pushAbletonStyle();
    defer popAbletonStyle();

    if (zgui.begin("zdaw##root", .{ .flags = .{
        .no_collapse = true,
        .no_resize = true,
        .no_move = true,
        .no_title_bar = true,
        .no_scrollbar = true,
        .no_scroll_with_mouse = true,
    } })) {
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

        // Draw splitter bar
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

        // Handle drag
        if (zgui.isItemActivated()) {
            state.splitter_drag_start = state.bottom_panel_height;
        }
        if (is_active) {
            const drag_delta = zgui.getMouseDragDelta(.left, .{});
            state.bottom_panel_height = std.math.clamp(state.splitter_drag_start - drag_delta[1] / ui_scale, 100.0, 800.0);
        }

        // Bottom panel
        if (zgui.beginChild("bottom_panel##root", .{ .w = 0, .h = bottom_height, .child_flags = .{ .border = true }, .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
            drawBottomPanel(state, ui_scale);
        }
        zgui.endChild();
    }
    zgui.end();
}

fn pushAbletonStyle() void {
    // Window & frame backgrounds
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = Colors.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = Colors.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .popup_bg, .c = Colors.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = Colors.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = .{ 0.22, 0.22, 0.22, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = .{ 0.25, 0.25, 0.25, 1.0 } });

    // Headers
    zgui.pushStyleColor4f(.{ .idx = .header, .c = Colors.bg_header });
    zgui.pushStyleColor4f(.{ .idx = .header_hovered, .c = .{ 0.18, 0.18, 0.18, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .header_active, .c = Colors.accent_dim });

    // Buttons
    zgui.pushStyleColor4f(.{ .idx = .button, .c = Colors.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ 0.25, 0.25, 0.25, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.accent_dim });

    // Sliders
    zgui.pushStyleColor4f(.{ .idx = .slider_grab, .c = Colors.accent });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab_active, .c = Colors.accent });

    // Text
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_bright });
    zgui.pushStyleColor4f(.{ .idx = .text_disabled, .c = Colors.text_dim });

    // Borders & separators
    zgui.pushStyleColor4f(.{ .idx = .border, .c = Colors.border });
    zgui.pushStyleColor4f(.{ .idx = .separator, .c = Colors.border });

    // Table
    zgui.pushStyleColor4f(.{ .idx = .table_header_bg, .c = Colors.bg_header });
    zgui.pushStyleColor4f(.{ .idx = .table_row_bg, .c = Colors.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .table_row_bg_alt, .c = Colors.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .table_border_strong, .c = Colors.border });
    zgui.pushStyleColor4f(.{ .idx = .table_border_light, .c = .{ 0.20, 0.20, 0.20, 1.0 } });

    // Scrollbar
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_bg, .c = Colors.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab, .c = .{ 0.30, 0.30, 0.30, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab_hovered, .c = .{ 0.40, 0.40, 0.40, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab_active, .c = Colors.accent_dim });
}

fn popAbletonStyle() void {
    zgui.popStyleColor(.{ .count = 27 });
}

pub fn tick(state: *State, dt: f64) void {
    if (!state.playing) {
        return;
    }
    const clip = &state.piano_clips[state.selected_track][state.selected_scene];
    const beats_per_second = state.bpm / 60.0;
    state.playhead_beat += @as(f32, @floatCast(dt)) * @as(f32, @floatCast(beats_per_second));
    // Loop within clip length
    if (state.playhead_beat >= clip.length_beats) {
        state.playhead_beat = @mod(state.playhead_beat, clip.length_beats);
    }
}

fn drawTransport(state: *State, ui_scale: f32) void {
    const transport_h = 32.0 * ui_scale;
    const btn_size = 28.0 * ui_scale;
    const spacing = 16.0 * ui_scale;

    // Transport container with darker background
    const draw_list = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    const avail_w = zgui.getContentRegionAvail()[0];
    draw_list.addRectFilled(.{
        .pmin = .{ pos[0], pos[1] },
        .pmax = .{ pos[0] + avail_w, pos[1] + transport_h },
        .col = zgui.colorConvertFloat4ToU32(Colors.bg_header),
    });

    zgui.setCursorPosY(zgui.getCursorPosY() + 4.0 * ui_scale);

    // Play/Stop button with triangle icon
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
    // Draw play triangle or stop square
    if (state.playing) {
        // Stop square
        const sq_size = 10.0 * ui_scale;
        const cx = btn_pos[0] + btn_size / 2.0;
        const cy = btn_pos[1] + btn_size / 2.0;
        draw_list.addRectFilled(.{
            .pmin = .{ cx - sq_size / 2.0, cy - sq_size / 2.0 },
            .pmax = .{ cx + sq_size / 2.0, cy + sq_size / 2.0 },
            .col = zgui.colorConvertFloat4ToU32(play_color),
        });
    } else {
        // Play triangle
        const tri_size = 12.0 * ui_scale;
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

    // BPM display with value
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
    zgui.textUnformatted("BPM");
    zgui.popStyleColor(.{ .count = 1 });
    zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
    zgui.setNextItemWidth(100.0 * ui_scale);
    _ = zgui.sliderFloat("##transport_bpm", .{
        .v = &state.bpm,
        .min = 40.0,
        .max = 200.0,
        .cfmt = "%.0f",
    });

    zgui.sameLine(.{ .spacing = spacing });

    // Quantize
    zgui.setNextItemWidth(80.0 * ui_scale);
    _ = zgui.combo("##transport_quantize", .{
        .current_item = &state.quantize_index,
        .items_separated_by_zeros = quantize_items,
    });

    zgui.setCursorPosY(zgui.getCursorPosY() + 4.0 * ui_scale);
}

fn drawClipGrid(state: *State, ui_scale: f32) void {
    const row_height = 48.0 * ui_scale;
    const header_height = 28.0 * ui_scale;
    const scene_col_w = 50.0 * ui_scale;
    const track_col_w = 180.0 * ui_scale;
    const grid_pos = zgui.getCursorScreenPos();
    const grid_width = scene_col_w + track_count * track_col_w;
    const grid_height = header_height + (header_height + 4.0 * ui_scale) + scene_count * row_height;
    const mouse = zgui.getMousePos();
    const shift_down = zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift);
    const in_grid = mouse[0] >= grid_pos[0] and mouse[0] < grid_pos[0] + grid_width and
        mouse[1] >= grid_pos[1] and mouse[1] < grid_pos[1] + grid_height;
    var drag_blocked = false;
    var hit_clip = false;

    if (!zgui.beginTable("clip_grid", .{
        .column = track_count + 1,
        .flags = .{ .borders = .{ .inner_v = true }, .row_bg = false, .sizing = .fixed_fit },
    })) {
        return;
    }
    defer zgui.endTable();

    if (!zgui.isMouseDown(.left)) {
        state.clip_drag_pending = false;
        state.clip_drag_active = false;
    }

    if (state.clip_drag_active) {
        state.clip_drag_current = mouse;
        if (!state.clip_drag_additive) {
            clearClipSelection(state);
        }
    }

    // Setup columns
    zgui.tableSetupColumn("##scenes", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = scene_col_w });
    for (0..track_count) |_| {
        zgui.tableSetupColumn("##track", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = track_col_w });
    }

    // Track headers
    zgui.tableNextRow(.{ .min_row_height = header_height });
    _ = zgui.tableNextColumn();
    for (state.tracks) |track| {
        _ = zgui.tableNextColumn();
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
        zgui.textUnformatted(track.name);
        zgui.popStyleColor(.{ .count = 1 });
    }

    // Plugin row
    zgui.tableNextRow(.{ .min_row_height = header_height + 4.0 * ui_scale });
    _ = zgui.tableNextColumn();
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
    zgui.textUnformatted("Plugin");
    zgui.popStyleColor(.{ .count = 1 });
    for (&state.track_plugins, 0..) |*plugin_ui, t| {
        var label_buf: [32]u8 = undefined;
        var button_buf: [32]u8 = undefined;
        const select_label = std.fmt.bufPrintZ(&label_buf, "##plugin_select_t{d}", .{t}) catch "##plugin_select";
        const button_label = std.fmt.bufPrintZ(
            &button_buf,
            "{s}##plugin_t{d}",
            .{ if (plugin_ui.gui_open) "X" else "E", t },
        ) catch "E##plugin";
        _ = zgui.tableNextColumn();
        zgui.setNextItemWidth(120.0 * ui_scale);
        const changed = zgui.combo(select_label, .{
            .current_item = &plugin_ui.choice_index,
            .items_separated_by_zeros = state.plugin_items,
        });
        if (changed) {
            if (state.plugin_divider_index) |divider_index| {
                if (plugin_ui.choice_index == divider_index) {
                    plugin_ui.choice_index = plugin_ui.last_valid_choice;
                } else {
                    plugin_ui.last_valid_choice = plugin_ui.choice_index;
                }
            } else {
                plugin_ui.last_valid_choice = plugin_ui.choice_index;
            }
        }
        zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
        if (zgui.button(button_label, .{ .w = 28.0 * ui_scale, .h = 0 })) {
            plugin_ui.gui_open = !plugin_ui.gui_open;
        }
    }

    // Clip slots
    for (0..scene_count) |scene_index| {
        zgui.tableNextRow(.{ .min_row_height = row_height });

        // Scene column with launch button
        _ = zgui.tableNextColumn();
        const draw_list = zgui.getWindowDrawList();

        // Scene number
        var scene_buf: [8]u8 = undefined;
        const scene_label = std.fmt.bufPrintZ(&scene_buf, "{d}", .{scene_index + 1}) catch "?";
        zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
        zgui.textUnformatted(scene_label);
        zgui.popStyleColor(.{ .count = 1 });

        zgui.sameLine(.{ .spacing = 8.0 * ui_scale });

        // Scene launch triangle button
        const launch_size = 20.0 * ui_scale;
        const launch_pos = zgui.getCursorScreenPos();
        var launch_buf: [32]u8 = undefined;
        const launch_id = std.fmt.bufPrintZ(&launch_buf, "##scene_launch{d}", .{scene_index}) catch "##scene_launch";

        zgui.pushStyleColor4f(.{ .idx = .button, .c = Colors.bg_panel });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ 0.22, 0.22, 0.22, 1.0 } });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.accent_dim });
        if (zgui.button(launch_id, .{ .w = launch_size, .h = launch_size })) {
            for (0..track_count) |track_index| {
                for (0..scene_count) |slot_index| {
                    state.clips[track_index][slot_index].state = if (slot_index == scene_index) .playing else .stopped;
                }
            }
        }
        zgui.popStyleColor(.{ .count = 3 });

        // Draw launch triangle
        const tri_size = 8.0 * ui_scale;
        const cx = launch_pos[0] + launch_size / 2.0 + 1.0 * ui_scale;
        const cy = launch_pos[1] + launch_size / 2.0;
        draw_list.addTriangleFilled(.{
            .p1 = .{ cx - tri_size / 2.0, cy - tri_size / 2.0 },
            .p2 = .{ cx - tri_size / 2.0, cy + tri_size / 2.0 },
            .p3 = .{ cx + tri_size / 2.0, cy },
            .col = zgui.colorConvertFloat4ToU32(Colors.accent),
        });

        // Clip slots for each track
        for (0..track_count) |track_index| {
            _ = zgui.tableNextColumn();
            const slot = &state.clips[track_index][scene_index];
            drawClipSlot(
                state,
                slot,
                track_index,
                scene_index,
                track_col_w - 8.0 * ui_scale,
                row_height - 6.0 * ui_scale,
                ui_scale,
                &drag_blocked,
                &hit_clip,
            );
        }
    }

    if (zgui.isMouseClicked(.left) and in_grid and !drag_blocked and !hit_clip) {
        state.clip_drag_pending = true;
        state.clip_drag_start = mouse;
        state.clip_drag_current = mouse;
        state.clip_drag_additive = shift_down;
        if (!shift_down) {
            clearClipSelection(state);
        }
    } else if (zgui.isMouseClicked(.left) and in_grid) {
        state.clip_drag_pending = false;
        state.clip_drag_active = false;
        if (!shift_down and !hit_clip) {
            clearClipSelection(state);
        }
    }

    if (state.clip_drag_pending and !state.clip_drag_active and zgui.isMouseDragging(.left, 4.0)) {
        state.clip_drag_active = true;
        state.clip_drag_pending = false;
    }

    if (state.clip_drag_active) {
        const sel_min = .{
            @min(state.clip_drag_start[0], state.clip_drag_current[0]),
            @min(state.clip_drag_start[1], state.clip_drag_current[1]),
        };
        const sel_max = .{
            @max(state.clip_drag_start[0], state.clip_drag_current[0]),
            @max(state.clip_drag_start[1], state.clip_drag_current[1]),
        };
        const overlay_color = zgui.colorConvertFloat4ToU32(.{
            Colors.selected[0],
            Colors.selected[1],
            Colors.selected[2],
            0.2,
        });
        const border_color = zgui.colorConvertFloat4ToU32(Colors.selected);
        const draw_list = zgui.getWindowDrawList();
        draw_list.addRectFilled(.{ .pmin = sel_min, .pmax = sel_max, .col = overlay_color });
        draw_list.addRect(.{ .pmin = sel_min, .pmax = sel_max, .col = border_color, .thickness = 1.0 });
    }

    const keyboard_free = !zgui.isAnyItemActive();
    const modifier_down = zgui.isKeyDown(.left_super) or zgui.isKeyDown(.right_super) or
        zgui.isKeyDown(.left_ctrl) or zgui.isKeyDown(.right_ctrl);

    if (keyboard_free and (in_grid or anyClipSelected(state))) {
        if (modifier_down and zgui.isKeyPressed(.c, false)) {
            copySelectedClips(state);
        }

        if (modifier_down and zgui.isKeyPressed(.x, false)) {
            copySelectedClips(state);
            deleteSelectedClips(state);
        }

        if (modifier_down and zgui.isKeyPressed(.v, false)) {
            if (state.clip_clipboard.items.len > 0) {
                clearClipSelection(state);
                for (state.clip_clipboard.items) |entry| {
                    const track_index_i = @as(i32, @intCast(state.selected_track)) + entry.track_offset;
                    const scene_index_i = @as(i32, @intCast(state.selected_scene)) + entry.scene_offset;
                    if (track_index_i < 0 or scene_index_i < 0) continue;
                    const track_index: usize = @intCast(track_index_i);
                    const scene_index: usize = @intCast(scene_index_i);
                    if (track_index >= track_count or scene_index >= scene_count) continue;

                    const slot = &state.clips[track_index][scene_index];
                    const clip = &state.piano_clips[track_index][scene_index];
                    clip.notes.clearRetainingCapacity();
                    clip.length_beats = entry.length_beats;
                    _ = clip.notes.appendSlice(state.allocator, entry.notes.items) catch {};

                    const has_content = entry.notes.items.len > 0 or entry.slot_state != .empty;
                    slot.state = if (has_content) .stopped else .empty;
                    state.clip_selected[track_index][scene_index] = true;
                }
            }
        }

        if (zgui.isKeyPressed(.delete, false)) {
            deleteSelectedClips(state);
        }
    }
}

fn drawClipSlot(
    state: *State,
    slot: *ClipSlot,
    track_index: usize,
    scene_index: usize,
    width: f32,
    height: f32,
    ui_scale: f32,
    drag_blocked: *bool,
    hit_clip: *bool,
) void {
    const draw_list = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    const shift_down = zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift);
    const mouse = zgui.getMousePos();

    // Clip colors based on state
    const clip_color = switch (slot.state) {
        .empty => Colors.clip_empty,
        .stopped => Colors.clip_stopped,
        .queued => Colors.clip_queued,
        .playing => Colors.clip_playing,
    };

    // Play button dimensions
    const play_btn_w = 24.0 * ui_scale;
    const clip_w = width - play_btn_w - 4.0 * ui_scale;
    const clip_rect_min = pos;
    const clip_rect_max = .{ pos[0] + clip_w, pos[1] + height };
    const over_clip = mouse[0] >= clip_rect_min[0] and mouse[0] < clip_rect_max[0] and
        mouse[1] >= clip_rect_min[1] and mouse[1] < clip_rect_max[1];
    if (over_clip) {
        drag_blocked.* = true;
        hit_clip.* = true;
    }

    if (state.clip_drag_active) {
        const sel_min = .{
            @min(state.clip_drag_start[0], state.clip_drag_current[0]),
            @min(state.clip_drag_start[1], state.clip_drag_current[1]),
        };
        const sel_max = .{
            @max(state.clip_drag_start[0], state.clip_drag_current[0]),
            @max(state.clip_drag_start[1], state.clip_drag_current[1]),
        };
        const rect_min = pos;
        const rect_max = .{ pos[0] + clip_w, pos[1] + height };
        const intersects = !(rect_max[0] < sel_min[0] or rect_min[0] > sel_max[0] or
            rect_max[1] < sel_min[1] or rect_min[1] > sel_max[1]);
        if (intersects) {
            state.clip_selected[track_index][scene_index] = true;
        }
    }

    const is_selected = state.clip_selected[track_index][scene_index];
    const is_active = state.selected_track == track_index and state.selected_scene == scene_index;

    // Draw clip background with rounded corners
    const rounding = 3.0 * ui_scale;
    var bg_color = clip_color;
    if (is_selected) {
        bg_color = .{
            @min(1.0, clip_color[0] + 0.12),
            @min(1.0, clip_color[1] + 0.12),
            @min(1.0, clip_color[2] + 0.12),
            1.0,
        };
    }

    draw_list.addRectFilled(.{
        .pmin = pos,
        .pmax = .{ pos[0] + clip_w, pos[1] + height },
        .col = zgui.colorConvertFloat4ToU32(bg_color),
        .rounding = rounding,
        .flags = zgui.DrawFlags.round_corners_all,
    });

    // Selection border
    if (is_selected or is_active) {
        draw_list.addRect(.{
            .pmin = pos,
            .pmax = .{ pos[0] + clip_w, pos[1] + height },
            .col = zgui.colorConvertFloat4ToU32(if (is_selected) Colors.selected else Colors.accent),
            .rounding = rounding,
            .flags = zgui.DrawFlags.round_corners_all,
            .thickness = 2.0,
        });
    }

    // Clip label - centered vertically
    const text_color = if (slot.state == .playing or slot.state == .queued)
        zgui.colorConvertFloat4ToU32(.{ 0.1, 0.1, 0.1, 1.0 })
    else
        zgui.colorConvertFloat4ToU32(Colors.text_bright);
    const text_y = pos[1] + (height - 14.0 * ui_scale) / 2.0;
    draw_list.addText(.{ pos[0] + 6.0 * ui_scale, text_y }, text_color, "{s}", .{slot.label});

    // Invisible button for clip selection
    var clip_buf: [32]u8 = undefined;
    const clip_id = std.fmt.bufPrintZ(&clip_buf, "##clip_t{d}s{d}", .{ track_index, scene_index }) catch "##clip";
    if (zgui.invisibleButton(clip_id, .{ .w = clip_w, .h = height })) {
        state.selected_track = track_index;
        state.selected_scene = scene_index;
        state.selected_note_index = null;
        state.selected_notes.clearRetainingCapacity();
        if (!shift_down) {
            clearClipSelection(state);
        }
        state.clip_selected[track_index][scene_index] = true;
    }
    if (over_clip and zgui.isMouseClicked(.left)) {
        state.selected_track = track_index;
        state.selected_scene = scene_index;
        state.selected_note_index = null;
        state.selected_notes.clearRetainingCapacity();
        if (!shift_down) {
            clearClipSelection(state);
        }
        state.clip_selected[track_index][scene_index] = true;
    }

    zgui.sameLine(.{ .spacing = 4.0 * ui_scale });

    // Play button with triangle
    const play_pos = zgui.getCursorScreenPos();
    var play_buf: [32]u8 = undefined;
    const play_id = std.fmt.bufPrintZ(&play_buf, "##play_t{d}s{d}", .{ track_index, scene_index }) catch "##play";

    const is_playing = slot.state == .playing;
    const play_bg = if (is_playing) Colors.clip_playing else Colors.bg_cell;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = play_bg });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ play_bg[0] + 0.08, play_bg[1] + 0.08, play_bg[2] + 0.08, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.accent_dim });
    if (zgui.button(play_id, .{ .w = play_btn_w, .h = height })) {
        state.selected_track = track_index;
        state.selected_scene = scene_index;
        state.selected_note_index = null;
        state.selected_notes.clearRetainingCapacity();
        if (!shift_down) {
            clearClipSelection(state);
        }
        state.clip_selected[track_index][scene_index] = true;
        if (slot.state == .playing) {
            slot.state = .stopped;
        } else {
            for (0..scene_count) |slot_index| {
                state.clips[track_index][slot_index].state = if (slot_index == scene_index) .playing else .stopped;
            }
        }
    }
    const play_rect_min = play_pos;
    const play_rect_max = .{ play_pos[0] + play_btn_w, play_pos[1] + height };
    const over_play = mouse[0] >= play_rect_min[0] and mouse[0] < play_rect_max[0] and
        mouse[1] >= play_rect_min[1] and mouse[1] < play_rect_max[1];
    if (over_play) {
        drag_blocked.* = true;
        hit_clip.* = true;
    }
    zgui.popStyleColor(.{ .count = 3 });

    // Draw play triangle or stop square on the button
    const icon_size = 8.0 * ui_scale;
    const cx = play_pos[0] + play_btn_w / 2.0;
    const cy = play_pos[1] + height / 2.0;

    if (is_playing) {
        // Stop square
        draw_list.addRectFilled(.{
            .pmin = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
            .pmax = .{ cx + icon_size / 2.0, cy + icon_size / 2.0 },
            .col = zgui.colorConvertFloat4ToU32(.{ 0.1, 0.1, 0.1, 1.0 }),
        });
    } else {
        // Play triangle
        draw_list.addTriangleFilled(.{
            .p1 = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
            .p2 = .{ cx - icon_size / 2.0, cy + icon_size / 2.0 },
            .p3 = .{ cx + icon_size / 2.0 + 1.0, cy },
            .col = zgui.colorConvertFloat4ToU32(Colors.text_dim),
        });
    }
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
    const track_info = std.fmt.bufPrintZ(&track_buf, "  Track {d} / Scene {d}", .{ state.selected_track + 1, state.selected_scene + 1 }) catch "";
    zgui.textUnformatted(track_info);
    zgui.popStyleColor(.{ .count = 1 });

    zgui.separator();

    switch (state.bottom_mode) {
        .device => {
            drawDevicePanel(state, ui_scale);
        },
        .sequencer => {
            drawSequencer(state, ui_scale);
        },
    }
}

fn drawDevicePanel(state: *State, ui_scale: f32) void {
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
    const track = &state.track_plugins[state.selected_track];
    const button_label = if (track.gui_open) "Close Window" else "Open Window";
    if (zgui.button(button_label, .{ .w = 140.0 * ui_scale, .h = 0 })) {
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

fn drawSequencer(state: *State, ui_scale: f32) void {
    const clip = &state.piano_clips[state.selected_track][state.selected_scene];
    const clip_label = state.clips[state.selected_track][state.selected_scene].label;

    // Layout constants
    const key_width = 48.0 * ui_scale;
    const ruler_height = 24.0 * ui_scale;
    const min_note_duration: f32 = 0.0625; // 1/16 note minimum
    const resize_handle_width = 8.0 * ui_scale;
    const clip_end_handle_width = 10.0 * ui_scale;
    const quantize_beats = quantizeIndexToBeats(state.quantize_index);

    // Zoom - pixels per beat
    const pixels_per_beat = 60.0 / state.beats_per_pixel;
    const row_height = 20.0 * ui_scale; // Taller rows for better visibility

    const mouse = zgui.getMousePos();
    const mouse_down = zgui.isMouseDown(.left);

    // Header with clip name, length, and zoom slider
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_bright });
    zgui.text("{s}", .{clip_label});
    zgui.popStyleColor(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = 20.0 * ui_scale });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
    zgui.text("{d:.0} bars", .{clip.length_beats / beats_per_bar});
    zgui.popStyleColor(.{ .count = 1 });

    // Scroll/Zoom bar - drag left/right to scroll, drag up/down to zoom
    zgui.sameLine(.{ .spacing = 30.0 * ui_scale });

    const scrollbar_width = 200.0 * ui_scale;
    const scrollbar_height = 16.0 * ui_scale;

    // Get position for drawing
    const bar_pos = zgui.getCursorScreenPos();

    // Create invisible button for interaction
    _ = zgui.invisibleButton("##scroll_zoom_bar", .{ .w = scrollbar_width, .h = scrollbar_height });
    const bar_hovered = zgui.isItemHovered(.{});
    const bar_active = zgui.isItemActive();

    // Handle drag
    if (bar_active) {
        const delta = zgui.getMouseDragDelta(.left, .{});
        if (delta[0] != 0 or delta[1] != 0) {
            // Horizontal drag = scroll (scaled by zoom level)
            const scroll_sensitivity = 2.0;
            state.scroll_x += delta[0] * scroll_sensitivity;

            // Vertical drag = zoom (up = zoom in, down = zoom out)
            const zoom_sensitivity = 0.003;
            state.beats_per_pixel = std.math.clamp(
                state.beats_per_pixel + delta[1] * zoom_sensitivity,
                0.005, // Max zoom in
                1.0, // Max zoom out - can see entire clip
            );

            zgui.resetMouseDragDelta(.left);
        }
        zgui.setMouseCursor(.resize_all);
    } else if (bar_hovered) {
        zgui.setMouseCursor(.resize_all);
    }

    // Draw the scrollbar background
    const draw_list = zgui.getWindowDrawList();
    const bar_color = if (bar_active)
        zgui.colorConvertFloat4ToU32(.{ 0.4, 0.4, 0.5, 1.0 })
    else if (bar_hovered)
        zgui.colorConvertFloat4ToU32(.{ 0.35, 0.35, 0.4, 1.0 })
    else
        zgui.colorConvertFloat4ToU32(.{ 0.25, 0.25, 0.3, 1.0 });

    draw_list.addRectFilled(.{
        .pmin = .{ bar_pos[0], bar_pos[1] },
        .pmax = .{ bar_pos[0] + scrollbar_width, bar_pos[1] + scrollbar_height },
        .col = bar_color,
        .rounding = 4.0,
    });

    // Draw a thumb indicator showing current scroll position
    // Calculate thumb size and position based on visible area vs total content
    const max_beats_preview = @max(clip.length_beats + 16, 64);
    const content_width_preview = max_beats_preview * pixels_per_beat;
    const avail_preview = zgui.getContentRegionAvail();
    const grid_view_width_preview = avail_preview[0] - key_width;

    const thumb_ratio = @min(1.0, grid_view_width_preview / content_width_preview);
    const thumb_width = @max(20.0 * ui_scale, scrollbar_width * thumb_ratio);
    const max_thumb_x = scrollbar_width - thumb_width;
    const scroll_ratio = if (content_width_preview > grid_view_width_preview)
        state.scroll_x / (content_width_preview - grid_view_width_preview)
    else
        0.0;
    const thumb_x = bar_pos[0] + scroll_ratio * max_thumb_x;

    draw_list.addRectFilled(.{
        .pmin = .{ thumb_x, bar_pos[1] + 2 },
        .pmax = .{ thumb_x + thumb_width, bar_pos[1] + scrollbar_height - 2 },
        .col = zgui.colorConvertFloat4ToU32(Colors.accent),
        .rounding = 3.0,
    });

    // Show zoom level indicator (higher % = more zoomed in)
    zgui.sameLine(.{ .spacing = 10.0 * ui_scale });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.text_dim });
    const zoom_pct = (1.0 - state.beats_per_pixel) / (1.0 - 0.005) * 100;
    zgui.text("{d:.0}%", .{zoom_pct});
    zgui.popStyleColor(.{ .count = 1 });

    zgui.spacing();

    // Calculate content size (full piano roll dimensions)
    const content_height = 128.0 * row_height;
    const max_beats = @max(clip.length_beats + 16, 64); // Extra space beyond clip end
    const content_width = max_beats * pixels_per_beat;

    // Get available space for the entire piano roll area
    const avail = zgui.getContentRegionAvail();
    const total_width = avail[0];
    const total_height = avail[1];

    const base_pos = zgui.getCursorScreenPos();

    // Define regions
    const keys_area_x = base_pos[0];
    const ruler_area_y = base_pos[1];
    const grid_area_x = base_pos[0] + key_width;
    const grid_area_y = base_pos[1] + ruler_height;
    const grid_view_width = total_width - key_width;
    const grid_view_height = total_height - ruler_height;

    // Clamp scroll values to valid range
    const max_scroll_x = @max(0.0, content_width - grid_view_width);
    const max_scroll_y = @max(0.0, content_height - grid_view_height);
    state.scroll_x = std.math.clamp(state.scroll_x, 0, max_scroll_x);
    state.scroll_y = std.math.clamp(state.scroll_y, 0, max_scroll_y);
    const scroll_x = state.scroll_x;
    const scroll_y = state.scroll_y;

    // Grid window position is grid_area position
    const grid_window_pos: [2]f32 = .{ grid_area_x, grid_area_y };

    {

        // Calculate visible ranges with proper clamping
        const first_visible_beat = scroll_x / pixels_per_beat;
        const last_visible_beat = (scroll_x + grid_view_width) / pixels_per_beat;

        // Safe row calculation - clamp to valid MIDI range [0, 127]
        const first_row_f = @max(0, @floor(scroll_y / row_height));
        const last_row_f = @min(127, @ceil((scroll_y + grid_view_height) / row_height));
        const first_visible_row: usize = @intFromFloat(first_row_f);
        const last_visible_row: usize = @intFromFloat(@max(first_row_f, last_row_f));

        const is_black_key = [_]bool{ false, true, false, true, false, false, true, false, true, false, true, false };

        // Clip to grid area
        draw_list.pushClipRect(.{
            .pmin = .{ grid_window_pos[0], grid_window_pos[1] },
            .pmax = .{ grid_window_pos[0] + grid_view_width, grid_window_pos[1] + grid_view_height },
        });

        // Draw grid background rows
        var row: usize = first_visible_row;
        while (row <= last_visible_row) : (row += 1) {
            const pitch: u8 = if (row <= 127) @intCast(127 - row) else 0;
            const y = grid_window_pos[1] + @as(f32, @floatFromInt(row)) * row_height - scroll_y;

            if (y < grid_window_pos[1] - row_height or y > grid_window_pos[1] + grid_view_height) continue;

            const note_in_octave = pitch % 12;
            const row_color = if (is_black_key[note_in_octave])
                zgui.colorConvertFloat4ToU32(.{ 0.10, 0.10, 0.10, 1.0 })
            else if (note_in_octave == 0)
                zgui.colorConvertFloat4ToU32(.{ 0.18, 0.18, 0.18, 1.0 }) // Highlight C rows
            else
                zgui.colorConvertFloat4ToU32(.{ 0.14, 0.14, 0.14, 1.0 });

            draw_list.addRectFilled(.{
                .pmin = .{ grid_window_pos[0], y },
                .pmax = .{ grid_window_pos[0] + content_width, y + row_height },
                .col = row_color,
            });

            // Horizontal grid line - brighter for C notes
            const line_col = if (note_in_octave == 0)
                zgui.colorConvertFloat4ToU32(.{ 0.30, 0.30, 0.30, 1.0 })
            else
                zgui.colorConvertFloat4ToU32(.{ 0.20, 0.20, 0.20, 1.0 });
            draw_list.addLine(.{
                .p1 = .{ grid_window_pos[0], y + row_height },
                .p2 = .{ grid_window_pos[0] + content_width, y + row_height },
                .col = line_col,
                .thickness = if (note_in_octave == 0) 1.0 else 0.5,
            });
        }

        // Draw vertical grid lines with subdivisions (1/16 note grid)
        var sub_beat: f32 = @floor(first_visible_beat * 4) / 4;
        while (sub_beat <= @min(last_visible_beat + 1, max_beats)) : (sub_beat += 0.25) {
            const x = grid_window_pos[0] + sub_beat * pixels_per_beat - scroll_x;
            const beat_16th = @as(i32, @intFromFloat(sub_beat * 4));
            const is_bar = @mod(beat_16th, 16) == 0; // Every 4 beats = bar
            const is_beat = @mod(beat_16th, 4) == 0; // Every beat
            const is_8th = @mod(beat_16th, 2) == 0; // Every 1/8 note

            const line_color = if (is_bar)
                zgui.colorConvertFloat4ToU32(.{ 0.45, 0.45, 0.45, 1.0 })
            else if (is_beat)
                zgui.colorConvertFloat4ToU32(.{ 0.32, 0.32, 0.32, 1.0 })
            else if (is_8th)
                zgui.colorConvertFloat4ToU32(.{ 0.24, 0.24, 0.24, 1.0 })
            else
                zgui.colorConvertFloat4ToU32(.{ 0.18, 0.18, 0.18, 1.0 });

            const thickness: f32 = if (is_bar) 2.0 else if (is_beat) 1.0 else 0.5;

            draw_list.addLine(.{
                .p1 = .{ x, grid_window_pos[1] },
                .p2 = .{ x, grid_window_pos[1] + content_height },
                .col = line_color,
                .thickness = thickness,
            });
        }

        // Draw clip end boundary (draggable)
        const clip_end_x = grid_window_pos[0] + clip.length_beats * pixels_per_beat - scroll_x;

        // Check if mouse is over clip end handle (direct hit test)
        const clip_end_hovered = mouse[0] >= clip_end_x - clip_end_handle_width and
            mouse[0] <= clip_end_x + clip_end_handle_width and
            mouse[1] >= grid_window_pos[1] and
            mouse[1] <= grid_window_pos[1] + grid_view_height;

        // Handle clip end drag - check this FIRST before note interactions
        if (clip_end_hovered and state.piano_drag.mode == .none) {
            zgui.setMouseCursor(.resize_ew);
            if (zgui.isMouseClicked(.left)) {
                state.piano_drag = .{
                    .mode = .resize_clip,
                    .note_index = 0,
                    .grab_offset_beats = 0,
                    .grab_offset_pitch = 0,
                    .original_start = clip.length_beats,
                    .original_pitch = 0,
                    .select_start_x = 0,
                    .select_start_y = 0,
                };
            }
        } else if (state.piano_drag.mode == .resize_clip) {
            zgui.setMouseCursor(.resize_ew);
        }

        // Now draw the clip end visuals
        if (clip_end_x > grid_window_pos[0] - clip_end_handle_width and clip_end_x < grid_window_pos[0] + grid_view_width + clip_end_handle_width) {
            // Semi-transparent area beyond clip
            if (clip_end_x < grid_window_pos[0] + grid_view_width) {
                draw_list.addRectFilled(.{
                    .pmin = .{ clip_end_x, grid_window_pos[1] },
                    .pmax = .{ grid_window_pos[0] + grid_view_width, grid_window_pos[1] + grid_view_height },
                    .col = zgui.colorConvertFloat4ToU32(.{ 0.0, 0.0, 0.0, 0.4 }),
                });
            }

            // Clip end line - bright when hovered or dragging
            const end_color = if (clip_end_hovered or state.piano_drag.mode == .resize_clip)
                Colors.accent
            else
                Colors.accent_dim;
            draw_list.addLine(.{
                .p1 = .{ clip_end_x, grid_window_pos[1] },
                .p2 = .{ clip_end_x, grid_window_pos[1] + grid_view_height },
                .col = zgui.colorConvertFloat4ToU32(end_color),
                .thickness = 3.0,
            });

            // Drag handle indicator (triangle at top)
            draw_list.addTriangleFilled(.{
                .p1 = .{ clip_end_x - 6, grid_window_pos[1] },
                .p2 = .{ clip_end_x + 6, grid_window_pos[1] },
                .p3 = .{ clip_end_x, grid_window_pos[1] + 10 },
                .col = zgui.colorConvertFloat4ToU32(end_color),
            });
        }

        // Draw playhead
        if (state.playing) {
            const playhead_x = grid_window_pos[0] + state.playhead_beat * pixels_per_beat - scroll_x;
            if (playhead_x >= grid_window_pos[0] and playhead_x <= grid_window_pos[0] + grid_view_width) {
                draw_list.addLine(.{
                    .p1 = .{ playhead_x, grid_window_pos[1] },
                    .p2 = .{ playhead_x, grid_window_pos[1] + grid_view_height },
                    .col = zgui.colorConvertFloat4ToU32(Colors.accent),
                    .thickness = 2.0,
                });
            }
        }

        // Draw notes
        var right_click_note_index: ?usize = null;
        var left_click_note = false;
        for (clip.notes.items, 0..) |note, note_idx| {
            const note_row = 127 - @as(usize, note.pitch);
            const note_end = note.start + note.duration;

            // Skip if not visible
            if (note_row < first_visible_row or note_row > last_visible_row) continue;
            if (note_end < first_visible_beat or note.start > last_visible_beat) continue;

            const note_x = grid_window_pos[0] + note.start * pixels_per_beat - scroll_x;
            const note_y = grid_window_pos[1] + @as(f32, @floatFromInt(note_row)) * row_height - scroll_y;
            const note_w = note.duration * pixels_per_beat;

            // Check if note is selected (in multi-selection set)
            const is_selected = state.selected_notes.contains(note_idx);

            // Note body
            const note_color = if (is_selected) Colors.note_selected else Colors.note_color;
            draw_list.addRectFilled(.{
                .pmin = .{ note_x + 1, note_y + 1 },
                .pmax = .{ note_x + note_w - 1, note_y + row_height - 1 },
                .col = zgui.colorConvertFloat4ToU32(note_color),
                .rounding = 2.0,
            });

            // Selection highlight border
            if (is_selected) {
                draw_list.addRect(.{
                    .pmin = .{ note_x, note_y },
                    .pmax = .{ note_x + note_w, note_y + row_height },
                    .col = zgui.colorConvertFloat4ToU32(.{ 1.0, 1.0, 1.0, 0.8 }),
                    .rounding = 3.0,
                    .thickness = 2.0,
                });
            }

            // Resize handle (subtle darker right edge)
            const handle_x = note_x + note_w - resize_handle_width;
            const handle_color = if (is_selected) [4]f32{ 0.45, 0.75, 0.55, 1.0 } else [4]f32{ 0.28, 0.58, 0.38, 1.0 };
            draw_list.addRectFilled(.{
                .pmin = .{ @max(note_x + 1, handle_x), note_y + 1 },
                .pmax = .{ note_x + note_w - 1, note_y + row_height - 1 },
                .col = zgui.colorConvertFloat4ToU32(handle_color),
                .rounding = 2.0,
                .flags = zgui.DrawFlags.round_corners_right,
            });

            // Interaction
            const over_note = mouse[0] >= note_x and mouse[0] < note_x + note_w and
                mouse[1] >= note_y and mouse[1] < note_y + row_height;
            const over_handle = mouse[0] >= handle_x;

            if (over_note and state.piano_drag.mode == .none) {
                if (over_handle) {
                    zgui.setMouseCursor(.resize_ew);
                } else {
                    zgui.setMouseCursor(.resize_all);
                }

                const shift_down_note = zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift);

                if (zgui.isMouseClicked(.left)) {
                    const grab_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
                    const already_selected = state.selected_notes.contains(note_idx);

                    // Handle selection
                    if (shift_down_note) {
                        // Shift+click: toggle this note in selection
                        if (already_selected) {
                            _ = state.selected_notes.orderedRemove(note_idx);
                        } else {
                            state.selected_notes.put(state.allocator, note_idx, {}) catch {};
                        }
                    } else if (!already_selected) {
                        // Regular click on unselected note: clear selection and select only this note
                        state.selected_notes.clearRetainingCapacity();
                        state.selected_notes.put(state.allocator, note_idx, {}) catch {};
                    }
                    // If already selected and no shift, keep the multi-selection for dragging
                    state.selected_note_index = note_idx;

                    // Start drag operation
                    state.piano_drag = .{
                        .mode = if (over_handle) .resize_right else .move,
                        .note_index = note_idx,
                        .grab_offset_beats = grab_beat - note.start,
                        .grab_offset_pitch = 0,
                        .original_start = note.start,
                        .original_pitch = note.pitch,
                        .select_start_x = 0,
                        .select_start_y = 0,
                    };
                    left_click_note = true;
                }

                if (zgui.isMouseClicked(.right)) {
                    right_click_note_index = note_idx;
                    state.selected_note_index = note_idx;
                    // Add to selection if not already selected
                    if (!state.selected_notes.contains(note_idx)) {
                        state.selected_notes.clearRetainingCapacity();
                        state.selected_notes.put(state.allocator, note_idx, {}) catch {};
                    }
                }
            }
        }

        draw_list.popClipRect();

        // ========== INTERACTION HANDLING ==========

        // Check if mouse is in grid area
        const in_grid = mouse[0] >= grid_window_pos[0] and mouse[0] < grid_window_pos[0] + grid_view_width and
            mouse[1] >= grid_window_pos[1] and mouse[1] < grid_window_pos[1] + grid_view_height;

        const modifier_down = zgui.isKeyDown(.left_super) or zgui.isKeyDown(.right_super) or
            zgui.isKeyDown(.left_ctrl) or zgui.isKeyDown(.right_ctrl);
        const shift_down = zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift);
        const keyboard_free = !zgui.isAnyItemActive();

        // Copy selected notes (Ctrl/Cmd+C)
        if (keyboard_free and modifier_down and zgui.isKeyPressed(.c, false)) {
            if (state.selected_notes.count() > 0) {
                state.piano_clipboard.clearRetainingCapacity();
                // Find the earliest note start time for relative positioning
                var min_start: f32 = std.math.floatMax(f32);
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        min_start = @min(min_start, clip.notes.items[idx].start);
                    }
                }
                // Copy notes with relative positions
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        var note_copy = clip.notes.items[idx];
                        note_copy.start -= min_start; // Store relative to first note
                        state.piano_clipboard.append(state.allocator, note_copy) catch {};
                    }
                }
            }
        }

        // Cut selected notes (Ctrl/Cmd+X)
        if (keyboard_free and modifier_down and zgui.isKeyPressed(.x, false)) {
            if (state.selected_notes.count() > 0) {
                state.piano_clipboard.clearRetainingCapacity();
                // Find the earliest note start time for relative positioning
                var min_start: f32 = std.math.floatMax(f32);
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        min_start = @min(min_start, clip.notes.items[idx].start);
                    }
                }
                // Copy notes with relative positions
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        var note_copy = clip.notes.items[idx];
                        note_copy.start -= min_start;
                        state.piano_clipboard.append(state.allocator, note_copy) catch {};
                    }
                }
                // Delete selected notes (in reverse order to maintain indices)
                var indices_to_delete: std.ArrayListUnmanaged(usize) = .{};
                defer indices_to_delete.deinit(state.allocator);
                for (state.selected_notes.keys()) |idx| {
                    indices_to_delete.append(state.allocator, idx) catch {};
                }
                std.mem.sort(usize, indices_to_delete.items, {}, std.sort.desc(usize));
                for (indices_to_delete.items) |idx| {
                    if (idx < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(idx);
                    }
                }
                state.selected_notes.clearRetainingCapacity();
                state.selected_note_index = null;
            }
        }

        // Paste notes (Ctrl/Cmd+V)
        if (keyboard_free and modifier_down and zgui.isKeyPressed(.v, false)) {
            if (state.piano_clipboard.items.len > 0 and in_grid) {
                const click_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
                const click_row = (mouse[1] - grid_window_pos[1] + scroll_y) / row_height;
                var click_pitch_i: i32 = 127 - @as(i32, @intFromFloat(click_row));
                click_pitch_i = std.math.clamp(click_pitch_i, 0, 127);
                const snapped_start = snapToStep(click_beat, quantize_beats);

                // Find pitch offset (paste at mouse pitch relative to first note)
                const first_pitch: i32 = @intCast(state.piano_clipboard.items[0].pitch);
                const pitch_offset = click_pitch_i - first_pitch;

                state.selected_notes.clearRetainingCapacity();
                for (state.piano_clipboard.items) |copied| {
                    const new_start = snapped_start + copied.start;
                    if (new_start >= 0 and new_start < clip.length_beats) {
                        const duration = @min(copied.duration, clip.length_beats - new_start);
                        if (duration >= min_note_duration) {
                            var new_pitch_i: i32 = @as(i32, copied.pitch) + pitch_offset;
                            new_pitch_i = std.math.clamp(new_pitch_i, 0, 127);
                            const new_pitch: u8 = @intCast(new_pitch_i);
                            clip.addNote(new_pitch, new_start, duration) catch {};
                            // Select newly pasted notes
                            const new_idx = clip.notes.items.len - 1;
                            state.selected_notes.put(state.allocator, new_idx, {}) catch {};
                            state.selected_note_index = new_idx;
                        }
                    }
                }
            }
        }

        // Delete selected notes (Delete key)
        if (keyboard_free and in_grid and zgui.isKeyPressed(.delete, false)) {
            if (state.selected_notes.count() > 0) {
                // Delete in reverse order to maintain indices
                var indices_to_delete: std.ArrayListUnmanaged(usize) = .{};
                defer indices_to_delete.deinit(state.allocator);
                for (state.selected_notes.keys()) |idx| {
                    indices_to_delete.append(state.allocator, idx) catch {};
                }
                std.mem.sort(usize, indices_to_delete.items, {}, std.sort.desc(usize));
                for (indices_to_delete.items) |idx| {
                    if (idx < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(idx);
                    }
                }
                state.selected_notes.clearRetainingCapacity();
                state.selected_note_index = null;
            }
        }

        // Select all (Ctrl/Cmd+A)
        if (keyboard_free and modifier_down and zgui.isKeyPressed(.a, false)) {
            state.selected_notes.clearRetainingCapacity();
            for (clip.notes.items, 0..) |_, idx| {
                state.selected_notes.put(state.allocator, idx, {}) catch {};
            }
            if (clip.notes.items.len > 0) {
                state.selected_note_index = 0;
            }
        }

        // Arrow key handling for all selected notes
        if (keyboard_free and in_grid and state.piano_drag.mode == .none and state.selected_notes.count() > 0) {
            // Capture keyboard to prevent system bonk sound on macOS
            zgui.setNextFrameWantCaptureKeyboard(true);

            if (shift_down) {
                // Shift+Arrow: adjust duration of all selected notes
                if (zgui.isKeyPressed(.left_arrow, true)) {
                    for (state.selected_notes.keys()) |idx| {
                        if (idx < clip.notes.items.len) {
                            const note = &clip.notes.items[idx];
                            note.duration = @max(min_note_duration, note.duration - quantize_beats);
                        }
                    }
                }
                if (zgui.isKeyPressed(.right_arrow, true)) {
                    for (state.selected_notes.keys()) |idx| {
                        if (idx < clip.notes.items.len) {
                            const note = &clip.notes.items[idx];
                            note.duration = @min(clip.length_beats - note.start, note.duration + quantize_beats);
                        }
                    }
                }
            } else {
                // Arrow: move all selected notes
                if (zgui.isKeyPressed(.left_arrow, true)) {
                    for (state.selected_notes.keys()) |idx| {
                        if (idx < clip.notes.items.len) {
                            const note = &clip.notes.items[idx];
                            note.start = @max(0, note.start - quantize_beats);
                        }
                    }
                }
                if (zgui.isKeyPressed(.right_arrow, true)) {
                    for (state.selected_notes.keys()) |idx| {
                        if (idx < clip.notes.items.len) {
                            const note = &clip.notes.items[idx];
                            note.start = @min(clip.length_beats - note.duration, note.start + quantize_beats);
                        }
                    }
                }
                if (zgui.isKeyPressed(.up_arrow, true)) {
                    for (state.selected_notes.keys()) |idx| {
                        if (idx < clip.notes.items.len) {
                            const note = &clip.notes.items[idx];
                            const pitch_i: i32 = @min(127, @as(i32, note.pitch) + 1);
                            note.pitch = @intCast(pitch_i);
                        }
                    }
                }
                if (zgui.isKeyPressed(.down_arrow, true)) {
                    for (state.selected_notes.keys()) |idx| {
                        if (idx < clip.notes.items.len) {
                            const note = &clip.notes.items[idx];
                            const pitch_i: i32 = @max(0, @as(i32, note.pitch) - 1);
                            note.pitch = @intCast(pitch_i);
                        }
                    }
                }
            }
        }

        // Middle mouse button pan
        if (in_grid and zgui.isMouseDragging(.middle, -1.0)) {
            const delta = zgui.getMouseDragDelta(.middle, .{});
            state.scroll_x = std.math.clamp(state.scroll_x - delta[0], 0, max_scroll_x);
            state.scroll_y = std.math.clamp(state.scroll_y - delta[1], 0, max_scroll_y);
            zgui.resetMouseDragDelta(.middle);
        }

        if (in_grid and zgui.isMouseClicked(.right) and state.piano_drag.mode == .none) {
            const click_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
            const click_row = (mouse[1] - grid_window_pos[1] + scroll_y) / row_height;
            var click_pitch_i: i32 = 127 - @as(i32, @intFromFloat(click_row));
            click_pitch_i = std.math.clamp(click_pitch_i, 0, 127);
            const click_pitch: u8 = @intCast(click_pitch_i);
            state.piano_context_note_index = right_click_note_index;
            state.piano_context_start = snapToStep(click_beat, quantize_beats);
            state.piano_context_pitch = click_pitch;
            state.piano_context_in_grid = true;
            zgui.openPopup("piano_roll_ctx", .{});
        }

        // Handle double-click on empty grid to create note
        if (in_grid and zgui.isMouseDoubleClicked(.left) and state.piano_drag.mode == .none and !left_click_note) {
            const click_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
            const click_row = (mouse[1] - grid_window_pos[1] + scroll_y) / row_height;
            const click_pitch_i: i32 = 127 - @as(i32, @intFromFloat(click_row));

            if (click_beat >= 0 and click_beat < clip.length_beats and click_pitch_i >= 0 and click_pitch_i < 128) {
                const click_pitch: u8 = @intCast(click_pitch_i);
                const snapped_start = snapToStep(click_beat, quantize_beats);
                const max_duration = clip.length_beats - snapped_start;
                const note_duration = @min(quantize_beats, max_duration);

                if (note_duration >= min_note_duration) {
                    clip.addNote(click_pitch, snapped_start, note_duration) catch {};
                    const new_idx = clip.notes.items.len - 1;
                    state.selected_notes.clearRetainingCapacity();
                    state.selected_notes.put(state.allocator, new_idx, {}) catch {};
                    state.selected_note_index = new_idx;
                    state.piano_drag = .{
                        .mode = .create,
                        .note_index = new_idx,
                        .grab_offset_beats = 0,
                        .grab_offset_pitch = 0,
                        .original_start = snapped_start,
                        .original_pitch = click_pitch,
                        .select_start_x = 0,
                        .select_start_y = 0,
                    };
                }
            }
        }

        // Handle single click on empty grid to start selection rectangle
        if (in_grid and zgui.isMouseClicked(.left) and state.piano_drag.mode == .none and !left_click_note) {
            // Clear selection unless shift is held
            if (!shift_down) {
                state.selected_notes.clearRetainingCapacity();
                state.selected_note_index = null;
            }
            // Start selection rectangle drag
            state.piano_drag = .{
                .mode = .select_rect,
                .note_index = 0,
                .grab_offset_beats = 0,
                .grab_offset_pitch = 0,
                .original_start = 0,
                .original_pitch = 0,
                .select_start_x = mouse[0],
                .select_start_y = mouse[1],
            };
        }

        // Handle ongoing drag
        if (state.piano_drag.mode != .none) {
            if (!mouse_down) {
                // On mouse release for select_rect, finalize selection
                if (state.piano_drag.mode == .select_rect) {
                    const sel_x1 = @min(state.piano_drag.select_start_x, mouse[0]);
                    const sel_y1 = @min(state.piano_drag.select_start_y, mouse[1]);
                    const sel_x2 = @max(state.piano_drag.select_start_x, mouse[0]);
                    const sel_y2 = @max(state.piano_drag.select_start_y, mouse[1]);

                    // Select all notes that intersect with the selection rectangle
                    for (clip.notes.items, 0..) |note, note_idx| {
                        const note_row = 127 - @as(usize, note.pitch);
                        const note_x = grid_window_pos[0] + note.start * pixels_per_beat - scroll_x;
                        const note_y = grid_window_pos[1] + @as(f32, @floatFromInt(note_row)) * row_height - scroll_y;
                        const note_w = note.duration * pixels_per_beat;

                        // Check if note rectangle intersects selection rectangle
                        const note_x2 = note_x + note_w;
                        const note_y2 = note_y + row_height;

                        if (note_x < sel_x2 and note_x2 > sel_x1 and note_y < sel_y2 and note_y2 > sel_y1) {
                            state.selected_notes.put(state.allocator, note_idx, {}) catch {};
                            state.selected_note_index = note_idx;
                        }
                    }
                }
                state.piano_drag.mode = .none;
            } else {
                switch (state.piano_drag.mode) {
                    .resize_clip => {
                        const current_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
                        var new_length = @floor(current_beat * 4) / 4; // Snap to 1/4 note
                        new_length = @max(beats_per_bar, new_length); // Minimum 1 bar
                        new_length = @min(256, new_length); // Maximum 64 bars
                        clip.length_beats = new_length;
                    },
                    .move => {
                        if (state.piano_drag.note_index < clip.notes.items.len) {
                            const current_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;
                            const current_row = (mouse[1] - grid_window_pos[1] + scroll_y) / row_height;

                            var new_start = current_beat - state.piano_drag.grab_offset_beats;
                            new_start = @floor(new_start * 4) / 4; // Snap to 1/4 note

                            var new_pitch_i: i32 = 127 - @as(i32, @intFromFloat(current_row));
                            new_pitch_i = std.math.clamp(new_pitch_i, 0, 127);

                            // Calculate delta from last frame position
                            const delta_start = new_start - state.piano_drag.original_start;
                            const delta_pitch = new_pitch_i - @as(i32, state.piano_drag.original_pitch);

                            // Move all selected notes by the same delta
                            for (state.selected_notes.keys()) |idx| {
                                if (idx < clip.notes.items.len) {
                                    const note = &clip.notes.items[idx];
                                    const note_new_start = note.start + delta_start;
                                    note.start = @max(0, @min(note_new_start, clip.length_beats - note.duration));
                                    const note_pitch_i = @as(i32, note.pitch) + delta_pitch;
                                    note.pitch = @intCast(std.math.clamp(note_pitch_i, 0, 127));
                                }
                            }

                            // Update reference position for next frame delta calculation
                            state.piano_drag.original_start = new_start;
                            state.piano_drag.original_pitch = @intCast(new_pitch_i);
                        }
                    },
                    .resize_right, .create => {
                        if (state.piano_drag.note_index < clip.notes.items.len) {
                            const note = &clip.notes.items[state.piano_drag.note_index];
                            const current_beat = (mouse[0] - grid_window_pos[0] + scroll_x) / pixels_per_beat;

                            var new_end = current_beat;
                            new_end = @max(note.start + min_note_duration, new_end);
                            new_end = @min(new_end, clip.length_beats);
                            new_end = @ceil(new_end * 16) / 16; // Snap to 1/16 note for resize
                            note.duration = new_end - note.start;
                        }
                    },
                    .select_rect => {
                        // Draw selection rectangle (handled below after clip rect)
                    },
                    .none => {},
                }
            }
        }

        // Draw selection rectangle while dragging
        if (state.piano_drag.mode == .select_rect) {
            const sel_x1 = @min(state.piano_drag.select_start_x, mouse[0]);
            const sel_y1 = @min(state.piano_drag.select_start_y, mouse[1]);
            const sel_x2 = @max(state.piano_drag.select_start_x, mouse[0]);
            const sel_y2 = @max(state.piano_drag.select_start_y, mouse[1]);

            // Clip to grid area
            const clipped_x1 = @max(sel_x1, grid_window_pos[0]);
            const clipped_y1 = @max(sel_y1, grid_window_pos[1]);
            const clipped_x2 = @min(sel_x2, grid_window_pos[0] + grid_view_width);
            const clipped_y2 = @min(sel_y2, grid_window_pos[1] + grid_view_height);

            if (clipped_x2 > clipped_x1 and clipped_y2 > clipped_y1) {
                draw_list.addRectFilled(.{
                    .pmin = .{ clipped_x1, clipped_y1 },
                    .pmax = .{ clipped_x2, clipped_y2 },
                    .col = zgui.colorConvertFloat4ToU32(Colors.selection_rect),
                });
                draw_list.addRect(.{
                    .pmin = .{ clipped_x1, clipped_y1 },
                    .pmax = .{ clipped_x2, clipped_y2 },
                    .col = zgui.colorConvertFloat4ToU32(Colors.selection_rect_border),
                    .thickness = 1.0,
                });
            }
        }

        if (zgui.beginPopup("piano_roll_ctx", .{})) {
            const has_selection = state.selected_notes.count() > 0;
            const can_paste = state.piano_clipboard.items.len > 0 and state.piano_context_in_grid;

            if (zgui.menuItem("Copy", .{ .shortcut = "Cmd/Ctrl+C", .enabled = has_selection })) {
                state.piano_clipboard.clearRetainingCapacity();
                var min_start: f32 = std.math.floatMax(f32);
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        min_start = @min(min_start, clip.notes.items[idx].start);
                    }
                }
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        var note_copy = clip.notes.items[idx];
                        note_copy.start -= min_start;
                        state.piano_clipboard.append(state.allocator, note_copy) catch {};
                    }
                }
            }

            if (zgui.menuItem("Cut", .{ .shortcut = "Cmd/Ctrl+X", .enabled = has_selection })) {
                state.piano_clipboard.clearRetainingCapacity();
                var min_start: f32 = std.math.floatMax(f32);
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        min_start = @min(min_start, clip.notes.items[idx].start);
                    }
                }
                for (state.selected_notes.keys()) |idx| {
                    if (idx < clip.notes.items.len) {
                        var note_copy = clip.notes.items[idx];
                        note_copy.start -= min_start;
                        state.piano_clipboard.append(state.allocator, note_copy) catch {};
                    }
                }
                // Delete in reverse order
                var indices_to_delete: std.ArrayListUnmanaged(usize) = .{};
                defer indices_to_delete.deinit(state.allocator);
                for (state.selected_notes.keys()) |idx| {
                    indices_to_delete.append(state.allocator, idx) catch {};
                }
                std.mem.sort(usize, indices_to_delete.items, {}, std.sort.desc(usize));
                for (indices_to_delete.items) |idx| {
                    if (idx < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(idx);
                    }
                }
                state.selected_notes.clearRetainingCapacity();
                state.selected_note_index = null;
            }

            if (zgui.menuItem("Paste", .{ .shortcut = "Cmd/Ctrl+V", .enabled = can_paste })) {
                const snapped_start = state.piano_context_start;
                const first_pitch: i32 = @intCast(state.piano_clipboard.items[0].pitch);
                const pitch_offset = @as(i32, state.piano_context_pitch) - first_pitch;

                state.selected_notes.clearRetainingCapacity();
                for (state.piano_clipboard.items) |copied| {
                    const new_start = snapped_start + copied.start;
                    if (new_start >= 0 and new_start < clip.length_beats) {
                        const duration = @min(copied.duration, clip.length_beats - new_start);
                        if (duration >= min_note_duration) {
                            var new_pitch_i: i32 = @as(i32, copied.pitch) + pitch_offset;
                            new_pitch_i = std.math.clamp(new_pitch_i, 0, 127);
                            const new_pitch: u8 = @intCast(new_pitch_i);
                            clip.addNote(new_pitch, new_start, duration) catch {};
                            const new_idx = clip.notes.items.len - 1;
                            state.selected_notes.put(state.allocator, new_idx, {}) catch {};
                            state.selected_note_index = new_idx;
                        }
                    }
                }
            }

            if (zgui.menuItem("Delete", .{ .shortcut = "Del", .enabled = has_selection })) {
                var indices_to_delete: std.ArrayListUnmanaged(usize) = .{};
                defer indices_to_delete.deinit(state.allocator);
                for (state.selected_notes.keys()) |idx| {
                    indices_to_delete.append(state.allocator, idx) catch {};
                }
                std.mem.sort(usize, indices_to_delete.items, {}, std.sort.desc(usize));
                for (indices_to_delete.items) |idx| {
                    if (idx < clip.notes.items.len) {
                        _ = clip.notes.orderedRemove(idx);
                    }
                }
                state.selected_notes.clearRetainingCapacity();
                state.selected_note_index = null;
            }

            zgui.separator();

            if (zgui.menuItem("Select All", .{ .shortcut = "Cmd/Ctrl+A" })) {
                state.selected_notes.clearRetainingCapacity();
                for (clip.notes.items, 0..) |_, idx| {
                    state.selected_notes.put(state.allocator, idx, {}) catch {};
                }
                if (clip.notes.items.len > 0) {
                    state.selected_note_index = 0;
                }
            }

            zgui.endPopup();
        }
    }

    // ========== RULER ==========

    // Ruler background
    draw_list.addRectFilled(.{
        .pmin = .{ grid_area_x, ruler_area_y },
        .pmax = .{ grid_area_x + grid_view_width, ruler_area_y + ruler_height },
        .col = zgui.colorConvertFloat4ToU32(Colors.bg_header),
    });

    // Ruler clip rect
    draw_list.pushClipRect(.{
        .pmin = .{ grid_area_x, ruler_area_y },
        .pmax = .{ grid_area_x + grid_view_width, ruler_area_y + ruler_height },
    });

    // Draw bar/beat markers on ruler
    const ruler_last_beat = (scroll_x + grid_view_width) / pixels_per_beat;
    var ruler_beat: f32 = @floor(scroll_x / pixels_per_beat);
    while (ruler_beat <= @min(ruler_last_beat + 1, max_beats)) : (ruler_beat += 1) {
        const x = grid_area_x + ruler_beat * pixels_per_beat - scroll_x;
        const beat_int = @as(i32, @intFromFloat(ruler_beat));
        const is_bar = @mod(beat_int, beats_per_bar) == 0;

        if (is_bar) {
            const bar_num = @divFloor(beat_int, beats_per_bar) + 1;
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrintZ(&buf, "{d}", .{bar_num}) catch "";
            draw_list.addText(.{ x + 4, ruler_area_y + 4 }, zgui.colorConvertFloat4ToU32(Colors.text_bright), "{s}", .{label});
        }

        // Tick marks
        const tick_height: f32 = if (is_bar) ruler_height * 0.6 else ruler_height * 0.3;
        draw_list.addLine(.{
            .p1 = .{ x, ruler_area_y + ruler_height - tick_height },
            .p2 = .{ x, ruler_area_y + ruler_height },
            .col = zgui.colorConvertFloat4ToU32(if (is_bar) Colors.text_dim else .{ 0.3, 0.3, 0.3, 1.0 }),
            .thickness = if (is_bar) 1.5 else 1.0,
        });
    }

    draw_list.popClipRect();

    // ========== PIANO KEYS ==========
    // Safe row calculation for piano keys
    const keys_first_row_f = @max(0, @floor(scroll_y / row_height));
    const keys_last_row_f = @min(127, @ceil((scroll_y + grid_view_height) / row_height));
    const keys_first_row: usize = @intFromFloat(keys_first_row_f);
    const keys_last_row: usize = @intFromFloat(@max(keys_first_row_f, keys_last_row_f));
    const is_black_key_keys = [_]bool{ false, true, false, true, false, false, true, false, true, false, true, false };

    // Keys background
    draw_list.addRectFilled(.{
        .pmin = .{ keys_area_x, grid_area_y },
        .pmax = .{ keys_area_x + key_width, grid_area_y + grid_view_height },
        .col = zgui.colorConvertFloat4ToU32(Colors.bg_dark),
    });

    draw_list.pushClipRect(.{
        .pmin = .{ keys_area_x, grid_area_y },
        .pmax = .{ keys_area_x + key_width, grid_area_y + grid_view_height },
    });

    var key_row: usize = keys_first_row;
    while (key_row <= keys_last_row) : (key_row += 1) {
        const pitch: u8 = if (key_row <= 127) @intCast(127 - key_row) else 0;
        const y = grid_area_y + @as(f32, @floatFromInt(key_row)) * row_height - scroll_y;

        if (y < grid_area_y - row_height or y > grid_area_y + grid_view_height) continue;

        const note_in_octave = pitch % 12;
        const oct = @as(i32, @intCast(pitch / 12)) - 1;

        // Key background
        const is_black = is_black_key_keys[note_in_octave];
        const key_color = if (is_black)
            zgui.colorConvertFloat4ToU32(.{ 0.08, 0.08, 0.08, 1.0 })
        else
            zgui.colorConvertFloat4ToU32(.{ 0.20, 0.20, 0.20, 1.0 });

        draw_list.addRectFilled(.{
            .pmin = .{ keys_area_x, y },
            .pmax = .{ keys_area_x + key_width - 1, y + row_height - 1 },
            .col = key_color,
        });

        // Only label C notes (octave markers)
        if (note_in_octave == 0) {
            var label_buf: [8]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "C{d}", .{oct}) catch "";
            draw_list.addText(.{ keys_area_x + 4, y + 2 }, zgui.colorConvertFloat4ToU32(Colors.text_bright), "{s}", .{label});
        }
    }

    draw_list.popClipRect();

    // Top-left corner (empty space)
    draw_list.addRectFilled(.{
        .pmin = .{ keys_area_x, ruler_area_y },
        .pmax = .{ keys_area_x + key_width, ruler_area_y + ruler_height },
        .col = zgui.colorConvertFloat4ToU32(Colors.bg_dark),
    });

    // Reserve space for the piano roll area
    zgui.dummy(.{ .w = total_width, .h = total_height });
}

fn pitchToNoteName(pitch: u8, buf: []u8) []const u8 {
    const note_names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const note = pitch % 12;
    const octave = @as(i32, @intCast(pitch / 12)) - 1;
    return std.fmt.bufPrint(buf, "{s}{d}", .{ note_names[note], octave }) catch "?";
}
