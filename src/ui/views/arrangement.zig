//! Arrangement view — timeline with clip blocks from host arrangement.
//! Clip drag/move/resize, box multi-select, zoom, right mixer strip.
//! Gestures: `arrangement_gestures.zig`; mixer: `arrangement_mixer.zig`.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const state_mod = @import("../state.zig");
const edit_actions = @import("../edit_actions.zig");
const host_mod = @import("../host.zig");
const document_model = @import("../../document/model.zig");
const document_commands = @import("../../document/commands.zig");
const audio_clip_view = @import("audio_clip.zig");
const peaks_mod = @import("../../session/peaks.zig");
const arr_timeline = @import("../../arrangement/timeline.zig");
const time_utils = @import("../../util/time_utils.zig");
const arrangement_mixer = @import("arrangement_mixer.zig");
const arrangement_gestures = @import("arrangement_gestures.zig");

const clip_pad_y: f32 = 3;
const min_ppb: f32 = 4;
const max_ppb: f32 = 80;
const default_timeline_beats: f32 = 64;
const clock_io: std.Io = std.Io.Threaded.global_single_threaded.io();

/// Peak pointers keyed by document revision (not rebuilt every paint).
var peak_cache: [state_mod.max_arr_clips]?[]const peaks_mod.PeakBin = @splat(null);
var peak_cache_revision: u64 = std.math.maxInt(u64);
/// CSR-style per-track index into `state.arr_clips` (rebuilt each paint).
var track_clip_starts: [state_mod.max_tracks + 1]u16 = @splat(0);
var track_clip_indices: [state_mod.max_arr_clips]u16 = undefined;

pub fn draw(state: *state_mod.State) void {
    // Chrome arr_clips projected each frame from host in root.frame.
    // Live drag mutates document without revision; sync chrome while gesturing.
    if (state.arr_drag_mode != .none or state.arr_box_select) {
        arrangement_gestures.syncArrClipsChrome(state);
    }

    rebuildTrackClipIndex(state);
    // Header shows previous-frame stats; reset drawn counter after display.
    const prev_drawn = state.arr_clips_drawn;
    const prev_us = state.arr_draw_us;
    state.arr_clips_drawn = 0;
    const t0 = std.Io.Clock.awake.now(clock_io);

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
    });
    defer col.deinit();

    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_tight },
        });
        defer header.deinit();

        dvui.label(@src(), "Arrangement", .{}, .{
            .font = .theme(.heading),
            .color_text = theme.text,
            .gravity_y = 0.5,
        });

        var zoom_buf: [24]u8 = undefined;
        const zoom_s = std.fmt.bufPrint(&zoom_buf, "{d:.0} px/beat", .{state.arr_pixels_per_beat}) catch "?";
        dvui.label(@src(), "  {s}  ·  scroll = zoom", .{zoom_s}, .{
            .color_text = theme.text_soft,
            .gravity_y = 0.5,
        });

        if (dvui.button(@src(), "−", .{}, .{
            .min_size_content = .{ .w = 18, .h = tokens.control_h },
            .margin = .{ .x = tokens.gap_group, .y = 0, .w = 0, .h = 0 },
            .corners = .round(tokens.radius_sm),
        })) {
            state.arr_pixels_per_beat = std.math.clamp(state.arr_pixels_per_beat * 0.85, min_ppb, max_ppb);
        }
        if (dvui.button(@src(), "+", .{}, .{
            .min_size_content = .{ .w = 18, .h = tokens.control_h },
            .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
            .corners = .round(tokens.radius_sm),
        })) {
            state.arr_pixels_per_beat = std.math.clamp(state.arr_pixels_per_beat * 1.15, min_ppb, max_ppb);
        }
        if (dvui.button(@src(), "Reset", .{}, .{
            .min_size_content = .{ .h = tokens.control_h },
            .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
            .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
            .corners = .round(tokens.radius_sm),
        })) {
            state.arr_pixels_per_beat = tokens.arr_beat_w;
        }

        // Dense-clip frame-time readout (previous frame; useful under load).
        if (state.arr_clip_count > 0 or prev_us > 0) {
            var prof_buf: [48]u8 = undefined;
            const prof = std.fmt.bufPrint(
                &prof_buf,
                "  ·  {d} clips · {d} drawn · {d}µs",
                .{ state.arr_clip_count, prev_drawn, prev_us },
            ) catch "";
            dvui.label(@src(), "{s}", .{prof}, .{
                .color_text = theme.text_dim,
                .gravity_y = 0.5,
            });
        }
    }

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.cell,
        .corners = .round(tokens.radius_md),
    });
    defer body.deinit();

    const body_rs = body.data().contentRectScale();
    const body_w = body_rs.r.w / @max(body_rs.s, 0.001);
    const show_mixer = body_w >= tokens.arr_mixer_min_body_w;
    const timeline_w = timelineWidth(state);
    const lanes_h = @as(f32, @floatFromInt(state.track_count)) * tokens.arr_lane_h;

    // Linked scroll: main timeline owns both axes; track headers + mixer share
    // vertical offset; ruler shares horizontal offset (DVUI linked-scroll pattern).
    const si_main = dvui.dataGetPtrDefault(null, body.data().id, "si_main", dvui.ScrollInfo, .{
        .horizontal = .auto,
        .vertical = .auto,
    });
    const si_left = dvui.dataGetPtrDefault(null, body.data().id, "si_left", dvui.ScrollInfo, .{
        .horizontal = .none,
        .vertical = .auto,
    });
    const si_mixer = dvui.dataGetPtrDefault(null, body.data().id, "si_mixer", dvui.ScrollInfo, .{
        .horizontal = .none,
        .vertical = .auto,
    });
    const si_ruler = dvui.dataGetPtrDefault(null, body.data().id, "si_ruler", dvui.ScrollInfo, .{
        .horizontal = .auto,
        .vertical = .none,
    });
    const fv = si_main.viewport.topLeft();

    var main_area: dvui.ScrollAreaWidget = undefined;
    main_area.init(@src(), .{
        .scroll_info = si_main,
        .frame_viewport = fv,
        .container = false,
    }, .{
        .expand = .both,
        .background = false,
    });
    defer main_area.deinit();

    // ── Fixed top: corner | horizontally linked ruler | mixer header ────────
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = tokens.arr_ruler_h },
            .max_size_content = .height(tokens.arr_ruler_h),
        });
        defer top.deinit();

        {
            var corner = dvui.box(@src(), .{}, .{
                .min_size_content = .{ .w = tokens.arr_track_w, .h = tokens.arr_ruler_h },
                .max_size_content = .{ .w = tokens.arr_track_w, .h = tokens.arr_ruler_h },
                .background = true,
                .color_fill = theme.header,
                .border = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
                .color_border = theme.grid,
            });
            defer corner.deinit();
        }

        {
            var ruler_scroll = dvui.scrollArea(@src(), .{
                .scroll_info = si_ruler,
                .frame_viewport = .{ .x = fv.x },
                .horizontal_bar = .hide,
                .vertical_bar = .hide,
                .process_events_after = false,
            }, .{
                .expand = .both,
                .background = false,
            });
            defer ruler_scroll.deinit();
            drawRuler(state, timeline_w);
        }

        if (show_mixer) {
            arrangement_mixer.drawHeader();
        }
    }

    // ── Scrollable body: headers | lanes | mixer rows ───────────────────────
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
        });
        defer row.deinit();

        // Track name headers (vertical scroll linked to main).
        {
            var headers_scroll = dvui.scrollArea(@src(), .{
                .scroll_info = si_left,
                .frame_viewport = .{ .y = fv.y },
                .horizontal_bar = .hide,
                .vertical_bar = .hide,
                .process_events_after = false,
            }, .{
                .min_size_content = .{ .w = tokens.arr_track_w },
                .max_size_content = .width(tokens.arr_track_w),
                .expand = .vertical,
                .background = true,
                .color_fill = theme.panel,
                .border = .{ .x = 0, .y = 0, .w = 1, .h = 0 },
                .color_border = theme.grid,
            });
            defer headers_scroll.deinit();

            var headers = dvui.box(@src(), .{ .dir = .vertical }, .{
                .min_size_content = .{ .w = tokens.arr_track_w, .h = lanes_h },
            });
            defer headers.deinit();

            var t: usize = 0;
            while (t < state.track_count) : (t += 1) {
                drawTrackHeader(state, t);
            }
        }

        // Timeline lanes (owns scroll interaction for both axes).
        {
            var scontainer: dvui.ScrollContainerWidget = undefined;
            scontainer.init(@src(), si_main, .{
                .scroll_area = &main_area,
                .frame_viewport = fv,
                .event_rect = main_area.data().borderRectScale().r,
            }, .{
                .expand = .both,
                .background = false,
            });
            defer scontainer.deinit();
            scontainer.processEvents();

            var timeline = dvui.box(@src(), .{ .dir = .vertical }, .{
                .min_size_content = .{ .w = timeline_w, .h = lanes_h },
            });
            defer timeline.deinit();

            var t: usize = 0;
            while (t < state.track_count) : (t += 1) {
                drawLane(state, t, timeline_w);
            }

            drawBoxSelection(state);
        }

        // Mixer strip: track rows scroll with lanes; master stays pinned below.
        if (show_mixer) {
            arrangement_mixer.draw(state, si_mixer, fv.y, lanes_h);
        }
    }

    // Sync linked viewports after all scroll areas have processed input.
    var new_x = fv.x;
    if (si_ruler.viewport.x != fv.x) new_x = si_ruler.viewport.x;
    if (si_main.viewport.x != fv.x) new_x = si_main.viewport.x;
    si_main.viewport.x = new_x;
    si_ruler.viewport.x = new_x;

    var new_y = fv.y;
    if (si_left.viewport.y != fv.y) new_y = si_left.viewport.y;
    if (si_mixer.viewport.y != fv.y) new_y = si_mixer.viewport.y;
    if (si_main.viewport.y != fv.y) new_y = si_main.viewport.y;
    si_main.viewport.y = new_y;
    si_left.viewport.y = new_y;
    si_mixer.viewport.y = new_y;

    const t1 = std.Io.Clock.awake.now(clock_io);
    const us = time_utils.nsSince(t0, t1) / 1000;
    state.arr_draw_us = @intCast(@min(us, std.math.maxInt(u32)));
}

fn drawTrackHeader(state: *state_mod.State, track: usize) void {
    const selected = track == state.selected_track and state.mixer_target == .track;
    const name = state.trackName(track);

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = tokens.arr_lane_h },
        .max_size_content = .height(tokens.arr_lane_h),
        .background = true,
        .color_fill = if (selected) theme.cell_hover else if (track % 2 == 0) theme.cell else theme.header,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.grid,
        .padding = .{ .x = tokens.gap_xs, .y = 0, .w = tokens.gap_xs, .h = 0 },
        .id_extra = track,
    });
    defer row.deinit();

    if (dvui.button(@src(), name, .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = tokens.arr_lane_h - 4 },
        .color_fill = if (selected) theme.accent else theme.panel,
        .color_text = if (selected) theme.bg else theme.text,
        .corners = .round(tokens.radius_sm),
        .gravity_y = 0.5,
        .id_extra = track,
    })) {
        state.selectTrack(track);
    }
}

fn timelineWidth(state: *const state_mod.State) f32 {
    var max_beat: f32 = default_timeline_beats;
    var i: usize = 0;
    while (i < state.arr_clip_count) : (i += 1) {
        const c = state.arr_clips[i];
        max_beat = @max(max_beat, c.start_beat + c.length_beats + 4);
    }
    if (state.playhead_beat > 0) max_beat = @max(max_beat, state.playhead_beat + 4);
    return max_beat * state.arr_pixels_per_beat;
}

fn ppb(state: *const state_mod.State) f32 {
    return state.arr_pixels_per_beat;
}

fn drawRuler(state: *state_mod.State, timeline_w: f32) void {
    var ruler = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.header,
        .min_size_content = .{ .h = tokens.arr_ruler_h, .w = timeline_w },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.grid,
    });
    defer ruler.deinit();

    const rs = ruler.data().contentRectScale();
    const area = rs.r;
    const beats_per_bar: f32 = @floatFromInt(state.time_signature_numerator);
    const beat_w = ppb(state);
    const bars: usize = @as(usize, @intFromFloat(@ceil(timeline_w / (beat_w * beats_per_bar)))) + 1;

    var bar: usize = 0;
    while (bar < bars) : (bar += 1) {
        const x = area.x + @as(f32, @floatFromInt(bar)) * beat_w * beats_per_bar * rs.s;
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
        const px = area.x + state.playhead_beat * beat_w * rs.s;
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

    handleZoomEvents(state, ruler.data(), area);
}

fn drawLane(state: *state_mod.State, track: usize, timeline_w: f32) void {
    const selected = track == state.selected_track and state.mixer_target == .track;
    const beat_w = ppb(state);
    var lane = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = if (selected) theme.panel else theme.cell,
        .min_size_content = .{ .h = tokens.arr_lane_h, .w = timeline_w },
        .max_size_content = .height(tokens.arr_lane_h),
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.grid,
        .id_extra = track,
    });
    defer lane.deinit();

    const rs = lane.data().contentRectScale();
    const area = rs.r;
    if (track < state_mod.max_tracks) {
        state.arr_lane_rects[track] = .{ area.x, area.y, area.w, area.h };
    }

    const beats_per_bar: f32 = @floatFromInt(state.time_signature_numerator);
    const bars: usize = @as(usize, @intFromFloat(@ceil(timeline_w / (beat_w * beats_per_bar)))) + 1;

    var bar: usize = 0;
    while (bar < bars) : (bar += 1) {
        const x = area.x + @as(f32, @floatFromInt(bar)) * beat_w * beats_per_bar * rs.s;
        if (x > area.x + area.w) break;
        const line: dvui.Rect.Physical = .{
            .x = x,
            .y = area.y,
            .w = @max(1.0, rs.s),
            .h = area.h,
        };
        line.fill(.all(0), .{ .color = theme.grid });
    }

    if (track < state_mod.max_tracks) {
        const start = track_clip_starts[track];
        const end = track_clip_starts[track + 1];
        var k: u16 = start;
        while (k < end) : (k += 1) {
            const i = track_clip_indices[k];
            drawArrClip(state, i, state.arr_clips[i], area, rs.s, beat_w);
        }
    }

    if (state.playing or state.playhead_beat > 0) {
        const px = area.x + state.playhead_beat * beat_w * rs.s;
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

    handleZoomEvents(state, lane.data(), area);
    arrangement_gestures.handleLaneEvents(state, track, lane.data(), area, rs.s, beat_w);
    drawContextMenu(state, lane.data().borderRectScale().r, track);
}

fn drawBoxSelection(state: *const state_mod.State) void {
    if (!state.arr_box_select) return;
    const x0 = @min(state.arr_box_start_x, state.arr_box_current_x);
    const y0 = @min(state.arr_box_start_y, state.arr_box_current_y);
    const x1 = @max(state.arr_box_start_x, state.arr_box_current_x);
    const y1 = @max(state.arr_box_start_y, state.arr_box_current_y);
    const rect: dvui.Rect.Physical = .{
        .x = x0,
        .y = y0,
        .w = @max(1, x1 - x0),
        .h = @max(1, y1 - y0),
    };
    rect.fill(.all(0), .{ .color = theme.alpha(theme.selected, 0.18) });
    const t = 1.5;
    const top: dvui.Rect.Physical = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = t };
    const bot: dvui.Rect.Physical = .{ .x = rect.x, .y = rect.y + rect.h - t, .w = rect.w, .h = t };
    const left: dvui.Rect.Physical = .{ .x = rect.x, .y = rect.y, .w = t, .h = rect.h };
    const right: dvui.Rect.Physical = .{ .x = rect.x + rect.w - t, .y = rect.y, .w = t, .h = rect.h };
    const border = theme.alpha(theme.selected, 0.85);
    top.fill(.all(0), .{ .color = border });
    bot.fill(.all(0), .{ .color = border });
    left.fill(.all(0), .{ .color = border });
    right.fill(.all(0), .{ .color = border });
}

fn handleZoomEvents(state: *state_mod.State, wd: *dvui.WidgetData, area: dvui.Rect.Physical) void {
    _ = area;
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, wd)) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .wheel_y => |ticks| {
                e.handle(@src(), wd);
                const old = state.arr_pixels_per_beat;
                const factor: f32 = if (ticks > 0) 1.12 else 0.89;
                state.arr_pixels_per_beat = std.math.clamp(old * factor, min_ppb, max_ppb);
                dvui.refresh(null, @src(), wd.id);
            },
            else => {},
        }
    }
}

fn drawContextMenu(state: *state_mod.State, rect: dvui.Rect.Physical, track: usize) void {
    const context = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = track });
    defer context.deinit();
    const point = context.activePoint() orelse return;
    const selected = if (document_model.ready())
        document_commands.arrangementHasSelection(&document_model.g)
    else
        state.selected_arr_clip != null;
    var menu = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(point) }, .{ .id_extra = track });
    defer menu.deinit();
    if (edit_actions.drawMenu(.{
        .duplicate = selected,
        .delete = selected,
        .select_all = true,
        .undo = document_model.ready() and document_commands.canUndo(&document_model.g),
        .redo = document_model.ready() and document_commands.canRedo(&document_model.g),
        .move_left = selected,
        .move_right = selected,
        .move_up = selected,
        .move_down = selected,
    })) |action| {
        _ = applyEditAction(state, action);
        menu.close();
    }
}

pub fn applyEditAction(state: *state_mod.State, action: edit_actions.Action) bool {
    if (!document_model.ready()) return false;
    const store = &document_model.g;
    const selected = state.selected_arr_clip;
    var changed = false;
    switch (action) {
        .select_all => {
            document_commands.selectAllArrangementClips(store);
            changed = true;
        },
        .duplicate => if (selected) |index| {
            if (document_commands.duplicateArrangementClip(store, index)) |new_index| {
                state.selected_arr_clip = new_index;
                changed = true;
            }
        },
        .delete => {
            if (document_commands.deleteSelectedArrangementClips(store)) {
                state.selected_arr_clip = null;
                changed = true;
            } else if (selected) |index| {
                if (document_commands.deleteArrangementClip(store, index)) {
                    state.selected_arr_clip = null;
                    changed = true;
                }
            }
        },
        .move_left, .move_right, .move_up, .move_down => if (selected) |index| {
            const dt: i32 = switch (action) {
                .move_up => -1,
                .move_down => 1,
                else => 0,
            };
            const ticks: i64 = switch (action) {
                .move_left => -store.arrangement.snap_division_ticks,
                .move_right => store.arrangement.snap_division_ticks,
                else => 0,
            };
            if (document_commands.moveArrangementClip(store, index, dt, ticks)) |new_index| {
                state.selected_arr_clip = new_index;
                changed = true;
            }
        },
        .undo => changed = document_commands.undo(store),
        .redo => changed = document_commands.redo(store),
        else => {},
    }
    if (changed and host_mod.ready()) host_mod.g.projectChrome(state);
    return changed;
}

fn drawArrClip(
    state: *state_mod.State,
    index: usize,
    clip: state_mod.ArrClip,
    lane_area: dvui.Rect.Physical,
    scale: f32,
    beat_w: f32,
) void {
    const x0 = lane_area.x + clip.start_beat * beat_w * scale;
    const w = clip.length_beats * beat_w * scale;
    if (w < 2) return;
    if (x0 + w < lane_area.x or x0 > lane_area.x + lane_area.w) return;

    state.arr_clips_drawn +%= 1;

    const is_sel = clip.selected or state.selected_arr_clip == index;
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

    const strip_w = @max(2.0, tokens.strip_w * scale);
    const strip: dvui.Rect.Physical = .{
        .x = x0,
        .y = y,
        .w = strip_w,
        .h = h,
    };
    strip.fill(.all(0), .{ .color = theme.trackColor(clip.track) });

    // Audio waveform thumbnail when peaks are available (revision-cached).
    if (clip.kind == .audio) {
        if (arrClipPeaksCached(index)) |peaks| {
            const pad = 2.0 * scale;
            const wave: dvui.Rect.Physical = .{
                .x = x0 + strip_w + pad,
                .y = y + pad,
                .w = @max(1.0, w - strip_w - 2 * pad),
                .h = @max(1.0, h - 2 * pad),
            };
            audio_clip_view.drawPeaks(wave, peaks, theme.colorFA(0.95, 0.95, 0.96, 0.35), 0.88, 0);
        }
    }

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

    // Name label when the clip is wide enough.
    if (w > 28 * scale and clip.name.len > 0) {
        const font = dvui.Font.theme(.body).withSize(@max(8, @min(11, h / scale - 2)));
        dvui.renderText(.{
            .text = clip.name,
            .font = font,
            .color = theme.text_on_fill,
            .rs = .{
                .r = .{
                    .x = x0 + strip_w + 3 * scale,
                    .y = y + (h - font.size * scale) * 0.5,
                    .w = @max(1, w - strip_w - 6 * scale),
                    .h = h,
                },
                .s = scale,
            },
        }) catch {};
    }
}

fn rebuildTrackClipIndex(state: *const state_mod.State) void {
    var counts: [state_mod.max_tracks]u16 = @splat(0);
    var i: usize = 0;
    while (i < state.arr_clip_count) : (i += 1) {
        const t = state.arr_clips[i].track;
        if (t < state_mod.max_tracks and counts[t] < std.math.maxInt(u16)) {
            counts[t] += 1;
        }
    }
    var off: u16 = 0;
    var t: usize = 0;
    while (t < state_mod.max_tracks) : (t += 1) {
        track_clip_starts[t] = off;
        off +%= counts[t];
    }
    track_clip_starts[state_mod.max_tracks] = off;

    var cursors = track_clip_starts;
    i = 0;
    while (i < state.arr_clip_count) : (i += 1) {
        const tr = state.arr_clips[i].track;
        if (tr >= state_mod.max_tracks) continue;
        const slot = cursors[tr];
        if (slot >= track_clip_indices.len) continue;
        track_clip_indices[slot] = @intCast(i);
        cursors[tr] = slot + 1;
    }
}

fn ensurePeakCache() void {
    const revision: u64 = if (document_model.ready()) document_model.g.revision else 0;
    // Live drag can move clips without a revision bump; peaks only depend on
    // sample identity, so revision is enough for the pointer table.
    if (peak_cache_revision == revision) return;
    peak_cache = @splat(null);
    peak_cache_revision = revision;
    if (!document_model.ready()) return;
    const document = &document_model.g;
    var global_i: usize = 0;
    for (document.arrangement.tracks.items) |*atrack| {
        for (atrack.clips.items) |*placement| {
            if (global_i >= state_mod.max_arr_clips) break;
            const pooled = document.arrangement.placementClip(placement) orelse {
                global_i += 1;
                continue;
            };
            if (pooled.content == .audio) {
                if (pooled.content.audio.sample_id) |sample_id| {
                    if (document.sample_store.get(sample_id)) |asset| {
                        peak_cache[global_i] = asset.peaks[0..];
                    }
                }
            }
            global_i += 1;
        }
    }
}

fn arrClipPeaksCached(index: usize) ?[]const peaks_mod.PeakBin {
    ensurePeakCache();
    if (index >= state_mod.max_arr_clips) return null;
    return peak_cache[index];
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
