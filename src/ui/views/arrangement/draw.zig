const std = @import("std");
const zgui = @import("zgui");
const colors = @import("../../theme/colors.zig");
const tokens = @import("../../theme/tokens.zig");
const widgets = @import("../../theme/widgets.zig");
const selection = @import("../../input/selection.zig");
const edit_actions = @import("../../input/edit_actions.zig");

const arr_types = @import("../../../arrangement/types.zig");
const arr_ops = @import("../../../arrangement/ops.zig");
const arr_timeline = @import("../../../arrangement/timeline.zig");
const arr_undo = @import("../../../arrangement/undo.zig");
const session_view = @import("../../../session/types.zig");
const sample_store_mod = @import("../../../audio/sample_store.zig");
const undo = @import("../../../undo/root.zig");

const draw_ruler = @import("ruler.zig");
const draw_track_lane = @import("track_lane.zig");
const draw_mixer = @import("mixer.zig");

extern fn fluxZguiGetMouseWheelY() f32;

const default_pixels_per_beat: f32 = 60.0;

pub const ArrangementScroll = struct {
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    max_scroll_x: f32 = 0,
    max_scroll_y: f32 = 0,

    pub fn applyZoom(self: *ArrangementScroll, view: *arr_types.ArrangementView, wheel: f32, mouse_x: f32, canvas_x: f32) void {
        const zoom_amount = 1.0 + wheel * 0.1;
        const new_zoom = std.math.clamp(view.zoom * zoom_amount, 0.05, 2.0);
        const world_x_before = (self.scroll_x + mouse_x - canvas_x) / view.zoom;
        view.zoom = new_zoom;
        self.scroll_x = world_x_before * view.zoom - (mouse_x - canvas_x);
        self.clampScroll(view);
    }

    pub fn clampScroll(self: *ArrangementScroll, view: *arr_types.ArrangementView) void {
        self.scroll_x = std.math.clamp(self.scroll_x, 0.0, self.max_scroll_x);
        self.scroll_y = std.math.clamp(self.scroll_y, 0.0, self.max_scroll_y);
        _ = view;
    }
};

const DragMode = enum {
    none,
    clip_drag,
    clip_resize_left,
    clip_resize_right,
    time_select,
};

const DragState = struct {
    mode: DragMode = .none,
    track: usize = 0,
    clip_index: usize = 0,
    original_start_tick: i64 = 0,
    original_duration_ticks: i64 = 0,
    original_track: usize = 0,
    original_clip_index: usize = 0,
    drag_start_mouse_x: f32 = 0,
    drag_start_tick: i64 = 0,
    ctrl_held: bool = false, // for Ctrl+drag = duplicate
    duplicated: bool = false,
};

pub var drag: DragState = .{};
pub var area_select: selection.DragSelectState = .{};
var context_tick: i64 = 0;
var context_track: ?usize = null;

const EditContext = struct {
    view: *arr_types.ArrangementView,
    history: *undo.UndoHistory,
};

fn deleteAction(ctx: *EditContext) void {
    deleteSelectedWithTrackShift(ctx.view, ctx.history);
}

fn selectAllAction(ctx: *EditContext) void {
    ctx.view.selectAllClips();
}

pub fn draw(
    view: *arr_types.ArrangementView,
    scroll: *ArrangementScroll,
    mixer: *session_view.SessionView,
    sample_store: *const sample_store_mod.SampleStore,
    track_levels: *const [@import("../../../session/constants.zig").max_tracks][2]f32,
    history: *undo.UndoHistory,
    bpm: f32,
    playhead_beat: *f32,
    _: bool,
    ui_scale: f32,
    is_focused: bool,
) void {
    view.bpm = bpm;
    const playhead_tick: i64 = @intFromFloat(playhead_beat.* * @as(f32, @floatFromInt(arr_timeline.ppq)));
    view.current_tick = playhead_tick;
    const ruler_h = tokens.s(40, ui_scale);
    const lane_h = tokens.sessionRowH(ui_scale);
    const pixels_per_beat = default_pixels_per_beat;

    const draw_list = zgui.getWindowDrawList();
    const mouse = zgui.getMousePos();

    drawToolbar(view, mixer, history, ui_scale);

    const avail = zgui.getContentRegionAvail();
    const canvas_w = avail[0];
    const mixer_w = if (canvas_w >= tokens.s(900, ui_scale)) tokens.s(560, ui_scale) else 0;
    const section_gap = if (mixer_w > 0) tokens.s(4, ui_scale) else 0;
    const timeline_w = canvas_w - mixer_w - section_gap;
    const track_area_h = avail[1];
    const track_area_visible_h = track_area_h - ruler_h;

    const total_track_h = lane_h * @as(f32, @floatFromInt(@max(1, view.tracks.items.len)));
    const ticks_per_bar = arr_timeline.ppq * @as(i64, view.beats_per_bar);
    var content_end_tick = ticks_per_bar * 16;
    for (view.tracks.items) |track| {
        for (track.clips.items) |clip| {
            content_end_tick = @max(content_end_tick, clip.endTick() + ticks_per_bar * 4);
        }
    }
    const content_w = arr_timeline.tickToPixel(content_end_tick, view.zoom, pixels_per_beat);
    scroll.max_scroll_x = @max(0.0, content_w - timeline_w);
    scroll.max_scroll_y = @max(0.0, total_track_h - track_area_visible_h);

    // ── Ruler ──
    const ruler_pos = zgui.getCursorScreenPos();
    if (zgui.beginChild("##arr_ruler", .{ .w = timeline_w, .h = ruler_h, .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
        const ruler_inner_w = zgui.getContentRegionAvail()[0];
        draw_ruler.drawRuler(scroll.scroll_x, ruler_h, ruler_inner_w, pixels_per_beat, view.zoom, bpm, view.beats_per_bar, ui_scale, playhead_tick);
    }
    zgui.endChild();
    if (mixer_w > 0) {
        zgui.setCursorScreenPos(.{ ruler_pos[0] + timeline_w + section_gap, ruler_pos[1] });
        draw_mixer.drawHeader(mixer_w, ruler_h, ui_scale);
    }
    zgui.setCursorScreenPos(.{ ruler_pos[0], ruler_pos[1] + ruler_h });

    // Ruler playhead click
    {
        const ph_x = ruler_pos[0] + arr_timeline.tickToPixel(playhead_tick, view.zoom, pixels_per_beat) - scroll.scroll_x;
        if (ph_x >= ruler_pos[0] and ph_x <= ruler_pos[0] + timeline_w) {
            const tri_h = ruler_h * 0.5;
            draw_list.addTriangleFilled(.{
                .p1 = .{ ph_x - 4, ruler_pos[1] + 2 },
                .p2 = .{ ph_x + 4, ruler_pos[1] + 2 },
                .p3 = .{ ph_x, ruler_pos[1] + 2 + tri_h },
                .col = zgui.colorConvertFloat4ToU32(.{ 0.98, 0.55, 0.15, 1.0 }),
            });
        }
    }

    // ── Lane layout computation ──
    const lanes_pos = zgui.getCursorScreenPos();
    const lane_area_y0 = lanes_pos[1];
    const lane_area_y1 = lanes_pos[1] + track_area_visible_h;

    {
        const ruler_hover = mouse[0] >= ruler_pos[0] and mouse[0] <= ruler_pos[0] + timeline_w and
            mouse[1] >= ruler_pos[1] and mouse[1] <= ruler_pos[1] + ruler_h;
        if (ruler_hover and zgui.isMouseClicked(.left) and !zgui.isAnyItemActive()) {
            const click_tick = arr_timeline.pixelToTick(mouse[0] - ruler_pos[0] + scroll.scroll_x, view.zoom, pixels_per_beat);
            const snapped = arr_timeline.snapToGrid(@max(0, click_tick), view.snap_division_ticks);
            playhead_beat.* = @as(f32, @floatFromInt(snapped)) / @as(f32, @floatFromInt(arr_timeline.ppq));
            view.current_tick = snapped;
        }
    }

    // ── Lanes child ──
    if (zgui.beginChild("##arr_lanes", .{
        .w = timeline_w,
        .h = track_area_visible_h,
        .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true },
    })) {
        const lanes_window_hovered = zgui.isWindowHovered(.{ .child_windows = true });
        const ctrl_held = selection.isModifierDown();
        const shift_held = selection.isShiftDown();

        // ── Scroll/zoom input ──
        if (lanes_window_hovered and !zgui.isAnyItemActive()) {
            const wheel = fluxZguiGetMouseWheelY();
            if (ctrl_held) {
                if (@abs(wheel) > 0.01) scroll.applyZoom(view, wheel, mouse[0], lanes_pos[0]);
            } else {
                if (shift_held) {
                    scroll.scroll_x += wheel * 30;
                } else {
                    scroll.scroll_y -= wheel * 30;
                }
                scroll.clampScroll(view);
            }

            // Middle-mouse pan
            if (zgui.isMouseDragging(.middle, 4.0)) {
                const drag_delta = zgui.getMouseDragDelta(.middle, .{});
                scroll.scroll_x -= drag_delta[0];
                scroll.scroll_y -= drag_delta[1];
                zgui.resetMouseDragDelta(.middle);
                scroll.clampScroll(view);
            }
        }

        // ── Draw track lanes + capture events ──
        var lane_event: ?draw_track_lane.LaneEvent = null;
        for (view.tracks.items, 0..) |_, ti| {
            const lane_top = lanes_pos[1] + @as(f32, @floatFromInt(ti)) * lane_h - scroll.scroll_y;
            zgui.setCursorScreenPos(.{ lanes_pos[0], lane_top });

            const evt = draw_track_lane.drawTrackLane(
                view,
                sample_store,
                ti,
                lanes_pos[0],
                lane_top,
                timeline_w,
                lane_h,
                pixels_per_beat,
                view.beats_per_bar,
                scroll.scroll_x,
                is_focused,
            );
            if (evt != null) lane_event = evt;
        }

        // ── Time selection click on empty area ──
        // Double-click on empty lane → create clip at snap position
        if (lanes_window_hovered and is_focused and lane_event == null and
            zgui.isMouseDoubleClicked(.left) and !zgui.isAnyItemActive())
        {
            const click_tick = arr_timeline.pixelToTick(mouse[0] - lanes_pos[0] + scroll.scroll_x, view.zoom, pixels_per_beat);
            const clicked_track = blk: {
                const ty = (mouse[1] - lanes_pos[1] + scroll.scroll_y) / lane_h;
                if (ty < 0) break :blk null;
                const ti: usize = @intFromFloat(@floor(ty));
                if (ti < view.tracks.items.len) break :blk ti;
                break :blk null;
            };
            if (clicked_track) |ti| {
                const snap = arr_timeline.snapToGrid(click_tick, view.snap_division_ticks);
                const default_dur = arr_timeline.ppq * 4 * 4; // 4 bars
                if (arr_ops.createClip(view, ti, .midi, snap, default_dur, "MIDI")) |clip_index| {
                    const source_track = view.tracks.items[ti].session_track_index;
                    arr_ops.setClipMidiSource(&view.tracks.items[ti].clips.items[clip_index], source_track, mixer.primary_scene);
                    arr_ops.selectClip(view, ti, clip_index, false);
                    pushCreatedClip(history, view, ti, clip_index);
                    if (source_track < mixer.track_count) {
                        mixer.primary_track = source_track;
                        mixer.mixer_target = .track;
                    }
                } else |_| {}
            }
        } else if (lanes_window_hovered and is_focused and lane_event == null and
            zgui.isMouseClicked(.left) and !zgui.isAnyItemActive() and !ctrl_held)
        {
            area_select.pending = true;
            area_select.start = mouse;
            area_select.current = mouse;
            area_select.additive = shift_held;
        }

        // ── Update area select ──
        if (area_select.pending) {
            area_select.current = mouse;
            if (zgui.isMouseDown(.left)) {
                if (area_select.checkThreshold(4.0)) {
                    if (!area_select.additive) view.clearSelection();
                }
            } else {
                area_select.reset();
            }
        }

        // ── Draw area select rectangle ──
        if (area_select.active) {
            selection.drawDragSelect(&area_select, draw_list);

            // Apply selection to clips within rect
            for (view.tracks.items, 0..) |track, ti| {
                const lane_top = lanes_pos[1] + @as(f32, @floatFromInt(ti)) * lane_h - scroll.scroll_y;
                const lane_bottom = lane_top + lane_h;
                const vs_tick = arr_timeline.pixelToTick(scroll.scroll_x, view.zoom, pixels_per_beat);

                for (track.clips.items, 0..) |clip, ci| {
                    const cx0 = lanes_pos[0] + arr_timeline.tickToPixel(clip.start_tick - vs_tick, view.zoom, pixels_per_beat);
                    const cx1 = lanes_pos[0] + arr_timeline.tickToPixel(clip.endTick() - vs_tick, view.zoom, pixels_per_beat);
                    if (area_select.intersects(.{ cx0, lane_top }, .{ cx1, lane_bottom })) {
                        view.tracks.items[ti].clips.items[ci].selected = true;
                    } else if (!area_select.additive) {
                        view.tracks.items[ti].clips.items[ci].selected = false;
                    }
                }
            }

            if (!zgui.isMouseDown(.left)) {
                area_select.reset();
            }
        }

        // ── Process lane event into drag/selection ──
        if (lane_event != null and is_focused and !area_select.active) {
            processLaneEvent(view, scroll, lane_event.?, pixels_per_beat, lanes_pos, timeline_w);
        }

        // ── Drag updates ──
        updateDrag(view, scroll, history, mouse, pixels_per_beat, lanes_pos, lane_h, ctrl_held);
    }
    zgui.endChild();
    if (mixer_w > 0) {
        zgui.setCursorScreenPos(.{ lanes_pos[0] + timeline_w + section_gap, lanes_pos[1] });
        draw_mixer.draw(view, mixer, track_levels, scroll.scroll_y, mixer_w, track_area_visible_h, lane_h, ui_scale, is_focused);
    }
    zgui.setCursorScreenPos(.{ lanes_pos[0], lanes_pos[1] + track_area_visible_h });

    // ── Playhead line through lanes ──
    {
        const ph_x = lanes_pos[0] + arr_timeline.tickToPixel(playhead_tick, view.zoom, pixels_per_beat) - scroll.scroll_x;
        if (ph_x >= lanes_pos[0] and ph_x <= lanes_pos[0] + timeline_w) {
            const ph_col = zgui.colorConvertFloat4ToU32(.{ 0.98, 0.55, 0.15, 0.85 });
            draw_list.addLine(.{
                .p1 = .{ ph_x, lane_area_y0 },
                .p2 = .{ ph_x, lane_area_y1 },
                .col = ph_col,
                .thickness = 1.5,
            });
        }
    }

    // ── Keyboard shortcuts ──
    if (is_focused and !zgui.isAnyItemActive()) {
        const mod_down = selection.isModifierDown();
        var edit_ctx = EditContext{ .view = view, .history = history };
        edit_actions.handleShortcuts(&edit_ctx, mod_down, .{
            .has_selection = view.hasSelection(),
            .can_paste = false,
        }, .{
            .delete = deleteAction,
            .select_all = selectAllAction,
        });
        if (mod_down and zgui.isKeyPressed(.d, false)) {
            duplicateSelectedClips(view, history);
        }
        if (mod_down and zgui.isKeyPressed(.t, false)) {
            addTrack(view, mixer, history);
        }
    }

    // ── Context menu ──
    {
        const in_lanes = mouse[0] >= lanes_pos[0] and mouse[0] <= lanes_pos[0] + timeline_w and
            mouse[1] >= lanes_pos[1] and mouse[1] <= lanes_pos[1] + track_area_visible_h;
        if (is_focused and in_lanes and zgui.isMouseClicked(.right) and !zgui.isAnyItemActive()) {
            context_tick = arr_timeline.pixelToTick(mouse[0] - lanes_pos[0] + scroll.scroll_x, view.zoom, pixels_per_beat);
            const track_y = (mouse[1] - lanes_pos[1] + scroll.scroll_y) / lane_h;
            context_track = if (track_y >= 0 and track_y < @as(f32, @floatFromInt(view.tracks.items.len)))
                @intFromFloat(@floor(track_y))
            else
                null;
            zgui.openPopup("arr_ctx", .{});
        }
        if (zgui.beginPopup("arr_ctx", .{})) {
            var edit_ctx = EditContext{ .view = view, .history = history };
            _ = edit_actions.drawMenu(&edit_ctx, .{
                .has_selection = view.hasSelection(),
                .can_paste = false,
            }, .{
                .delete = deleteAction,
                .select_all = selectAllAction,
            });
            if (view.hasSelection()) {
                if (zgui.menuItem("Duplicate", .{ .shortcut = "Ctrl+D" })) {
                    duplicateSelectedClips(view, history);
                }
                if (zgui.menuItem("Split at Cursor", .{})) splitSelectedAt(view, history, context_tick);
                zgui.separator();
            }
            const selected_track = context_track orelse firstSelectedTrack(view);
            if (zgui.menuItem("Move Track Up", .{ .enabled = selected_track != null and selected_track.? > 0 })) {
                reorderSelectedTrack(view, history, selected_track.?, selected_track.? - 1);
            }
            if (zgui.menuItem("Move Track Down", .{ .enabled = selected_track != null and selected_track.? + 1 < view.tracks.items.len })) {
                reorderSelectedTrack(view, history, selected_track.?, selected_track.? + 1);
            }
            zgui.separator();
            if (zgui.menuItem("Add Track", .{ .shortcut = "Ctrl+T" })) {
                addTrack(view, mixer, history);
            }
            zgui.endPopup();
        }
    }
}

// ── Interaction helpers ──

fn processLaneEvent(
    view: *arr_types.ArrangementView,
    scroll: *ArrangementScroll,
    evt: draw_track_lane.LaneEvent,
    pixels_per_beat: f32,
    lanes_pos: [2]f32,
    _: f32,
) void {
    const ctrl_held = selection.isModifierDown();
    const shift_held = selection.isShiftDown();

    switch (evt.action) {
        .clicked => {
            area_select.reset();
            arr_ops.selectClip(view, evt.track, evt.clip_index, shift_held);
        },
        .right_clicked => {
            // Ensure clicked clip is selected for context menu
            if (!view.tracks.items[evt.track].clips.items[evt.clip_index].selected) {
                arr_ops.selectClip(view, evt.track, evt.clip_index, false);
            }
            context_tick = arr_timeline.pixelToTick(zgui.getMousePos()[0] - lanes_pos[0] + scroll.scroll_x, view.zoom, pixels_per_beat);
            context_track = evt.track;
            zgui.openPopup("arr_ctx", .{});
        },
        .start_drag => {
            const clip = view.tracks.items[evt.track].clips.items[evt.clip_index];
            if (!clip.selected) {
                arr_ops.selectClip(view, evt.track, evt.clip_index, false);
            }
            drag = .{
                .mode = .clip_drag,
                .track = evt.track,
                .clip_index = evt.clip_index,
                .original_start_tick = clip.start_tick,
                .original_duration_ticks = clip.duration_ticks,
                .original_track = evt.track,
                .original_clip_index = evt.clip_index,
                .drag_start_mouse_x = zgui.getMousePos()[0],
                .drag_start_tick = clip.start_tick,
                .ctrl_held = ctrl_held,
                .duplicated = false,
            };
        },
        .start_resize_left => {
            const clip = view.tracks.items[evt.track].clips.items[evt.clip_index];
            drag = .{
                .mode = .clip_resize_left,
                .track = evt.track,
                .clip_index = evt.clip_index,
                .original_start_tick = clip.start_tick,
                .original_duration_ticks = clip.duration_ticks,
                .original_track = evt.track,
                .original_clip_index = evt.clip_index,
                .drag_start_mouse_x = zgui.getMousePos()[0],
                .drag_start_tick = clip.start_tick,
            };
            if (!clip.selected) {
                arr_ops.selectClip(view, evt.track, evt.clip_index, false);
            }
        },
        .start_resize_right => {
            const clip = view.tracks.items[evt.track].clips.items[evt.clip_index];
            drag = .{
                .mode = .clip_resize_right,
                .track = evt.track,
                .clip_index = evt.clip_index,
                .original_start_tick = clip.start_tick,
                .original_duration_ticks = clip.duration_ticks,
                .original_track = evt.track,
                .original_clip_index = evt.clip_index,
                .drag_start_mouse_x = zgui.getMousePos()[0],
                .drag_start_tick = clip.endTick(),
            };
            if (!clip.selected) {
                arr_ops.selectClip(view, evt.track, evt.clip_index, false);
            }
        },
        .double_clicked => {
            // Future: open clip editor
        },
        else => {},
    }
}

fn updateDrag(
    view: *arr_types.ArrangementView,
    scroll: *ArrangementScroll,
    history: *undo.UndoHistory,
    mouse: [2]f32,
    pixels_per_beat: f32,
    lanes_pos: [2]f32,
    lane_h: f32,
    ctrl_held: bool,
) void {
    if (drag.mode == .none) return;
    if (!zgui.isMouseDown(.left)) {
        commitDrag(view, history);
        drag = .{};
        return;
    }

    const dx = mouse[0] - drag.drag_start_mouse_x;
    const tick_delta = arr_timeline.pixelToTick(dx, view.zoom, pixels_per_beat);
    const snap = view.snap_division_ticks;

    switch (drag.mode) {
        .clip_drag => {
            if (ctrl_held and !drag.duplicated) {
                const new_idx = arr_ops.duplicateClip(view, drag.track, drag.clip_index) catch return;
                arr_ops.selectClip(view, drag.track, drag.clip_index, false);
                drag.clip_index = new_idx;
                drag.duplicated = true;
                drag.drag_start_tick = view.tracks.items[drag.track].clips.items[new_idx].start_tick;
                drag.original_start_tick = drag.drag_start_tick;
            }

            const new_start = drag.original_start_tick + tick_delta;
            const clip = &view.tracks.items[drag.track].clips.items[drag.clip_index];
            arr_ops.moveClip(clip, new_start, snap);

            const mouse_track = blk: {
                const ty = (mouse[1] - lanes_pos[1] + scroll.scroll_y) / lane_h;
                if (ty < 0) break :blk null;
                const ti: usize = @intFromFloat(@floor(ty));
                if (ti < view.tracks.items.len) break :blk ti;
                break :blk null;
            };
            if (mouse_track != null and mouse_track.? != drag.track) {
                const new_idx = arr_ops.moveClipToTrack(view, drag.track, drag.clip_index, mouse_track.?) catch return;
                drag.track = mouse_track.?;
                drag.clip_index = new_idx;
            }
        },
        .clip_resize_left => {
            const new_start = drag.original_start_tick + tick_delta;
            arr_ops.resizeClipLeft(
                &view.tracks.items[drag.track].clips.items[drag.clip_index],
                new_start,
                snap,
            );
        },
        .clip_resize_right => {
            const new_dur = drag.original_duration_ticks + tick_delta;
            arr_ops.resizeClip(
                &view.tracks.items[drag.track].clips.items[drag.clip_index],
                new_dur,
                snap,
            );
        },
        else => {},
    }
}

fn deleteSelectedWithTrackShift(view: *arr_types.ArrangementView, history: *undo.UndoHistory) void {
    var changes = std.ArrayList(undo.ArrangementClipChange).empty;
    defer changes.deinit(history.allocator);
    for (view.tracks.items, 0..) |track, ti| {
        for (track.clips.items, 0..) |clip, ci| {
            if (!clip.selected) continue;
            const before = arr_undo.captureClip(history.allocator, ti, ci, &clip) catch {
                for (changes.items) |change| if (change.before) |item| arr_undo.deinitCaptured(history.allocator, item);
                return;
            };
            changes.append(history.allocator, .{ .before = before }) catch {
                arr_undo.deinitCaptured(history.allocator, before);
                for (changes.items) |change| if (change.before) |item| arr_undo.deinitCaptured(history.allocator, item);
                return;
            };
        }
    }
    if (changes.items.len == 0) return;
    // Delete selected clips from all tracks, working backwards to avoid index shifts
    var ti: usize = view.tracks.items.len;
    while (ti > 0) {
        ti -= 1;
        var ci: usize = view.tracks.items[ti].clips.items.len;
        while (ci > 0) {
            ci -= 1;
            if (view.tracks.items[ti].clips.items[ci].selected) {
                arr_ops.deleteClip(view, ti, ci);
            }
        }
    }
    history.push(.{ .arrangement_edit = .{ .changes = changes.toOwnedSlice(history.allocator) catch return } });
}

fn duplicateSelectedClips(view: *arr_types.ArrangementView, history: *undo.UndoHistory) void {
    var changes = std.ArrayList(undo.ArrangementClipChange).empty;
    defer changes.deinit(history.allocator);
    for (0..view.tracks.items.len) |ti| {
        var ci: usize = view.tracks.items[ti].clips.items.len;
        while (ci > 0) {
            ci -= 1;
            if (view.tracks.items[ti].clips.items[ci].selected) {
                const new_idx = arr_ops.duplicateClip(view, ti, ci) catch continue;
                view.tracks.items[ti].clips.items[ci].selected = false;
                view.tracks.items[ti].clips.items[new_idx].selected = true;
                const after = arr_undo.captureClip(history.allocator, ti, new_idx, &view.tracks.items[ti].clips.items[new_idx]) catch {
                    arr_ops.deleteClip(view, ti, new_idx);
                    continue;
                };
                changes.append(history.allocator, .{ .after = after }) catch {
                    arr_undo.deinitCaptured(history.allocator, after);
                    arr_ops.deleteClip(view, ti, new_idx);
                };
            }
        }
    }
    if (changes.items.len > 0) {
        history.push(.{ .arrangement_edit = .{ .changes = changes.toOwnedSlice(history.allocator) catch return } });
    }
}

fn commitDrag(view: *arr_types.ArrangementView, history: *undo.UndoHistory) void {
    if (drag.track >= view.tracks.items.len or drag.clip_index >= view.tracks.items[drag.track].clips.items.len) return;
    const clip = &view.tracks.items[drag.track].clips.items[drag.clip_index];
    const changed = drag.duplicated or drag.track != drag.original_track or
        clip.start_tick != drag.original_start_tick or clip.duration_ticks != drag.original_duration_ticks;
    if (!changed) return;

    const after = arr_undo.captureClip(history.allocator, drag.track, drag.clip_index, clip) catch return;
    var change: undo.ArrangementClipChange = .{ .after = after };
    if (!drag.duplicated) {
        var before = arr_undo.captureClip(history.allocator, drag.original_track, drag.original_clip_index, clip) catch {
            arr_undo.deinitCaptured(history.allocator, after);
            return;
        };
        before.clip.start_tick = drag.original_start_tick;
        before.clip.duration_ticks = drag.original_duration_ticks;
        before.clip.midi_length_beats = @as(f32, @floatFromInt(drag.original_duration_ticks)) / @as(f32, @floatFromInt(arr_timeline.ppq));
        change.before = before;
    }

    const changes = history.allocator.alloc(undo.ArrangementClipChange, 1) catch {
        if (change.before) |before| arr_undo.deinitCaptured(history.allocator, before);
        arr_undo.deinitCaptured(history.allocator, after);
        return;
    };
    changes[0] = change;
    history.push(.{ .arrangement_edit = .{ .changes = changes } });
}

fn pushCreatedClip(history: *undo.UndoHistory, view: *arr_types.ArrangementView, track: usize, clip_index: usize) void {
    const after = arr_undo.captureClip(history.allocator, track, clip_index, &view.tracks.items[track].clips.items[clip_index]) catch return;
    const changes = history.allocator.alloc(undo.ArrangementClipChange, 1) catch {
        arr_undo.deinitCaptured(history.allocator, after);
        return;
    };
    changes[0] = .{ .after = after };
    history.push(.{ .arrangement_edit = .{ .changes = changes } });
}

fn firstSelectedTrack(view: *const arr_types.ArrangementView) ?usize {
    for (view.tracks.items, 0..) |track, ti| {
        for (track.clips.items) |clip| if (clip.selected) return ti;
    }
    return null;
}

fn reorderSelectedTrack(view: *arr_types.ArrangementView, history: *undo.UndoHistory, from: usize, to: usize) void {
    arr_ops.reorderTrack(view, from, to);
    history.push(.{ .arrangement_track_reorder = .{ .from = from, .to = to } });
}

fn splitSelectedAt(view: *arr_types.ArrangementView, history: *undo.UndoHistory, tick: i64) void {
    for (view.tracks.items, 0..) |track, ti| {
        for (track.clips.items, 0..) |clip, ci| {
            if (!clip.selected or tick <= clip.start_tick or tick >= clip.endTick()) continue;
            const before = arr_undo.captureClip(history.allocator, ti, ci, &clip) catch return;
            const new_idx = (arr_ops.splitClip(view, ti, ci, tick, view.snap_division_ticks) catch {
                arr_undo.deinitCaptured(history.allocator, before);
                return;
            }) orelse {
                arr_undo.deinitCaptured(history.allocator, before);
                return;
            };
            const after_left = arr_undo.captureClip(history.allocator, ti, ci, &view.tracks.items[ti].clips.items[ci]) catch {
                rollbackSplit(view, ti, ci, new_idx, before.clip.duration_ticks);
                arr_undo.deinitCaptured(history.allocator, before);
                return;
            };
            const after_right = arr_undo.captureClip(history.allocator, ti, new_idx, &view.tracks.items[ti].clips.items[new_idx]) catch {
                rollbackSplit(view, ti, ci, new_idx, before.clip.duration_ticks);
                arr_undo.deinitCaptured(history.allocator, after_left);
                arr_undo.deinitCaptured(history.allocator, before);
                return;
            };
            const changes = history.allocator.alloc(undo.ArrangementClipChange, 2) catch {
                rollbackSplit(view, ti, ci, new_idx, before.clip.duration_ticks);
                arr_undo.deinitCaptured(history.allocator, after_right);
                arr_undo.deinitCaptured(history.allocator, after_left);
                arr_undo.deinitCaptured(history.allocator, before);
                return;
            };
            changes[0] = .{ .before = before, .after = after_left };
            changes[1] = .{ .after = after_right };
            history.push(.{ .arrangement_edit = .{ .changes = changes } });
            return;
        }
    }
}

fn rollbackSplit(view: *arr_types.ArrangementView, track: usize, left: usize, right: usize, duration_ticks: i64) void {
    arr_ops.deleteClip(view, track, right);
    const clip = &view.tracks.items[track].clips.items[left];
    clip.duration_ticks = duration_ticks;
    if (clip.midi) |*midi| midi.length_beats = @as(f32, @floatFromInt(duration_ticks)) / @as(f32, @floatFromInt(arr_timeline.ppq));
}

fn addTrack(view: *arr_types.ArrangementView, mixer: *session_view.SessionView, history: *undo.UndoHistory) void {
    const session_track_index = firstUnmappedSessionTrack(view, mixer.track_count) orelse return;
    const index = view.tracks.items.len;
    const color = colors.Colors.trackColor(index);
    arr_ops.createTrack(view, session_track_index, "Track", color) catch return;
    history.push(.{ .arrangement_track_add = .{
        .index = index,
        .session_track_index = session_track_index,
        .name = view.tracks.items[index].name,
        .color = color,
    } });
}

fn firstUnmappedSessionTrack(view: *const arr_types.ArrangementView, session_track_count: usize) ?usize {
    var mapped: [@import("../../../session/constants.zig").max_tracks]bool = @splat(false);
    for (view.tracks.items) |track| {
        if (track.session_track_index < mapped.len) mapped[track.session_track_index] = true;
    }
    for (mapped[0..session_track_count], 0..) |used, index| if (!used) return index;
    return null;
}

// ── Toolbar ──

fn drawToolbar(view: *arr_types.ArrangementView, mixer: *session_view.SessionView, history: *undo.UndoHistory, ui_scale: f32) void {
    const control_h = zgui.getFrameHeight();
    const gap = tokens.gapTight(ui_scale);
    const row_y = zgui.getCursorPosY() + (tokens.controlH(.md, ui_scale) + 8 - control_h) * 0.5;

    zgui.alignTextToFramePadding();
    zgui.setCursorPosY(row_y);

    if (widgets.iconButton("##arr_add_track", .plus, ui_scale, "Add Track")) {
        addTrack(view, mixer, history);
    }
    zgui.sameLine(.{ .spacing = gap });
    zgui.setCursorPosY(row_y);
    zgui.alignTextToFramePadding();
    dimLabel("+Track", ui_scale);

    zgui.sameLine(.{ .spacing = tokens.gapGroup(ui_scale) });
    zgui.setCursorPosY(row_y);
    widgets.toolbarSeparator(ui_scale, control_h);

    zgui.sameLine(.{ .spacing = 0 });
    zgui.setCursorPosY(row_y);
    zgui.alignTextToFramePadding();
    dimLabel("Zoom:", ui_scale);
    zgui.sameLine(.{ .spacing = gap });
    zgui.setCursorPosY(row_y);
    var zoom_display: f32 = view.zoom * 100;
    zgui.setNextItemWidth(tokens.s(50, ui_scale));
    if (zgui.sliderFloat("##arr_zoom", .{ .v = &zoom_display, .min = 5, .max = 200, .cfmt = "%.0f%%" })) {
        view.zoom = zoom_display / 100.0;
    }

    zgui.sameLine(.{ .spacing = tokens.gapGroup(ui_scale) });
    zgui.setCursorPosY(row_y);
    widgets.toolbarSeparator(ui_scale, control_h);

    zgui.sameLine(.{ .spacing = 0 });
    zgui.setCursorPosY(row_y);
    widgets.statusPill("Arrangement", ui_scale);

    zgui.spacing();
}

fn dimLabel(text: []const u8, ui_scale: f32) void {
    _ = ui_scale;
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
    zgui.textUnformatted(text);
    zgui.popStyleColor(.{ .count = 1 });
}
