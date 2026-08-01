//! Arrangement view — timeline with clip blocks from host arrangement.
//! Full timeline: `ui_zgui/views/arrangement/`.

const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const state_mod = @import("../state.zig");

const clip_pad_y: f32 = 3;

pub fn draw(state: *state_mod.State) void {
    // Chrome arr_clips projected each frame from host in root.frame.

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
    });
    defer col.deinit();

    dvui.label(@src(), "Arrangement", .{}, .{
        .font = .theme(.heading),
        .color_text = theme.text,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_tight },
    });

    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.cell,
        .corners = .round(tokens.radius_md),
    });
    defer body.deinit();

    // Track headers
    {
        var headers = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background = true,
            .color_fill = theme.panel,
            .min_size_content = .{ .w = tokens.arr_track_w },
            .expand = .vertical,
            .border = .{ .x = 0, .y = 0, .w = 1, .h = 0 },
            .color_border = theme.grid,
        });
        defer headers.deinit();

        var spacer = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .h = tokens.arr_ruler_h },
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.header,
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .color_border = theme.grid,
        });
        spacer.deinit();

        var t: usize = 0;
        while (t < state.track_count) : (t += 1) {
            const selected = t == state.selected_track;
            const name = state.trackName(t);
            if (dvui.button(@src(), name, .{}, .{
                .expand = .horizontal,
                .min_size_content = .{ .h = tokens.arr_lane_h - 4 },
                .color_fill = if (selected) theme.accent else theme.cell,
                .color_text = if (selected) theme.bg else theme.text,
                .margin = .{ .x = tokens.gap_xs, .y = 1, .w = tokens.gap_xs, .h = 1 },
                .corners = .round(tokens.radius_sm),
                .id_extra = t,
            })) {
                state.selectTrack(t);
            }
        }
    }

    // Timeline
    {
        var scroll = dvui.scrollArea(@src(), .{
            .horizontal_bar = .auto,
            .vertical_bar = .auto,
        }, .{
            .expand = .both,
            .background = false,
        });
        defer scroll.deinit();

        var timeline = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = tokens.arr_beat_w * 64 },
        });
        defer timeline.deinit();

        drawRuler(state);

        var t: usize = 0;
        while (t < state.track_count) : (t += 1) {
            drawLane(state, t);
        }
    }
}

fn drawRuler(state: *const state_mod.State) void {
    var ruler = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.header,
        .min_size_content = .{ .h = tokens.arr_ruler_h, .w = tokens.arr_beat_w * 64 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.grid,
    });
    defer ruler.deinit();

    const rs = ruler.data().contentRectScale();
    const area = rs.r;
    const beats_per_bar: f32 = @floatFromInt(state.time_signature_numerator);
    const bars: usize = 16;

    var bar: usize = 0;
    while (bar < bars) : (bar += 1) {
        const x = area.x + @as(f32, @floatFromInt(bar)) * tokens.arr_beat_w * beats_per_bar * rs.s;
        if (x > area.x + area.w) break;
        const line: dvui.Rect.Physical = .{
            .x = x,
            .y = area.y,
            .w = @max(1.0, rs.s),
            .h = area.h,
        };
        line.fill(.all(0), .{ .color = theme.grid });
    }

    if (state.playing or state.playhead_beat > 0) {
        const px = area.x + state.playhead_beat * tokens.arr_beat_w * rs.s;
        if (px >= area.x and px < area.x + area.w) {
            const ph: dvui.Rect.Physical = .{
                .x = px,
                .y = area.y,
                .w = @max(2.0, rs.s),
                .h = area.h,
            };
            ph.fill(.all(0), .{ .color = theme.play });
        }
    }
}

fn drawLane(state: *state_mod.State, track: usize) void {
    const selected = track == state.selected_track;
    var lane = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = if (selected) theme.panel else theme.cell,
        .min_size_content = .{ .h = tokens.arr_lane_h, .w = tokens.arr_beat_w * 64 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.grid,
        .id_extra = track,
    });
    defer lane.deinit();

    const rs = lane.data().contentRectScale();
    const area = rs.r;
    const beats_per_bar: f32 = @floatFromInt(state.time_signature_numerator);

    var bar: usize = 0;
    while (bar < 16) : (bar += 1) {
        const x = area.x + @as(f32, @floatFromInt(bar)) * tokens.arr_beat_w * beats_per_bar * rs.s;
        if (x > area.x + area.w) break;
        const line: dvui.Rect.Physical = .{
            .x = x,
            .y = area.y,
            .w = @max(1.0, rs.s),
            .h = area.h,
        };
        line.fill(.all(0), .{ .color = theme.grid });
    }

    var i: usize = 0;
    while (i < state.arr_clip_count) : (i += 1) {
        const clip = state.arr_clips[i];
        if (clip.track != track) continue;
        drawArrClip(state, i, clip, area, rs.s);
    }

    if (state.playing or state.playhead_beat > 0) {
        const px = area.x + state.playhead_beat * tokens.arr_beat_w * rs.s;
        if (px >= area.x and px < area.x + area.w) {
            const ph: dvui.Rect.Physical = .{
                .x = px,
                .y = area.y,
                .w = @max(2.0, rs.s),
                .h = area.h,
            };
            ph.fill(.all(0), .{ .color = theme.play });
        }
    }

    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, lane.data())) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .press or !me.button.pointer()) continue;
        e.handle(@src(), lane.data());

        const local_x = (me.p.x - area.x) / rs.s;
        var hit: ?usize = null;
        var ci: usize = 0;
        while (ci < state.arr_clip_count) : (ci += 1) {
            const c = state.arr_clips[ci];
            if (c.track != track) continue;
            const x0 = c.start_beat * tokens.arr_beat_w;
            const x1 = x0 + c.length_beats * tokens.arr_beat_w;
            if (local_x >= x0 and local_x < x1) {
                hit = ci;
                break;
            }
        }

        if (hit) |idx| {
            state.selectTrack(track);
            state.selected_arr_clip = idx;
            state.bottom_mode = .sequencer;
        } else {
            state.selectTrack(track);
            state.selected_arr_clip = null;
        }
        dvui.refresh(null, @src(), lane.data().id);
    }
}

fn drawArrClip(
    state: *state_mod.State,
    index: usize,
    clip: state_mod.ArrClip,
    lane_area: dvui.Rect.Physical,
    scale: f32,
) void {
    const x0 = lane_area.x + clip.start_beat * tokens.arr_beat_w * scale;
    const w = clip.length_beats * tokens.arr_beat_w * scale;
    if (w < 2) return;
    if (x0 + w < lane_area.x or x0 > lane_area.x + lane_area.w) return;

    const is_sel = state.selected_arr_clip == index;
    const body = clipBodyColor(clip.kind, is_sel);
    const y = lane_area.y + clip_pad_y * scale;
    const h = lane_area.h - 2 * clip_pad_y * scale;

    const rect: dvui.Rect.Physical = .{
        .x = x0,
        .y = y,
        .w = w,
        .h = h,
    };
    rect.fill(.all(2), .{ .color = body });

    const strip: dvui.Rect.Physical = .{
        .x = x0,
        .y = y,
        .w = @max(2.0, tokens.strip_w * scale),
        .h = h,
    };
    strip.fill(.all(0), .{ .color = theme.trackColor(clip.track) });

    if (is_sel) {
        const t = @max(1.5, 1.5 * scale);
        const top: dvui.Rect.Physical = .{ .x = x0, .y = y, .w = w, .h = t };
        const bot: dvui.Rect.Physical = .{ .x = x0, .y = y + h - t, .w = w, .h = t };
        const left: dvui.Rect.Physical = .{ .x = x0, .y = y, .w = t, .h = h };
        const right: dvui.Rect.Physical = .{ .x = x0 + w - t, .y = y, .w = t, .h = h };
        top.fill(.all(0), .{ .color = theme.selected });
        bot.fill(.all(0), .{ .color = theme.selected });
        left.fill(.all(0), .{ .color = theme.selected });
        right.fill(.all(0), .{ .color = theme.selected });
    }

    _ = clip.name;
}

fn clipBodyColor(kind: state_mod.ClipKind, selected: bool) dvui.Color {
    const base = switch (kind) {
        .empty => theme.empty_slot_fill,
        .midi => theme.clip_stopped,
        .audio => theme.clip_audio_stopped,
    };
    if (selected) return base;
    return theme.lighten(base, -0.06);
}
