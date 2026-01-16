// Ableton-style color palette
pub const Colors = struct {
    // Backgrounds
    pub const bg_dark: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 };
    pub const bg_panel: [4]f32 = .{ 0.14, 0.14, 0.14, 1.0 };
    pub const bg_cell: [4]f32 = .{ 0.18, 0.18, 0.18, 1.0 };
    pub const bg_header: [4]f32 = .{ 0.12, 0.12, 0.12, 1.0 };

    // Clip states
    pub const clip_empty: [4]f32 = .{ 0.15, 0.15, 0.15, 1.0 };
    pub const clip_stopped: [4]f32 = .{ 0.35, 0.55, 0.70, 1.0 }; // Brighter blue for real clips
    pub const clip_queued: [4]f32 = .{ 0.90, 0.55, 0.10, 1.0 };
    pub const clip_playing: [4]f32 = .{ 0.35, 0.75, 0.35, 1.0 };

    // Accent & highlights
    pub const accent: [4]f32 = .{ 0.95, 0.50, 0.10, 1.0 };
    pub const accent_dim: [4]f32 = .{ 0.60, 0.35, 0.10, 1.0 };
    pub const selected: [4]f32 = .{ 0.30, 0.55, 0.80, 1.0 };
    pub const border: [4]f32 = .{ 0.25, 0.25, 0.25, 1.0 };

    // Text
    pub const text_bright: [4]f32 = .{ 0.90, 0.90, 0.90, 1.0 };
    pub const text_dim: [4]f32 = .{ 0.55, 0.55, 0.55, 1.0 };

    // Transport
    pub const transport_play: [4]f32 = .{ 0.35, 0.75, 0.35, 1.0 };
    pub const transport_stop: [4]f32 = .{ 0.75, 0.35, 0.35, 1.0 };

    // Sequencer
    pub const note_color: [4]f32 = .{ 0.40, 0.75, 0.50, 1.0 };
    pub const note_selected: [4]f32 = .{ 0.55, 0.85, 0.65, 1.0 };
    pub const playhead_bg: [4]f32 = .{ 0.25, 0.35, 0.45, 0.6 };
    pub const selection_rect: [4]f32 = .{ 0.4, 0.6, 0.9, 0.3 };
    pub const selection_rect_border: [4]f32 = .{ 0.5, 0.7, 1.0, 0.8 };
};
