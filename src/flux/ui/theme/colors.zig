// Minimalist palette with light/dark variants.
pub const Colors = struct {
    pub const Theme = enum {
        light,
        dark,
    };

    pub const Palette = struct {
        // Backgrounds
        bg_dark: [4]f32,
        bg_panel: [4]f32,
        bg_cell: [4]f32,
        bg_header: [4]f32,
        bg_cell_hover: [4]f32,
        bg_cell_active: [4]f32,

        // Clip states
        clip_empty: [4]f32,
        clip_stopped: [4]f32,
        clip_queued: [4]f32,
        clip_playing: [4]f32,
        /// Audio clip fill (stopped) — teal to distinguish from MIDI blue
        clip_audio_stopped: [4]f32,
        /// Audio clip fill (playing)
        clip_audio_playing: [4]f32,

        // Accent & highlights
        accent: [4]f32,
        accent_dim: [4]f32,
        selected: [4]f32,
        border: [4]f32,
        border_light: [4]f32,
        focus_ring: [4]f32,

        // Text
        text_bright: [4]f32,
        text_dim: [4]f32,
        text_soft: [4]f32,
        /// Prefer for labels drawn on solid clip fills (pastel/dark).
        text_on_fill: [4]f32,

        // Transport
        transport_play: [4]f32,
        transport_stop: [4]f32,

        // Mixer semantics
        mute_on: [4]f32,
        mute_on_hover: [4]f32,
        solo_on: [4]f32,
        solo_on_hover: [4]f32,
        arm_on: [4]f32,
        arm_on_hover: [4]f32,

        // Status
        danger: [4]f32,
        warning: [4]f32,
        empty_slot_fill: [4]f32,
        empty_slot_border: [4]f32,

        // Sequencer
        note_color: [4]f32,
        note_selected: [4]f32,
        note_border: [4]f32,
        note_handle: [4]f32,
        note_handle_selected: [4]f32,
        playhead_bg: [4]f32,
        selection_rect: [4]f32,
        selection_rect_border: [4]f32,

        // Recording
        record_armed: [4]f32,
        record_armed_hover: [4]f32,
        clip_recording: [4]f32,

        // Piano roll/grid
        grid_row_light: [4]f32,
        grid_row_dark: [4]f32,
        grid_row_root: [4]f32,
        grid_row_black: [4]f32,
        grid_line_bar: [4]f32,
        grid_line_beat: [4]f32,
        grid_line_8th: [4]f32,
        grid_line_16th: [4]f32,
        ruler_tick: [4]f32,
        piano_key_white: [4]f32,
        piano_key_black: [4]f32,
        piano_key_border: [4]f32,

        // Track color cycle (left strip on clips)
        track_colors: [8][4]f32,
    };

    pub const light: Palette = .{
        .bg_dark = .{ 0.96, 0.95, 0.94, 1.0 },
        .bg_panel = .{ 0.93, 0.92, 0.91, 1.0 },
        .bg_cell = .{ 0.90, 0.89, 0.88, 1.0 },
        .bg_header = .{ 0.88, 0.87, 0.85, 1.0 },
        .bg_cell_hover = .{ 0.86, 0.85, 0.84, 1.0 },
        .bg_cell_active = .{ 0.82, 0.81, 0.80, 1.0 },

        .clip_empty = .{ 0.90, 0.89, 0.88, 1.0 },
        .clip_stopped = .{ 0.55, 0.72, 0.88, 1.0 },
        .clip_queued = .{ 0.94, 0.74, 0.48, 1.0 },
        .clip_playing = .{ 0.52, 0.78, 0.58, 1.0 },
        .clip_audio_stopped = .{ 0.42, 0.72, 0.74, 1.0 },
        .clip_audio_playing = .{ 0.38, 0.76, 0.68, 1.0 },

        .accent = .{ 0.42, 0.68, 0.84, 1.0 },
        .accent_dim = .{ 0.32, 0.56, 0.74, 1.0 },
        .selected = .{ 0.36, 0.62, 0.88, 1.0 },
        .border = .{ 0.78, 0.76, 0.74, 1.0 },
        .border_light = .{ 0.86, 0.84, 0.82, 1.0 },
        .focus_ring = .{ 0.42, 0.68, 0.84, 0.65 },

        .text_bright = .{ 0.12, 0.12, 0.12, 1.0 },
        .text_dim = .{ 0.40, 0.40, 0.40, 1.0 },
        .text_soft = .{ 0.55, 0.55, 0.55, 1.0 },
        .text_on_fill = .{ 0.10, 0.12, 0.14, 1.0 },

        .transport_play = .{ 0.32, 0.72, 0.42, 1.0 },
        .transport_stop = .{ 0.86, 0.38, 0.40, 1.0 },

        .mute_on = .{ 0.45, 0.62, 0.82, 1.0 },
        .mute_on_hover = .{ 0.52, 0.68, 0.86, 1.0 },
        .solo_on = .{ 0.90, 0.72, 0.28, 1.0 },
        .solo_on_hover = .{ 0.94, 0.78, 0.38, 1.0 },
        .arm_on = .{ 0.88, 0.32, 0.34, 1.0 },
        .arm_on_hover = .{ 0.92, 0.42, 0.44, 1.0 },

        .danger = .{ 0.86, 0.32, 0.34, 1.0 },
        .warning = .{ 0.90, 0.68, 0.28, 1.0 },
        .empty_slot_fill = .{ 0.92, 0.91, 0.90, 1.0 },
        .empty_slot_border = .{ 0.80, 0.78, 0.76, 1.0 },

        .note_color = .{ 0.48, 0.74, 0.68, 1.0 },
        .note_selected = .{ 0.38, 0.70, 0.64, 1.0 },
        .note_border = .{ 0.20, 0.20, 0.20, 0.40 },
        .note_handle = .{ 0.42, 0.68, 0.62, 1.0 },
        .note_handle_selected = .{ 0.35, 0.62, 0.56, 1.0 },
        .playhead_bg = .{ 0.55, 0.72, 0.88, 0.35 },
        .selection_rect = .{ 0.45, 0.68, 0.90, 0.22 },
        .selection_rect_border = .{ 0.32, 0.58, 0.84, 0.75 },

        .record_armed = .{ 0.88, 0.32, 0.34, 1.0 },
        .record_armed_hover = .{ 0.92, 0.42, 0.44, 1.0 },
        .clip_recording = .{ 0.86, 0.36, 0.38, 0.92 },

        .grid_row_light = .{ 0.97, 0.97, 0.96, 1.0 },
        .grid_row_dark = .{ 0.93, 0.93, 0.92, 1.0 },
        .grid_row_root = .{ 0.91, 0.91, 0.90, 1.0 },
        .grid_row_black = .{ 0.88, 0.88, 0.87, 1.0 },
        .grid_line_bar = .{ 0.68, 0.68, 0.67, 1.0 },
        .grid_line_beat = .{ 0.76, 0.76, 0.75, 1.0 },
        .grid_line_8th = .{ 0.82, 0.82, 0.81, 1.0 },
        .grid_line_16th = .{ 0.86, 0.86, 0.85, 1.0 },
        .ruler_tick = .{ 0.58, 0.58, 0.57, 1.0 },
        .piano_key_white = .{ 0.96, 0.96, 0.95, 1.0 },
        .piano_key_black = .{ 0.84, 0.84, 0.83, 1.0 },
        .piano_key_border = .{ 0.80, 0.80, 0.79, 1.0 },

        .track_colors = .{
            .{ 0.55, 0.72, 0.88, 1.0 },
            .{ 0.62, 0.78, 0.58, 1.0 },
            .{ 0.88, 0.70, 0.48, 1.0 },
            .{ 0.78, 0.58, 0.82, 1.0 },
            .{ 0.55, 0.78, 0.78, 1.0 },
            .{ 0.88, 0.58, 0.58, 1.0 },
            .{ 0.72, 0.72, 0.55, 1.0 },
            .{ 0.62, 0.65, 0.88, 1.0 },
        },
    };

    pub const dark: Palette = .{
        .bg_dark = .{ 0.09, 0.09, 0.10, 1.0 },
        .bg_panel = .{ 0.13, 0.13, 0.14, 1.0 },
        .bg_cell = .{ 0.17, 0.17, 0.18, 1.0 },
        .bg_header = .{ 0.11, 0.11, 0.12, 1.0 },
        .bg_cell_hover = .{ 0.22, 0.22, 0.23, 1.0 },
        .bg_cell_active = .{ 0.26, 0.26, 0.27, 1.0 },

        .clip_empty = .{ 0.14, 0.14, 0.15, 1.0 },
        .clip_stopped = .{ 0.32, 0.52, 0.68, 1.0 },
        .clip_queued = .{ 0.88, 0.55, 0.18, 1.0 },
        .clip_playing = .{ 0.32, 0.70, 0.38, 1.0 },
        .clip_audio_stopped = .{ 0.22, 0.52, 0.56, 1.0 },
        .clip_audio_playing = .{ 0.24, 0.66, 0.55, 1.0 },

        .accent = .{ 0.45, 0.70, 0.86, 1.0 },
        .accent_dim = .{ 0.34, 0.58, 0.76, 1.0 },
        .selected = .{ 0.35, 0.58, 0.85, 1.0 },
        .border = .{ 0.24, 0.24, 0.25, 1.0 },
        .border_light = .{ 0.30, 0.30, 0.31, 1.0 },
        .focus_ring = .{ 0.45, 0.70, 0.86, 0.55 },

        .text_bright = .{ 0.93, 0.93, 0.93, 1.0 },
        .text_dim = .{ 0.62, 0.62, 0.63, 1.0 },
        .text_soft = .{ 0.46, 0.46, 0.47, 1.0 },
        .text_on_fill = .{ 0.95, 0.95, 0.96, 1.0 },

        .transport_play = .{ 0.40, 0.82, 0.50, 1.0 },
        .transport_stop = .{ 0.88, 0.42, 0.42, 1.0 },

        .mute_on = .{ 0.35, 0.55, 0.75, 1.0 },
        .mute_on_hover = .{ 0.42, 0.62, 0.82, 1.0 },
        .solo_on = .{ 0.88, 0.68, 0.22, 1.0 },
        .solo_on_hover = .{ 0.94, 0.76, 0.32, 1.0 },
        .arm_on = .{ 0.86, 0.28, 0.30, 1.0 },
        .arm_on_hover = .{ 0.92, 0.38, 0.40, 1.0 },

        .danger = .{ 0.88, 0.35, 0.36, 1.0 },
        .warning = .{ 0.90, 0.70, 0.28, 1.0 },
        .empty_slot_fill = .{ 0.13, 0.13, 0.14, 1.0 },
        .empty_slot_border = .{ 0.28, 0.28, 0.30, 1.0 },

        .note_color = .{ 0.38, 0.72, 0.48, 1.0 },
        .note_selected = .{ 0.52, 0.82, 0.62, 1.0 },
        .note_border = .{ 1.0, 1.0, 1.0, 0.55 },
        .note_handle = .{ 0.28, 0.58, 0.38, 1.0 },
        .note_handle_selected = .{ 0.42, 0.72, 0.52, 1.0 },
        .playhead_bg = .{ 0.25, 0.35, 0.48, 0.55 },
        .selection_rect = .{ 0.38, 0.58, 0.90, 0.28 },
        .selection_rect_border = .{ 0.50, 0.70, 1.0, 0.8 },

        .record_armed = .{ 0.86, 0.28, 0.30, 1.0 },
        .record_armed_hover = .{ 0.94, 0.38, 0.40, 1.0 },
        .clip_recording = .{ 0.78, 0.28, 0.30, 0.92 },

        .grid_row_light = .{ 0.15, 0.15, 0.16, 1.0 },
        .grid_row_dark = .{ 0.12, 0.12, 0.13, 1.0 },
        .grid_row_root = .{ 0.18, 0.18, 0.19, 1.0 },
        .grid_row_black = .{ 0.10, 0.10, 0.11, 1.0 },
        .grid_line_bar = .{ 0.42, 0.42, 0.44, 1.0 },
        .grid_line_beat = .{ 0.30, 0.30, 0.32, 1.0 },
        .grid_line_8th = .{ 0.22, 0.22, 0.24, 1.0 },
        .grid_line_16th = .{ 0.19, 0.19, 0.20, 1.0 },
        .ruler_tick = .{ 0.55, 0.55, 0.56, 1.0 },
        .piano_key_white = .{ 0.20, 0.20, 0.21, 1.0 },
        .piano_key_black = .{ 0.08, 0.08, 0.09, 1.0 },
        .piano_key_border = .{ 0.16, 0.16, 0.17, 1.0 },

        .track_colors = .{
            .{ 0.40, 0.62, 0.82, 1.0 },
            .{ 0.42, 0.72, 0.48, 1.0 },
            .{ 0.88, 0.62, 0.32, 1.0 },
            .{ 0.72, 0.48, 0.82, 1.0 },
            .{ 0.38, 0.72, 0.72, 1.0 },
            .{ 0.86, 0.42, 0.45, 1.0 },
            .{ 0.72, 0.72, 0.42, 1.0 },
            .{ 0.52, 0.55, 0.86, 1.0 },
        },
    };

    pub var current: Palette = dark;

    pub fn setTheme(theme: Theme) void {
        current = switch (theme) {
            .light => light,
            .dark => dark,
        };
    }

    pub fn trackColor(track_index: usize) [4]f32 {
        return current.track_colors[track_index % current.track_colors.len];
    }

    /// Relative luminance of an opaque sRGB-ish color.
    pub fn luminance(c: [4]f32) f32 {
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    }

    /// Pick high-contrast text for a filled surface.
    pub fn textOn(fill: [4]f32) [4]f32 {
        return if (luminance(fill) > 0.55)
            .{ 0.10, 0.11, 0.12, 1.0 }
        else
            .{ 0.95, 0.95, 0.96, 1.0 };
    }

    pub fn lighten(c: [4]f32, amount: f32) [4]f32 {
        return .{
            @min(1.0, c[0] + amount),
            @min(1.0, c[1] + amount),
            @min(1.0, c[2] + amount),
            c[3],
        };
    }
};
