//! Arrangement right-side mixer strip (M/S/R, vol, pan, meters) + master bus.
//! Track rows scroll with the timeline lanes; master stays pinned under them.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const state_mod = @import("../state.zig");
const host_mod = @import("../host.zig");
const document_model = @import("../../document/model.zig");
const document_commands = @import("../../document/commands.zig");

pub fn drawHeader() void {
    var head = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = tokens.arr_mixer_w, .h = tokens.arr_ruler_h },
        .max_size_content = .{ .w = tokens.arr_mixer_w, .h = tokens.arr_ruler_h },
        .background = true,
        .color_fill = theme.header,
        .border = .{ .x = 1, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.grid,
        .padding = .{ .x = tokens.gap_group, .y = 0, .w = 0, .h = 0 },
        .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
    });
    defer head.deinit();
    dvui.label(@src(), "Mixer", .{}, .{
        .color_text = theme.text_dim,
        .gravity_y = 0.5,
    });
}

/// `si_mixer` / `viewport_y` come from the arrangement linked-scroll setup so
/// mixer track rows stay row-aligned with timeline lanes while scrolling.
pub fn draw(state: *state_mod.State, si_mixer: *dvui.ScrollInfo, viewport_y: f32, lanes_h: f32) void {
    var strip = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = theme.panel,
        .min_size_content = .{ .w = tokens.arr_mixer_w },
        .max_size_content = .width(tokens.arr_mixer_w),
        .expand = .vertical,
        .border = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
        .color_border = theme.grid,
        .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
    });
    defer strip.deinit();

    {
        var rows_scroll = dvui.scrollArea(@src(), .{
            .scroll_info = si_mixer,
            .frame_viewport = .{ .y = viewport_y },
            .horizontal_bar = .hide,
            .vertical_bar = .hide,
            .process_events_after = false,
        }, .{
            .expand = .both,
            .background = false,
        });
        defer rows_scroll.deinit();

        var rows = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = lanes_h },
        });
        defer rows.deinit();

        var t: usize = 0;
        while (t < state.track_count) : (t += 1) {
            drawMixerRow(state, t, false);
        }
    }

    // Master bus pinned under the scrolling track rows (session mixer parity).
    drawMixerRow(state, state_mod.master_track_index, true);
}

fn drawMixerRow(state: *state_mod.State, track: usize, is_master: bool) void {
    const selected = if (is_master)
        state.mixer_target == .master
    else
        state.mixer_target == .track and state.selected_track == track;

    const mute = if (is_master) state.master_mute else state.track_mute[track];
    const volume_ptr = if (is_master) &state.master_volume else &state.track_volume[track];
    const pan_ptr = if (is_master) &state.master_pan else &state.track_pan[track];
    const levels: [2]f32 = if (is_master)
        .{ 0, 0 }
    else if (track < state_mod.max_tracks)
        state.track_levels[track]
    else
        .{ 0, 0 };
    const id = if (is_master) state_mod.master_track_index else track;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = tokens.arr_lane_h },
        .max_size_content = .height(tokens.arr_lane_h),
        .background = true,
        .color_fill = if (selected) theme.cell_hover else if (is_master) theme.header else if (track % 2 == 0) theme.cell else theme.header,
        .border = .{ .x = 0, .y = if (is_master) 1 else 0, .w = 0, .h = 1 },
        .color_border = theme.grid,
        .padding = .{ .x = tokens.gap_tight, .y = 0, .w = tokens.gap_tight, .h = 0 },
        .id_extra = id,
    });
    defer row.deinit();

    // Track / master color accent
    {
        const rs = row.data().contentRectScale();
        const area = rs.r;
        const strip_r: dvui.Rect.Physical = .{
            .x = area.x - 2 * rs.s,
            .y = area.y,
            .w = @max(2.0, 3 * rs.s),
            .h = area.h,
        };
        const accent = if (is_master) theme.selected else theme.trackColor(track);
        strip_r.fill(.all(0), .{ .color = accent });
    }

    if (is_master) {
        dvui.label(@src(), "Master", .{}, .{
            .color_text = if (selected) theme.text else theme.text_dim,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 40 },
        });
    }

    const btn_w: f32 = 18;
    const btn_pad = dvui.Rect{ .x = 1, .y = 0, .w = 1, .h = 0 };

    if (dvui.button(@src(), "M", .{}, .{
        .color_fill = if (mute) theme.mute_on else theme.panel,
        .color_text = theme.text,
        .min_size_content = .{ .w = btn_w, .h = tokens.control_h },
        .padding = btn_pad,
        .corners = .round(tokens.radius_sm),
        .id_extra = id,
        .gravity_y = 0.5,
        .margin = if (is_master) .{ .x = tokens.gap_tight, .y = 0, .w = 0, .h = 0 } else .{},
    })) {
        if (document_model.ready()) document_commands.toggleTrackMute(&document_model.g, track);
        if (is_master) state.selectMaster() else state.selectTrack(track);
    }

    if (!is_master) {
        if (dvui.button(@src(), "S", .{}, .{
            .color_fill = if (state.track_solo[track]) theme.solo_on else theme.panel,
            .color_text = theme.text,
            .min_size_content = .{ .w = btn_w, .h = tokens.control_h },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .padding = btn_pad,
            .corners = .round(tokens.radius_sm),
            .id_extra = id,
            .gravity_y = 0.5,
        })) {
            if (document_model.ready()) document_commands.toggleTrackSolo(&document_model.g, track);
            state.selectTrack(track);
        }
        const armed = state.armed_track == track;
        if (dvui.button(@src(), "R", .{}, .{
            .color_fill = if (armed) theme.arm_on else theme.panel,
            .color_text = theme.text,
            .min_size_content = .{ .w = btn_w, .h = tokens.control_h },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .padding = btn_pad,
            .corners = .round(tokens.radius_sm),
            .id_extra = id,
            .gravity_y = 0.5,
        })) {
            if (document_model.ready()) {
                document_commands.toggleTrackArm(&document_model.g, track);
                if (host_mod.ready()) host_mod.g.projectChrome(state);
            } else {
                state.armed_track = if (armed) null else track;
            }
            state.selectTrack(track);
        }
    }

    if (dvui.sliderEntry(@src(), "{d:.2}", .{
        .value = volume_ptr,
        .min = 0,
        .max = 1.5,
        .interval = 0.01,
    }, .{
        .min_size_content = .{ .w = if (is_master) 90 else 72, .h = tokens.control_h },
        .margin = .{ .x = tokens.gap_tight, .y = 0, .w = 0, .h = 0 },
        .id_extra = id,
        .gravity_y = 0.5,
    })) {
        if (document_model.ready()) {
            document_commands.setTrackVolume(&document_model.g, track, volume_ptr.*);
        }
        if (is_master) state.selectMaster() else state.selectTrack(track);
    }

    if (dvui.sliderEntry(@src(), "P{d:.1}", .{
        .value = pan_ptr,
        .min = -1,
        .max = 1,
        .interval = 0.01,
    }, .{
        .min_size_content = .{ .w = 52, .h = tokens.control_h },
        .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
        .id_extra = id,
        .gravity_y = 0.5,
    })) {
        if (document_model.ready()) {
            document_commands.setTrackPan(&document_model.g, track, pan_ptr.*);
        }
        if (is_master) state.selectMaster() else state.selectTrack(track);
    }

    if (!is_master) {
        drawArrMeter(levels, id);
    } else {
        // Clicking master label area also selects the bus for the device rack.
        if (dvui.button(@src(), "FX", .{}, .{
            .min_size_content = .{ .w = 28, .h = tokens.control_h },
            .margin = .{ .x = tokens.gap_tight, .y = 0, .w = 0, .h = 0 },
            .padding = btn_pad,
            .corners = .round(tokens.radius_sm),
            .id_extra = id,
            .gravity_y = 0.5,
            .color_fill = if (selected) theme.accent else theme.panel,
            .color_text = if (selected) theme.bg else theme.text_dim,
        })) {
            state.selectMaster();
        }
    }
}

fn drawArrMeter(levels: [2]f32, id_extra: usize) void {
    var meter = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 14, .h = tokens.control_h },
        .background = true,
        .color_fill = theme.panel,
        .margin = .{ .x = tokens.gap_tight, .y = 2, .w = 0, .h = 2 },
        .corners = .round(1),
        .id_extra = id_extra,
        .gravity_y = 0.5,
    });
    defer meter.deinit();

    const rs = meter.data().contentRectScale();
    const area = rs.r;
    const gap = 1.0 * rs.s;
    const ch_w = (area.w - gap) * 0.5;
    for (levels, 0..) |level, ch| {
        const amount = std.math.clamp(level, 0, 1);
        const x0 = area.x + @as(f32, @floatFromInt(ch)) * (ch_w + gap);
        const bg: dvui.Rect.Physical = .{ .x = x0, .y = area.y, .w = ch_w, .h = area.h };
        bg.fill(.all(0), .{ .color = theme.cell });
        const fill_h = area.h * amount;
        const fill: dvui.Rect.Physical = .{
            .x = x0,
            .y = area.y + area.h - fill_h,
            .w = ch_w,
            .h = fill_h,
        };
        fill.fill(.all(0), .{ .color = if (amount > 0.9) theme.arm_on else theme.solo_on });
    }
}
