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
const document_commands = @import("../../document/commands.zig");
const notes_mod = @import("../../session/notes.zig");
const piano_math = @import("../piano_roll_math.zig");

const keyboard_w: f32 = 42;
const velocity_h: f32 = 34;
const ruler_h: f32 = 20;
const fine_time_step = piano_math.fine_time_step;

pub fn draw(state: *state_mod.State) void {
    const clip = selectedClip(state) orelse {
        dvui.label(@src(), "Selected MIDI clip is unavailable.", .{}, .{ .color_text = theme.text_soft });
        return;
    };
    syncSelectionClip(state, clip.notes.items.len);

    drawScrollZoomBar(state, clip);

    {
        var tools = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer tools.deinit();
        if (dvui.button(@src(), "+", .{}, .{})) addNote(state);
        if (dvui.button(@src(), "Del", .{}, .{})) deleteSelection(state, clip);
        if (dvui.button(@src(), "Copy", .{}, .{})) copySelection(state, clip);
        if (dvui.button(@src(), "Paste", .{}, .{})) pasteClipboard(state, clip);
        if (dvui.button(@src(), "Dup", .{}, .{})) transform(state, clip, .duplicate);
        if (dvui.button(@src(), if (state.piano_velocity_open) "Notes" else "Vel", .{}, .{})) state.piano_velocity_open = !state.piano_velocity_open;
        if (dvui.button(@src(), if (state.piano_tools_open) "Less" else "Tools", .{}, .{})) state.piano_tools_open = !state.piano_tools_open;
    }
    if (state.piano_tools_open) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        if (dvui.button(@src(), "All", .{}, .{})) selectAll(state, clip.notes.items.len);
        if (dvui.button(@src(), "Quantize", .{}, .{})) transform(state, clip, .quantize);
        if (dvui.button(@src(), "Duplicate", .{}, .{})) transform(state, clip, .duplicate);
        if (dvui.button(@src(), "Time -", .{}, .{})) state.piano_pixels_per_beat = @max(20, state.piano_pixels_per_beat / 1.25);
        if (dvui.button(@src(), "Time +", .{}, .{})) state.piano_pixels_per_beat = @min(220, state.piano_pixels_per_beat * 1.25);
    }
    if (state.piano_tools_open) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        if (dvui.button(@src(), "Legato", .{}, .{})) transform(state, clip, .legato);
        if (dvui.button(@src(), "Overlap", .{}, .{})) transform(state, clip, .resolve_overlaps);
        if (dvui.button(@src(), "Humanize", .{}, .{})) transform(state, clip, .humanize);
    }
    if (state.piano_tools_open) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        if (dvui.button(@src(), "Invert", .{}, .{})) transform(state, clip, .invert);
        if (dvui.button(@src(), "Reverse", .{}, .{})) transform(state, clip, .reverse);
        if (dvui.button(@src(), "Half", .{}, .{})) transform(state, clip, .half_time);
        if (dvui.button(@src(), "Double", .{}, .{})) transform(state, clip, .double_time);
    }

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
    const ruler_area = rulerArea(rs.r, rs.s);
    const grid_area = gridArea(state, rs.r, rs.s);
    const velocity_area = velocityArea(state, rs.r, rs.s);
    clampHorizontalScroll(state, clip, grid_area.w, rs.s);
    drawRuler(state, clip, ruler_area, grid_area, rs.s);
    drawGrid(state, grid_area, rs.s);
    drawClipBoundary(state, clip, grid_area, rs.s);
    drawRegionMarkers(state, clip, grid_area, rs.s);
    drawPlayhead(state, grid_area, rs.s);
    const visible = drawNotes(state, clip, grid_area, rs.s);
    drawBoxSelection(state);
    if (state.piano_velocity_open) drawVelocityLane(state, clip, velocity_area, rs.s);
    handleEvents(state, clip, canvas.data(), grid_area, velocity_area, rs.s);

    _ = visible;
}

/// Editor-owned shortcuts are dispatched by the root before the live MIDI map.
pub fn handleKey(state: *state_mod.State, key: dvui.Event.Key) bool {
    if (key.action != .down and key.action != .repeat) return false;
    const clip = selectedClip(state) orelse return false;
    const command = key.mod.control() or key.mod.command();
    if (command) switch (key.code) {
        .a => selectAll(state, clip.notes.items.len),
        .c => copySelection(state, clip),
        .x => {
            copySelection(state, clip);
            deleteSelection(state, clip);
        },
        .v => pasteClipboard(state, clip),
        .d => transform(state, clip, .duplicate),
        else => return false,
    } else switch (key.code) {
        .delete, .backspace => deleteSelection(state, clip),
        .q => transform(state, clip, .quantize),
        .left => nudgeSelection(state, clip, -quantizeStep(state), 0),
        .right => nudgeSelection(state, clip, quantizeStep(state), 0),
        .up => nudgeSelection(state, clip, 0, if (key.mod.shift()) 12 else 1),
        .down => nudgeSelection(state, clip, 0, if (key.mod.shift()) -12 else -1),
        .escape => {
            state.piano_note_selected = @splat(false);
            state.piano_selected_note = null;
        },
        else => return false,
    }
    return true;
}

fn nudgeSelection(state: *state_mod.State, clip: *notes_mod.PianoRollClip, beat_delta: f32, pitch_delta: i32) void {
    var changed = false;
    for (clip.notes.items, 0..) |*note, i| {
        if (i >= state_mod.max_piano_notes or !state.piano_note_selected[i]) continue;
        const start = @max(0, note.start + beat_delta);
        const pitch = std.math.clamp(@as(i32, note.pitch) + pitch_delta, 0, 127);
        changed = changed or start != note.start or pitch != @as(i32, note.pitch);
        note.start = start;
        note.pitch = @intCast(pitch);
    }
    if (changed) document_commands.commitMidiNoteEdit(&document_model.g, state.selected_track, state.selected_scene);
}

fn syncSelectionClip(state: *state_mod.State, note_len: usize) void {
    if (state.piano_selection_track != state.selected_track or state.piano_selection_scene != state.selected_scene) {
        state.piano_note_selected = @splat(false);
        state.piano_selected_note = null;
        state.piano_selection_track = state.selected_track;
        state.piano_selection_scene = state.selected_scene;
    }
    if (state.piano_selected_note) |i| {
        if (i >= note_len) state.piano_selected_note = null;
    }
}

fn selectionCount(state: *const state_mod.State, note_len: usize) usize {
    var count: usize = 0;
    for (state.piano_note_selected[0..@min(note_len, state_mod.max_piano_notes)]) |on| if (on) {
        count += 1;
    };
    return count;
}

fn selectedIndices(state: *const state_mod.State, note_len: usize, out: []usize) []const usize {
    var count: usize = 0;
    for (state.piano_note_selected[0..@min(note_len, state_mod.max_piano_notes)], 0..) |on, i| if (on and count < out.len) {
        out[count] = i;
        count += 1;
    };
    return out[0..count];
}

fn selectAll(state: *state_mod.State, note_len: usize) void {
    state.piano_note_selected = @splat(false);
    for (state.piano_note_selected[0..@min(note_len, state_mod.max_piano_notes)]) |*on| on.* = true;
    state.piano_selected_note = if (note_len > 0) 0 else null;
}

fn addNote(state: *state_mod.State) void {
    const pitch: u8 = @intFromFloat(std.math.clamp(@round(state.piano_scroll_pitch), 0, 127));
    const start = quantize(state.piano_scroll_beat + 1, quantizeStep(state));
    if (document_commands.addMidiNote(&document_model.g, state.selected_track, state.selected_scene, .{ .pitch = pitch, .start = start, .duration = quantizeStep(state) })) |index| {
        state.piano_note_selected = @splat(false);
        if (index < state_mod.max_piano_notes) state.piano_note_selected[index] = true;
        state.piano_selected_note = index;
    }
}

fn deleteSelection(state: *state_mod.State, clip: *notes_mod.PianoRollClip) void {
    var scratch: [state_mod.max_piano_notes]usize = undefined;
    const indices = selectedIndices(state, clip.notes.items.len, &scratch);
    _ = document_commands.removeMidiNotes(&document_model.g, state.selected_track, state.selected_scene, indices);
    state.piano_note_selected = @splat(false);
    state.piano_selected_note = null;
}

fn copySelection(state: *state_mod.State, clip: *const notes_mod.PianoRollClip) void {
    state.piano_clipboard_len = 0;
    var min_start = std.math.floatMax(f32);
    for (clip.notes.items, 0..) |note, i| if (i < state_mod.max_piano_notes and state.piano_note_selected[i]) {
        min_start = @min(min_start, note.start);
    };
    if (min_start == std.math.floatMax(f32)) return;
    for (clip.notes.items, 0..) |note, i| {
        if (i >= state_mod.max_piano_notes or !state.piano_note_selected[i] or state.piano_clipboard_len >= state.piano_clipboard.len) continue;
        state.piano_clipboard[state.piano_clipboard_len] = .{
            .pitch = note.pitch,
            .start = note.start - min_start,
            .duration = note.duration,
            .velocity = note.velocity,
            .release_velocity = note.release_velocity,
        };
        state.piano_clipboard_len += 1;
    }
}

fn pasteClipboard(state: *state_mod.State, clip: *notes_mod.PianoRollClip) void {
    if (state.piano_clipboard_len == 0) return;
    var pasted: [512]notes_mod.Note = undefined;
    const anchor = quantize(state.piano_scroll_beat + 1, quantizeStep(state));
    for (state.piano_clipboard[0..state.piano_clipboard_len], 0..) |note, i| pasted[i] = .{
        .pitch = note.pitch,
        .start = anchor + note.start,
        .duration = note.duration,
        .velocity = note.velocity,
        .release_velocity = note.release_velocity,
    };
    const first = document_commands.addMidiNotes(&document_model.g, state.selected_track, state.selected_scene, pasted[0..state.piano_clipboard_len]) orelse return;
    state.piano_note_selected = @splat(false);
    for (first..@min(clip.notes.items.len, state_mod.max_piano_notes)) |i| state.piano_note_selected[i] = true;
    state.piano_selected_note = first;
}

fn transform(state: *state_mod.State, clip: *notes_mod.PianoRollClip, kind: document_commands.MidiTransform) void {
    var scratch: [state_mod.max_piano_notes]usize = undefined;
    const indices = selectedIndices(state, clip.notes.items.len, &scratch);
    const old_len = clip.notes.items.len;
    if (document_commands.transformMidiNotes(&document_model.g, state.selected_track, state.selected_scene, indices, kind, quantizeStep(state)) and kind == .duplicate) {
        state.piano_note_selected = @splat(false);
        for (old_len..@min(clip.notes.items.len, state_mod.max_piano_notes)) |i| state.piano_note_selected[i] = true;
        state.piano_selected_note = if (clip.notes.items.len > old_len) old_len else null;
    }
}

fn applyVelocity(state: *state_mod.State, clip: *notes_mod.PianoRollClip, velocity: f32) void {
    const value = std.math.clamp(velocity, 0, 1);
    var changed = false;
    for (clip.notes.items, 0..) |*note, i| if (i < state_mod.max_piano_notes and state.piano_note_selected[i]) {
        changed = changed or note.velocity != value;
        note.velocity = value;
    };
    if (changed) document_commands.commitMidiNoteEdit(&document_model.g, state.selected_track, state.selected_scene);
}

fn quantizeStep(state: *const state_mod.State) f32 {
    const bpb = state.beatsPerBar();
    const steps = [_]f32{ 0.125, 0.25, 0.5, 1, 2, bpb, bpb * 2, bpb * 4, bpb * 8 };
    return steps[@min(state.quantize_index, steps.len - 1)];
}

fn quantize(value: f32, step: f32) f32 {
    return @max(0, @round(value / step) * step);
}

fn gridArea(state: *const state_mod.State, area: dvui.Rect.Physical, scale: f32) dvui.Rect.Physical {
    const top = @min(area.h, ruler_h * scale);
    const bottom = if (state.piano_velocity_open) @min(area.h - top, velocity_h * scale) else 0;
    return .{ .x = area.x, .y = area.y + top, .w = area.w, .h = @max(1, area.h - top - bottom) };
}

fn rulerArea(area: dvui.Rect.Physical, scale: f32) dvui.Rect.Physical {
    return .{ .x = area.x, .y = area.y, .w = area.w, .h = @min(area.h, ruler_h * scale) };
}

fn velocityArea(state: *const state_mod.State, area: dvui.Rect.Physical, scale: f32) dvui.Rect.Physical {
    if (!state.piano_velocity_open) return .{ .x = area.x, .y = area.y + area.h, .w = area.w, .h = 0 };
    const h = @min(area.h, velocity_h * scale);
    return .{ .x = area.x, .y = area.y + area.h - h, .w = area.w, .h = h };
}

const HorizontalMetrics = struct {
    max_beats: f32,
    visible_beats: f32,
    max_scroll: f32,
};

fn horizontalMetrics(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, viewport_w: f32, scale: f32) HorizontalMetrics {
    const timeline_w = @max(1, viewport_w - keyboard_w * scale);
    const visible_beats = timeline_w / @max(1, state.piano_pixels_per_beat * scale);
    const max_beats = @max(64, clip.length_beats + 16);
    return .{
        .max_beats = max_beats,
        .visible_beats = visible_beats,
        .max_scroll = piano_math.maxHorizontalScroll(clip.length_beats, viewport_w, keyboard_w, state.piano_pixels_per_beat, scale),
    };
}

fn clampHorizontalScroll(state: *state_mod.State, clip: *const notes_mod.PianoRollClip, viewport_w: f32, scale: f32) void {
    const metrics = horizontalMetrics(state, clip, viewport_w, scale);
    state.piano_scroll_beat = std.math.clamp(state.piano_scroll_beat, 0, metrics.max_scroll);
}

fn scrollZoomTrackRect(area: dvui.Rect.Physical, scale: f32) dvui.Rect.Physical {
    const pad = 3 * scale;
    const x = area.x + keyboard_w * scale;
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
    clampHorizontalScroll(state, clip, rs.r.w, rs.s);

    track.fill(.all(3 * rs.s), .{ .color = theme.cell });
    const metrics = horizontalMetrics(state, clip, rs.r.w, rs.s);
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
            .press => if (mouse.button.pointer() and containsPoint(track, mouse.p)) {
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
                clampHorizontalScroll(state, clip, rs.r.w, rs.s);
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
    const rows: usize = @as(usize, @intFromFloat(@ceil(area.h / row_h))) + 1;
    const bottom_pitch = bottomVisiblePitch(state, area, scale);
    const first_pitch: i32 = @intFromFloat(@floor(bottom_pitch));
    for (0..rows) |row| {
        const pitch = first_pitch + @as(i32, @intCast(row));
        if (pitch > 127) break;
        const y = area.y + area.h - (@as(f32, @floatFromInt(pitch)) - bottom_pitch + 1) * row_h;
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
        if (x < area.x + key_w or x > area.x + area.w) continue;
        const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(1, scale), .h = area.h };
        line.fill(.all(0), .{ .color = if (@mod(beat, 4) == 0) theme.text_soft else theme.grid });
    }
}

fn drawRuler(state: *const state_mod.State, _: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, grid: dvui.Rect.Physical, scale: f32) void {
    area.fill(.all(0), .{ .color = theme.header });
    const beat_w = state.piano_pixels_per_beat * scale;
    const first = @floor(state.piano_scroll_beat);
    const count: usize = @as(usize, @intFromFloat(@ceil(grid.w / beat_w))) + 2;
    for (0..count) |i| {
        const beat = first + @as(f32, @floatFromInt(i));
        const x = beatX(state, beat, grid, scale);
        if (x < area.x + keyboard_w * scale or x > area.x + area.w) continue;
        const is_bar = @mod(@as(i32, @intFromFloat(beat)), @as(i32, @intFromFloat(state.beatsPerBar()))) == 0;
        const tick_h = if (is_bar) area.h * 0.65 else area.h * 0.32;
        const tick: dvui.Rect.Physical = .{ .x = x, .y = area.y + area.h - tick_h, .w = @max(1, scale), .h = tick_h };
        tick.fill(.all(0), .{ .color = if (is_bar) theme.text_dim else theme.text_soft });
    }
}

fn drawNotes(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, scale: f32) usize {
    var visible: usize = 0;
    for (clip.notes.items, 0..) |note, index| {
        const rect = noteRect(state, note, area, scale);
        if (!intersects(rect, area)) continue;
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
    const key_w = keyboard_w * scale;
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
    const x = area.x + keyboard_w * scale + (clip.length_beats - state.piano_scroll_beat) * state.piano_pixels_per_beat * scale;
    if (x < area.x + keyboard_w * scale or x > area.x + area.w) return;
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

fn beatX(state: *const state_mod.State, beat: f32, area: dvui.Rect.Physical, scale: f32) f32 {
    return area.x + keyboard_w * scale + (beat - state.piano_scroll_beat) * state.piano_pixels_per_beat * scale;
}

fn drawRegionMarkers(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, scale: f32) void {
    const loop_end = clip.loopEnd();
    const has_sub_loop = clip.loop_start_beats > 0.001 or loop_end < clip.length_beats - 0.001;
    const grid_start = area.x + keyboard_w * scale;
    const clip_end_x = beatX(state, clip.length_beats, area, scale);
    if (clip_end_x < area.x + area.w) {
        const left = @max(grid_start, clip_end_x);
        if (left < area.x + area.w) {
            const dim: dvui.Rect.Physical = .{ .x = left, .y = area.y, .w = area.x + area.w - left, .h = area.h };
            dim.fill(.all(0), .{ .color = theme.colorFA(0.02, 0.02, 0.025, 0.62) });
        }
    }
    if (has_sub_loop and clip.loop_start_beats > 0.001) {
        const right = @min(area.x + area.w, beatX(state, clip.loop_start_beats, area, scale));
        const left = @max(grid_start, beatX(state, 0, area, scale));
        if (right > left) {
            const dim: dvui.Rect.Physical = .{ .x = left, .y = area.y, .w = right - left, .h = area.h };
            dim.fill(.all(0), .{ .color = theme.colorFA(0.02, 0.02, 0.025, 0.38) });
        }
    }
    if (has_sub_loop and loop_end < clip.length_beats - 0.001) {
        const left = @max(grid_start, beatX(state, loop_end, area, scale));
        const right = @min(area.x + area.w, clip_end_x);
        if (right > left) {
            const dim: dvui.Rect.Physical = .{ .x = left, .y = area.y, .w = right - left, .h = area.h };
            dim.fill(.all(0), .{ .color = theme.colorFA(0.02, 0.02, 0.025, 0.38) });
        }
    }
    const brace_w = 6 * scale;
    if (has_sub_loop and clip.loop_start_beats > 0.001) {
        const x = beatX(state, clip.loop_start_beats, area, scale);
        if (x >= grid_start and x <= area.x + area.w) {
            const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(1, 1.5 * scale), .h = area.h };
            line.fill(.all(0), .{ .color = theme.solo_on });
            const tick: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = brace_w, .h = @max(1, 1.5 * scale) };
            tick.fill(.all(0), .{ .color = theme.solo_on });
        }
    }
    if (has_sub_loop and loop_end > 0.001 and loop_end < clip.length_beats - 0.001) {
        const x = beatX(state, loop_end, area, scale);
        if (x >= grid_start and x <= area.x + area.w) {
            const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(1, 1.5 * scale), .h = area.h };
            line.fill(.all(0), .{ .color = theme.solo_on });
            const tick: dvui.Rect.Physical = .{ .x = x - brace_w, .y = area.y, .w = brace_w, .h = @max(1, 1.5 * scale) };
            tick.fill(.all(0), .{ .color = theme.solo_on });
        }
    }
    if (clip.play_start_beats > 0.001 and clip.play_start_beats < clip.length_beats - 0.001) {
        const x = beatX(state, clip.play_start_beats, area, scale);
        if (x >= grid_start and x <= area.x + area.w) {
            const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(1, 1.5 * scale), .h = area.h };
            line.fill(.all(0), .{ .color = theme.play });
            drawDownFlag(x, area.y, 5 * scale, 7 * scale, theme.play);
        }
    }
}

fn drawPlayhead(state: *const state_mod.State, area: dvui.Rect.Physical, scale: f32) void {
    const x = area.x + keyboard_w * scale + (state.playhead_beat - state.piano_scroll_beat) * state.piano_pixels_per_beat * scale;
    if (x < area.x + keyboard_w * scale or x > area.x + area.w) return;
    const line: dvui.Rect.Physical = .{ .x = x, .y = area.y, .w = @max(1, scale), .h = area.h };
    line.fill(.all(0), .{ .color = theme.text });
}

fn handleEvents(state: *state_mod.State, clip: *notes_mod.PianoRollClip, wd: *dvui.WidgetData, area: dvui.Rect.Physical, velocity_area: dvui.Rect.Physical, scale: f32) void {
    for (dvui.events()) |*event| {
        if (!dvui.eventMatchSimple(event, wd)) continue;
        if (event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        switch (mouse.action) {
            .wheel_y => |ticks| {
                event.handle(@src(), wd);
                if (mouse.mod.control() or mouse.mod.command()) {
                    const old_width = state.piano_pixels_per_beat;
                    const mouse_beat = state.piano_scroll_beat + @max(0, mouse.p.x - area.x - keyboard_w * scale) / (old_width * scale);
                    state.piano_pixels_per_beat = std.math.clamp(old_width * @exp(-ticks * 0.08), 20, 220);
                    state.piano_scroll_beat = @max(0, mouse_beat - @max(0, mouse.p.x - area.x - keyboard_w * scale) / (state.piano_pixels_per_beat * scale));
                    clampHorizontalScroll(state, clip, area.w, scale);
                } else {
                    const pitch_delta = ticks * 0.5 / @max(1, state.piano_row_height * scale);
                    state.piano_scroll_pitch = std.math.clamp(state.piano_scroll_pitch + pitch_delta, 0, 127);
                }
                dvui.refresh(null, @src(), wd.id);
            },
            .wheel_x => |ticks| {
                event.handle(@src(), wd);
                const beat_delta = ticks / @max(1, state.piano_pixels_per_beat * scale);
                state.piano_scroll_beat -= beat_delta;
                clampHorizontalScroll(state, clip, area.w, scale);
                dvui.refresh(null, @src(), wd.id);
            },
            .press => if (mouse.button.pointer()) {
                event.handle(@src(), wd);
                state.focused_pane = .bottom;
                state.piano_drag_changed = false;
                if (hitRegionMarker(state, clip, mouse.p, area, scale)) |marker| {
                    state.piano_marker_drag = marker;
                    dvui.captureMouse(wd, event.num);
                } else if (containsPoint(velocity_area, mouse.p)) {
                    if (hitVelocity(state, clip, mouse.p, velocity_area, scale)) |index| {
                        selectClicked(state, index, mouse.mod.shift());
                        state.piano_velocity_drag = true;
                        setDraggedVelocity(state, clip, mouse.p, velocity_area);
                        dvui.captureMouse(wd, event.num);
                    }
                } else if (@abs(mouse.p.x - clipEndX(state, clip, area, scale)) <= 7 * scale and containsPoint(area, mouse.p)) {
                    state.piano_clip_resize = true;
                    state.piano_drag_mouse_x = mouse.p.x;
                    state.piano_drag_start = clip.length_beats;
                    dvui.captureMouse(wd, event.num);
                } else if (hitNote(state, clip, mouse.p, area, scale)) |index| {
                    selectClicked(state, index, mouse.mod.shift());
                    if (index < state_mod.max_piano_notes and !state.piano_note_selected[index]) continue;
                    const note = clip.notes.items[index];
                    state.piano_drag_note = index;
                    state.piano_drag_mouse_x = mouse.p.x;
                    state.piano_drag_mouse_y = mouse.p.y;
                    state.piano_drag_start = note.start;
                    state.piano_drag_pitch = note.pitch;
                    state.piano_drag_duration = note.duration;
                    const rect = noteRect(state, note, area, scale);
                    const handle_w = @min(rect.w * 0.35, 7 * scale);
                    state.piano_drag_resize = mouse.p.x >= rect.x + rect.w - handle_w;
                    captureSelectedNotes(state, clip);
                    dvui.captureMouse(wd, event.num);
                } else if (containsPoint(area, mouse.p) and mouse.p.x >= area.x + keyboard_w * scale) {
                    const now = dvui.currentWindow().frame_time_ns;
                    const elapsed = now - state.piano_last_grid_click_ns;
                    const nearby = @abs(mouse.p.x - state.piano_last_grid_click_x) <= 6 * scale and @abs(mouse.p.y - state.piano_last_grid_click_y) <= 6 * scale;
                    state.piano_last_grid_click_ns = now;
                    state.piano_last_grid_click_x = mouse.p.x;
                    state.piano_last_grid_click_y = mouse.p.y;
                    if (nearby and elapsed > 0 and elapsed <= 450 * std.time.ns_per_ms) {
                        addNoteAt(state, clip, mouse.p, area, scale);
                        dvui.refresh(null, @src(), wd.id);
                        continue;
                    }
                    if (!mouse.mod.shift()) state.piano_note_selected = @splat(false);
                    state.piano_selected_note = null;
                    state.piano_box_select = true;
                    state.piano_box_additive = mouse.mod.shift();
                    state.piano_box_start_x = mouse.p.x;
                    state.piano_box_start_y = mouse.p.y;
                    state.piano_box_current_x = mouse.p.x;
                    state.piano_box_current_y = mouse.p.y;
                    dvui.captureMouse(wd, event.num);
                }
                dvui.refresh(null, @src(), wd.id);
            },
            .motion => {
                if (!dvui.captured(wd.id)) continue;
                event.handle(@src(), wd);
                if (state.piano_velocity_drag) {
                    setDraggedVelocity(state, clip, mouse.p, velocity_area);
                } else if (state.piano_marker_drag != .none) {
                    dragRegionMarker(state, clip, mouse.p, area, scale);
                } else if (state.piano_clip_resize) {
                    const dx = (mouse.p.x - state.piano_drag_mouse_x) / (state.piano_pixels_per_beat * scale);
                    const value = piano_math.resizedClipLength(state.piano_drag_start, dx, state.beatsPerBar());
                    state.piano_drag_changed = state.piano_drag_changed or value != clip.length_beats;
                    _ = clip.resizeKeepingLoop(value);
                    if (clip.play_start_beats > value) clip.play_start_beats = value;
                } else if (state.piano_drag_note != null) {
                    const dx = (mouse.p.x - state.piano_drag_mouse_x) / (state.piano_pixels_per_beat * scale);
                    const dy: i32 = @intFromFloat(@round((state.piano_drag_mouse_y - mouse.p.y) / (state.piano_row_height * scale)));
                    for (clip.notes.items, 0..) |*note, i| {
                        if (i >= state_mod.max_piano_notes or !state.piano_note_selected[i]) continue;
                        if (state.piano_drag_resize) {
                            const duration = piano_math.resizedNoteDuration(state.piano_drag_original_start[i], state.piano_drag_original_duration[i], dx, clip.length_beats);
                            state.piano_drag_changed = state.piano_drag_changed or duration != note.duration;
                            note.duration = duration;
                        } else {
                            const pitch = std.math.clamp(@as(i32, state.piano_drag_original_pitch[i]) + dy, 0, 127);
                            const start = piano_math.movedNoteStart(
                                state.piano_drag_original_start[i],
                                dx,
                                note.duration,
                                clip.length_beats,
                            );
                            state.piano_drag_changed = state.piano_drag_changed or start != note.start or pitch != @as(i32, note.pitch);
                            note.start = start;
                            note.pitch = @intCast(pitch);
                        }
                    }
                } else if (state.piano_box_select) {
                    state.piano_box_current_x = mouse.p.x;
                    state.piano_box_current_y = mouse.p.y;
                }
                dvui.refresh(null, @src(), wd.id);
            },
            .release => if (dvui.captured(wd.id)) {
                event.handle(@src(), wd);
                if (state.piano_box_select) finishBoxSelection(state, clip, area, scale);
                state.piano_drag_note = null;
                state.piano_drag_resize = false;
                state.piano_velocity_drag = false;
                state.piano_clip_resize = false;
                state.piano_marker_drag = .none;
                state.piano_box_select = false;
                if (state.piano_drag_changed) document_commands.commitMidiNoteEdit(&document_model.g, state.selected_track, state.selected_scene);
                state.piano_drag_changed = false;
                dvui.captureMouse(null, event.num);
            },
            else => {},
        }
    }
}

fn addNoteAt(state: *state_mod.State, clip: *const notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical, scale: f32) void {
    const row_h = state.piano_row_height * scale;
    const row_from_bottom: i32 = @intFromFloat(@floor((area.y + area.h - point.y) / row_h));
    const pitch_f = bottomVisiblePitch(state, area, scale) + @as(f32, @floatFromInt(row_from_bottom));
    const pitch: u8 = @intFromFloat(std.math.clamp(@floor(pitch_f), 0, 127));
    const raw_beat = state.piano_scroll_beat + (point.x - area.x - keyboard_w * scale) / (state.piano_pixels_per_beat * scale);
    if (raw_beat < 0 or raw_beat >= clip.length_beats) return;
    const step = quantizeStep(state);
    const start = piano_math.containingGridStart(raw_beat, step);
    const duration = @min(step, clip.length_beats - start);
    if (duration < piano_math.min_note_duration) return;
    if (document_commands.addMidiNote(&document_model.g, state.selected_track, state.selected_scene, .{ .pitch = pitch, .start = start, .duration = duration })) |index| {
        state.piano_note_selected = @splat(false);
        if (index < state_mod.max_piano_notes) state.piano_note_selected[index] = true;
        state.piano_selected_note = index;
    }
}

fn hitRegionMarker(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical, scale: f32) ?state_mod.PianoMarkerDrag {
    const loop_end = clip.loopEnd();
    const candidates = [_]struct { marker: state_mod.PianoMarkerDrag, beat: f32, visible: bool }{
        .{ .marker = .play_start, .beat = clip.play_start_beats, .visible = clip.play_start_beats > 0.001 and clip.play_start_beats < clip.length_beats - 0.001 },
        .{ .marker = .loop_start, .beat = clip.loop_start_beats, .visible = clip.loop_start_beats > 0.001 },
        .{ .marker = .loop_end, .beat = loop_end, .visible = loop_end > 0.001 and loop_end < clip.length_beats - 0.001 },
    };
    for (candidates) |candidate| {
        if (!candidate.visible) continue;
        const x = beatX(state, candidate.beat, area, scale);
        if (@abs(point.x - x) <= 7 * scale and point.y >= area.y - 2 * scale and point.y <= area.y + 10 * scale) return candidate.marker;
    }
    return null;
}

fn dragRegionMarker(state: *state_mod.State, clip: *notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical, scale: f32) void {
    const raw = state.piano_scroll_beat + (point.x - area.x - keyboard_w * scale) / (state.piano_pixels_per_beat * scale);
    const beat = std.math.clamp(@round(raw / fine_time_step) * fine_time_step, 0, clip.length_beats);
    switch (state.piano_marker_drag) {
        .play_start => {
            state.piano_drag_changed = state.piano_drag_changed or beat != clip.play_start_beats;
            clip.play_start_beats = beat;
        },
        .loop_start => {
            const value = @min(beat, @max(0, clip.loopEnd() - fine_time_step));
            state.piano_drag_changed = state.piano_drag_changed or value != clip.loop_start_beats;
            clip.loop_start_beats = value;
        },
        .loop_end => {
            const value = @max(beat, @min(clip.length_beats, clip.loop_start_beats + fine_time_step));
            state.piano_drag_changed = state.piano_drag_changed or value != clip.loopEnd();
            clip.loop_end_beats = value;
        },
        .none => {},
    }
}

fn selectClicked(state: *state_mod.State, index: usize, additive: bool) void {
    if (index >= state_mod.max_piano_notes) return;
    if (additive) {
        state.piano_note_selected[index] = !state.piano_note_selected[index];
    } else if (!state.piano_note_selected[index]) {
        state.piano_note_selected = @splat(false);
        state.piano_note_selected[index] = true;
    }
    state.piano_selected_note = if (state.piano_note_selected[index]) index else null;
}

fn captureSelectedNotes(state: *state_mod.State, clip: *const notes_mod.PianoRollClip) void {
    for (clip.notes.items, 0..) |note, i| {
        if (i >= state_mod.max_piano_notes or !state.piano_note_selected[i]) continue;
        state.piano_drag_original_start[i] = note.start;
        state.piano_drag_original_pitch[i] = note.pitch;
        state.piano_drag_original_duration[i] = note.duration;
    }
}

fn finishBoxSelection(state: *state_mod.State, clip: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, scale: f32) void {
    if (!state.piano_box_additive) state.piano_note_selected = @splat(false);
    const selection: dvui.Rect.Physical = .{
        .x = @min(state.piano_box_start_x, state.piano_box_current_x),
        .y = @min(state.piano_box_start_y, state.piano_box_current_y),
        .w = @abs(state.piano_box_current_x - state.piano_box_start_x),
        .h = @abs(state.piano_box_current_y - state.piano_box_start_y),
    };
    state.piano_selected_note = null;
    for (clip.notes.items, 0..) |note, i| {
        if (i >= state_mod.max_piano_notes or !intersects(noteRect(state, note, area, scale), selection)) continue;
        state.piano_note_selected[i] = true;
        state.piano_selected_note = i;
    }
}

fn setDraggedVelocity(state: *state_mod.State, clip: *notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical) void {
    const value = std.math.clamp((area.y + area.h - point.y) / area.h, 0, 1);
    for (clip.notes.items, 0..) |*note, i| if (i < state_mod.max_piano_notes and state.piano_note_selected[i]) {
        state.piano_drag_changed = state.piano_drag_changed or value != note.velocity;
        note.velocity = value;
    };
}

fn hitVelocity(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical, scale: f32) ?usize {
    const beat_w = state.piano_pixels_per_beat * scale;
    var best: ?usize = null;
    var distance = 8 * scale;
    for (clip.notes.items, 0..) |note, i| {
        const x = area.x + keyboard_w * scale + (note.start - state.piano_scroll_beat) * beat_w;
        const d = @abs(point.x - x);
        if (d <= distance) {
            best = i;
            distance = d;
        }
    }
    return best;
}

fn clipEndX(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, scale: f32) f32 {
    return area.x + keyboard_w * scale + (clip.length_beats - state.piano_scroll_beat) * state.piano_pixels_per_beat * scale;
}

fn containsPoint(area: dvui.Rect.Physical, point: dvui.Point.Physical) bool {
    return point.x >= area.x and point.x <= area.x + area.w and point.y >= area.y and point.y <= area.y + area.h;
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
    const bottom_pitch = bottomVisiblePitch(state, area, scale);
    return .{
        .x = area.x + keyboard_w * scale + (note.start - state.piano_scroll_beat) * beat_w,
        .y = area.y + area.h - (@as(f32, @floatFromInt(note.pitch)) - bottom_pitch + 1) * row_h + scale,
        .w = @max(3 * scale, note.duration * beat_w),
        .h = @max(2 * scale, row_h - 2 * scale),
    };
}

fn bottomVisiblePitch(state: *const state_mod.State, area: dvui.Rect.Physical, scale: f32) f32 {
    const visible_rows = @max(1, area.h / @max(1, state.piano_row_height * scale));
    return std.math.clamp(state.piano_scroll_pitch - visible_rows * 0.5, 0, @max(0, 128 - visible_rows));
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
