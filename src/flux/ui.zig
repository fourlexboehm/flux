const std = @import("std");
const zgui = @import("zgui");
const zsynth = @import("zsynth-core");
const clap = @import("clap-bindings");
const zsynth_view = zsynth.View;

// Import UI modules
pub const ui = @import("ui/root.zig");
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
    keyboard_octave: i8,

    // Project file requests (handled by main.zig)
    load_project_request: bool,
    save_project_request: bool,

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
            .keyboard_octave = 0,
            .load_project_request = false,
            .save_project_request = false,
        };
    }

    pub fn deinit(self: *State) void {
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
    if (!state.playing) {
        return;
    }

    const clip = state.currentClip();
    const beats_per_second = state.bpm / 60.0;
    const prev_beat = state.playhead_beat;
    state.playhead_beat += @as(f32, @floatCast(dt)) * @as(f32, @floatCast(beats_per_second));

    // Check quantize boundary for scene switches
    const quantize_beats = quantizeIndexToBeats(state.quantize_index);
    const prev_quantize = @floor(prev_beat / quantize_beats);
    const curr_quantize = @floor(state.playhead_beat / quantize_beats);

    if (curr_quantize > prev_quantize) {
        state.session.processQuantizedSwitches();
    }

    // Loop within clip length
    if (state.playhead_beat >= clip.length_beats) {
        state.playhead_beat = @mod(state.playhead_beat, clip.length_beats);
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

    const selected = state.selectedTrack();
    for (0..ui.max_tracks) |track_index| {
        if (track_index == selected) {
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
    _ = zgui.sliderFloat("##transport_bpm", .{
        .v = &state.bpm,
        .min = 40.0,
        .max = 200.0,
        .cfmt = "%.0f",
    });

    zgui.sameLine(.{ .spacing = spacing });

    zgui.setNextItemWidth(80.0 * ui_scale);
    _ = zgui.combo("##transport_quantize", .{
        .current_item = &state.quantize_index,
        .items_separated_by_zeros = quantize_items,
    });

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

    if (zgui.button("Save", .{})) {
        state.save_project_request = true;
    }
    zgui.popStyleVar(.{ .count = 1 });

    zgui.setCursorPosY(save_y + transport_h - 6.0 * ui_scale);
}

fn drawClipGrid(state: *State, ui_scale: f32) void {
    // Draw session view
    const is_focused = state.focused_pane == .session;
    state.session.draw(ui_scale, state.playing, is_focused);
    if (state.session.open_clip_request) |req| {
        state.session.open_clip_request = null;
        state.session.primary_track = req.track;
        state.session.primary_scene = req.scene;
        state.bottom_mode = .sequencer;
        state.focused_pane = .bottom;
    }
    if (state.session.start_playback_request) {
        state.session.start_playback_request = false;
        state.playing = true;
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
