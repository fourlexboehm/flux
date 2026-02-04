const session_constants = @import("session_view/constants.zig");
const session_playback = @import("session_view/playback.zig");
const session_recording = @import("session_view/recording.zig");
const piano_roll_types = @import("piano_roll/types.zig");
const State = @import("state.zig").State;

const beats_per_bar = session_constants.beats_per_bar;
const default_clip_bars = session_constants.default_clip_bars;

pub fn tick(state: *State, dt: f64) void {
    // Handle playhead reset request (for immediate recording start)
    if (state.session.reset_playhead_request) {
        state.session.reset_playhead_request = false;
        state.playhead_beat = 0;
    }

    // Handle recording finalization request (when manually stopping recording)
    if (state.session.finalize_recording_track) |track| {
        if (state.session.finalize_recording_scene) |scene| {
            // Finalize held notes to the specified clip
            const piano_clip = &state.piano_clips[track][scene];
            const rec = &state.session.recording;
            const clip_length = state.session.clips[track][scene].length_beats;

            // Calculate current position relative to recording start
            const current_beat = @mod(state.playhead_beat - rec.start_beat + clip_length, clip_length);

            for (0..128) |pitch| {
                if (rec.note_start_beats[pitch]) |start_beat| {
                    const p: u8 = @intCast(pitch);
                    var duration = current_beat - start_beat;
                    // Handle wrap-around
                    if (duration < 0) {
                        duration = duration + clip_length;
                    }
                    if (duration > 0.01) {
                        piano_clip.addNote(p, start_beat, duration) catch {};
                    }
                }
            }
        }
        // Clear the request and reset recording state
        state.session.finalize_recording_track = null;
        state.session.finalize_recording_scene = null;
        state.session.recording.reset();
    }

    if (!state.playing) {
        // Update previous_key_states even when not playing
        state.previous_key_states = state.live_key_states;
        return;
    }

    const beats_per_second = state.bpm / 60.0;
    const prev_beat = state.playhead_beat;
    state.playhead_beat += @as(f32, @floatCast(dt)) * @as(f32, @floatCast(beats_per_second));

    // Check quantize boundary for scene switches
    const quantize_beats = piano_roll_types.quantizeIndexToBeats(state.quantize_index);
    const prev_quantize = @floor(prev_beat / quantize_beats);
    const curr_quantize = @floor(state.playhead_beat / quantize_beats);

    if (curr_quantize > prev_quantize) {
        session_playback.processQuantizedSwitches(&state.session);

        // Start queued recording at quantize boundary (not waiting for loop)
        if (session_recording.hasQueuedRecording(&state.session)) {
            // Calculate the beat position at the quantize boundary
            const quantize_boundary = curr_quantize * quantize_beats;
            session_recording.processRecordingQuantize(&state.session, quantize_boundary);
        }
    }

    // Fallback: ensure queued recordings start at the next quantize boundary after being armed.
    if (session_recording.hasQueuedRecording(&state.session)) {
        if (state.session.recording.track) |track| {
            if (state.session.recording.scene) |scene| {
                const queued_at = state.session.recording.queued_at_beat;
                const next_boundary = (@floor(queued_at / quantize_beats) + 1) * quantize_beats;
                if (state.session.clips[track][scene].state == .record_queued and state.playhead_beat >= next_boundary) {
                    session_recording.processRecordingQuantize(&state.session, next_boundary);
                }
            }
        }
    }

    // Determine loop length (use recording clip if recording, otherwise current clip)
    var loop_length = if (state.session.recording.track) |t|
        if (state.session.recording.scene) |s|
            state.session.clips[t][s].length_beats
        else
            state.currentClip().length_beats
    else
        state.currentClip().length_beats;

    // Check if playhead is about to loop
    var will_loop = state.playhead_beat >= loop_length;

    // Grow new recording clips instead of looping at the default length.
    if (will_loop) {
        if (state.session.recording.track) |track| {
            if (state.session.recording.scene) |scene| {
                if (state.session.recording.is_new_clip and state.session.clips[track][scene].state == .recording) {
                    const extend_beats = default_clip_bars * beats_per_bar;
                    while (state.playhead_beat >= loop_length) {
                        loop_length += extend_beats;
                    }
                    state.session.clips[track][scene].length_beats = loop_length;
                    state.piano_clips[track][scene].length_beats = loop_length;
                    state.session.recording.target_length_beats = loop_length;
                    will_loop = false;
                }
            }
        }
    }

    // Process MIDI recording (before loop so we can finalize held notes at loop point)
    if (session_recording.isActivelyRecording(&state.session)) {
        // If about to loop, finalize any held notes at the end of the clip
        if (will_loop) {
            finalizeHeldNotesAtPosition(state, loop_length);
        }
        processRecordingMidi(state);
    }

    // Update previous_key_states at end of frame
    state.previous_key_states = state.live_key_states;

    // Handle playhead looping
    if (will_loop) {
        // At clip loop boundary, start queued recording BEFORE wrapping
        if (session_recording.hasQueuedRecording(&state.session)) {
            session_recording.processRecordingQuantize(&state.session, 0);
        }

        state.playhead_beat = @mod(state.playhead_beat, loop_length);

        // If actively recording and we just looped
        if (state.session.recording.track) |track| {
            if (state.session.recording.scene) |scene| {
                // Transition from recording to playing (overdub mode)
                // This allows the clip to play back recorded notes while continuing to record
                if (state.session.clips[track][scene].state == .recording and !state.session.recording.is_new_clip) {
                    state.session.clips[track][scene].state = .playing;
                }

                // Reset recording start beat to 0 for subsequent passes
                // This ensures notes are recorded at correct positions after the first loop
                state.session.recording.start_beat = 0;

                // Reset note tracking for new pass - held notes start fresh from beat 0
                const rec = &state.session.recording;
                for (0..128) |pitch| {
                    if (rec.note_start_beats[pitch] != null) {
                        rec.note_start_beats[pitch] = 0;
                    }
                }
            }
        }
    }
}

/// Process MIDI note recording from keyboard input
fn processRecordingMidi(state: *State) void {
    const rec = &state.session.recording;
    const track = rec.track orelse return;
    const scene = rec.scene orelse return;

    const piano_clip = &state.piano_clips[track][scene];
    const clip_length = state.session.clips[track][scene].length_beats;

    // Calculate position within the clip (relative to recording start)
    // This ensures notes are placed at the beginning of the clip, not at absolute playhead position
    const current_beat = @mod(state.playhead_beat - rec.start_beat + clip_length, clip_length);

    // Compare current and previous key states
    for (0..128) |pitch| {
        const p: u8 = @intCast(pitch);
        const is_pressed = state.live_key_states[track][pitch];
        const was_pressed = state.previous_key_states[track][pitch];

        if (is_pressed and !was_pressed) {
            // Note on: store start beat (using position within clip)
            rec.note_start_beats[pitch] = current_beat;
            rec.note_start_velocities[pitch] = state.live_key_velocities[track][pitch];
        } else if (!is_pressed and was_pressed) {
            // Note off: create note
            if (rec.note_start_beats[pitch]) |start_beat| {
                const velocity = rec.note_start_velocities[pitch] orelse 0.8;
                var duration = current_beat - start_beat;
                // Handle wrap-around (note started near end of clip, ended after loop)
                if (duration < 0) {
                    duration = duration + clip_length;
                }
                if (duration > 0.01) { // Minimum note duration
                    piano_clip.addNoteWithVelocity(p, start_beat, duration, velocity, 0.8) catch {};
                }
                rec.note_start_beats[pitch] = null;
                rec.note_start_velocities[pitch] = null;
            }
        }
    }
}

/// Finalize held notes at a specific position (used at loop boundary)
fn finalizeHeldNotesAtPosition(state: *State, end_beat: f32) void {
    const rec = &state.session.recording;
    const track = rec.track orelse return;
    const scene = rec.scene orelse return;

    const piano_clip = &state.piano_clips[track][scene];
    const clip_length = state.session.clips[track][scene].length_beats;

    // Calculate end position relative to recording start
    const relative_end = @mod(end_beat - rec.start_beat + clip_length, clip_length);

    // Finalize all held notes at the specified position
    for (0..128) |pitch| {
        if (rec.note_start_beats[pitch]) |start_beat| {
            const p: u8 = @intCast(pitch);
            const velocity = rec.note_start_velocities[pitch] orelse 0.8;
            var duration = relative_end - start_beat;
            // Handle wrap-around
            if (duration < 0) {
                duration = duration + clip_length;
            }
            if (duration > 0.01) {
                piano_clip.addNoteWithVelocity(p, start_beat, duration, velocity, 0.8) catch {};
            }
            // Don't clear note_start_beats here - the loop handler will reset them to 0
        }
    }
}

/// Finalize any notes that are still held when recording stops
pub fn finalizeHeldNotes(state: *State) void {
    const rec = &state.session.recording;
    const track = rec.track orelse return;
    const scene = rec.scene orelse return;

    const piano_clip = &state.piano_clips[track][scene];
    const clip_length = state.session.clips[track][scene].length_beats;

    // Calculate current position relative to recording start
    const current_beat = @mod(state.playhead_beat - rec.start_beat + clip_length, clip_length);

    // Finalize all held notes at current position
    for (0..128) |pitch| {
        if (rec.note_start_beats[pitch]) |start_beat| {
            const p: u8 = @intCast(pitch);
            const velocity = rec.note_start_velocities[pitch] orelse 0.8;
            var duration = current_beat - start_beat;
            // Handle wrap-around
            if (duration < 0) {
                duration = duration + clip_length;
            }
            if (duration > 0.01) {
                piano_clip.addNoteWithVelocity(p, start_beat, duration, velocity, 0.8) catch {};
            }
            rec.note_start_beats[pitch] = null;
            rec.note_start_velocities[pitch] = null;
        }
    }
}
