//! Piano-roll pointer gestures: note drag/resize, box select, markers, velocity, automation edit mode.
const std = @import("std");
const dvui = @import("dvui");
const state_mod = @import("../state.zig");
const document_model = @import("../../document/model.zig");
const document_commands = @import("../../document/commands.zig");
const notes_mod = @import("../../session/notes.zig");
const piano_math = @import("../piano_roll_math.zig");
const layout = @import("piano_roll_layout.zig");
const automation = @import("piano_roll_automation.zig");

pub fn handleEvents(
    state: *state_mod.State,
    clip: *notes_mod.PianoRollClip,
    wd: *dvui.WidgetData,
    area: dvui.Rect.Physical,
    velocity_area: dvui.Rect.Physical,
    scale: f32,
    automation_mode: bool,
) void {
    const key_strip: dvui.Rect.Physical = .{ .x = area.x, .y = area.y, .w = layout.keyboard_w * scale, .h = area.h };
    const timeline: dvui.Rect.Physical = .{
        .x = area.x + layout.keyboard_w * scale,
        .y = area.y,
        .w = @max(1, area.w - layout.keyboard_w * scale),
        .h = area.h,
    };

    for (dvui.events()) |*event| {
        if (!dvui.eventMatchSimple(event, wd)) continue;
        if (event.evt != .mouse) continue;
        const mouse = event.evt.mouse;

        // Hover pitch for key labels (grid or keyboard strip).
        if (layout.containsPoint(area, mouse.p) or layout.containsPoint(key_strip, mouse.p)) {
            if (layout.pitchAtY(state, mouse.p.y, area, scale)) |pitch| state.piano_hover_pitch = pitch;
        }

        switch (mouse.action) {
            .wheel_y => |ticks| {
                event.handle(@src(), wd);
                if (mouse.mod.control() or mouse.mod.command()) {
                    const old_width = state.piano_pixels_per_beat;
                    const mouse_beat = state.piano_scroll_beat + @max(0, mouse.p.x - area.x - layout.keyboard_w * scale) / (old_width * scale);
                    state.piano_pixels_per_beat = std.math.clamp(old_width * @exp(-ticks * 0.08), 20, 220);
                    state.piano_scroll_beat = @max(0, mouse_beat - @max(0, mouse.p.x - area.x - layout.keyboard_w * scale) / (state.piano_pixels_per_beat * scale));
                    layout.clampHorizontalScroll(state, clip, area.w, scale);
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
                layout.clampHorizontalScroll(state, clip, area.w, scale);
                dvui.refresh(null, @src(), wd.id);
            },
            .press => {
                if (automation_mode and mouse.button == .right and layout.containsPoint(timeline, mouse.p)) {
                    event.handle(@src(), wd);
                    state.focused_pane = .bottom;
                    if (state.piano_automation_lane_index) |lane_index| {
                        if (automation.hitAutomationPoint(state, clip, lane_index, mouse.p, area, scale)) |idx| {
                            automation.removeAutomationPointAt(state, clip, lane_index, idx);
                        }
                    }
                    dvui.refresh(null, @src(), wd.id);
                    continue;
                }
                if (!mouse.button.pointer()) continue;
                event.handle(@src(), wd);
                state.focused_pane = .bottom;
                state.piano_drag_changed = false;

                if (automation_mode and layout.containsPoint(timeline, mouse.p)) {
                    if (state.piano_automation_lane_index) |lane_index| {
                        if (automation.hitAutomationPoint(state, clip, lane_index, mouse.p, area, scale)) |idx| {
                            state.piano_automation_drag_active = true;
                            state.piano_automation_drag_lane = lane_index;
                            state.piano_automation_drag_point = idx;
                            state.piano_automation_selected_point = idx;
                            state.piano_automation_drag_changed = false;
                            dvui.captureMouse(wd, event.num);
                            dvui.refresh(null, @src(), wd.id);
                            continue;
                        }
                        if (document_model.ready()) {
                            const time = layout.quantize(
                                std.math.clamp(layout.beatAtX(state, mouse.p.x, area, scale), 0, clip.length_beats),
                                layout.quantizeStep(state),
                            );
                            const range = automation.automationRange(state, clip, lane_index);
                            const value = automation.valueFromY(mouse.p.y, range.min_value, range.max_value, area.y, area.h);
                            if (document_commands.addAutomationPoint(
                                &document_model.g,
                                state.selected_track,
                                state.selected_scene,
                                lane_index,
                                time,
                                value,
                            )) |new_idx| {
                                state.piano_automation_selected_point = new_idx;
                                state.piano_automation_drag_active = true;
                                state.piano_automation_drag_lane = lane_index;
                                state.piano_automation_drag_point = new_idx;
                                state.piano_automation_drag_changed = false;
                                dvui.captureMouse(wd, event.num);
                            }
                        }
                        dvui.refresh(null, @src(), wd.id);
                        continue;
                    }
                }

                if (layout.containsPoint(key_strip, mouse.p)) {
                    // Click-to-play / pitch audition on the keyboard strip.
                    if (layout.pitchAtY(state, mouse.p.y, area, scale)) |pitch| {
                        state.piano_key_held = pitch;
                        state.piano_preview_pitch = pitch;
                        state.piano_hover_pitch = pitch;
                    }
                    dvui.captureMouse(wd, event.num);
                } else if (hitRegionMarker(state, clip, mouse.p, area, scale)) |marker| {
                    beginGesture(state);
                    state.piano_marker_drag = marker;
                    dvui.captureMouse(wd, event.num);
                } else if (layout.containsPoint(velocity_area, mouse.p)) {
                    if (hitVelocity(state, clip, mouse.p, velocity_area, scale)) |index| {
                        selectClicked(state, index, mouse.mod.shift());
                        beginGesture(state);
                        state.piano_velocity_drag = true;
                        setDraggedVelocity(state, clip, mouse.p, velocity_area);
                        dvui.captureMouse(wd, event.num);
                    }
                } else if (@abs(mouse.p.x - layout.clipEndX(state, clip, area, scale)) <= 7 * scale and layout.containsPoint(area, mouse.p)) {
                    beginGesture(state);
                    state.piano_clip_resize = true;
                    state.piano_drag_mouse_x = mouse.p.x;
                    state.piano_drag_start = clip.length_beats;
                    dvui.captureMouse(wd, event.num);
                } else if (!automation_mode) {
                    if (hitNote(state, clip, mouse.p, area, scale)) |index| {
                        selectClicked(state, index, mouse.mod.shift());
                        if (index < state_mod.max_piano_notes and !state.piano_note_selected[index]) continue;
                        const note = clip.notes.items[index];
                        beginGesture(state);
                        state.piano_drag_note = index;
                        state.piano_drag_mouse_x = mouse.p.x;
                        state.piano_drag_mouse_y = mouse.p.y;
                        state.piano_drag_start = note.start;
                        state.piano_drag_pitch = note.pitch;
                        state.piano_drag_duration = note.duration;
                        state.piano_preview_pitch = note.pitch;
                        const rect = layout.noteRect(state, note, area, scale);
                        const handle_w = @min(rect.w * 0.35, 7 * scale);
                        state.piano_drag_resize = mouse.p.x >= rect.x + rect.w - handle_w;
                        captureSelectedNotes(state, clip);
                        dvui.captureMouse(wd, event.num);
                    } else if (layout.containsPoint(area, mouse.p) and mouse.p.x >= area.x + layout.keyboard_w * scale) {
                        const now = dvui.currentWindow().frame_time_ns;
                        const elapsed = now - state.piano_last_grid_click_ns;
                        const nearby = @abs(mouse.p.x - state.piano_last_grid_click_x) <= 6 * scale and @abs(mouse.p.y - state.piano_last_grid_click_y) <= 6 * scale;
                        state.piano_last_grid_click_ns = now;
                        state.piano_last_grid_click_x = mouse.p.x;
                        state.piano_last_grid_click_y = mouse.p.y;
                        if (nearby and elapsed > 0 and elapsed <= 450 * std.time.ns_per_ms) {
                            addNoteAt(state, clip, mouse.p, area, scale);
                            if (layout.pitchAtY(state, mouse.p.y, area, scale)) |pitch| state.piano_preview_pitch = pitch;
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
                }
                dvui.refresh(null, @src(), wd.id);
            },
            .motion => {
                // Drag across keys to glissando while held.
                if (state.piano_key_held != null and dvui.captured(wd.id)) {
                    event.handle(@src(), wd);
                    if (layout.pitchAtY(state, mouse.p.y, area, scale)) |pitch| {
                        state.piano_key_held = pitch;
                        state.piano_preview_pitch = pitch;
                        state.piano_hover_pitch = pitch;
                    }
                    dvui.refresh(null, @src(), wd.id);
                    continue;
                }
                if (!dvui.captured(wd.id)) continue;
                event.handle(@src(), wd);
                if (state.piano_automation_drag_active) {
                    automation.dragAutomationPoint(state, clip, mouse.p, area, scale);
                } else if (state.piano_velocity_drag) {
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
                const was_key = state.piano_key_held != null;
                const was_auto_drag = state.piano_automation_drag_active;
                const auto_changed = state.piano_automation_drag_changed;
                state.piano_key_held = null;
                state.piano_drag_note = null;
                state.piano_drag_resize = false;
                state.piano_velocity_drag = false;
                state.piano_clip_resize = false;
                state.piano_marker_drag = .none;
                state.piano_box_select = false;
                state.piano_automation_drag_active = false;
                state.piano_automation_drag_changed = false;
                if (was_auto_drag) {
                    if (auto_changed and document_model.ready()) {
                        document_commands.commitAutomationEdit(&document_model.g, state.selected_track, state.selected_scene);
                    }
                } else if (!was_key) {
                    if (state.piano_drag_changed) {
                        document_commands.commitMidiNoteEdit(&document_model.g, state.selected_track, state.selected_scene);
                    } else if (document_model.ready()) {
                        document_model.g.midi_history.cancelGesture();
                    }
                }
                state.piano_drag_changed = false;
                dvui.captureMouse(null, event.num);
            },
            else => {},
        }
    }
}

pub fn beginGesture(state: *const state_mod.State) void {
    if (!document_model.ready()) return;
    document_commands.beginMidiGesture(&document_model.g, state.selected_track, state.selected_scene);
}

pub fn addNoteAt(state: *state_mod.State, clip: *const notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical, scale: f32) void {
    const row_h = state.piano_row_height * scale;
    const row_from_bottom: i32 = @intFromFloat(@floor((area.y + area.h - point.y) / row_h));
    const pitch_f = layout.bottomVisiblePitch(state, area, scale) + @as(f32, @floatFromInt(row_from_bottom));
    const pitch: u8 = @intFromFloat(std.math.clamp(@floor(pitch_f), 0, 127));
    const raw_beat = state.piano_scroll_beat + (point.x - area.x - layout.keyboard_w * scale) / (state.piano_pixels_per_beat * scale);
    if (raw_beat < 0 or raw_beat >= clip.length_beats) return;
    const step = layout.quantizeStep(state);
    const start = piano_math.containingGridStart(raw_beat, step);
    const duration = @min(step, clip.length_beats - start);
    if (duration < piano_math.min_note_duration) return;
    if (document_commands.addMidiNote(&document_model.g, state.selected_track, state.selected_scene, .{ .pitch = pitch, .start = start, .duration = duration })) |index| {
        state.piano_note_selected = @splat(false);
        if (index < state_mod.max_piano_notes) state.piano_note_selected[index] = true;
        state.piano_selected_note = index;
    }
}

pub fn hitRegionMarker(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical, scale: f32) ?state_mod.PianoMarkerDrag {
    const loop_end = clip.loopEnd();
    const candidates = [_]struct { marker: state_mod.PianoMarkerDrag, beat: f32, visible: bool }{
        .{ .marker = .play_start, .beat = clip.play_start_beats, .visible = clip.play_start_beats > 0.001 and clip.play_start_beats < clip.length_beats - 0.001 },
        .{ .marker = .loop_start, .beat = clip.loop_start_beats, .visible = clip.loop_start_beats > 0.001 },
        .{ .marker = .loop_end, .beat = loop_end, .visible = loop_end > 0.001 and loop_end < clip.length_beats - 0.001 },
    };
    for (candidates) |candidate| {
        if (!candidate.visible) continue;
        const x = layout.beatX(state, candidate.beat, area, scale);
        if (@abs(point.x - x) <= 7 * scale and point.y >= area.y - 2 * scale and point.y <= area.y + 10 * scale) return candidate.marker;
    }
    return null;
}

pub fn dragRegionMarker(state: *state_mod.State, clip: *notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical, scale: f32) void {
    const raw = state.piano_scroll_beat + (point.x - area.x - layout.keyboard_w * scale) / (state.piano_pixels_per_beat * scale);
    const beat = std.math.clamp(@round(raw / layout.fine_time_step) * layout.fine_time_step, 0, clip.length_beats);
    switch (state.piano_marker_drag) {
        .play_start => {
            state.piano_drag_changed = state.piano_drag_changed or beat != clip.play_start_beats;
            clip.play_start_beats = beat;
        },
        .loop_start => {
            const value = @min(beat, @max(0, clip.loopEnd() - layout.fine_time_step));
            state.piano_drag_changed = state.piano_drag_changed or value != clip.loop_start_beats;
            clip.loop_start_beats = value;
        },
        .loop_end => {
            const value = @max(beat, @min(clip.length_beats, clip.loop_start_beats + layout.fine_time_step));
            state.piano_drag_changed = state.piano_drag_changed or value != clip.loopEnd();
            clip.loop_end_beats = value;
        },
        .none => {},
    }
}

pub fn selectClicked(state: *state_mod.State, index: usize, additive: bool) void {
    if (index >= state_mod.max_piano_notes) return;
    if (additive) {
        state.piano_note_selected[index] = !state.piano_note_selected[index];
    } else if (!state.piano_note_selected[index]) {
        state.piano_note_selected = @splat(false);
        state.piano_note_selected[index] = true;
    }
    state.piano_selected_note = if (state.piano_note_selected[index]) index else null;
}

pub fn captureSelectedNotes(state: *state_mod.State, clip: *const notes_mod.PianoRollClip) void {
    for (clip.notes.items, 0..) |note, i| {
        if (i >= state_mod.max_piano_notes or !state.piano_note_selected[i]) continue;
        state.piano_drag_original_start[i] = note.start;
        state.piano_drag_original_pitch[i] = note.pitch;
        state.piano_drag_original_duration[i] = note.duration;
    }
}

pub fn finishBoxSelection(state: *state_mod.State, clip: *const notes_mod.PianoRollClip, area: dvui.Rect.Physical, scale: f32) void {
    if (!state.piano_box_additive) state.piano_note_selected = @splat(false);
    const selection: dvui.Rect.Physical = .{
        .x = @min(state.piano_box_start_x, state.piano_box_current_x),
        .y = @min(state.piano_box_start_y, state.piano_box_current_y),
        .w = @abs(state.piano_box_current_x - state.piano_box_start_x),
        .h = @abs(state.piano_box_current_y - state.piano_box_start_y),
    };
    state.piano_selected_note = null;
    for (clip.notes.items, 0..) |note, i| {
        if (i >= state_mod.max_piano_notes or !layout.intersects(layout.noteRect(state, note, area, scale), selection)) continue;
        state.piano_note_selected[i] = true;
        state.piano_selected_note = i;
    }
}

pub fn setDraggedVelocity(state: *state_mod.State, clip: *notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical) void {
    const value = std.math.clamp((area.y + area.h - point.y) / area.h, 0, 1);
    for (clip.notes.items, 0..) |*note, i| if (i < state_mod.max_piano_notes and state.piano_note_selected[i]) {
        state.piano_drag_changed = state.piano_drag_changed or value != note.velocity;
        note.velocity = value;
    };
}

pub fn hitVelocity(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical, scale: f32) ?usize {
    const beat_w = state.piano_pixels_per_beat * scale;
    var best: ?usize = null;
    var distance = 8 * scale;
    for (clip.notes.items, 0..) |note, i| {
        const x = area.x + layout.keyboard_w * scale + (note.start - state.piano_scroll_beat) * beat_w;
        const d = @abs(point.x - x);
        if (d <= distance) {
            best = i;
            distance = d;
        }
    }
    return best;
}

fn hitNote(state: *const state_mod.State, clip: *const notes_mod.PianoRollClip, point: dvui.Point.Physical, area: dvui.Rect.Physical, scale: f32) ?usize {
    var index = clip.notes.items.len;
    while (index > 0) {
        index -= 1;
        const rect = layout.noteRect(state, clip.notes.items[index], area, scale);
        if (point.x >= rect.x and point.x <= rect.x + rect.w and point.y >= rect.y and point.y <= rect.y + rect.h) return index;
    }
    return null;
}
