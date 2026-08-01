//! Session view — Ableton-style clip grid (tracks as columns, scenes as rows).
//! Slot content projects from `ui/host.zig` (real session + clip pool).
//! Full behavior reference: `ui_zgui/views/session/`.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const icons = @import("../icons.zig");
const state_mod = @import("../state.zig");
const edit_actions = @import("../edit_actions.zig");
const host_mod = @import("../host.zig");
const document_model = @import("../../document/model.zig");
const document_commands = @import("../../document/commands.zig");

const add_track_col_w: f32 = 84;

pub fn draw(state: *state_mod.State) void {
    // Chrome is projected each frame from host in root.frame.

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    defer col.deinit();

    const grid_w = tokens.scene_col_w +
        @as(f32, @floatFromInt(state.track_count)) * tokens.track_col_w + add_track_col_w;
    var horizontal_scroll = dvui.scrollArea(@src(), .{
        .horizontal_bar = .auto,
        .vertical_bar = .hide,
    }, .{ .expand = .both, .background = false });
    defer horizontal_scroll.deinit();

    var session_content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .min_size_content = .{ .w = grid_w },
    });
    defer session_content.deinit();

    {
        var scroll = dvui.scrollArea(@src(), .{
            .horizontal_bar = .hide,
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
                .padding = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .color_border = theme.grid,
            });
            defer header.deinit();

            var corner = dvui.box(@src(), .{}, .{
                .min_size_content = .{ .w = tokens.scene_col_w, .h = tokens.session_header_h - 2 },
                .max_size_content = .width(tokens.scene_col_w),
            });
            corner.deinit();

            var t: usize = 0;
            while (t < state.track_count) : (t += 1) {
                const selected = t == state.selected_track;
                const name = state.trackName(t);
                var track_cell = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .min_size_content = .{ .w = tokens.track_col_w, .h = tokens.session_header_h - 2 },
                    .max_size_content = .width(tokens.track_col_w),
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
                    .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
                    .id_extra = t,
                })) {
                    state.selectTrack(t);
                    if (document_model.ready()) document_commands.setSessionAnchor(&document_model.g, state.selected_track, state.selected_scene, true);
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
                .min_size_content = .{ .w = add_track_col_w - 11, .h = tokens.session_header_h - 4 },
                .color_fill = theme.cell,
                .color_text = theme.text_dim,
                .corners = .round(tokens.radius_sm),
                .margin = .{ .x = 3, .y = 1, .w = 2, .h = 1 },
                .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
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
                .padding = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .color_border = theme.grid,
                .id_extra = s,
            });
            defer row.deinit();

            // Scene launch + name (vertically centered in row)
            {
                var scene_cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .min_size_content = .{ .w = tokens.scene_col_w, .h = tokens.session_row_h - 4 },
                    .max_size_content = .width(tokens.scene_col_w),
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
                    .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                    .corners = .round(tokens.radius_sm),
                    .gravity_y = 0.5,
                    .id_extra = s + 1000,
                })) {
                    state.selectScene(s);
                    if (document_model.ready()) document_commands.setSessionAnchor(&document_model.g, state.selected_track, state.selected_scene, true);
                }
            }

            var t: usize = 0;
            while (t < state.track_count) : (t += 1) {
                drawClipSlot(state, t, s);
            }
        }

        if (dvui.button(@src(), "+ Scene", .{}, .{
            .min_size_content = .{ .w = tokens.scene_col_w - 10, .h = tokens.session_row_h - 8 },
            .color_fill = theme.panel,
            .color_text = theme.text_dim,
            .corners = .round(tokens.radius_sm),
            .margin = .{ .x = 2, .y = 3, .w = 2, .h = 2 },
            .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
        })) {
            if (document_model.ready()) {
                if (document_commands.addScene(&document_model.g) and host_mod.ready()) host_mod.g.projectChrome(state);
            }
        }
    }

    drawMixer(state);
}

fn drawMixer(state: *state_mod.State) void {
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = theme.header,
        .min_size_content = .{ .h = tokens.session_mixer_h },
        .padding = .{ .x = tokens.scene_col_w, .y = 4, .w = 0, .h = 4 },
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
    var track_cell = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = tokens.track_col_w },
        .max_size_content = .width(tokens.track_col_w),
        .id_extra = track,
    });
    defer track_cell.deinit();

    var channel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = tokens.session_mixer_h - 8 },
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

        const button_w: f32 = 16;
        const button_padding = dvui.Rect{ .x = 2, .y = 0, .w = 2, .h = 0 };
        if (dvui.button(@src(), "M", .{}, .{
            .color_fill = if (state.track_mute[track]) theme.mute_on else theme.panel,
            .color_text = theme.text,
            .min_size_content = .{ .w = button_w, .h = tokens.control_h },
            .margin = .{},
            .padding = button_padding,
            .corners = .round(tokens.radius_sm),
            .id_extra = track,
        })) {
            if (document_model.ready()) document_commands.toggleTrackMute(&document_model.g, track);
            state.selectTrack(track);
        }
        if (dvui.button(@src(), "S", .{}, .{
            .color_fill = if (state.track_solo[track]) theme.solo_on else theme.panel,
            .color_text = theme.text,
            .min_size_content = .{ .w = button_w, .h = tokens.control_h },
            .margin = .{ .x = tokens.gap_tight, .y = 0, .w = 0, .h = 0 },
            .padding = button_padding,
            .corners = .round(tokens.radius_sm),
            .id_extra = track,
        })) {
            if (document_model.ready()) document_commands.toggleTrackSolo(&document_model.g, track);
            state.selectTrack(track);
        }

        const armed = state.armed_track == track;
        if (dvui.button(@src(), "R", .{}, .{
            .color_fill = if (armed) theme.arm_on else theme.panel,
            .color_text = theme.text,
            .min_size_content = .{ .w = button_w, .h = tokens.control_h },
            .margin = .{ .x = tokens.gap_tight, .y = 0, .w = 0, .h = 0 },
            .padding = button_padding,
            .corners = .round(tokens.radius_sm),
            .id_extra = track,
        })) {
            if (document_model.ready()) {
                document_commands.toggleTrackArm(&document_model.g, track);
                if (host_mod.ready()) host_mod.g.projectChrome(state);
            } else {
                state.armed_track = if (armed) null else track;
            }
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
    const is_selected = slotIsSelected(state, track, scene, slot);
    const is_drop_target = state.session_drag_target_valid and
        state.session_drag_target_track == track and state.session_drag_target_scene == scene;
    const id = track * 64 + scene;

    const fill = slotFill(slot);
    const border_col = if (is_selected or is_drop_target)
        theme.selected
    else if (slot.kind == .empty)
        theme.empty_slot_border
    else
        theme.grid;

    const slot_h = tokens.session_row_h - 6;
    var track_cell = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = tokens.track_col_w },
        .max_size_content = .width(tokens.track_col_w),
        .id_extra = id,
    });
    defer track_cell.deinit();

    var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = slot_h },
        .background = true,
        .color_fill = if (is_selected and slot.kind != .empty) theme.lighten(fill, 0.08) else fill,
        .corners = .round(tokens.radius_sm),
        .border = dvui.Rect.all(if (is_selected or is_drop_target) 1.5 else 1),
        .color_border = border_col,
        .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
        .id_extra = id,
    });
    defer cell.deinit();

    const cell_area = cell.data().borderRectScale().r;
    state.session_slot_rects[track][scene] = .{ cell_area.x, cell_area.y, cell_area.w, cell_area.h };

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

    const body_w = tokens.track_col_w - tokens.play_btn_w - 11;
    const label = slotLabel(slot);
    {
        var body = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = body_w, .h = slot_h - 2 },
            .background = false,
            .padding = .{ .x = if (slot.kind != .empty) 5 else 2, .y = 0, .w = 1, .h = 0 },
            .margin = .{},
            .gravity_y = 0.5,
            .id_extra = id,
        });
        dvui.labelNoFmt(@src(), label, .{}, .{
            .expand = .both,
            .color_text = if (slot.kind == .empty) theme.text_soft else theme.text_on_fill,
            .gravity_y = 0.5,
            .margin = .{},
            .padding = .{},
            .id_extra = id,
        });
        handleSlotEvents(state, track, scene, slot, body.data());
        drawSlotContextMenu(state, track, scene, body.data().borderRectScale().r, id);
        body.deinit();
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
        if (slot.kind != .empty) {
            toggleSlotPlay(state, track, scene);
        }
    }
}

fn slotIsSelected(state: *const state_mod.State, track: usize, scene: usize, slot: state_mod.ClipSlot) bool {
    if (slot.kind == .empty or !document_model.ready()) {
        return track == state.selected_track and scene == state.selected_scene;
    }
    return document_commands.sessionSlotSelected(&document_model.g, track, scene);
}

fn handleSlotEvents(
    state: *state_mod.State,
    track: usize,
    scene: usize,
    slot: state_mod.ClipSlot,
    wd: *dvui.WidgetData,
) void {
    for (dvui.events()) |*event| {
        if (!dvui.eventMatchSimple(event, wd) or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        switch (mouse.action) {
            .press => if (mouse.button.pointer()) {
                event.handle(@src(), wd);
                state.focused_pane = .session;
                focusSlot(state, track, scene, mouse.mod.shift());
                state.session_drag_active = slot.kind != .empty;
                state.session_drag_started = false;
                state.session_drag_source_track = track;
                state.session_drag_source_scene = scene;
                state.session_drag_target_track = track;
                state.session_drag_target_scene = scene;
                state.session_drag_target_valid = slot.kind != .empty;
                dvui.captureMouse(wd, event.num);
                dvui.dragPreStart(mouse.button, mouse.p, .{ .name = "session_clip" });
                dvui.refresh(null, @src(), wd.id);
            },
            .motion => if (dvui.captured(wd.id)) {
                event.handle(@src(), wd);
                if (state.session_drag_active and dvui.dragging(mouse.p, null) != null) {
                    state.session_drag_started = true;
                    if (hitSlot(state, mouse.p)) |target| {
                        state.session_drag_target_track = target[0];
                        state.session_drag_target_scene = target[1];
                        state.session_drag_target_valid = true;
                    } else {
                        state.session_drag_target_valid = false;
                    }
                    dvui.refresh(null, @src(), wd.id);
                }
            },
            .release => if (mouse.button.pointer() and dvui.captured(wd.id)) {
                event.handle(@src(), wd);
                if (state.session_drag_started and state.session_drag_target_valid) {
                    const dt = @as(i32, @intCast(state.session_drag_target_track)) - @as(i32, @intCast(state.session_drag_source_track));
                    const ds = @as(i32, @intCast(state.session_drag_target_scene)) - @as(i32, @intCast(state.session_drag_source_scene));
                    _ = moveSelection(state, state.session_drag_source_track, state.session_drag_source_scene, dt, ds);
                } else if (!state.session_drag_started) {
                    activateSlot(state, track, scene, slot);
                }
                state.session_drag_active = false;
                state.session_drag_started = false;
                state.session_drag_target_valid = false;
                dvui.captureMouse(null, event.num);
                dvui.dragEnd();
                dvui.refresh(null, @src(), wd.id);
            },
            .position => if (slot.kind != .empty) dvui.cursorSet(.arrow_all),
            else => {},
        }
    }
}

fn hitSlot(state: *const state_mod.State, point: dvui.Point.Physical) ?[2]usize {
    for (0..state.track_count) |track| {
        for (0..state.scene_count) |scene| {
            const raw = state.session_slot_rects[track][scene];
            const rect: dvui.Rect.Physical = .{ .x = raw[0], .y = raw[1], .w = raw[2], .h = raw[3] };
            if (rect.w > 0 and rect.h > 0 and rect.contains(point)) return .{ track, scene };
        }
    }
    return null;
}

fn activateSlot(state: *state_mod.State, track: usize, scene: usize, slot: state_mod.ClipSlot) void {
    const now = dvui.currentWindow().frame_time_ns;
    const same_slot = state.session_last_slot_click_track == track and state.session_last_slot_click_scene == scene;
    const elapsed = now - state.session_last_slot_click_ns;
    const double_click = same_slot and elapsed > 0 and elapsed <= 450 * std.time.ns_per_ms;
    if (double_click) {
        if (slot.kind == .empty) {
            createClipAt(state, track, scene);
        } else {
            state.bottom_mode = .sequencer;
            state.focused_pane = .bottom;
        }
    }
    state.session_last_slot_click_ns = now;
    state.session_last_slot_click_track = track;
    state.session_last_slot_click_scene = scene;
}

fn drawSlotContextMenu(
    state: *state_mod.State,
    track: usize,
    scene: usize,
    rect: dvui.Rect.Physical,
    id: usize,
) void {
    const context = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id });
    defer context.deinit();
    const point = context.activePoint() orelse return;

    state.focused_pane = .session;
    focusSlot(state, track, scene, false);
    var menu = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(point) }, .{ .id_extra = id });
    defer menu.deinit();
    if (edit_actions.drawMenu(editAvailability())) |action| {
        _ = applyEditAction(state, action);
        menu.close();
    }
}

fn editAvailability() edit_actions.Availability {
    if (!document_model.ready()) return .{};
    const store = &document_model.g;
    const selected = document_commands.sessionHasSelection(store);
    return .{
        .copy = selected,
        .cut = selected,
        .paste = document_commands.sessionCanPaste(store),
        .duplicate = selected,
        .delete = selected,
        .select_all = true,
        .move_left = document_commands.canMoveSessionSelection(store, -1, 0),
        .move_right = document_commands.canMoveSessionSelection(store, 1, 0),
        .move_up = document_commands.canMoveSessionSelection(store, 0, -1),
        .move_down = document_commands.canMoveSessionSelection(store, 0, 1),
    };
}

/// Shared entry point for context-menu and keyboard edit actions.
pub fn applyEditAction(state: *state_mod.State, action: edit_actions.Action) bool {
    if (!document_model.ready()) return false;
    const store = &document_model.g;
    const changed = switch (action) {
        .copy => blk: {
            if (!document_commands.sessionHasSelection(store)) break :blk false;
            document_commands.copySessionSelection(store);
            break :blk true;
        },
        .cut => document_commands.cutSessionSelection(store),
        .paste => document_commands.pasteSessionSelection(store),
        .duplicate => document_commands.duplicateSessionSelection(store),
        .delete => document_commands.deleteSessionSelection(store),
        .select_all => blk: {
            document_commands.selectAllSessionClips(store);
            break :blk true;
        },
        .move_left => moveSelection(state, state.selected_track, state.selected_scene, -1, 0),
        .move_right => moveSelection(state, state.selected_track, state.selected_scene, 1, 0),
        .move_up => moveSelection(state, state.selected_track, state.selected_scene, 0, -1),
        .move_down => moveSelection(state, state.selected_track, state.selected_scene, 0, 1),
    };
    if (changed) syncAfterEdit(state);
    return changed;
}

fn moveSelection(state: *state_mod.State, anchor_track: usize, anchor_scene: usize, dt: i32, ds: i32) bool {
    if (!document_model.ready()) return false;
    const moved = document_commands.moveSessionSelection(&document_model.g, anchor_track, anchor_scene, dt, ds);
    if (moved) syncAfterEdit(state);
    return moved;
}

fn syncAfterEdit(state: *state_mod.State) void {
    if (!document_model.ready()) return;
    state.selected_track = document_model.g.session.primary_track;
    state.selected_scene = document_model.g.session.primary_scene;
    if (host_mod.ready()) host_mod.g.projectChrome(state);
}

fn focusSlot(state: *state_mod.State, track: usize, scene: usize, additive: bool) void {
    state.selectSlot(track, scene);
    if (document_model.ready()) {
        if (state.slot(track, scene).kind == .empty) {
            document_commands.setSessionAnchor(&document_model.g, track, scene, !additive);
        } else {
            document_commands.selectSessionSlot(&document_model.g, track, scene, additive);
        }
        document_commands.setPrimarySelection(&document_model.g, state.selected_track, state.selected_scene);
    }
}

fn createClipAt(state: *state_mod.State, track: usize, scene: usize) void {
    if (document_model.ready()) {
        document_commands.createClip(&document_model.g, track, scene, state.beatsPerBar());
        if (host_mod.ready()) host_mod.g.projectChrome(state);
        state.selectSlot(track, scene);
        state.bottom_mode = .sequencer;
        state.focused_pane = .bottom;
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
