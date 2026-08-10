//! Flux-ish palette for the DVUI host (dark theme).

const dvui = @import("dvui");

pub const bg = colorF(0.09, 0.09, 0.10);
pub const panel = colorF(0.13, 0.13, 0.14);
pub const cell = colorF(0.17, 0.17, 0.18);
pub const cell_hover = colorF(0.22, 0.22, 0.23);
pub const header = colorF(0.11, 0.11, 0.12);
pub const accent = colorF(0.45, 0.70, 0.86);
pub const accent_dim = colorF(0.34, 0.58, 0.76);
pub const selected = colorF(0.35, 0.58, 0.85);
pub const play = colorF(0.32, 0.70, 0.38);
pub const stop = colorF(0.86, 0.38, 0.40);
pub const text = colorF(0.93, 0.93, 0.93);
pub const text_dim = colorF(0.62, 0.62, 0.63);
pub const text_soft = colorF(0.46, 0.46, 0.47);
pub const text_on_fill = colorF(0.95, 0.95, 0.96);
pub const grid = colorF(0.24, 0.24, 0.25);
pub const border_light = colorF(0.30, 0.30, 0.31);

// Clip states (session / arrangement)
pub const empty_slot_fill = colorF(0.13, 0.13, 0.14);
pub const empty_slot_border = colorF(0.28, 0.28, 0.30);
pub const clip_stopped = colorF(0.32, 0.52, 0.68);
pub const clip_queued = colorF(0.88, 0.55, 0.18);
pub const clip_playing = colorF(0.32, 0.70, 0.38);
pub const clip_audio_stopped = colorF(0.22, 0.52, 0.56);
pub const clip_audio_playing = colorF(0.24, 0.66, 0.55);
pub const clip_recording = colorF(0.78, 0.28, 0.30);

// Mixer / device
pub const mute_on = colorF(0.35, 0.55, 0.75);
pub const solo_on = colorF(0.88, 0.68, 0.22);
pub const arm_on = colorF(0.86, 0.28, 0.30);
pub const danger = colorF(0.88, 0.35, 0.36);

/// Track color cycle (left strip on clips) — dark theme.
pub const track_colors = [_]dvui.Color{
    colorF(0.40, 0.62, 0.82),
    colorF(0.42, 0.72, 0.48),
    colorF(0.88, 0.62, 0.32),
    colorF(0.72, 0.48, 0.82),
    colorF(0.38, 0.72, 0.72),
    colorF(0.86, 0.42, 0.45),
    colorF(0.72, 0.72, 0.42),
    colorF(0.52, 0.55, 0.86),
};

pub fn trackColor(track_index: usize) dvui.Color {
    return track_colors[track_index % track_colors.len];
}

pub fn colorF(r: f32, g: f32, b: f32) dvui.Color {
    return .{
        .r = @intFromFloat(@min(255.0, r * 255.0)),
        .g = @intFromFloat(@min(255.0, g * 255.0)),
        .b = @intFromFloat(@min(255.0, b * 255.0)),
        .a = 255,
    };
}

pub fn colorFA(r: f32, g: f32, b: f32, a: f32) dvui.Color {
    return .{
        .r = @intFromFloat(@min(255.0, r * 255.0)),
        .g = @intFromFloat(@min(255.0, g * 255.0)),
        .b = @intFromFloat(@min(255.0, b * 255.0)),
        .a = @intFromFloat(@min(255.0, a * 255.0)),
    };
}

/// Lighten (amount > 0) or darken (amount < 0) an opaque color. amount ≈ -1..1.
pub fn lighten(c: dvui.Color, amount: f32) dvui.Color {
    const delta: i32 = @intFromFloat(amount * 255.0);
    return .{
        .r = clampU8(@as(i32, c.r) + delta),
        .g = clampU8(@as(i32, c.g) + delta),
        .b = clampU8(@as(i32, c.b) + delta),
        .a = c.a,
    };
}

fn clampU8(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

pub fn apply(win: *dvui.Window) void {
    var theme = win.theme;
    theme.fill = bg;
    theme.window = .{
        .fill = panel,
        .text = text,
        .border = grid,
    };
    theme.control = .{
        .fill = cell,
        .text = text,
        .border = grid,
    };
    theme.highlight = .{
        .fill = accent,
        .text = bg,
    };
    theme.focus = accent;
    theme.dark = true;
    win.themeSet(theme);
}
