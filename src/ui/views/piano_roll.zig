//! DVUI dense-canvas piano-roll.
//!
//! Notes are direct draw calls inside one widget, not one widget per note.
//! Only notes intersecting the viewport are submitted. Mouse wheel scrolls
//! pitches; Ctrl/Cmd+wheel zooms time; pointer drag moves a selected note.
//! Audition (keyboard strip + drag pitch), MIDI undo/redo, context menus,
//! and clip automation lanes (overlay + edit mode) live here.
//!
//! Layout helpers: `piano_roll_layout.zig`
//! Edit ops: `piano_roll_edit.zig`
//! Gestures: `piano_roll_gestures.zig`
//! Automation: `piano_roll_automation.zig`

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../theme.zig");
const state_mod = @import("../state.zig");
const edit_actions = @import("../edit_actions.zig");
const document_model = @import("../../document/model.zig");
const document_commands = @import("../../document/commands.zig");
const notes_mod = @import("../../session/notes.zig");
const plugin_host = @import("../plugin_host.zig");
const layout = @import("piano_roll_layout.zig");
const edit = @import("piano_roll_edit.zig");
const gestures = @import("piano_roll_gestures.zig");
const automation = @import("piano_roll_automation.zig");

pub fn draw(state: *state_mod.State) void {
    const clip = layout.selectedClip(state) orelse {
        dvui.label(@src(), "Selected MIDI clip is unavailable.", .{}, .{ .color_text = theme.text_soft });
        return;
    };
    layout.syncSelectionClip(state, clip.notes.items.len);
    // Preview is recomputed from active gestures each frame (before draw so
    // keys highlight on the same frame as the gesture).
    state.piano_preview_pitch = null;
    state.piano_hover_pitch = null;
    edit.updateAudition(state, clip);

    drawScrollZoomBar(state, clip);

    {
        var tools = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer tools.deinit();
        if (dvui.button(@src(), "+", .{}, .{})) edit.addNote(state);
        if (dvui.button(@src(), "Del", .{}, .{})) edit.deleteSelection(state, clip);
        if (dvui.button(@src(), "Copy", .{}, .{})) edit.copySelection(state, clip);
        if (dvui.button(@src(), "Paste", .{}, .{})) edit.pasteClipboard(state, clip);
        if (dvui.button(@src(), "Dup", .{}, .{})) edit.transform(state, clip, .duplicate);
        if (dvui.button(@src(), "Undo", .{}, .{})) {
            if (document_model.ready()) _ = document_commands.undo(&document_model.g);
        }
        if (dvui.button(@src(), "Redo", .{}, .{})) {
            if (document_model.ready()) _ = document_commands.redo(&document_model.g);
        }
        if (dvui.button(@src(), if (state.piano_velocity_open) "Notes" else "Vel", .{}, .{})) state.piano_velocity_open = !state.piano_velocity_open;
        if (dvui.button(@src(), if (state.piano_tools_open) "Less" else "Tools", .{}, .{})) state.piano_tools_open = !state.piano_tools_open;
    }
    if (state.piano_tools_open) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        if (dvui.button(@src(), "All", .{}, .{})) layout.selectAll(state, clip.notes.items.len);
        if (dvui.button(@src(), "Quantize", .{}, .{})) edit.transform(state, clip, .quantize);
        if (dvui.button(@src(), "Duplicate", .{}, .{})) edit.transform(state, clip, .duplicate);
        if (dvui.button(@src(), "Time -", .{}, .{})) state.piano_pixels_per_beat = @max(20, state.piano_pixels_per_beat / 1.25);
        if (dvui.button(@src(), "Time +", .{}, .{})) state.piano_pixels_per_beat = @min(220, state.piano_pixels_per_beat * 1.25);
    }
    if (state.piano_tools_open) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        if (dvui.button(@src(), "Legato", .{}, .{})) edit.transform(state, clip, .legato);
        if (dvui.button(@src(), "Overlap", .{}, .{})) edit.transform(state, clip, .resolve_overlaps);
        if (dvui.button(@src(), "Humanize", .{}, .{})) edit.transform(state, clip, .humanize);
    }
    if (state.piano_tools_open) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        if (dvui.button(@src(), "Invert", .{}, .{})) edit.transform(state, clip, .invert);
        if (dvui.button(@src(), "Reverse", .{}, .{})) edit.transform(state, clip, .reverse);
        if (dvui.button(@src(), "Half", .{}, .{})) edit.transform(state, clip, .half_time);
        if (dvui.button(@src(), "Double", .{}, .{})) edit.transform(state, clip, .double_time);
    }

    automation.drawAutomationHeader(state, clip);
    automation.drawAutomationAddDialog(state, clip);
    const automation_mode = state.piano_automation_edit and state.piano_automation_lane_index != null;

    var canvas = dvui.box(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.cell,
        .border = dvui.Rect.all(1),
        .color_border = theme.grid,
        .min_size_content = .{ .h = 100 },
    });
    defer canvas.deinit();

    const rs = canvas.data().contentRectScale();
    const ruler_area = layout.rulerArea(rs.r, rs.s);
    const grid_area = layout.gridArea(state, rs.r, rs.s);
    const velocity_area = layout.velocityArea(state, rs.r, rs.s);
    layout.clampHorizontalScroll(state, clip, grid_area.w, rs.s);
    drawRuler(state, clip, ruler_area, grid_area, rs.s);
    drawGrid(state, grid_area, rs.s);
    drawClipBoundary(state, clip, grid_area, rs.s);
    drawRegionMarkers(state, clip, grid_area, rs.s);
    drawPlayhead(state, grid_area, rs.s);
    const visible = drawNotes(state, clip, grid_area, rs.s);
    drawBoxSelection(state);
    if (state.piano_velocity_open) drawVelocityLane(state, clip, velocity_area, rs.s);
    if (state.piano_automation_lane_index) |lane_index| {
        automation.drawAutomationOverlay(state, clip, lane_index, grid_area, rs.s);
    }
    gestures.handleEvents(state, clip, canvas.data(), grid_area, velocity_area, rs.s, automation_mode);
    // Events may have started/changed a gesture; refresh audition for live keys.
    edit.updateAudition(state, clip);
    if (!automation_mode) drawContextMenu(state, clip, grid_area);

    _ = visible;
}

fn drawContextMenu(state: *state_mod.State, clip: *notes_mod.PianoRollClip, rect: dvui.Rect.Physical) void {
    const context = dvui.context(@src(), .{ .rect = rect }, .{});
    defer context.deinit();
    const point = context.activePoint() orelse return;
    state.focused_pane = .bottom;

    const has_selection = layout.selectionCount(state, clip.notes.items.len) > 0;
    const can_undo = document_model.ready() and document_commands.canUndo(&document_model.g);
    const can_redo = document_model.ready() and document_commands.canRedo(&document_model.g);
    var menu = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(point) }, .{});
    defer menu.deinit();
    const action = edit_actions.drawMenu(.{
        .copy = has_selection,
        .cut = has_selection,
        .paste = state.piano_clipboard_len > 0,
        .duplicate = has_selection,
        .delete = has_selection,
        .select_all = true,
        .undo = can_undo,
        .redo = can_redo,
        .quantize = has_selection,
    }) orelse return;
    switch (action) {
        .copy => edit.copySelection(state, clip),
        .cut => {
            edit.copySelection(state, clip);
            edit.deleteSelection(state, clip);
        },
        .paste => edit.pasteClipboard(state, clip),
        .duplicate => edit.transform(state, clip, .duplicate),
        .delete => edit.deleteSelection(state, clip),
        .select_all => layout.selectAll(state, clip.notes.items.len),
        .undo => {
            if (document_model.ready()) _ = document_commands.undo(&document_model.g);
        },
        .redo => {
            if (document_model.ready()) _ = document_commands.redo(&document_model.g);
        },
        .quantize => edit.transform(state, clip, .quantize),
        else => return,
    }
    menu.close();
}


pub fn handleKey(state: *state_mod.State, key: dvui.Event.Key) bool {
    if (key.action != .down and key.action != .repeat) return false;
    const clip = layout.selectedClip(state) orelse return false;
    const automation_mode = state.piano_automation_edit and state.piano_automation_lane_index != null;
    if (automation_mode) {
        if (edit_actions.fromKey(key)) |action| switch (action) {
            .delete => {
                automation.deleteSelectedAutomationPoint(state, clip);
                return true;
            },
            else => {},
        } else switch (key.code) {
            .escape => {
                state.piano_automation_selected_point = null;
                state.piano_automation_edit = false;
                return true;
            },
            .delete, .backspace => {
                automation.deleteSelectedAutomationPoint(state, clip);
                return true;
            },
            else => {},
        }
        // Note tools stay disabled while editing automation.
        if (edit_actions.fromKey(key) != null) return false;
    }
    if (edit_actions.fromKey(key)) |action| switch (action) {
        .select_all => layout.selectAll(state, clip.notes.items.len),
        .copy => edit.copySelection(state, clip),
        .cut => {
            edit.copySelection(state, clip);
            edit.deleteSelection(state, clip);
        },
        .paste => edit.pasteClipboard(state, clip),
        .duplicate => edit.transform(state, clip, .duplicate),
        .delete => edit.deleteSelection(state, clip),
        .undo => {
            if (!document_model.ready() or !document_commands.undo(&document_model.g)) return false;
        },
        .redo => {
            if (!document_model.ready() or !document_commands.redo(&document_model.g)) return false;
        },
        .quantize => edit.transform(state, clip, .quantize),
        else => return false,
    } else switch (key.code) {
        .q => edit.transform(state, clip, .quantize),
        .left => edit.nudgeSelection(state, clip, -layout.quantizeStep(state), 0),
        .right => edit.nudgeSelection(state, clip, layout.quantizeStep(state), 0),
        .up => edit.nudgeSelection(state, clip, 0, if (key.mod.shift()) 12 else 1),
        .down => edit.nudgeSelection(state, clip, 0, if (key.mod.shift()) -12 else -1),
        .escape => {
            state.piano_note_selected = @splat(false);
            state.piano_selected_note = null;
        },
        else => return false,
    }
    return true;
}

fn scrollZoomTrackRect(area: dvui.Rect.Physical, scale: f32) dvui.Rect.Physical {
    const pad = 3 * scale;
    const x = area.x + layout.keyboard_w * scale;
    const available = @max(1, area.x + area.w - x - pad);
    return .{
        .x = x,
        .y = area.y + pad,
        .w = @min(200 * scale, available),
        .h = @max(4 * scale, area.h - pad * 2),
    };
}

/// The zgui editor kept this compact scroll/zoom control in the header. Keep it
/// outside the ruler so it cannot cover bar ticks or steal ruler interaction.
fn drawScrollZoomBar(state: *state_mod.State, clip: *const notes_mod.PianoRollClip) void {
    var widget = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.header,
        .min_size_content = .{ .h = 18 },
    });
    defer widget.deinit();

    const rs = widget.data().contentRectScale();
    const track = scrollZoomTrackRect(rs.r, rs.s);
    layout.clampHorizontalScroll(state, clip, rs.r.w, rs.s);

    track.fill(.all(3 * rs.s), .{ .color = theme.cell });
    const metrics = layout.horizontalMetrics(state, clip, rs.r.w, rs.s);
    const thumb_ratio = std.math.clamp(metrics.visible_beats / metrics.max_beats, 0.08, 1);
    const thumb_w = track.w * thumb_ratio;
    const scroll_ratio = if (metrics.max_scroll > 0) state.piano_scroll_beat / metrics.max_scroll else 0;
    const thumb: dvui.Rect.Physical = .{
        .x = track.x + scroll_ratio * (track.w - thumb_w),
        .y = track.y + 2 * rs.s,
        .w = thumb_w,
        .h = @max(2 * rs.s, track.h - 4 * rs.s),
    };
    thumb.fill(.all(2 * rs.s), .{ .color = theme.accent });

    for (dvui.events()) |*event| {
        if (!dvui.eventMatchSimple(event, widget.data())) continue;
        if (event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        switch (mouse.action) {
            .press => if (mouse.button.pointer() and layout.containsPoint(track, mouse.p)) {
                event.handle(@src(), widget.data());
                state.piano_nav_drag = true;
                state.piano_nav_mouse_x = mouse.p.x;
                state.piano_nav_mouse_y = mouse.p.y;
                state.piano_nav_start_beat = state.piano_scroll_beat;
                state.piano_nav_start_zoom = state.piano_pixels_per_beat;
                dvui.captureMouse(widget.data(), event.num);
            },
            .motion => if (state.piano_nav_drag and dvui.captured(widget.data().id)) {
                event.handle(@src(), widget.data());
                const dx = mouse.p.x - state.piano_nav_mouse_x;
                const dy = mouse.p.y - state.piano_nav_mouse_y;
                state.piano_pixels_per_beat = std.math.clamp(state.piano_nav_start_zoom * @exp(-dy / (70 * rs.s)), 20, 220);
                state.piano_scroll_beat = state.piano_nav_start_beat + dx * 2 / (state.piano_nav_start_zoom * rs.s);
                layout.clampHorizontalScroll(state, clip, rs.r.w, rs.s);
                dvui.refresh(null, @src(), widget.data().id);
            },
            .release => if (state.piano_nav_drag and dvui.captured(widget.data().id)) {
                event.handle(@src(), widget.data());
                state.piano_nav_drag = false;
                dvui.captureMouse(null, event.num);
            },
            else => {},
        }
    }
}

fn drawGrid(state: *const state_mod.State, area: dvui.Rect.Physical, scale: f32) void {
    const row_h = state.piano_row_height * scale;
    const beat_w = state.piano_pixels_per_beat * scale;
    const key_w = layout.keyboard_w * scale;
    const rows: usize = @as(usize, @intFromFloat(@ceil(area.h / row_h))) + 1;
    const bottom_pitch = layout.bottomVisiblePitch(state, area, scale);
    const first_pitch: i32 = @intFromFloat(@floor(bottom_pitch));
    const live = liveKeysForTrack(state.selected_track);
    const font = dvui.Font.theme(.body).withSize(@max(8, @min(11, row_h / scale - 2)));
    for (0..rows) |row| {
        const pitch = first_pitch + @as(i32, @intCast(row));
        if (pitch < 0 or pitch > 127) continue;
        const pitch_u: u8 = @intCast(pitch);
        const y = area.y + area.h - (@as(f32, @floatFromInt(pitch)) - bottom_pitch + 1) * row_h;
        const black = layout.isBlackKey(pitch_u);
        const lane: dvui.Rect.Physical = .{ .x = area.x + key_w, .y = y, .w = area.w - key_w, .h = row_h };
        lane.fill(.all(0), .{ .color = if (black) theme.panel else theme.cell });

        const key: dvui.Rect.Physical = .{ .x = area.x, .y = y, .w = key_w - scale, .h = @max(1, row_h - scale) };
        const key_base = if (black) theme.colorF(0.12, 0.12, 0.13) else theme.colorF(0.82, 0.82, 0.84);
        key.fill(.all(0), .{ .color = key_base });
        const active = live[pitch_u] or (state.piano_preview_pitch != null and state.piano_preview_pitch.? == pitch_u) or (state.piano_key_held != null and state.piano_key_held.? == pitch_u);
        if (active) {
            key.fill(.all(0), .{ .color = theme.colorFA(0.45, 0.70, 0.86, if (black) 0.55 else 0.4) });
            const border: dvui.Rect.Physical = .{ .x = key.x, .y = key.y, .w = key.w, .h = @max(1, scale) };
            border.fill(.all(0), .{ .color = theme.accent_dim });
        }
        const show_label = (pitch_u % 12 == 0) or (state.piano_hover_pitch != null and state.piano_hover_pitch.? == pitch_u);
        if (show_label and row_h >= 8 * scale) {
            var buf: [8]u8 = undefined;
            const label = notes_mod.pitchToName(&buf, pitch_u);
            const text_color = if (black or active) theme.text else theme.colorF(0.25, 0.25, 0.28);
            dvui.renderText(.{
                .font = font,
                .text = label,
                .rs = .{ .r = .{ .x = key.x + 4 * scale, .y = key.y + @max(0, (key.h - font.size * scale) * 0.5), .w = key.w, .h = key.h }, .s = scale },
                .color = text_color,
            }) catch {};
        }

        const line: dvui.Rect.Physical = .{ .x = area.x, .y = y, .w = area.w, .h = @max(1, scale) };
        line.fill(.all(0), .{ .color = theme.grid });
    }

    const first_beat: i32 = @intFromFloat(@floor(state.piano_scroll_beat));
    const beats: usize = @as(usize, @intFromFloat(@ceil((area.w - key_w) / beat_w))) + 2;
    for (0..beats) |i| {
        const beat = first_beat + @as(i32, @intCast(i));
        const x = area.x + key_w + (@as(f32, @floatFromInt(beat)) - state.piano_scroll_beat) * beat_w;
        if (x < area.x + key_w or x > area.x + area.w) continue;
        const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(1, scale), .h = area.h };
        line.fill(.all(0), .{ .color = if (@mod(beat, 4) == 0) theme.text_soft else theme.grid });
    }
}

const empty_live_keys: [128]bool = @splat(false);

fn liveKeysForTrack(track: usize) *const [128]bool {
    if (!plugin_host.ready() or track >= plugin_host.track_count) return &empty_live_keys;
    return &plugin_host.g.live_key_states[track];
}

fn drawRuler(state: *const state_mod.State, _: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, grid: dvui.Rect.Physical, scale: f32) void {
    area.fill(.all(0), .{ .color = theme.header });
    const beat_w = state.piano_pixels_per_beat * scale;
    const first = @floor(state.piano_scroll_beat);
    const count: usize = @as(usize, @intFromFloat(@ceil(grid.w / beat_w))) + 2;
    for (0..count) |i| {
        const beat = first + @as(f32, @floatFromInt(i));
        const x = layout.beatX(state, beat, grid, scale);
        if (x < area.x + layout.keyboard_w * scale or x > area.x + area.w) continue;
        const is_bar = @mod(@as(i32, @intFromFloat(beat)), @as(i32, @intFromFloat(state.beatsPerBar()))) == 0;
        const tick_h = if (is_bar) area.h * 0.65 else area.h * 0.32;
        const tick: dvui.Rect.Physical = .{ .x = x, .y = area.y + area.h - tick_h, .w = @max(1, scale), .h = tick_h };
        tick.fill(.all(0), .{ .color = if (is_bar) theme.text_dim else theme.text_soft });
    }
}

fn drawNotes(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, scale: f32) usize {
    var visible: usize = 0;
    // Cheap pitch/time pre-cull before noteRect for dense clips (4k+ notes).
    const bottom_pitch = layout.bottomVisiblePitch(state, area, scale);
    const row_h = state.piano_row_height * scale;
    const top_pitch = bottom_pitch + area.h / @max(row_h, 1);
    const beat_lo = state.piano_scroll_beat - 1;
    const key_w = layout.keyboard_w * scale;
    const beat_w = state.piano_pixels_per_beat * scale;
    const beat_hi = state.piano_scroll_beat + (area.w - key_w) / @max(beat_w, 1) + 1;

    for (clip.notes.items, 0..) |note, index| {
        if (note.pitch < bottom_pitch - 1 or @as(f32, @floatFromInt(note.pitch)) > top_pitch + 1) continue;
        if (note.start + note.duration < beat_lo or note.start > beat_hi) continue;
        const rect = layout.noteRect(state, note, area, scale);
        if (!layout.intersects(rect, area)) continue;
        visible += 1;
        const selected = index < state_mod.max_piano_notes and state.piano_note_selected[index];
        const color = if (selected) theme.selected else theme.lighten(theme.clip_stopped, (0.5 - note.velocity) * 0.28);
        rect.fill(.all(2 * scale), .{ .color = color });
        const handle_w = @min(rect.w * 0.35, 7 * scale);
        const handle: dvui.Rect.Physical = .{ .x = rect.x + rect.w - handle_w, .y = rect.y, .w = handle_w, .h = rect.h };
        handle.fill(.all(1 * scale), .{ .color = if (selected) theme.text_on_fill else theme.accent_dim });
    }
    return visible;
}

fn drawVelocityLane(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, scale: f32) void {
    area.fill(.all(0), .{ .color = theme.header });
    const key_w = layout.keyboard_w * scale;
    const beat_w = state.piano_pixels_per_beat * scale;
    const baseline: dvui.Rect.Physical = .{ .x = area.x, .y = area.y, .w = area.w, .h = @max(1, scale) };
    baseline.fill(.all(0), .{ .color = theme.grid });
    for (clip.notes.items, 0..) |note, index| {
        const x = area.x + key_w + (note.start - state.piano_scroll_beat) * beat_w;
        if (x < area.x + key_w or x > area.x + area.w) continue;
        const h = std.math.clamp(note.velocity, 0, 1) * (area.h - 4 * scale);
        const bar: dvui.Rect.Physical = .{ .x = x, .y = area.y + area.h - h, .w = @max(2 * scale, 3 * scale), .h = h };
        const selected = index < state_mod.max_piano_notes and state.piano_note_selected[index];
        bar.fill(.all(1 * scale), .{ .color = if (selected) theme.selected else theme.clip_stopped });
    }
}

fn drawBoxSelection(state: *const state_mod.State) void {
    if (!state.piano_box_select) return;
    const x = @min(state.piano_box_start_x, state.piano_box_current_x);
    const y = @min(state.piano_box_start_y, state.piano_box_current_y);
    const rect: dvui.Rect.Physical = .{
        .x = x,
        .y = y,
        .w = @abs(state.piano_box_current_x - state.piano_box_start_x),
        .h = @abs(state.piano_box_current_y - state.piano_box_start_y),
    };
    rect.fill(.all(1), .{ .color = theme.colorFA(0.45, 0.70, 0.86, 0.25) });
}

fn drawClipBoundary(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, scale: f32) void {
    const x = area.x + layout.keyboard_w * scale + (clip.length_beats - state.piano_scroll_beat) * state.piano_pixels_per_beat * scale;
    if (x < area.x + layout.keyboard_w * scale or x > area.x + area.w) return;
    const color = if (state.piano_clip_resize) theme.accent else theme.accent_dim;
    const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(2, 3 * scale), .h = area.h };
    line.fill(.all(0), .{ .color = color });
    drawDownFlag(x, area.y, 6 * scale, 10 * scale, color);
}

fn drawDownFlag(x: f32, y: f32, half_w: f32, height: f32, color: dvui.Color) void {
    const flag: dvui.Path = .{ .points = &.{
        .{ .x = x - half_w, .y = y },
        .{ .x = x, .y = y + height },
        .{ .x = x + half_w, .y = y },
    } };
    flag.fillConvex(.{ .color = color });
}

fn drawRegionMarkers(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, scale: f32) void {
    const loop_end = clip.loopEnd();
    const has_sub_loop = clip.loop_start_beats > 0.001 or loop_end < clip.length_beats - 0.001;
    const grid_start = area.x + layout.keyboard_w * scale;
    const clip_end_x = layout.beatX(state, clip.length_beats, area, scale);
    if (clip_end_x < area.x + area.w) {
        const left = @max(grid_start, clip_end_x);
        if (left < area.x + area.w) {
            const dim: dvui.Rect.Physical = .{ .x = left, .y = area.y, .w = area.x + area.w - left, .h = area.h };
            dim.fill(.all(0), .{ .color = theme.colorFA(0.02, 0.02, 0.025, 0.62) });
        }
    }
    if (has_sub_loop and clip.loop_start_beats > 0.001) {
        const right = @min(area.x + area.w, layout.beatX(state, clip.loop_start_beats, area, scale));
        const left = @max(grid_start, layout.beatX(state, 0, area, scale));
        if (right > left) {
            const dim: dvui.Rect.Physical = .{ .x = left, .y = area.y, .w = right - left, .h = area.h };
            dim.fill(.all(0), .{ .color = theme.colorFA(0.02, 0.02, 0.025, 0.38) });
        }
    }
    if (has_sub_loop and loop_end < clip.length_beats - 0.001) {
        const left = @max(grid_start, layout.beatX(state, loop_end, area, scale));
        const right = @min(area.x + area.w, clip_end_x);
        if (right > left) {
            const dim: dvui.Rect.Physical = .{ .x = left, .y = area.y, .w = right - left, .h = area.h };
            dim.fill(.all(0), .{ .color = theme.colorFA(0.02, 0.02, 0.025, 0.38) });
        }
    }
    const brace_w = 6 * scale;
    if (has_sub_loop and clip.loop_start_beats > 0.001) {
        const x = layout.beatX(state, clip.loop_start_beats, area, scale);
        if (x >= grid_start and x <= area.x + area.w) {
            const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(1, 1.5 * scale), .h = area.h };
            line.fill(.all(0), .{ .color = theme.solo_on });
            const tick: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = brace_w, .h = @max(1, 1.5 * scale) };
            tick.fill(.all(0), .{ .color = theme.solo_on });
        }
    }
    if (has_sub_loop and loop_end > 0.001 and loop_end < clip.length_beats - 0.001) {
        const x = layout.beatX(state, loop_end, area, scale);
        if (x >= grid_start and x <= area.x + area.w) {
            const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(1, 1.5 * scale), .h = area.h };
            line.fill(.all(0), .{ .color = theme.solo_on });
            const tick: dvui.Rect.Physical = .{ .x = x - brace_w, .y = area.y, .w = brace_w, .h = @max(1, 1.5 * scale) };
            tick.fill(.all(0), .{ .color = theme.solo_on });
        }
    }
    if (clip.play_start_beats > 0.001 and clip.play_start_beats < clip.length_beats - 0.001) {
        const x = layout.beatX(state, clip.play_start_beats, area, scale);
        if (x >= grid_start and x <= area.x + area.w) {
            const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(1, 1.5 * scale), .h = area.h };
            line.fill(.all(0), .{ .color = theme.play });
            drawDownFlag(x, area.y, 5 * scale, 7 * scale, theme.play);
        }
    }
}

fn drawPlayhead(state: *const state_mod.State, area: dvui.Rect.Physical, scale: f32) void {
    const x = area.x + layout.keyboard_w * scale + (state.playhead_beat - state.piano_scroll_beat) * state.piano_pixels_per_beat * scale;
    if (x < area.x + layout.keyboard_w * scale or x > area.x + area.w) return;
    const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(1, scale), .h = area.h };
    line.fill(.all(0), .{ .color = theme.text });
}

