//! Layout density tokens for the DVUI host.
//! Values are **natural** pixels — DVUI already multiplies by content scale
//! for Retina/HiDPI. Do not multiply these by DPI again.
//!
//! Tuned dense for DAW chrome: transport stays thin; the device chain uses
//! full-height horizontal rack cards with per-plugin widths (zgui parity).

/// Control / button height (transport, tabs, compact tools).
pub const control_h: f32 = 22;
/// Transport bar content height.
pub const transport_h: f32 = 32;
/// Icon size inside icon buttons.
pub const icon_sm: f32 = 12;
pub const icon_md: f32 = 14;

/// Session scene row height.
pub const session_row_h: f32 = 28;
/// Session track header height.
pub const session_header_h: f32 = 28;
/// Session mixer strip height below the launcher grid.
pub const session_mixer_h: f32 = 208;
/// Scene name column width.
pub const scene_col_w: f32 = 80;
/// Track / clip column width.
pub const track_col_w: f32 = 112;
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
/// Right-side arrangement mixer strip (natural px; zgui 560÷2 content-scale).
pub const arr_mixer_w: f32 = 280;
/// Hide arrangement mixer when the pane is narrower than this.
pub const arr_mixer_min_body_w: f32 = 520;

// ── Device rack (zgui card_width table ÷ 2: DVUI already applies content scale) ─

/// Empty instrument slot.
pub const device_w_empty: f32 = 184;
/// External CLAP without embedded UI (compact info + open-window).
pub const device_w_external: f32 = 240;
/// Stock equalizer (multi-band layout room).
pub const device_w_equalizer: f32 = 435;
/// Stock dynamics FX (compressor / gate / limiter).
pub const device_w_dynamics: f32 = 425;
/// Legacy reserved widths (prefer `param_chrome.preferredCardWidth` for embedded UIs).
pub const device_w_zsynth: f32 = 520;
pub const device_w_zminimoog: f32 = 520;
pub const device_w_zportafm: f32 = 520;
/// Fallback width for other plugins with many params.
pub const device_w_params: f32 = 320;
/// "+" add-device card.
pub const device_add_w: f32 = 40;
/// Card header row height.
pub const device_header_h: f32 = 34;
/// Enable LED size.
pub const device_led: f32 = 8;
/// Minimum rack card height (fills remaining bottom pane when larger).
pub const device_card_min_h: f32 = 120;
/// Gap between cards / chevrons.
pub const device_chain_gap: f32 = 8;

/// Legacy aliases used by older call sites.
pub const device_card_w: f32 = device_w_empty;
pub const device_card_h: f32 = device_card_min_h;
pub const device_chain_h: f32 = device_card_min_h;

/// Bounded catalog/picker column; plugin rows should not span the whole pane.
pub const plugin_list_w: f32 = 320;

/// Browser category column.
pub const browser_nav_w: f32 = 112;

/// Spacing.
pub const gap_xs: f32 = 2;
pub const gap_tight: f32 = 4;
pub const gap_group: f32 = 8;
pub const pad_panel: f32 = 8;
pub const pad_content: f32 = 8;
pub const radius_sm: f32 = 4;
pub const radius_md: f32 = 6;

/// Default vertical split: more room for device/plugin bottom pane.
pub const top_split_default: f32 = 0.62;
