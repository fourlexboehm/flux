//! MIDI recording tick for the DVUI host.
//!
//! MIDI recording tick: quantize-boundary arming, hardware MIDI at
//! event timestamps, computer-keyboard edge capture, new-clip free-grow, and
//! held-note finalization. Domain transitions live in `session/recording.zig`
//! and `document/cmd_recording.zig`.

const std = @import("std");
const chrome = @import("state.zig");
const document_model = @import("../document/model.zig");
const document_commands = @import("../document/commands.zig");
const session_recording = @import("../session/recording.zig");
const session_constants = @import("../session/constants.zig");
const notes = @import("../session/notes.zig");
const midi_input = @import("../midi/input.zig");
const time_utils = @import("../util/time_utils.zig");
const plugin_host = @import("plugin_host.zig");

const max_tracks = chrome.max_tracks;
const default_clip_bars = session_constants.default_clip_bars;

/// Edge baseline for keyboard-MIDI capture (updated after each frame's tick).
var previous_key_states: [max_tracks][128]bool = @splat(@splat(false));

/// Advance playhead, process quantize/recording transitions, finalize held notes.
pub fn tick(state: *chrome.State, dt: f64) void {
    if (!document_model.ready()) {
        advancePlayheadOnly(state, dt);
        return;
    }
    const store = &document_model.g;
    const session = &store.session;

    // Handle playhead reset request (immediate recording start when stopped).
    if (session.reset_playhead_request) {
        session.reset_playhead_request = false;
        state.playhead_beat = 0;
        seedHeldNotesAtRecordingStart(state);
    }

    // Finalize held notes after stopRecording(.stop|.loop) while actively recording.
    if (session.finalize_recording_track) |track| {
        if (session.finalize_recording_scene) |scene| {
            finalizeHeldNotesAtCurrentPosition(state, track, scene);
            session.finalize_recording_track = null;
            session.finalize_recording_scene = null;
            session.recording.reset();
            store.markChanged();
        }
    }

    if (!state.playing) {
        previous_key_states = liveKeySnapshot();
        return;
    }

    const beats_per_second = state.bpm / 60.0;
    const prev_beat = state.playhead_beat;
    state.playhead_beat += @as(f32, @floatCast(dt)) * @as(f32, @floatCast(beats_per_second));

    const quantize_beats = notes.quantizeIndexToBeats(@intCast(state.quantize_index));
    const prev_quantize = @floor(prev_beat / quantize_beats);
    const curr_quantize = @floor(state.playhead_beat / quantize_beats);

    if (curr_quantize > prev_quantize) {
        document_commands.processQuantizedSwitches(store);

        if (session_recording.hasQueuedRecording(session)) {
            var recording_start = curr_quantize * quantize_beats;
            if (session.reset_playhead_request) {
                session.reset_playhead_request = false;
                state.playhead_beat = 0;
                recording_start = 0;
            }
            startQueuedRecording(state, recording_start);
        }
    }

    // Fallback: start queued recording once past the next quantize boundary.
    if (session_recording.hasQueuedRecording(session)) {
        if (session.recording.track) |track| {
            if (session.recording.scene) |scene| {
                const queued_at = session.recording.queued_at_beat;
                const next_boundary = (@floor(queued_at / quantize_beats) + 1) * quantize_beats;
                if (session.clips[track][scene].state == .record_queued and state.playhead_beat >= next_boundary) {
                    startQueuedRecording(state, next_boundary);
                }
            }
        }
    }

    var loop_length = currentLoopLength(state);
    var will_loop = state.playhead_beat >= loop_length;

    // Grow new recording clips instead of looping at the default length.
    if (will_loop) {
        if (session.recording.track) |track| {
            if (session.recording.scene) |scene| {
                if (session.recording.is_new_clip and session.clips[track][scene].state == .recording) {
                    const extend_beats = default_clip_bars * state.beatsPerBar();
                    while (state.playhead_beat >= loop_length) {
                        loop_length += extend_beats;
                    }
                    document_commands.setRecordingClipLength(store, track, scene, loop_length);
                    will_loop = false;
                }
            }
        }
    }

    if (session_recording.isActivelyRecording(session) and will_loop) {
        finalizeHeldNotesAtPosition(state, loop_length);
    }

    previous_key_states = liveKeySnapshot();

    if (will_loop) {
        if (session_recording.hasQueuedRecording(session)) {
            startQueuedRecording(state, 0);
        }

        state.playhead_beat = @mod(state.playhead_beat, loop_length);

        if (session.recording.track) |track| {
            if (session.recording.scene) |scene| {
                // Overdub: after first pass, clip plays back while still recording.
                if (session.clips[track][scene].state == .recording and !session.recording.is_new_clip) {
                    session.clips[track][scene].state = .playing;
                    store.markChanged();
                }
                session.recording.start_beat = 0;
                const rec = &session.recording;
                for (0..128) |pitch| {
                    if (rec.note_start_beats[pitch] != null) {
                        rec.note_start_beats[pitch] = 0;
                    }
                }
            }
        }
    }

    document_commands.lockSelectionToRecording(store);
}

fn advancePlayheadOnly(state: *chrome.State, dt: f64) void {
    if (!state.playing) return;
    const beats_per_second = state.bpm / 60.0;
    state.playhead_beat += @as(f32, @floatCast(dt)) * @as(f32, @floatCast(beats_per_second));
}

/// Record hardware MIDI at capture time (not quantized to the UI tick).
pub fn processMidiEvents(state: *chrome.State, events: []const midi_input.MidiEvent, now: std.Io.Timestamp) void {
    if (!document_model.ready()) return;
    const store = &document_model.g;
    if (!session_recording.isActivelyRecording(&store.session)) return;
    const rec = &store.session.recording;
    const track = rec.track orelse return;
    const scene = rec.scene orelse return;
    const clip_length = document_commands.slotLengthBeats(store, track, scene, state.beatsPerBar());
    if (clip_length <= 0) return;
    const beats_per_ns = @as(f64, state.bpm) / (60.0 * std.time.ns_per_s);

    for (events) |event| {
        const message = event.message();
        if (message != 0x80 and message != 0x90) continue;
        const pitch = event.data1;
        if (pitch >= 128) continue;

        const age_beats = @as(f64, @floatFromInt(time_utils.nsSince(event.timestamp, now))) * beats_per_ns;
        const event_beat = @as(f64, state.playhead_beat) - age_beats;
        const relative = event_beat - @as(f64, rec.start_beat);
        if (relative < 0) continue;
        const position: f32 = @floatCast(@mod(relative, @as(f64, clip_length)));
        const is_note_on = message == 0x90 and event.data2 != 0;

        // Prevent the keyboard-edge fallback from recording this event again.
        if (track < max_tracks) previous_key_states[track][pitch] = is_note_on;

        if (is_note_on) {
            rec.note_start_beats[pitch] = position;
            rec.note_start_velocities[pitch] = @as(f32, @floatFromInt(event.data2)) / 127.0;
        } else if (rec.note_start_beats[pitch]) |start_beat| {
            var duration = position - start_beat;
            if (duration < 0) duration += clip_length;
            if (duration > 0.01) {
                const vel = rec.note_start_velocities[pitch] orelse 0.8;
                document_commands.recordNote(store, track, scene, pitch, start_beat, duration, vel);
            }
            rec.note_start_beats[pitch] = null;
            rec.note_start_velocities[pitch] = null;
        }
    }
}

/// Process MIDI note recording from computer-keyboard (and residual live-key) edges.
pub fn processKeyboardEvents(state: *chrome.State) void {
    if (!document_model.ready()) return;
    const store = &document_model.g;
    if (!session_recording.isActivelyRecording(&store.session)) return;
    const rec = &store.session.recording;
    const track = rec.track orelse return;
    const scene = rec.scene orelse return;
    if (track >= max_tracks) return;

    const clip_length = document_commands.slotLengthBeats(store, track, scene, state.beatsPerBar());
    if (clip_length <= 0) return;
    const current_beat = @mod(state.playhead_beat - rec.start_beat + clip_length, clip_length);
    const live = liveKeyStates(track);
    const live_vel = liveKeyVelocities(track);

    for (0..128) |pitch| {
        const p: u8 = @intCast(pitch);
        const is_pressed = live[pitch];
        const was_pressed = previous_key_states[track][pitch];

        if (is_pressed and !was_pressed) {
            rec.note_start_beats[pitch] = current_beat;
            rec.note_start_velocities[pitch] = live_vel[pitch];
        } else if (!is_pressed and was_pressed) {
            if (rec.note_start_beats[pitch]) |start_beat| {
                const velocity = rec.note_start_velocities[pitch] orelse 0.8;
                var duration = current_beat - start_beat;
                if (duration < 0) duration += clip_length;
                if (duration > 0.01) {
                    document_commands.recordNote(store, track, scene, p, start_beat, duration, velocity);
                }
                rec.note_start_beats[pitch] = null;
                rec.note_start_velocities[pitch] = null;
            }
        }
    }
    previous_key_states[track] = live.*;
}

/// Apply chrome side-effects from session requests (start play, open clip panel).
pub fn drainUiRequests(state: *chrome.State) void {
    if (!document_model.ready()) return;
    const store = &document_model.g;

    if (store.session.start_playback_request) {
        store.session.start_playback_request = false;
        if (!state.playing) {
            state.playing = true;
            state.playhead_beat = 0;
        }
    }
    // reset_playhead is handled in tick so held notes seed correctly.

    if (document_commands.takeOpenClipRequest(store)) |req| {
        state.selected_track = req.track;
        state.selected_scene = req.scene;
        state.bottom_mode = .sequencer;
        state.focused_pane = .bottom;
    }
}

fn startQueuedRecording(state: *chrome.State, start_beat: f32) void {
    document_commands.processRecordingQuantize(&document_model.g, start_beat);
    seedHeldNotesAtRecordingStart(state);
}

fn seedHeldNotesAtRecordingStart(state: *chrome.State) void {
    if (!document_model.ready()) return;
    const rec = &document_model.g.session.recording;
    const track = rec.track orelse return;
    const scene = rec.scene orelse return;
    if (track >= max_tracks) return;
    if (document_model.g.session.clips[track][scene].state != .recording) return;

    const live = liveKeyStates(track);
    const live_vel = liveKeyVelocities(track);
    for (0..128) |pitch| {
        if (live[pitch] and previous_key_states[track][pitch] and rec.note_start_beats[pitch] == null) {
            rec.note_start_beats[pitch] = 0;
            rec.note_start_velocities[pitch] = live_vel[pitch];
        }
    }
    previous_key_states[track] = live.*;
    _ = state;
}

fn finalizeHeldNotesAtCurrentPosition(state: *chrome.State, track: usize, scene: usize) void {
    if (!document_model.ready()) return;
    const store = &document_model.g;
    const rec = &store.session.recording;
    const clip_length = document_commands.slotLengthBeats(store, track, scene, state.beatsPerBar());
    if (clip_length <= 0) return;
    const current_beat = @mod(state.playhead_beat - rec.start_beat + clip_length, clip_length);

    for (0..128) |pitch| {
        if (rec.note_start_beats[pitch]) |start_beat| {
            const p: u8 = @intCast(pitch);
            const velocity = rec.note_start_velocities[pitch] orelse 0.8;
            var duration = current_beat - start_beat;
            if (duration < 0) duration += clip_length;
            if (duration > 0.01) {
                document_commands.recordNote(store, track, scene, p, start_beat, duration, velocity);
            }
            rec.note_start_beats[pitch] = null;
            rec.note_start_velocities[pitch] = null;
        }
    }
}

fn finalizeHeldNotesAtPosition(state: *chrome.State, end_beat: f32) void {
    if (!document_model.ready()) return;
    const store = &document_model.g;
    const rec = &store.session.recording;
    const track = rec.track orelse return;
    const scene = rec.scene orelse return;
    const clip_length = document_commands.slotLengthBeats(store, track, scene, state.beatsPerBar());
    if (clip_length <= 0) return;
    const relative_end = @mod(end_beat - rec.start_beat + clip_length, clip_length);

    for (0..128) |pitch| {
        if (rec.note_start_beats[pitch]) |start_beat| {
            const p: u8 = @intCast(pitch);
            const velocity = rec.note_start_velocities[pitch] orelse 0.8;
            var duration = relative_end - start_beat;
            if (duration < 0) duration += clip_length;
            if (duration > 0.01) {
                document_commands.recordNote(store, track, scene, p, start_beat, duration, velocity);
            }
            // Loop handler resets held starts to 0; leave note_start_beats set.
        }
    }
}

fn currentLoopLength(state: *const chrome.State) f32 {
    if (!document_model.ready()) return default_clip_bars * state.beatsPerBar();
    const store = &document_model.g;
    if (store.session.recording.track) |t| {
        if (store.session.recording.scene) |s| {
            return document_commands.slotLengthBeats(store, t, s, state.beatsPerBar());
        }
    }
    const track = store.session.primary_track;
    const scene = store.session.primary_scene;
    return document_commands.slotLengthBeats(store, track, scene, state.beatsPerBar());
}

fn liveKeySnapshot() [max_tracks][128]bool {
    if (plugin_host.ready()) return plugin_host.g.live_key_states;
    return @splat(@splat(false));
}

const empty_keys: [128]bool = @splat(false);
const empty_vels: [128]f32 = @splat(0);

fn liveKeyStates(track: usize) *const [128]bool {
    if (!plugin_host.ready() or track >= plugin_host.track_count) return &empty_keys;
    return &plugin_host.g.live_key_states[track];
}

fn liveKeyVelocities(track: usize) *const [128]f32 {
    if (!plugin_host.ready() or track >= plugin_host.track_count) return &empty_vels;
    return &plugin_host.g.live_key_velocities[track];
}

/// Target track for live MIDI: armed track wins (zgui keyboard_midi parity).
pub fn midiTargetTrack(state: *const chrome.State) usize {
    if (state.armed_track) |armed| {
        if (armed < state.track_count) return armed;
    }
    return state.selected_track;
}

/// Session launcher play/record button (zgui draw_clip_slot behavior).
/// Returns true when the click was handled as a recording action (caller may
/// still need to fall through to normal play/stop for non-record cases).
pub fn handlePlayButton(
    state: *chrome.State,
    track: usize,
    scene: usize,
    slot: chrome.ClipSlot,
) enum { recording_action, play_toggle, none } {
    if (!document_model.ready()) {
        return if (slot.kind != .empty) .play_toggle else .none;
    }
    const store = &document_model.g;
    const is_recording = slot.play == .recording;
    const is_record_queued = slot.play == .record_queued;
    const is_overdubbing = slot.play == .playing and
        store.session.recording.track == track and store.session.recording.scene == scene;
    const is_armed = state.armed_track == track;
    const is_empty = slot.kind == .empty;
    const is_stopped = slot.play == .stopped or (slot.kind != .empty and slot.play == .empty);

    if (is_recording or is_record_queued or is_overdubbing) {
        store.session.armed_track = null;
        if (is_recording) {
            document_commands.stopRecording(store, .loop);
        } else if (is_overdubbing) {
            store.session.recording.reset();
            store.markChanged();
        } else {
            document_commands.cancelRecording(store);
        }
        state.selectSlot(track, scene);
        return .recording_action;
    }

    if (is_armed and (is_empty or is_stopped)) {
        document_commands.startRecording(
            store,
            track,
            scene,
            state.playing,
            state.playhead_beat,
            state.beatsPerBar(),
        );
        if (store.session.start_playback_request) {
            store.session.start_playback_request = false;
            if (!state.playing) {
                state.playing = true;
                state.playhead_beat = 0;
            }
        }
        if (document_commands.takeOpenClipRequest(store)) |req| {
            state.selected_track = req.track;
            state.selected_scene = req.scene;
            state.bottom_mode = .sequencer;
            state.focused_pane = .bottom;
        } else {
            state.selectSlot(track, scene);
        }
        return .recording_action;
    }

    return if (slot.kind != .empty) .play_toggle else .none;
}
