const zgui = @import("zgui");
const session_constants = @import("session_view/constants.zig");
const State = @import("state.zig").State;

const max_tracks = session_constants.max_tracks;
const keyboard_base_pitch: u8 = 60; // Middle C (C4)

pub fn updateKeyboardMidi(state: *State) void {
    // Skip keyboard MIDI when text input is active (e.g., renaming tracks/scenes)
    // This prevents piano keys from triggering while typing
    if (zgui.io.getWantTextInput() and zgui.isAnyItemActive()) {
        // Clear all key states when text input is active to release any held notes
        for (0..max_tracks) |track_index| {
            state.live_key_states[track_index] = [_]bool{false} ** 128;
            state.live_key_velocities[track_index] = [_]f32{0.0} ** 128;
        }
        return;
    }

    // Handle octave change with z/x keys (edge detection, no repeat)
    if (zgui.isKeyPressed(.z, false)) {
        state.keyboard_octave = @max(state.keyboard_octave - 1, -5);
    }
    if (zgui.isKeyPressed(.x, false)) {
        state.keyboard_octave = @min(state.keyboard_octave + 1, 5);
    }

    const KeyMapping = struct {
        key: zgui.Key,
        offset: u8, // Offset from base pitch
    };
    const mappings = [_]KeyMapping{
        .{ .key = .a, .offset = 0 }, // C
        .{ .key = .s, .offset = 2 }, // D
        .{ .key = .d, .offset = 4 }, // E
        .{ .key = .f, .offset = 5 }, // F
        .{ .key = .g, .offset = 7 }, // G
        .{ .key = .h, .offset = 9 }, // A
        .{ .key = .j, .offset = 11 }, // B
        .{ .key = .k, .offset = 12 }, // C (octave up)
        .{ .key = .l, .offset = 14 }, // D
        .{ .key = .semicolon, .offset = 16 }, // E
        .{ .key = .w, .offset = 1 }, // C#
        .{ .key = .e, .offset = 3 }, // D#
        .{ .key = .t, .offset = 6 }, // F#
        .{ .key = .y, .offset = 8 }, // G#
        .{ .key = .u, .offset = 10 }, // A#
    };

    const octave_offset: i16 = @as(i16, state.keyboard_octave) * 12;

    var pressed = [_]bool{false} ** 128;
    var pressed_velocities = [_]f32{0.0} ** 128;
    for (mappings) |mapping| {
        if (zgui.isKeyDown(mapping.key)) {
            const pitch: i16 = @as(i16, keyboard_base_pitch) + @as(i16, mapping.offset) + octave_offset;
            if (pitch >= 0 and pitch <= 127) {
                const idx: usize = @intCast(pitch);
                pressed[idx] = true;
                pressed_velocities[idx] = 0.8;
            }
        }
    }
    for (0..128) |pitch| {
        if (state.midi_note_states[pitch]) {
            pressed[pitch] = true;
            pressed_velocities[pitch] = @max(pressed_velocities[pitch], state.midi_note_velocities[pitch]);
        }
    }

    // Route keyboard to armed track if one is armed, otherwise to selected track
    const target_track = state.session.armed_track orelse state.selectedTrack();
    for (0..max_tracks) |track_index| {
        if (track_index == target_track) {
            state.live_key_states[track_index] = pressed;
            state.live_key_velocities[track_index] = pressed_velocities;
        } else {
            state.live_key_states[track_index] = [_]bool{false} ** 128;
            state.live_key_velocities[track_index] = [_]f32{0.0} ** 128;
        }
    }
}
