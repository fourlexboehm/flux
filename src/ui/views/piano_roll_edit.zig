//! Piano-roll note edit operations (clipboard, transform, audition).
const std = @import("std");
const state_mod = @import("../state.zig");
const document_model = @import("../../document/model.zig");
const document_commands = @import("../../document/commands.zig");
const notes_mod = @import("../../session/notes.zig");
const layout = @import("piano_roll_layout.zig");

pub fn updateAudition(state: *state_mod.State, clip: *const notes_mod.PianoRollClip) void {
    if (state.piano_key_held) |pitch| {
        state.piano_preview_pitch = pitch;
        return;
    }
    if (state.piano_drag_note != null and !state.piano_drag_resize) {
        // Prefer the primary drag note; fall back to any selected pitch.
        if (state.piano_drag_note) |index| {
            if (index < clip.notes.items.len) {
                state.piano_preview_pitch = clip.notes.items[index].pitch;
                return;
            }
        }
        for (clip.notes.items, 0..) |note, i| {
            if (i < state_mod.max_piano_notes and state.piano_note_selected[i]) {
                state.piano_preview_pitch = note.pitch;
                return;
            }
        }
    }
}

pub fn nudgeSelection(state: *state_mod.State, clip: *notes_mod.PianoRollClip, beat_delta: f32, pitch_delta: i32) void {
    if (!document_model.ready()) return;
    const changed = document_commands.nudgeMidiNotes(&document_model.g, state.selected_track, state.selected_scene, &state.piano_note_selected, beat_delta, pitch_delta);
    if (changed and pitch_delta != 0) {
        // Audition the first selected note after a pitch nudge.
        for (clip.notes.items, 0..) |note, i| {
            if (i < state_mod.max_piano_notes and state.piano_note_selected[i]) {
                state.piano_preview_pitch = note.pitch;
                break;
            }
        }
    }
}

pub fn addNote(state: *state_mod.State) void {
    const pitch: u8 = @intFromFloat(std.math.clamp(@round(state.piano_scroll_pitch), 0, 127));
    const start = layout.quantize(state.piano_scroll_beat + 1, layout.quantizeStep(state));
    if (document_commands.addMidiNote(&document_model.g, state.selected_track, state.selected_scene, .{ .pitch = pitch, .start = start, .duration = layout.quantizeStep(state) })) |index| {
        state.piano_note_selected = @splat(false);
        if (index < state_mod.max_piano_notes) state.piano_note_selected[index] = true;
        state.piano_selected_note = index;
    }
}

pub fn deleteSelection(state: *state_mod.State, clip: *notes_mod.PianoRollClip) void {
    var scratch: [state_mod.max_piano_notes]usize = undefined;
    const indices = layout.selectedIndices(state, clip.notes.items.len, &scratch);
    _ = document_commands.removeMidiNotes(&document_model.g, state.selected_track, state.selected_scene, indices);
    state.piano_note_selected = @splat(false);
    state.piano_selected_note = null;
}

pub fn copySelection(state: *state_mod.State, clip: *const notes_mod.PianoRollClip) void {
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

pub fn pasteClipboard(state: *state_mod.State, clip: *notes_mod.PianoRollClip) void {
    if (state.piano_clipboard_len == 0) return;
    var pasted: [512]notes_mod.Note = undefined;
    const anchor = layout.quantize(state.piano_scroll_beat + 1, layout.quantizeStep(state));
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

pub fn transform(state: *state_mod.State, clip: *notes_mod.PianoRollClip, kind: document_commands.MidiTransform) void {
    var scratch: [state_mod.max_piano_notes]usize = undefined;
    const indices = layout.selectedIndices(state, clip.notes.items.len, &scratch);
    const old_len = clip.notes.items.len;
    if (document_commands.transformMidiNotes(&document_model.g, state.selected_track, state.selected_scene, indices, kind, layout.quantizeStep(state)) and kind == .duplicate) {
        state.piano_note_selected = @splat(false);
        for (old_len..@min(clip.notes.items.len, state_mod.max_piano_notes)) |i| state.piano_note_selected[i] = true;
        state.piano_selected_note = if (clip.notes.items.len > old_len) old_len else null;
    }
}

pub fn applyVelocity(state: *state_mod.State, clip: *notes_mod.PianoRollClip, velocity: f32) void {
    if (!document_model.ready()) return;
    const value = std.math.clamp(velocity, 0, 1);
    document_commands.beginMidiGesture(&document_model.g, state.selected_track, state.selected_scene);
    var changed = false;
    for (clip.notes.items, 0..) |*note, i| if (i < state_mod.max_piano_notes and state.piano_note_selected[i]) {
        changed = changed or note.velocity != value;
        note.velocity = value;
    };
    if (changed) {
        document_commands.commitMidiNoteEdit(&document_model.g, state.selected_track, state.selected_scene);
    } else {
        document_model.g.midi_history.cancelGesture();
    }
}
