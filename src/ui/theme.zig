//! Semantic host palette, shared by widgets and custom music canvases.

const std = @import("std");
const sdl = @import("dvui").backend.c;

const dvui = @import("dvui");

pub var bg = colorF(0.09, 0.09, 0.10);
pub var panel = colorF(0.13, 0.13, 0.14);
pub var cell = colorF(0.17, 0.17, 0.18);
pub var cell_hover = colorF(0.22, 0.22, 0.23);
pub var header = colorF(0.11, 0.11, 0.12);
pub var accent = colorF(0.45, 0.70, 0.86);
pub var accent_dim = colorF(0.34, 0.58, 0.76);
pub var selected = colorF(0.35, 0.58, 0.85);
pub var play = colorF(0.32, 0.70, 0.38);
pub var stop = colorF(0.86, 0.38, 0.40);
pub var text = colorF(0.93, 0.93, 0.93);
pub var text_dim = colorF(0.62, 0.62, 0.63);
pub var text_soft = colorF(0.46, 0.46, 0.47);
pub var text_on_fill = colorF(0.95, 0.95, 0.96);
pub var grid = colorF(0.24, 0.24, 0.25);
pub var border_light = colorF(0.30, 0.30, 0.31);

// Clip states (session / arrangement)
pub var empty_slot_fill = colorF(0.13, 0.13, 0.14);
pub var empty_slot_border = colorF(0.28, 0.28, 0.30);
pub var clip_stopped = colorF(0.32, 0.52, 0.68);
pub var clip_queued = colorF(0.88, 0.55, 0.18);
pub var clip_playing = colorF(0.32, 0.70, 0.38);
pub var clip_audio_stopped = colorF(0.22, 0.52, 0.56);
pub var clip_audio_playing = colorF(0.24, 0.66, 0.55);
pub var clip_recording = colorF(0.78, 0.28, 0.30);

// Mixer / device
pub var mute_on = colorF(0.35, 0.55, 0.75);
pub var solo_on = colorF(0.88, 0.68, 0.22);
pub var arm_on = colorF(0.86, 0.28, 0.30);
pub var danger = colorF(0.88, 0.35, 0.36);

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

pub const Appearance = enum { system, light, dark };
pub var appearance: Appearance = .system;
var applied_dark: ?bool = null;
var preference_loaded = false;

fn hex(value: u24) dvui.Color {
    return .{ .r = @intCast(value >> 16), .g = @intCast((value >> 8) & 255), .b = @intCast(value & 255), .a = 255 };
}

/// SDL owns the platform-specific preference directory and system appearance.
fn preferencePath(buf: []u8) ?[:0]const u8 {
    const base = sdl.SDL_GetPrefPath("Flux", "Flux") orelse return null;
    defer sdl.SDL_free(base);
    const prefix = std.mem.span(base);
    const suffix = "appearance";
    const len = prefix.len + suffix.len;
    if (len >= buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..len], suffix);
    buf[len] = 0;
    return buf[0..len :0];
}

pub fn setAppearance(value: Appearance) void {
    appearance = value;
    var buf: [4096]u8 = undefined;
    if (preferencePath(&buf)) |path| {
        const data = @tagName(value);
        if (!sdl.SDL_SaveFile(path, data.ptr, data.len)) std.log.warn("Could not save appearance preference", .{});
    }
    dvui.refresh(null, @src(), null);
}

pub fn apply(win: *dvui.Window) void {
    if (!preference_loaded) {
        preference_loaded = true;
        var buf: [4096]u8 = undefined;
        if (preferencePath(&buf)) |path| {
            var len: usize = 0;
            if (sdl.SDL_LoadFile(path, &len)) |data| {
                defer sdl.SDL_free(data);
                const bytes: [*]const u8 = @ptrCast(data);
                appearance = std.meta.stringToEnum(Appearance, bytes[0..len]) orelse .system;
            }
        }
    }
    const dark = switch (appearance) {
        .system => sdl.SDL_GetSystemTheme() != sdl.SDL_SYSTEM_THEME_LIGHT,
        .light => false,
        .dark => true,
    };
    if (applied_dark == dark) return;
    applied_dark = dark;
    bg = hex(if (dark) 0x191C21 else 0xE9ECF0);
    panel = hex(if (dark) 0x22262C else 0xF5F6F8);
    cell = hex(if (dark) 0x2C3139 else 0xFFFFFF);
    cell_hover = hex(if (dark) 0x363E48 else 0xE3EAF2);
    header = hex(if (dark) 0x1E2228 else 0xEDF0F4);
    accent = hex(if (dark) 0x82BCE8 else 0x245F91);
    accent_dim = hex(if (dark) 0x345875 else 0x336B99);
    selected = hex(if (dark) 0x82BCE8 else 0x245F91);
    play = hex(if (dark) 0x72CF9C else 0x237448);
    stop = hex(if (dark) 0xF08086 else 0xAE3548);
    text = hex(if (dark) 0xE8EDF3 else 0x202B38);
    text_dim = hex(if (dark) 0xB0BAC7 else 0x4C5B6C);
    text_soft = hex(if (dark) 0x929EAD else 0x59697A);
    text_on_fill = hex(if (dark) 0xFFFFFF else 0xFFFFFF);
    grid = hex(if (dark) 0x353D48 else 0xD2D9E2);
    border_light = hex(if (dark) 0x647184 else 0x8392A3);
    empty_slot_fill = hex(if (dark) 0x252A31 else 0xF9FAFC);
    empty_slot_border = hex(if (dark) 0x414B58 else 0xBFC9D5);
    clip_stopped = hex(if (dark) 0x385C7C else 0x38658A);
    clip_queued = hex(if (dark) 0x98621E else 0x885617);
    clip_playing = hex(if (dark) 0x28734E else 0x26714B);
    clip_audio_stopped = hex(if (dark) 0x2B666D else 0x286771);
    clip_audio_playing = hex(if (dark) 0x226956 else 0x236B58);
    clip_recording = hex(if (dark) 0xA43B4A else 0xA03949);
    mute_on = hex(if (dark) 0x385C7C else 0x38658A);
    solo_on = hex(if (dark) 0x846019 else 0x805B17);
    arm_on = hex(if (dark) 0xA43B4A else 0xA03949);
    danger = hex(if (dark) 0xF08086 else 0xAE3548);
    var t = if (dark) dvui.Theme.builtin.adwaita_dark else dvui.Theme.builtin.adwaita_light;
    t.name = "Flux";
    t.dark = dark;
    t.fill = cell;
    t.text = text;
    t.border = border_light;
    t.fill_hover = cell_hover;
    t.window = .{ .fill = panel, .text = text, .border = grid };
    t.control = .{ .fill = cell, .fill_hover = cell_hover, .text = text, .border = grid };
    t.highlight = .{ .fill = accent, .text = bg };
    t.err = .{ .fill = clip_recording, .text = text_on_fill };
    t.focus = selected;
    t.text_select = accent;
    // DVUI font sizes measure capital height, not typographic points.
    t.font_body = t.font_body.withSize(10);
    t.font_heading = t.font_heading.withSize(11);
    t.font_title = t.font_title.withSize(14);
    t.corner = .round(4);
    win.themeSet(t);
    dvui.ButtonWidget.defaults.margin = dvui.Rect.all(0);
    dvui.ButtonWidget.defaults.padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 };
}

pub fn alpha(color: dvui.Color, opacity: f32) dvui.Color {
    var result = color;
    result.a = @intFromFloat(@max(0, @min(1, opacity)) * 255);
    return result;
}
