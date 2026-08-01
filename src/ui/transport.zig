//! Transport bar — chrome port of `ui_zgui/draw.zig` `drawTransport`.
//! Dense icon-first chrome so content panes keep vertical space.
//! DSP % / meters come from full `AudioEngine` via `ui/audio_runtime.zig`.

const dvui = @import("dvui");
const theme = @import("theme.zig");
const tokens = @import("tokens.zig");
const icons = @import("icons.zig");
const state_mod = @import("state.zig");

pub fn draw(state: *state_mod.State) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.panel,
        .padding = .{ .x = tokens.gap_tight, .y = 2, .w = tokens.gap_tight, .h = 2 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.grid,
        .min_size_content = .{ .h = tokens.transport_h },
    });
    defer bar.deinit();

    // Play / Stop — icon only
    const play_kind: icons.IconKind = if (state.playing) .stop else .play;
    const play_fill = if (state.playing) theme.stop else theme.play;
    if (icons.button(@src(), play_kind, .{
        .fill = play_fill,
        .color = theme.bg,
        .size = tokens.icon_md,
    })) {
        state.togglePlay();
    }

    // Metronome
    if (icons.button(@src(), .metronome, .{
        .fill = if (state.metronome_enabled) theme.accent else theme.cell,
        .color = if (state.metronome_enabled) theme.bg else theme.text_dim,
        .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
        .id_extra = 1,
    })) {
        state.toggleMetronome();
    }

    separator(0);

    // Browser
    if (icons.button(@src(), .browser, .{
        .fill = if (state.browser_open) theme.accent else theme.cell,
        .color = if (state.browser_open) theme.bg else theme.text_dim,
        .id_extra = 2,
    })) {
        state.toggleBrowser();
    }

    separator(1);

    // Time signature
    fieldLabel("TS", 0);
    var ts_idx = state.timeSignatureIndex();
    if (dvui.dropdown(@src(), &state_mod.time_signature_labels, .{ .choice = &ts_idx }, .{}, .{
        .min_size_content = .{ .w = 46, .h = tokens.control_h },
        .gravity_y = 0.5,
    })) {
        state.setTimeSignatureIndex(ts_idx);
    }

    // BPM
    fieldLabel("BPM", 1);
    _ = dvui.sliderEntry(@src(), "{d:.0}", .{
        .value = &state.bpm,
        .min = 40,
        .max = 200,
        .interval = 1,
    }, .{
        .min_size_content = .{ .w = 48, .h = tokens.control_h },
        .gravity_y = 0.5,
    });

    separator(2);

    // Quantize
    fieldLabel("Q", 2);
    _ = dvui.dropdown(@src(), &state_mod.quantize_labels, .{ .choice = &state.quantize_index }, .{}, .{
        .min_size_content = .{ .w = 48, .h = tokens.control_h },
        .gravity_y = 0.5,
    });

    // Buffer
    fieldLabel("Buf", 3);
    var buf_idx = state.bufferIndex();
    if (dvui.dropdown(@src(), &state_mod.buffer_labels, .{ .choice = &buf_idx }, .{}, .{
        .min_size_content = .{ .w = 46, .h = tokens.control_h },
        .gravity_y = 0.5,
    })) {
        state.setBufferIndex(buf_idx);
    }

    dvui.label(@src(), "DSP {d}%", .{state.dsp_load_pct}, .{
        .gravity_y = 0.5,
        .color_text = theme.text_dim,
        .margin = .{ .x = tokens.gap_group, .y = 0, .w = 0, .h = 0 },
    });

    separator(3);

    // View mode
    const sess_fill = if (state.view_mode == .session) theme.accent else theme.cell;
    const sess_text = if (state.view_mode == .session) theme.bg else theme.text;
    if (dvui.button(@src(), "Sess", .{}, .{
        .color_fill = sess_fill,
        .color_text = sess_text,
        .min_size_content = .{ .h = tokens.control_h },
        .gravity_y = 0.5,
        .corners = .round(tokens.radius_sm),
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
    })) {
        state.view_mode = .session;
    }
    const arr_fill = if (state.view_mode == .arrangement) theme.accent else theme.cell;
    const arr_text = if (state.view_mode == .arrangement) theme.bg else theme.text;
    if (dvui.button(@src(), "Arr", .{}, .{
        .color_fill = arr_fill,
        .color_text = arr_text,
        .min_size_content = .{ .h = tokens.control_h },
        .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
        .corners = .round(tokens.radius_sm),
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
    })) {
        state.view_mode = .arrangement;
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .min_size_content = .{} });

    if (dvui.button(@src(), "Load", .{}, .{
        .min_size_content = .{ .h = tokens.control_h },
        .gravity_y = 0.5,
        .color_fill = theme.cell,
        .color_text = theme.text,
        .corners = .round(tokens.radius_sm),
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
    })) {
        state.load_project_request = true;
    }
    if (dvui.button(@src(), "Save", .{}, .{
        .min_size_content = .{ .h = tokens.control_h },
        .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
        .color_fill = theme.cell,
        .color_text = theme.text,
        .corners = .round(tokens.radius_sm),
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
    })) {
        state.save_project_request = true;
    }
    if (dvui.button(@src(), "Save as…", .{}, .{
        .min_size_content = .{ .h = tokens.control_h },
        .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
        .color_fill = theme.cell,
        .color_text = theme.text,
        .corners = .round(tokens.radius_sm),
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
    })) {
        state.save_project_as_request = true;
    }
}

fn fieldLabel(text: []const u8, id_extra: usize) void {
    dvui.label(@src(), "{s}", .{text}, .{
        .gravity_y = 0.5,
        .color_text = theme.text_dim,
        .margin = .{ .x = tokens.gap_group, .y = 0, .w = tokens.gap_xs, .h = 0 },
        .id_extra = id_extra,
    });
}

fn separator(id_extra: usize) void {
    var sep = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = theme.grid,
        .min_size_content = .{ .w = 1, .h = tokens.control_h - 2 },
        .margin = .{ .x = tokens.gap_group, .y = 0, .w = tokens.gap_group, .h = 0 },
        .gravity_y = 0.5,
        .id_extra = id_extra,
    });
    sep.deinit();
}
