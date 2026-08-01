//! DVUI dense-canvas piano-roll viability slice.
//!
//! Notes are direct draw calls inside one widget, not one widget per note.
//! Only notes intersecting the viewport are submitted. Mouse wheel scrolls
//! pitches; Ctrl/Cmd+wheel zooms time; pointer drag moves a selected note.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../theme.zig");
const state_mod = @import("../state.zig");
const document_model = @import("../../document/model.zig");
const notes_mod = @import("../../session/notes.zig");

const keyboard_w: f32 = 42;

pub fn draw(state: *state_mod.State) void {
    const clip = selectedClip(state) orelse {
        dvui.label(@src(), "Selected MIDI clip is unavailable.", .{}, .{ .color_text = theme.text_soft });
        return;
    };

    dvui.label(@src(), "Piano roll · {d} notes · wheel: pitches · Ctrl/Cmd+wheel: time zoom", .{clip.notes.items.len}, .{
        .color_text = theme.text_dim,
    });

    var canvas = dvui.box(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.cell,
        .border = dvui.Rect.all(1),
        .color_border = theme.grid,
        .min_size_content = .{ .h = 150 },
    });
    defer canvas.deinit();

    const rs = canvas.data().contentRectScale();
    drawGrid(state, rs.r, rs.s);
    const visible = drawNotes(state, clip, rs.r, rs.s);
    handleEvents(state, clip, canvas.data(), rs.r, rs.s);

    dvui.label(@src(), "visible {d}/{d} · {d:.1}px/beat · {d:.1}px/row", .{
        visible,
        clip.notes.items.len,
        state.piano_pixels_per_beat,
        state.piano_row_height,
    }, .{ .color_text = theme.text_soft });
}

fn selectedClip(state: *const state_mod.State) ?*notes_mod.PianoRollClip {
    if (!document_model.ready()) return null;
    const document = &document_model.g;
    if (state.selected_track >= document.session.track_count or state.selected_scene >= document.session.scene_count) return null;
    const id = document.session.clips[state.selected_track][state.selected_scene].clip;
    const clip = document.clip_pool.get(id) orelse return null;
    return if (clip.content == .midi) &clip.content.midi else null;
}

fn drawGrid(state: *const state_mod.State, area: dvui.Rect.Physical, scale: f32) void {
    const row_h = state.piano_row_height * scale;
    const beat_w = state.piano_pixels_per_beat * scale;
    const key_w = keyboard_w * scale;
    const first_pitch: i32 = @intFromFloat(@floor(state.piano_scroll_pitch));
    const rows: usize = @as(usize, @intFromFloat(@ceil(area.h / row_h))) + 1;
    for (0..rows) |row| {
        const pitch = first_pitch + @as(i32, @intCast(row));
        if (pitch > 127) break;
        const y = area.y + area.h - @as(f32, @floatFromInt(row + 1)) * row_h;
        const black = isBlackKey(@intCast(@max(0, pitch)));
        const lane: dvui.Rect.Physical = .{ .x = area.x + key_w, .y = y, .w = area.w - key_w, .h = row_h };
        lane.fill(.all(0), .{ .color = if (black) theme.panel else theme.cell });
        const key: dvui.Rect.Physical = .{ .x = area.x, .y = y, .w = key_w, .h = row_h };
        key.fill(.all(0), .{ .color = if (black) theme.header else theme.text_dim });
        const line: dvui.Rect.Physical = .{ .x = area.x, .y = y, .w = area.w, .h = @max(1, scale) };
        line.fill(.all(0), .{ .color = theme.grid });
    }

    const first_beat: i32 = @intFromFloat(@floor(state.piano_scroll_beat));
    const beats: usize = @as(usize, @intFromFloat(@ceil((area.w - key_w) / beat_w))) + 2;
    for (0..beats) |i| {
        const beat = first_beat + @as(i32, @intCast(i));
        const x = area.x + key_w + (@as(f32, @floatFromInt(beat)) - state.piano_scroll_beat) * beat_w;
        const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(1, scale), .h = area.h };
        line.fill(.all(0), .{ .color = if (@mod(beat, 4) == 0) theme.text_soft else theme.grid });
    }
}

fn drawNotes(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, scale: f32) usize {
    var visible: usize = 0;
    for (clip.notes.items, 0..) |note, index| {
        const rect = noteRect(state, note, area, scale);
        if (!intersects(rect, area)) continue;
        visible += 1;
        rect.fill(.all(2 * scale), .{ .color = if (state.piano_selected_note == index) theme.selected else theme.clip_stopped });
    }
    return visible;
}

fn handleEvents(state: *state_mod.State, clip: *notes_mod.PianoRollClip, wd: *dvui.WidgetData, area: dvui.Rect.Physical, scale: f32) void {
    for (dvui.events()) |*event| {
        if (!dvui.eventMatchSimple(event, wd)) continue;
        if (event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        switch (mouse.action) {
            .wheel_y => |ticks| {
                event.handle(@src(), wd);
                if (mouse.mod.control() or mouse.mod.command()) {
                    state.piano_pixels_per_beat = std.math.clamp(state.piano_pixels_per_beat * (1 - ticks * 0.08), 16, 256);
                } else {
                    state.piano_scroll_pitch = std.math.clamp(state.piano_scroll_pitch + ticks * 3, 0, 116);
                }
                dvui.refresh(null, @src(), wd.id);
            },
            .wheel_x => |ticks| {
                event.handle(@src(), wd);
                state.piano_scroll_beat = @max(0, state.piano_scroll_beat + ticks * 0.5);
                dvui.refresh(null, @src(), wd.id);
            },
            .press => if (mouse.button.pointer()) {
                event.handle(@src(), wd);
                state.piano_selected_note = hitNote(state, clip, mouse.p, area, scale);
                if (state.piano_selected_note) |index| {
                    const note = clip.notes.items[index];
                    state.piano_drag_note = index;
                    state.piano_drag_mouse_x = mouse.p.x;
                    state.piano_drag_mouse_y = mouse.p.y;
                    state.piano_drag_start = note.start;
                    state.piano_drag_pitch = note.pitch;
                    dvui.captureMouse(wd, event.num);
                }
                dvui.refresh(null, @src(), wd.id);
            },
            .motion => if (state.piano_drag_note) |index| {
                if (!dvui.captured(wd.id) or index >= clip.notes.items.len) continue;
                event.handle(@src(), wd);
                const dx = (mouse.p.x - state.piano_drag_mouse_x) / (state.piano_pixels_per_beat * scale);
                const dy: i32 = @intFromFloat(@round((state.piano_drag_mouse_y - mouse.p.y) / (state.piano_row_height * scale)));
                const pitch = std.math.clamp(@as(i32, state.piano_drag_pitch) + dy, 0, 127);
                clip.notes.items[index].start = @max(0, @round((state.piano_drag_start + dx) * 4) / 4);
                clip.notes.items[index].pitch = @intCast(pitch);
                dvui.refresh(null, @src(), wd.id);
            },
            .release => if (state.piano_drag_note != null) {
                event.handle(@src(), wd);
                state.piano_drag_note = null;
                document_model.g.markChanged();
                dvui.captureMouse(null, event.num);
            },
            else => {},
        }
    }
}

fn hitNote(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical, scale: f32) ?usize {
    var index = clip.notes.items.len;
    while (index > 0) {
        index -= 1;
        const rect = noteRect(state, clip.notes.items[index], area, scale);
        if (point.x >= rect.x and point.x <= rect.x + rect.w and point.y >= rect.y and point.y <= rect.y + rect.h) return index;
    }
    return null;
}

fn noteRect(state: *const state_mod.State, note: notes_mod.Note, area: dvui.Rect.Physical, scale: f32) dvui.Rect.Physical {
    const row_h = state.piano_row_height * scale;
    const beat_w = state.piano_pixels_per_beat * scale;
    return .{
        .x = area.x + keyboard_w * scale + (note.start - state.piano_scroll_beat) * beat_w,
        .y = area.y + area.h - (@as(f32, @floatFromInt(note.pitch)) - state.piano_scroll_pitch + 1) * row_h + scale,
        .w = @max(3 * scale, note.duration * beat_w),
        .h = @max(2 * scale, row_h - 2 * scale),
    };
}

fn intersects(a: dvui.Rect.Physical, b: dvui.Rect.Physical) bool {
    return a.x + a.w >= b.x and a.x <= b.x + b.w and a.y + a.h >= b.y and a.y <= b.y + b.h;
}

fn isBlackKey(pitch: u8) bool {
    return switch (pitch % 12) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}
