//! Layout tokens for consistent spacing/sizing across the UI.
//! Prefer: `tokens.s(8, ui_scale)` over raw `8.0 * ui_scale`.

const zgui = @import("zgui");

/// Scale a logical pixel size by ui_scale.
pub fn s(logical: f32, ui_scale: f32) f32 {
    return logical * ui_scale;
}

pub const ControlSize = enum {
    sm,
    md,
    lg,
};

pub fn controlH(size: ControlSize, ui_scale: f32) f32 {
    return switch (size) {
        .sm => zgui.getFrameHeight(),
        .md => @max(zgui.getFrameHeight(), s(28, ui_scale)),
        .lg => s(32, ui_scale),
    };
}

pub fn radius(size: ControlSize, ui_scale: f32) f32 {
    return switch (size) {
        .sm => s(2, ui_scale),
        .md => s(4, ui_scale),
        .lg => s(6, ui_scale),
    };
}

pub fn transportH(ui_scale: f32) f32 {
    return s(44, ui_scale);
}

pub fn sessionRowH(ui_scale: f32) f32 {
    return s(48, ui_scale);
}

pub fn sessionHeaderH(ui_scale: f32) f32 {
    return s(30, ui_scale);
}

pub fn sceneColW(ui_scale: f32) f32 {
    return s(120, ui_scale);
}

pub fn trackColW(ui_scale: f32) f32 {
    return s(152, ui_scale);
}

/// Gap between related controls in a group (label+widget).
pub fn gapTight(ui_scale: f32) f32 {
    return s(6, ui_scale);
}

/// Gap between control groups on a toolbar.
pub fn gapGroup(ui_scale: f32) f32 {
    return s(12, ui_scale);
}

/// Larger section gap.
pub fn gapSection(ui_scale: f32) f32 {
    return s(16, ui_scale);
}

/// Vertically center the next item of height `item_h` within a bar of height `bar_h`
/// starting at current cursor Y `bar_start_y`.
pub fn centerInBar(bar_start_y: f32, bar_h: f32, item_h: f32) f32 {
    return bar_start_y + @max(0.0, (bar_h - item_h) * 0.5);
}
