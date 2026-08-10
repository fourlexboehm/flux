//! Arrangement pointer gestures: clip drag/resize, box select, double-click create.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const state_mod = @import("../state.zig");
const host_mod = @import("../host.zig");
const document_model = @import("../../document/model.zig");
const document_commands = @import("../../document/commands.zig");
const arr_timeline = @import("../../arrangement/timeline.zig");

const resize_zone_natural: f32 = 6;
const drag_threshold_px: f32 = 4;
const clip_pad_y: f32 = 3;

fn ppb(state: *const state_mod.State) f32 {
    return state.arr_pixels_per_beat;
}

pub fn handleLaneEvents(
    state: *state_mod.State,
    track: usize,
    wd: *dvui.WidgetData,
    area: dvui.Rect.Physical,
    scale: f32,
    beat_w: f32,
) void {
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        const captured = dvui.captured(wd.id);

        // Captured gestures receive motion/release even outside the lane.
        if (!captured and !dvui.eventMatchSimple(e, wd)) continue;

        switch (me.action) {
            .press => {
                if (!me.button.pointer() and me.button != .right) continue;
                if (!area.contains(me.p)) continue;
                e.handle(@src(), wd);
                state.focused_pane = .session;

                const hit = hitClipOnTrack(state, track, me.p, area, scale, beat_w);
                if (hit) |h| {
                    beginClipInteraction(state, h.index, h.zone, me, track);
                    if (me.button.pointer()) {
                        dvui.captureMouse(wd, e.num);
                        dvui.dragPreStart(me.button, me.p, .{ .name = "arr_clip" });
                    }
                } else if (me.button.pointer()) {
                    // Empty lane: double-click creates a MIDI clip; otherwise pending box select.
                    const now = dvui.currentWindow().frame_time_ns;
                    const elapsed = now - state.arr_last_clip_click_ns;
                    const empty_double = state.arr_last_clip_click_index == null and
                        state.selected_track == track and
                        state.arr_last_clip_click_ns != 0 and
                        elapsed > 0 and elapsed <= 450 * std.time.ns_per_ms;

                    if (empty_double) {
                        createClipAtPointer(state, track, me.p, area, scale, beat_w);
                        state.arr_last_clip_click_ns = 0;
                        state.arr_last_clip_click_index = null;
                    } else {
                        state.selectTrack(track);
                        state.arr_box_pending = true;
                        state.arr_box_select = false;
                        state.arr_box_additive = me.mod.shift();
                        state.arr_box_start_x = me.p.x;
                        state.arr_box_start_y = me.p.y;
                        state.arr_box_current_x = me.p.x;
                        state.arr_box_current_y = me.p.y;
                        state.arr_last_clip_click_ns = now;
                        state.arr_last_clip_click_index = null;
                        dvui.captureMouse(wd, e.num);
                        dvui.dragPreStart(me.button, me.p, .{ .name = "arr_box" });
                    }
                }
                dvui.refresh(null, @src(), wd.id);
            },
            .motion => if (captured) {
                e.handle(@src(), wd);
                if (state.arr_drag_mode != .none) {
                    updateClipDrag(state, me.p, area, scale, beat_w);
                    dvui.cursorSet(if (state.arr_drag_mode == .move) .arrow_all else .arrow_w_e);
                } else if (state.arr_box_pending or state.arr_box_select) {
                    updateBoxSelect(state, me.p);
                }
                dvui.refresh(null, @src(), wd.id);
            },
            .release => if (me.button.pointer() and captured) {
                e.handle(@src(), wd);
                finishGestures(state);
                dvui.captureMouse(null, e.num);
                dvui.dragEnd();
                dvui.refresh(null, @src(), wd.id);
            },
            .position => {
                if (state.arr_drag_mode != .none) {
                    dvui.cursorSet(if (state.arr_drag_mode == .move) .arrow_all else .arrow_w_e);
                } else if (area.contains(me.p)) {
                    if (hitClipOnTrack(state, track, me.p, area, scale, beat_w)) |h| {
                        dvui.cursorSet(switch (h.zone) {
                            .body => .hand,
                            .left, .right => .arrow_w_e,
                        });
                    }
                }
            },
            else => {},
        }
    }
}

const HitZone = enum { body, left, right };

const ClipHit = struct {
    index: usize,
    zone: HitZone,
};

pub fn hitClipOnTrack(
    state: *const state_mod.State,
    track: usize,
    point: dvui.Point.Physical,
    area: dvui.Rect.Physical,
    scale: f32,
    beat_w: f32,
) ?ClipHit {
    const resize_z = resize_zone_natural * scale;
    // Prefer topmost (later) clips if overlapping.
    var i = state.arr_clip_count;
    while (i > 0) {
        i -= 1;
        const c = state.arr_clips[i];
        if (c.track != track) continue;
        const x0 = area.x + c.start_beat * beat_w * scale;
        const w = c.length_beats * beat_w * scale;
        const y = area.y + clip_pad_y * scale;
        const h = area.h - 2 * clip_pad_y * scale;
        if (point.x < x0 or point.x >= x0 + w or point.y < y or point.y >= y + h) continue;
        if (w > resize_z * 3) {
            if (point.x - x0 <= resize_z) return .{ .index = i, .zone = .left };
            if (x0 + w - point.x <= resize_z) return .{ .index = i, .zone = .right };
        }
        return .{ .index = i, .zone = .body };
    }
    return null;
}

fn beginClipInteraction(
    state: *state_mod.State,
    index: usize,
    zone: HitZone,
    me: dvui.Event.Mouse,
    track: usize,
) void {
    state.selectTrack(track);
    const shift = me.mod.shift();
    if (document_model.ready()) {
        _ = document_commands.selectArrangementClip(&document_model.g, index, shift);
        syncArrClipsChrome(state);
    }
    state.selected_arr_clip = index;

    // Double-click opens clip panel.
    const now = dvui.currentWindow().frame_time_ns;
    const same = state.arr_last_clip_click_index == index;
    const elapsed = now - state.arr_last_clip_click_ns;
    if (same and elapsed > 0 and elapsed <= 450 * std.time.ns_per_ms and me.button.pointer() and zone == .body) {
        state.bottom_mode = .sequencer;
        state.focused_pane = .bottom;
    }
    state.arr_last_clip_click_ns = now;
    state.arr_last_clip_click_index = index;

    if (!me.button.pointer() or !document_model.ready()) return;

    const loc = document_commands.arrangementLocation(&document_model.g, index) orelse return;
    const clip = document_model.g.arrangement.tracks.items[loc.track].clips.items[loc.clip];

    // Ensure the interaction clip is selected (non-shift body/edge).
    if (!shift and zone != .body) {
        _ = document_commands.selectArrangementClip(&document_model.g, index, false);
    }

    const mode: state_mod.ArrDragMode = switch (zone) {
        .body => .move,
        .left => .resize_left,
        .right => .resize_right,
    };
    // Drag starts after threshold via motion; store originals now.
    state.arr_drag_mode = mode;
    state.arr_drag_clip = index;
    state.arr_drag_mouse_x = me.p.x;
    state.arr_drag_mouse_y = me.p.y;
    state.arr_drag_orig_start_tick = clip.start_tick;
    state.arr_drag_orig_duration_ticks = clip.duration_ticks;
    state.arr_drag_orig_track = loc.track;
    state.arr_drag_orig_clip_index = loc.clip;
    state.arr_drag_changed = false;
    state.arr_drag_ctrl = me.mod.control() or me.mod.command();
    state.arr_drag_duplicated = false;
    state.arr_box_pending = false;
    state.arr_box_select = false;
}

fn updateClipDrag(
    state: *state_mod.State,
    point: dvui.Point.Physical,
    area: dvui.Rect.Physical,
    scale: f32,
    beat_w: f32,
) void {
    if (!document_model.ready()) return;
    const index = state.arr_drag_clip orelse return;
    const store = &document_model.g;

    // Require a small threshold before mutating (avoids accidental nudges on click).
    const dx_px = point.x - state.arr_drag_mouse_x;
    const dy_px = point.y - state.arr_drag_mouse_y;
    if (!state.arr_drag_changed and @abs(dx_px) < drag_threshold_px and @abs(dy_px) < drag_threshold_px and state.arr_drag_mode == .move) {
        return;
    }

    // Ctrl/Cmd+drag duplicates once on first real move.
    var active_index = index;
    if (state.arr_drag_mode == .move and state.arr_drag_ctrl and !state.arr_drag_duplicated) {
        if (document_commands.duplicateArrangementClipInPlace(store, active_index)) |new_idx| {
            active_index = new_idx;
            state.arr_drag_clip = new_idx;
            state.arr_drag_duplicated = true;
            state.arr_drag_changed = true;
            state.selected_arr_clip = new_idx;
            if (document_commands.arrangementLocation(store, new_idx)) |loc| {
                const c = store.arrangement.tracks.items[loc.track].clips.items[loc.clip];
                state.arr_drag_orig_start_tick = c.start_tick;
                state.arr_drag_orig_duration_ticks = c.duration_ticks;
                state.arr_drag_orig_track = loc.track;
            }
        }
    }

    const tick_delta = arr_timeline.pixelToTick(dx_px / scale, 1.0, beat_w);

    switch (state.arr_drag_mode) {
        .none => {},
        .move => {
            const target_track = trackAtY(state, point.y) orelse state.arr_drag_orig_track;
            const new_start = state.arr_drag_orig_start_tick + tick_delta;
            if (document_commands.setArrangementClipGeometry(
                store,
                active_index,
                new_start,
                state.arr_drag_orig_duration_ticks,
                target_track,
            )) |new_idx| {
                if (new_idx != active_index) {
                    state.arr_drag_clip = new_idx;
                    state.selected_arr_clip = new_idx;
                }
                state.arr_drag_changed = true;
            }
        },
        .resize_left => {
            const new_start = state.arr_drag_orig_start_tick + tick_delta;
            if (document_commands.resizeArrangementClipLeft(store, active_index, new_start)) {
                state.arr_drag_changed = true;
            }
        },
        .resize_right => {
            const new_dur = state.arr_drag_orig_duration_ticks + tick_delta;
            if (document_commands.resizeArrangementClipRight(store, active_index, new_dur)) {
                state.arr_drag_changed = true;
            }
        },
    }
    _ = area;
    syncArrClipsChrome(state);
}

fn updateBoxSelect(state: *state_mod.State, point: dvui.Point.Physical) void {
    state.arr_box_current_x = point.x;
    state.arr_box_current_y = point.y;
    const dx = point.x - state.arr_box_start_x;
    const dy = point.y - state.arr_box_start_y;
    if (!state.arr_box_select and (@abs(dx) >= drag_threshold_px or @abs(dy) >= drag_threshold_px)) {
        state.arr_box_select = true;
        state.arr_box_pending = false;
        if (!state.arr_box_additive and document_model.ready()) {
            document_commands.clearArrangementSelection(&document_model.g);
            state.selected_arr_clip = null;
        }
    }
    if (state.arr_box_select) {
        applyBoxSelection(state);
        syncArrClipsChrome(state);
    }
}

fn applyBoxSelection(state: *state_mod.State) void {
    if (!document_model.ready()) return;
    const store = &document_model.g;
    const x0 = @min(state.arr_box_start_x, state.arr_box_current_x);
    const x1 = @max(state.arr_box_start_x, state.arr_box_current_x);
    const y0 = @min(state.arr_box_start_y, state.arr_box_current_y);
    const y1 = @max(state.arr_box_start_y, state.arr_box_current_y);

    var selected_buf: [state_mod.max_arr_clips]usize = undefined;
    var selected_len: usize = 0;

    const beat_w = ppb(state);
    var i: usize = 0;
    while (i < state.arr_clip_count) : (i += 1) {
        const c = state.arr_clips[i];
        if (c.track >= state_mod.max_tracks) continue;
        const lr = state.arr_lane_rects[c.track];
        if (lr[2] <= 0 or lr[3] <= 0) continue;
        // Infer content scale from lane height vs natural lane height.
        const s = lr[3] / tokens.arr_lane_h;
        const cx0 = lr[0] + c.start_beat * beat_w * s;
        const cx1 = cx0 + c.length_beats * beat_w * s;
        const cy0 = lr[1] + clip_pad_y * s;
        const cy1 = lr[1] + lr[3] - clip_pad_y * s;
        if (cx1 >= x0 and cx0 <= x1 and cy1 >= y0 and cy0 <= y1) {
            if (selected_len < selected_buf.len) {
                selected_buf[selected_len] = i;
                selected_len += 1;
            }
        }
    }

    if (state.arr_box_additive) {
        // Additive: union with existing selection.
        var existing: [state_mod.max_arr_clips]usize = undefined;
        var existing_len: usize = 0;
        var gi: usize = 0;
        while (gi < state.arr_clip_count) : (gi += 1) {
            if (document_commands.arrangementClipSelected(store, gi)) {
                if (existing_len < existing.len) {
                    existing[existing_len] = gi;
                    existing_len += 1;
                }
            }
        }
        // Merge.
        var merged: [state_mod.max_arr_clips]usize = undefined;
        var merged_len: usize = 0;
        for (existing[0..existing_len]) |g| {
            if (merged_len < merged.len) {
                merged[merged_len] = g;
                merged_len += 1;
            }
        }
        for (selected_buf[0..selected_len]) |g| {
            var found = false;
            for (merged[0..merged_len]) |m| {
                if (m == g) {
                    found = true;
                    break;
                }
            }
            if (!found and merged_len < merged.len) {
                merged[merged_len] = g;
                merged_len += 1;
            }
        }
        document_commands.setArrangementSelection(store, merged[0..merged_len], false);
    } else {
        document_commands.setArrangementSelection(store, selected_buf[0..selected_len], false);
    }

    if (selected_len > 0) {
        state.selected_arr_clip = selected_buf[selected_len - 1];
    }
}

pub fn finishGestures(state: *state_mod.State) void {
    if (state.arr_drag_mode != .none) {
        if (state.arr_drag_changed and document_model.ready()) {
            if (state.arr_drag_clip) |global_index| {
                if (document_commands.arrangementLocation(&document_model.g, global_index)) |loc| {
                    document_commands.commitArrangementDrag(
                        &document_model.g,
                        loc.track,
                        loc.clip,
                        state.arr_drag_orig_track,
                        state.arr_drag_orig_clip_index,
                        state.arr_drag_orig_start_tick,
                        state.arr_drag_orig_duration_ticks,
                        state.arr_drag_duplicated,
                    );
                } else {
                    document_commands.commitArrangementEdit(&document_model.g);
                }
            } else {
                document_commands.commitArrangementEdit(&document_model.g);
            }
            if (host_mod.ready()) host_mod.g.projectChrome(state);
        } else {
            // Click without drag: selection already applied; re-sync selected flags.
            syncArrClipsChrome(state);
        }
        state.arr_drag_mode = .none;
        state.arr_drag_clip = null;
        state.arr_drag_changed = false;
        state.arr_drag_duplicated = false;
        state.arr_drag_ctrl = false;
    }
    if (state.arr_box_select or state.arr_box_pending) {
        if (state.arr_box_select) {
            applyBoxSelection(state);
            syncArrClipsChrome(state);
        }
        state.arr_box_select = false;
        state.arr_box_pending = false;
    }
}

pub fn createClipAtPointer(
    state: *state_mod.State,
    track: usize,
    point: dvui.Point.Physical,
    area: dvui.Rect.Physical,
    scale: f32,
    beat_w: f32,
) void {
    if (!document_model.ready()) return;
    const local_x = (point.x - area.x) / scale;
    const start_tick = arr_timeline.pixelToTick(local_x, 1.0, beat_w);
    if (document_commands.createArrangementMidiClip(&document_model.g, track, start_tick)) |idx| {
        state.selected_arr_clip = idx;
        state.selectTrack(track);
        if (host_mod.ready()) host_mod.g.projectChrome(state);
    }
}

fn trackAtY(state: *const state_mod.State, y: f32) ?usize {
    var t: usize = 0;
    while (t < state.track_count) : (t += 1) {
        const r = state.arr_lane_rects[t];
        if (r[3] <= 0) continue;
        if (y >= r[1] and y < r[1] + r[3]) return t;
    }
    return null;
}

/// Refresh arrangement clip chrome from the document without requiring a revision bump.
pub fn syncArrClipsChrome(state: *state_mod.State) void {
    if (!document_model.ready()) return;
    const store = &document_model.g;
    var global_i: usize = 0;
    for (store.arrangement.tracks.items, 0..) |*atrack, ti| {
        for (atrack.clips.items) |*placement| {
            if (global_i >= state_mod.max_arr_clips) break;
            const pooled = store.arrangement.placementClip(placement);
            const kind: state_mod.ClipKind = blk: {
                if (pooled) |c| {
                    break :blk switch (c.content) {
                        .midi => .midi,
                        .audio => .audio,
                    };
                }
                break :blk .midi;
            };
            const name: []const u8 = if (pooled) |c| c.name.get() else "";
            const start_beat = @as(f32, @floatFromInt(placement.start_tick)) /
                @as(f32, @floatFromInt(arr_timeline.ppq));
            const length_beats = @as(f32, @floatFromInt(placement.duration_ticks)) /
                @as(f32, @floatFromInt(arr_timeline.ppq));
            state.arr_clips[global_i] = .{
                .track = ti,
                .start_beat = start_beat,
                .length_beats = length_beats,
                .kind = kind,
                .name = name,
                .selected = placement.selected,
            };
            global_i += 1;
        }
    }
    state.arr_clip_count = global_i;
}

