//! MIDI recording document commands.
//!
//! Domain transitions live in `session/recording.zig`. This module materializes
//! pooled MIDI clips (claim/clear) and bumps revision so engine/chrome reproject.

const std = @import("std");
const model = @import("model.zig");
const session_recording = @import("../session/recording.zig");
const session_types = @import("../session/types.zig");
const session_constants = @import("../session/constants.zig");
const notes = @import("../session/notes.zig");
const session_ops = @import("../session/ops.zig");

pub const StopRecordingMode = session_types.StopRecordingMode;
pub const OpenClipRequest = session_types.OpenClipRequest;

/// Intrinsic length of the clip a slot references, or default bars when empty.
pub fn slotLengthBeats(store: *const model.Store, track: usize, scene: usize, beats_per_bar: f32) f32 {
    if (track >= store.session.track_count or scene >= store.session.scene_count) {
        return session_constants.default_clip_bars * beats_per_bar;
    }
    if (store.slotClipConst(track, scene)) |c| return c.lengthBeats();
    return session_constants.default_clip_bars * beats_per_bar;
}

/// Resolve (or materialize) the slot's MIDI content, converting a prior audio clip.
/// Returns null only on allocation failure.
pub fn ensureSlotPiano(store: *model.Store, track: usize, scene: usize) ?*notes.PianoRollClip {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return null;
    if (store.slotMidiClip(track, scene)) |piano| return piano;

    const prev_len = if (store.slotClip(track, scene)) |c| c.lengthBeats() else 0;
    releaseSlotClip(store, track, scene);

    var piano = notes.PianoRollClip.init(store.allocator);
    if (prev_len > 0) piano.length_beats = prev_len;
    const id = store.clip_pool.addMidi(piano) catch {
        piano.deinit();
        return null;
    };
    store.clip_pool.retain(id);
    const slot = &store.session.clips[track][scene];
    slot.clip = id;
    if (slot.state == .empty) slot.state = .stopped;
    store.markChanged();
    return &store.clip_pool.get(id).?.content.midi;
}

fn releaseSlotClip(store: *model.Store, track: usize, scene: usize) void {
    const slot = &store.session.clips[track][scene];
    if (!slot.clip.isNone()) {
        store.clip_pool.release(slot.clip, &store.sample_store);
    }
    // Preserve launch state when converting content; only clear the handle.
    slot.clip = .none;
}

/// Exclusive MIDI ownership for the cell (drops any sample).
pub fn claimSlotForMidi(store: *model.Store, track: usize, scene: usize) void {
    _ = ensureSlotPiano(store, track, scene);
}

/// Apply pending claim/clear requests raised by `session_recording.startRecording`.
fn drainClipMaterializeRequests(store: *model.Store) void {
    if (store.session.claim_midi_slot_request) |req| {
        store.session.claim_midi_slot_request = null;
        claimSlotForMidi(store, req.track, req.scene);
    }
    if (store.session.clear_piano_clip_request) |req| {
        store.session.clear_piano_clip_request = null;
        if (ensureSlotPiano(store, req.track, req.scene)) |piano| {
            piano.clear();
        }
    }
}

/// Start recording into `(track, scene)`. Materializes the MIDI clip immediately.
pub fn startRecording(
    store: *model.Store,
    track: usize,
    scene: usize,
    playing: bool,
    playhead_beat: f32,
    beats_per_bar: f32,
) void {
    if (track >= store.session.track_count or scene >= store.session.scene_count) return;
    session_recording.startRecording(&store.session, track, scene, playing, playhead_beat, beats_per_bar);
    drainClipMaterializeRequests(store);
    // target_length may have been computed before materialize; refresh from pool.
    if (store.session.recording.track) |t| {
        if (store.session.recording.scene) |s| {
            store.session.recording.target_length_beats = slotLengthBeats(store, t, s, beats_per_bar);
        }
    }
    store.markChanged();
}

pub fn stopRecording(store: *model.Store, mode: StopRecordingMode) void {
    if (!store.session.recording.isRecording()) return;
    session_recording.stopRecording(&store.session, mode);
    store.markChanged();
}

pub fn cancelRecording(store: *model.Store) void {
    if (!store.session.recording.isRecording()) return;
    session_recording.cancelRecording(&store.session);
    store.markChanged();
}

/// Take and clear `open_clip_request` (UI opens the clip panel).
pub fn takeOpenClipRequest(store: *model.Store) ?OpenClipRequest {
    const req = store.session.open_clip_request;
    store.session.open_clip_request = null;
    return req;
}

pub fn isRecording(store: *const model.Store) bool {
    return store.session.recording.isRecording();
}

pub fn isActivelyRecording(store: *model.Store) bool {
    return session_recording.isActivelyRecording(&store.session);
}

pub fn hasQueuedRecording(store: *model.Store) bool {
    return session_recording.hasQueuedRecording(&store.session);
}

pub fn processRecordingQuantize(store: *model.Store, playhead_beat: f32) void {
    if (!hasQueuedRecording(store)) return;
    session_recording.processRecordingQuantize(&store.session, playhead_beat);
    store.markChanged();
}

/// Arm toggle with zgui parity: stop any active recording when arm changes.
pub fn toggleTrackArm(store: *model.Store, track: usize) void {
    if (track >= store.session.track_count) return;
    if (store.session.recording.isRecording()) {
        session_recording.stopRecording(&store.session, .stop);
    }
    store.session.armed_track = if (store.session.armed_track == track) null else track;
    store.markChanged();
}

/// Lock selection to the active recording clip (avoids cross-clip input confusion).
pub fn lockSelectionToRecording(store: *model.Store) void {
    if (store.session.recording.track) |track| {
        if (store.session.recording.scene) |scene| {
            if (store.session.primary_track != track or store.session.primary_scene != scene) {
                session_ops.selectOnly(&store.session, track, scene);
            }
        }
    }
}

/// Append a note during live recording (no midi_history entry — zgui parity).
pub fn recordNote(
    store: *model.Store,
    track: usize,
    scene: usize,
    pitch: u8,
    start: f32,
    duration: f32,
    velocity: f32,
) void {
    const piano = ensureSlotPiano(store, track, scene) orelse return;
    piano.addNoteWithVelocity(pitch, start, duration, velocity, 0.8) catch {};
    store.markChanged();
}

/// Grow a new recording clip's length (first-pass free-grow, not loop).
pub fn setRecordingClipLength(store: *model.Store, track: usize, scene: usize, length_beats: f32) void {
    const piano = ensureSlotPiano(store, track, scene) orelse return;
    if (piano.length_beats == length_beats) return;
    piano.length_beats = length_beats;
    store.session.recording.target_length_beats = length_beats;
    store.markChanged();
}
