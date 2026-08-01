//! Layout density tokens for the DVUI host.
//! Values are **natural** pixels — DVUI already multiplies by content scale
//! for Retina/HiDPI. Do not multiply these by DPI again.
//!
//! Tuned dense for DAW chrome: transport + device chain stay thin so the
//! bottom pane has room for real plugin UIs.

/// Control / button height (transport, tabs, compact tools).
pub const control_h: f32 = 16;
/// Transport bar content height.
pub const transport_h: f32 = 22;
/// Icon size inside icon buttons.
pub const icon_sm: f32 = 11;
pub const icon_md: f32 = 13;

/// Session scene row height.
pub const session_row_h: f32 = 28;
/// Session track header height.
pub const session_header_h: f32 = 20;
/// Scene name column width.
pub const scene_col_w: f32 = 80;
/// Track / clip column width.
pub const track_col_w: f32 = 88;
/// Clip-slot play/create button width.
pub const play_btn_w: f32 = 16;
/// Scene launch button size.
pub const launch_btn: f32 = 16;
/// Track color strip width on clips.
pub const strip_w: f32 = 3;

/// Arrangement track header width.
pub const arr_track_w: f32 = 80;
/// Arrangement lane height.
pub const arr_lane_h: f32 = 30;
/// Arrangement ruler height.
pub const arr_ruler_h: f32 = 16;
/// Pixels per beat on arrangement timeline.
pub const arr_beat_w: f32 = 12;

/// Device chain — compact chips (header + one subtitle line).
/// Selected device detail + floating plugin GUIs use remaining bottom height.
pub const device_card_w: f32 = 100;
pub const device_card_h: f32 = 32;
pub const device_header_h: f32 = 16;
pub const device_add_w: f32 = 36;
pub const device_led: f32 = 9;
pub const device_chain_h: f32 = 36;

/// Browser category column.
pub const browser_nav_w: f32 = 92;

/// Spacing.
pub const gap_xs: f32 = 1;
pub const gap_tight: f32 = 3;
pub const gap_group: f32 = 6;
pub const pad_panel: f32 = 4;
pub const pad_content: f32 = 6;
pub const radius_sm: f32 = 2;
pub const radius_md: f32 = 3;

/// Default vertical split: more room for device/plugin bottom pane.
pub const top_split_default: f32 = 0.58;
