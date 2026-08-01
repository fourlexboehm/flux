//! Session view — Ableton-style clip grid (tracks as columns, scenes as rows).
//! Slot content projects from `ui/host.zig` (real session + clip pool).
//! Full behavior reference: `ui_zgui/views/session/`.

const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const icons = @import("../icons.zig");
const state_mod = @import("../state.zig");
const host_mod = @import("../host.zig");
const document_model = @import("../../document/model.zig");
const document_commands = @import("../../document/commands.zig");

pub fn draw(state: *state_mod.State) void {
    // Chrome is projected each frame from host in root.frame.

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    defer col.deinit();

    var scroll = dvui.scrollArea(@src(), .{
        .horizontal_bar = .auto,
        .vertical_bar = .auto,
    }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.cell,
        .corners = .round(tokens.radius_md),
    });
    defer scroll.deinit();

    // Give the scroll container a real virtual width. Expanding each row to
    // the viewport hid horizontal overflow even when the track cells did not
    // fit, so no horizontal scrollbar could be produced.
    const grid_w = tokens.scene_col_w +
        @as(f32, @floatFromInt(state.track_count)) * tokens.track_col_w + 84;
    var grid_content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = grid_w },
    });
    defer grid_content.deinit();

    // ── Header: scene corner + track names ──────────────────────────────────
    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.header,
            .min_size_content = .{ .h = tokens.session_header_h },
            .padding = .{ .x = tokens.gap_xs, .y = 1, .w = tokens.gap_xs, .h = 1 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .color_border = theme.grid,
        });
        defer header.deinit();

        var corner = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = tokens.scene_col_w, .h = tokens.session_header_h - 2 },
        });
        corner.deinit();

        var t: usize = 0;
        while (t < state.track_count) : (t += 1) {
            const selected = t == state.selected_track;
            const name = state.trackName(t);
            var track_cell = dvui.box(@src(), .{ .dir = .vertical }, .{
                .min_size_content = .{ .w = tokens.track_col_w, .h = tokens.session_header_h - 2 },
                .padding = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
                .id_extra = t,
            });
            defer track_cell.deinit();

            if (dvui.button(@src(), name, .{}, .{
                .expand = .horizontal,
                .min_size_content = .{ .h = tokens.session_header_h - 6 },
                .color_fill = if (selected) theme.accent else theme.panel,
                .color_text = if (selected) theme.bg else theme.text_dim,
                .corners = .round(tokens.radius_sm),
                .gravity_y = 0.5,
                .id_extra = t,
            })) {
                state.selectTrack(t);
                if (document_model.ready()) document_commands.setPrimarySelection(&document_model.g, state.selected_track, state.selected_scene);
            }

            // Track color stripe under header
            const stripe_rs = track_cell.data().borderRectScale();
            const stripe_area = stripe_rs.r;
            if (stripe_area.w > 0 and stripe_area.h > 0) {
                const bar_h = @max(2.0, stripe_rs.s * 2.0);
                const bar: dvui.Rect.Physical = .{
                    .x = stripe_area.x + 2 * stripe_rs.s,
                    .y = stripe_area.y + stripe_area.h - bar_h,
                    .w = stripe_area.w - 4 * stripe_rs.s,
                    .h = bar_h,
                };
                bar.fill(.all(0), .{ .color = theme.trackColor(t) });
            }
        }

        if (dvui.button(@src(), "+ Track", .{}, .{
            .min_size_content = .{ .w = 72, .h = tokens.session_header_h - 4 },
            .color_fill = theme.cell,
            .color_text = theme.text_dim,
            .corners = .round(tokens.radius_sm),
            .margin = .{ .x = 3, .y = 1, .w = 2, .h = 1 },
        })) {
            if (document_model.ready()) {
                if (document_commands.addTrack(&document_model.g) and host_mod.ready()) host_mod.g.projectChrome(state);
            }
        }
    }

    // ── Scene rows ──────────────────────────────────────────────────────────
    var s: usize = 0;
    while (s < state.scene_count) : (s += 1) {
        const scene_sel = s == state.selected_scene;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = if (scene_sel) theme.panel else theme.cell,
            .min_size_content = .{ .h = tokens.session_row_h },
            .padding = .{ .x = tokens.gap_xs, .y = 2, .w = tokens.gap_xs, .h = 2 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .color_border = theme.grid,
            .id_extra = s,
        });
        defer row.deinit();

        // Scene launch + name (vertically centered in row)
        {
            var scene_cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .min_size_content = .{ .w = tokens.scene_col_w - 2, .h = tokens.session_row_h - 4 },
                .gravity_y = 0.5,
                .id_extra = s,
            });
            defer scene_cell.deinit();

            const has_clip = sceneHasClip(state, s);
            if (icons.button(@src(), if (has_clip) .play else .stop, .{
                .fill = if (has_clip) theme.panel else theme.empty_slot_fill,
                .color = if (has_clip) theme.accent else theme.text_soft,
                .size = tokens.icon_sm,
                .pad = 2,
                .border = true,
                .id_extra = s,
            })) {
                launchScene(state, s);
            }

            const sn = state.sceneName(s);
            if (dvui.button(@src(), sn, .{}, .{
                .min_size_content = .{ .w = tokens.scene_col_w - tokens.launch_btn - 12, .h = tokens.launch_btn },
                .color_fill = if (scene_sel) theme.accent_dim else theme.panel,
                .color_text = if (scene_sel) theme.text else theme.text_dim,
                .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
                .corners = .round(tokens.radius_sm),
                .gravity_y = 0.5,
                .id_extra = s + 1000,
            })) {
                state.selectScene(s);
                if (document_model.ready()) document_commands.setPrimarySelection(&document_model.g, state.selected_track, state.selected_scene);
            }
        }

        var t: usize = 0;
        while (t < state.track_count) : (t += 1) {
            drawClipSlot(state, t, s);
        }
    }

    if (dvui.button(@src(), "+ Scene", .{}, .{
        .min_size_content = .{ .w = tokens.scene_col_w - 4, .h = tokens.session_row_h - 8 },
        .color_fill = theme.panel,
        .color_text = theme.text_dim,
        .corners = .round(tokens.radius_sm),
        .margin = .{ .x = 2, .y = 3, .w = 2, .h = 2 },
    })) {
        if (document_model.ready()) {
            if (document_commands.addScene(&document_model.g) and host_mod.ready()) host_mod.g.projectChrome(state);
        }
    }

    drawMixer(state);
}

fn drawMixer(state: *state_mod.State) void {
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = theme.header,
        .min_size_content = .{ .h = tokens.session_mixer_h },
        .padding = .{ .x = tokens.scene_col_w + 2, .y = 4, .w = 4, .h = 4 },
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
        .color_border = theme.grid,
    });
    defer strip.deinit();

    var t: usize = 0;
    while (t < state.track_count) : (t += 1) drawMixerChannel(state, t);
}

fn drawMixerChannel(state: *state_mod.State, track: usize) void {
    const selected = state.selected_track == track;
    var channel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = tokens.track_col_w - 2, .h = tokens.session_mixer_h - 8 },
        .background = true,
        .color_fill = if (selected) theme.panel else theme.cell,
        .border = dvui.Rect.all(if (selected) 1.5 else 1),
        .color_border = if (selected) theme.selected else theme.grid,
        .corners = .round(tokens.radius_sm),
        .padding = dvui.Rect.all(tokens.gap_tight),
        .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
        .id_extra = track,
    });
    defer channel.deinit();

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = track });
        defer row.deinit();

        if (dvui.button(@src(), "M", .{}, .{
            .color_fill = if (state.track_mute[track]) theme.mute_on else theme.panel,
            .color_text = theme.text,
            .min_size_content = .{ .w = 24, .h = tokens.control_h },
            .corners = .round(tokens.radius_sm),
            .id_extra = track,
        })) {
            if (document_model.ready()) document_commands.toggleTrackMute(&document_model.g, track);
            state.selectTrack(track);
        }
        if (dvui.button(@src(), "S", .{}, .{
            .color_fill = if (state.track_solo[track]) theme.solo_on else theme.panel,
            .color_text = theme.text,
            .min_size_content = .{ .w = 24, .h = tokens.control_h },
            .margin = .{ .x = tokens.gap_tight, .y = 0, .w = 0, .h = 0 },
            .corners = .round(tokens.radius_sm),
            .id_extra = track,
        })) {
            if (document_model.ready()) document_commands.toggleTrackSolo(&document_model.g, track);
            state.selectTrack(track);
        }

        drawMeter(state.track_levels[track], track);
    }

    if (dvui.sliderEntry(@src(), "Vol {d:.2}", .{
        .value = &state.track_volume[track],
        .min = 0,
        .max = 1.5,
        .interval = 0.01,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = tokens.control_h },
        .id_extra = track,
    })) {
        if (document_model.ready()) document_commands.setTrackVolume(&document_model.g, track, state.track_volume[track]);
        state.selected_track = track;
    }

    if (dvui.sliderEntry(@src(), "Pan {d:.2}", .{
        .value = &state.track_pan[track],
        .min = -1,
        .max = 1,
        .interval = 0.01,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = tokens.control_h },
        .id_extra = track,
    })) {
        if (document_model.ready()) document_commands.setTrackPan(&document_model.g, track, state.track_pan[track]);
        state.selected_track = track;
    }

    if (dvui.button(@src(), state.trackName(track), .{}, .{
        .expand = .horizontal,
        .color_fill = theme.colorFA(0, 0, 0, 0),
        .color_text = if (selected) theme.text else theme.text_dim,
        .min_size_content = .{ .h = tokens.control_h },
        .id_extra = track,
    })) state.selectTrack(track);
}

fn drawMeter(levels: [2]f32, id_extra: usize) void {
    var meter = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = tokens.control_h },
        .background = true,
        .color_fill = theme.panel,
        .margin = .{ .x = tokens.gap_tight, .y = 2, .w = 0, .h = 2 },
        .id_extra = id_extra,
    });
    defer meter.deinit();

    const rs = meter.data().contentRectScale();
    const area = rs.r;
    const peak = @max(levels[0], levels[1]);
    const amount = @max(0, @min(peak, 1));
    const fill: dvui.Rect.Physical = .{
        .x = area.x,
        .y = area.y,
        .w = area.w * amount,
        .h = area.h,
    };
    fill.fill(.all(0), .{ .color = if (amount > 0.9) theme.mute_on else theme.solo_on });
}

fn sceneHasClip(state: *const state_mod.State, scene: usize) bool {
    var t: usize = 0;
    while (t < state.track_count) : (t += 1) {
        if (state.slot(t, scene).kind != .empty) return true;
    }
    return false;
}

fn launchScene(state: *state_mod.State, scene: usize) void {
    state.selectScene(scene);
    if (document_model.ready() and host_mod.ready()) {
        document_commands.launchScene(&document_model.g, scene, state.playing);
        host_mod.g.drainPlaybackRequests(state);
        host_mod.g.projectChrome(state);
        return;
    }
    // Offline chrome fallback (unit / no host).
    var t: usize = 0;
    while (t < state.track_count) : (t += 1) {
        var sc: usize = 0;
        while (sc < state.scene_count) : (sc += 1) {
            const slot = state.slotPtr(t, sc);
            if (slot.kind == .empty) continue;
            if (sc == scene) {
                slot.play = .playing;
            } else if (slot.play == .playing or slot.play == .queued) {
                slot.play = .stopped;
            }
        }
    }
}

fn drawClipSlot(state: *state_mod.State, track: usize, scene: usize) void {
    const slot = state.slot(track, scene);
    const is_selected = track == state.selected_track and scene == state.selected_scene;
    const id = track * 64 + scene;

    const fill = slotFill(slot);
    const border_col = if (is_selected)
        theme.selected
    else if (slot.kind == .empty)
        theme.empty_slot_border
    else
        theme.grid;

    const slot_h = tokens.session_row_h - 6;
    var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .{ .w = tokens.track_col_w - 2, .h = slot_h },
        .background = true,
        .color_fill = if (is_selected and slot.kind != .empty) theme.lighten(fill, 0.08) else fill,
        .corners = .round(tokens.radius_sm),
        .border = dvui.Rect.all(if (is_selected) 1.5 else 1),
        .color_border = border_col,
        .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
        .id_extra = id,
    });
    defer cell.deinit();

    // Track color strip on filled clips
    if (slot.kind != .empty) {
        const rs = cell.data().contentRectScale();
        const area = rs.r;
        if (area.w > 0 and area.h > 0) {
            const strip: dvui.Rect.Physical = .{
                .x = area.x,
                .y = area.y,
                .w = @max(2.0, tokens.strip_w * rs.s),
                .h = area.h,
            };
            strip.fill(.all(0), .{ .color = theme.trackColor(track) });
        }
    }

    const body_w = tokens.track_col_w - tokens.play_btn_w - 10;
    const label = slotLabel(slot);
    if (dvui.button(@src(), label, .{}, .{
        .min_size_content = .{ .w = body_w, .h = slot_h - 2 },
        .color_fill = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = if (slot.kind == .empty) theme.text_soft else theme.text_on_fill,
        .padding = .{ .x = if (slot.kind != .empty) 5 else 2, .y = 0, .w = 1, .h = 0 },
        .gravity_y = 0.5,
        .id_extra = id,
    })) {
        selectSlot(state, track, scene);
        if (slot.kind != .empty) state.bottom_mode = .sequencer;
    }

    const kind = playIconKind(slot);
    const play_fill = playButtonFill(slot);
    const play_col = if (slot.kind == .empty) theme.text_soft else theme.text_on_fill;
    if (icons.button(@src(), kind, .{
        .fill = play_fill,
        .color = play_col,
        .size = tokens.icon_sm,
        .pad = 1,
        .margin = .{ .x = 0, .y = 0, .w = 1, .h = 0 },
        .id_extra = id + 10000,
    })) {
        if (slot.kind == .empty) {
            createClipAt(state, track, scene);
        } else {
            toggleSlotPlay(state, track, scene);
        }
    }
}

fn selectSlot(state: *state_mod.State, track: usize, scene: usize) void {
    state.selectSlot(track, scene);
    if (document_model.ready()) {
        document_commands.selectSlot(&document_model.g, track, scene);
        document_commands.setPrimarySelection(&document_model.g, state.selected_track, state.selected_scene);
    }
}

fn createClipAt(state: *state_mod.State, track: usize, scene: usize) void {
    if (document_model.ready()) {
        document_commands.createClip(&document_model.g, track, scene, state.beatsPerBar());
        if (host_mod.ready()) host_mod.g.projectChrome(state);
        state.selectSlot(track, scene);
        state.bottom_mode = .sequencer;
        return;
    }
    state.createClipAt(track, scene);
}

fn toggleSlotPlay(state: *state_mod.State, track: usize, scene: usize) void {
    if (document_model.ready() and host_mod.ready()) {
        document_commands.toggleSlotPlayback(&document_model.g, track, scene, state.playing);
        host_mod.g.drainPlaybackRequests(state);
        host_mod.g.projectChrome(state);
        state.selectSlot(track, scene);
        return;
    }
    state.toggleSlotPlay(track, scene);
}

fn slotFill(slot: state_mod.ClipSlot) dvui.Color {
    return switch (slot.kind) {
        .empty => theme.empty_slot_fill,
        .midi => switch (slot.play) {
            .empty, .stopped => theme.clip_stopped,
            .queued => theme.clip_queued,
            .playing => theme.clip_playing,
        },
        .audio => switch (slot.play) {
            .empty, .stopped => theme.clip_audio_stopped,
            .queued => theme.clip_queued,
            .playing => theme.clip_audio_playing,
        },
    };
}

fn slotLabel(slot: state_mod.ClipSlot) []const u8 {
    if (slot.kind == .empty) return "";
    if (slot.name.len > 0) return slot.name;
    return switch (@as(u32, @intFromFloat(@min(slot.bars, 16)))) {
        1 => "1 bar",
        2 => "2 bars",
        4 => "4 bars",
        8 => "8 bars",
        else => "clip",
    };
}

fn playIconKind(slot: state_mod.ClipSlot) icons.IconKind {
    return switch (slot.play) {
        .playing => .stop,
        .queued => .play,
        .empty, .stopped => if (slot.kind == .empty) .plus else .play,
    };
}

fn playButtonFill(slot: state_mod.ClipSlot) dvui.Color {
    return switch (slot.play) {
        .playing => theme.clip_playing,
        .queued => theme.clip_queued,
        .empty, .stopped => if (slot.kind == .empty) theme.empty_slot_fill else theme.cell,
    };
}
