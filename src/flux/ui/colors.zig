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

        // Accent & highlights
        accent: [4]f32,
        accent_dim: [4]f32,
        selected: [4]f32,
        border: [4]f32,
        border_light: [4]f32,

        // Text
        text_bright: [4]f32,
        text_dim: [4]f32,
        text_soft: [4]f32,

        // Transport
        transport_play: [4]f32,
        transport_stop: [4]f32,

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
    };

    pub const light: Palette = .{
    .bg_dark = .{ 0.97, 0.96, 0.95, 1.0 },
    .bg_panel = .{ 0.94, 0.93, 0.92, 1.0 },
    .bg_cell = .{ 0.91, 0.90, 0.89, 1.0 },
    .bg_header = .{ 0.88, 0.87, 0.85, 1.0 },
    .bg_cell_hover = .{ 0.87, 0.86, 0.85, 1.0 },
    .bg_cell_active = .{ 0.84, 0.83, 0.82, 1.0 },

    .clip_empty = .{ 0.91, 0.90, 0.89, 1.0 },
    .clip_stopped = .{ 0.62, 0.78, 0.91, 1.0 },
    .clip_queued = .{ 0.95, 0.80, 0.65, 1.0 },
    .clip_playing = .{ 0.66, 0.85, 0.72, 1.0 },

    .accent = .{ 0.49, 0.72, 0.85, 1.0 },
    .accent_dim = .{ 0.37, 0.62, 0.78, 1.0 },
    .selected = .{ 0.56, 0.76, 0.89, 1.0 },
    .border = .{ 0.82, 0.80, 0.78, 1.0 },
    .border_light = .{ 0.88, 0.86, 0.85, 1.0 },

    .text_bright = .{ 0.15, 0.15, 0.15, 1.0 },
    .text_dim = .{ 0.42, 0.42, 0.42, 1.0 },
    .text_soft = .{ 0.55, 0.55, 0.55, 1.0 },

    .transport_play = .{ 0.66, 0.85, 0.72, 1.0 },
    .transport_stop = .{ 0.89, 0.61, 0.64, 1.0 },

    .note_color = .{ 0.61, 0.83, 0.77, 1.0 },
    .note_selected = .{ 0.50, 0.77, 0.71, 1.0 },
    .note_border = .{ 0.24, 0.24, 0.24, 0.35 },
    .note_handle = .{ 0.54, 0.75, 0.69, 1.0 },
    .note_handle_selected = .{ 0.45, 0.69, 0.64, 1.0 },
    .playhead_bg = .{ 0.62, 0.76, 0.88, 0.35 },
    .selection_rect = .{ 0.54, 0.74, 0.90, 0.25 },
    .selection_rect_border = .{ 0.40, 0.63, 0.82, 0.7 },

    .record_armed = .{ 0.89, 0.61, 0.64, 1.0 },
    .record_armed_hover = .{ 0.92, 0.69, 0.71, 1.0 },
    .clip_recording = .{ 0.89, 0.54, 0.54, 0.9 },

    .grid_row_light = .{ 0.97, 0.97, 0.96, 1.0 },
    .grid_row_dark = .{ 0.93, 0.93, 0.92, 1.0 },
    .grid_row_root = .{ 0.91, 0.91, 0.90, 1.0 },
    .grid_row_black = .{ 0.89, 0.89, 0.88, 1.0 },
    .grid_line_bar = .{ 0.72, 0.72, 0.71, 1.0 },
    .grid_line_beat = .{ 0.78, 0.78, 0.77, 1.0 },
    .grid_line_8th = .{ 0.83, 0.83, 0.82, 1.0 },
    .grid_line_16th = .{ 0.86, 0.86, 0.85, 1.0 },
    .ruler_tick = .{ 0.62, 0.62, 0.61, 1.0 },
    .piano_key_white = .{ 0.96, 0.96, 0.95, 1.0 },
    .piano_key_black = .{ 0.86, 0.86, 0.85, 1.0 },
    .piano_key_border = .{ 0.84, 0.84, 0.83, 1.0 },
    };

    pub const dark: Palette = .{
    .bg_dark = .{ 0.10, 0.10, 0.10, 1.0 },
    .bg_panel = .{ 0.14, 0.14, 0.14, 1.0 },
    .bg_cell = .{ 0.18, 0.18, 0.18, 1.0 },
    .bg_header = .{ 0.12, 0.12, 0.12, 1.0 },
    .bg_cell_hover = .{ 0.22, 0.22, 0.22, 1.0 },
    .bg_cell_active = .{ 0.25, 0.25, 0.25, 1.0 },

    .clip_empty = .{ 0.15, 0.15, 0.15, 1.0 },
    .clip_stopped = .{ 0.35, 0.55, 0.70, 1.0 },
    .clip_queued = .{ 0.90, 0.55, 0.10, 1.0 },
    .clip_playing = .{ 0.35, 0.75, 0.35, 1.0 },

    .accent = .{ 0.49, 0.72, 0.85, 1.0 },
    .accent_dim = .{ 0.37, 0.62, 0.78, 1.0 },
    .selected = .{ 0.30, 0.55, 0.80, 1.0 },
    .border = .{ 0.25, 0.25, 0.25, 1.0 },
    .border_light = .{ 0.30, 0.30, 0.30, 1.0 },

    .text_bright = .{ 0.92, 0.92, 0.92, 1.0 },
    .text_dim = .{ 0.60, 0.60, 0.60, 1.0 },
    .text_soft = .{ 0.45, 0.45, 0.45, 1.0 },

    .transport_play = .{ 0.45, 0.85, 0.55, 1.0 },
    .transport_stop = .{ 0.85, 0.45, 0.45, 1.0 },

    .note_color = .{ 0.40, 0.75, 0.50, 1.0 },
    .note_selected = .{ 0.55, 0.85, 0.65, 1.0 },
    .note_border = .{ 1.0, 1.0, 1.0, 0.6 },
    .note_handle = .{ 0.28, 0.58, 0.38, 1.0 },
    .note_handle_selected = .{ 0.45, 0.75, 0.55, 1.0 },
    .playhead_bg = .{ 0.25, 0.35, 0.45, 0.6 },
    .selection_rect = .{ 0.40, 0.60, 0.90, 0.3 },
    .selection_rect_border = .{ 0.50, 0.70, 1.0, 0.8 },

    .record_armed = .{ 0.85, 0.25, 0.25, 1.0 },
    .record_armed_hover = .{ 0.95, 0.35, 0.35, 1.0 },
    .clip_recording = .{ 0.75, 0.25, 0.25, 0.9 },

    .grid_row_light = .{ 0.16, 0.16, 0.16, 1.0 },
    .grid_row_dark = .{ 0.13, 0.13, 0.13, 1.0 },
    .grid_row_root = .{ 0.20, 0.20, 0.20, 1.0 },
    .grid_row_black = .{ 0.11, 0.11, 0.11, 1.0 },
    .grid_line_bar = .{ 0.45, 0.45, 0.45, 1.0 },
    .grid_line_beat = .{ 0.32, 0.32, 0.32, 1.0 },
    .grid_line_8th = .{ 0.24, 0.24, 0.24, 1.0 },
    .grid_line_16th = .{ 0.18, 0.18, 0.18, 1.0 },
    .ruler_tick = .{ 0.55, 0.55, 0.55, 1.0 },
    .piano_key_white = .{ 0.20, 0.20, 0.20, 1.0 },
    .piano_key_black = .{ 0.08, 0.08, 0.08, 1.0 },
    .piano_key_border = .{ 0.16, 0.16, 0.16, 1.0 },
    };

    pub var current: Palette = light;

    pub fn setTheme(theme: Theme) void {
        current = switch (theme) {
            .light => light,
            .dark => dark,
        };
    }
};
