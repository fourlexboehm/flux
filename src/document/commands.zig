//! UI-neutral mutations for the editable document.
//!
//! Split across cmd_session / cmd_arrangement / cmd_midi / cmd_recording; this
//! file re-exports the public API and holds command unit tests.

const std = @import("std");
const model = @import("model.zig");
const session_types = @import("../session/types.zig");
const arr_ops = @import("../arrangement/ops.zig");
const session_cmd = @import("cmd_session.zig");
const arr_cmd = @import("cmd_arrangement.zig");
const midi_cmd = @import("cmd_midi.zig");
const rec_cmd = @import("cmd_recording.zig");
const undo_cmd = @import("cmd_undo.zig");

pub const syncArrangementTracks = session_cmd.syncArrangementTracks;
pub const createClip = session_cmd.createClip;
pub const toggleSlotPlayback = session_cmd.toggleSlotPlayback;
pub const launchScene = session_cmd.launchScene;
pub const selectSlot = session_cmd.selectSlot;
pub const selectSessionSlot = session_cmd.selectSessionSlot;
pub const setSessionAnchor = session_cmd.setSessionAnchor;
pub const sessionSlotSelected = session_cmd.sessionSlotSelected;
pub const sessionHasSelection = session_cmd.sessionHasSelection;
pub const sessionCanPaste = session_cmd.sessionCanPaste;
pub const copySessionSelection = session_cmd.copySessionSelection;
pub const cutSessionSelection = session_cmd.cutSessionSelection;
pub const pasteSessionSelection = session_cmd.pasteSessionSelection;
pub const deleteSessionSelection = session_cmd.deleteSessionSelection;
pub const selectAllSessionClips = session_cmd.selectAllSessionClips;
pub const canMoveSessionSelection = session_cmd.canMoveSessionSelection;
pub const moveSessionSelection = session_cmd.moveSessionSelection;
pub const duplicateSessionSelection = session_cmd.duplicateSessionSelection;
pub const addTrack = session_cmd.addTrack;
pub const addScene = session_cmd.addScene;
pub const deleteClip = session_cmd.deleteClip;
pub const setTrackVolume = session_cmd.setTrackVolume;
pub const setTrackPan = session_cmd.setTrackPan;
pub const toggleTrackMute = session_cmd.toggleTrackMute;
pub const toggleTrackSolo = session_cmd.toggleTrackSolo;
pub const toggleTrackArm = rec_cmd.toggleTrackArm;
pub const PlaybackRequests = session_cmd.PlaybackRequests;
pub const takePlaybackRequests = session_cmd.takePlaybackRequests;
pub const processQuantizedSwitches = session_cmd.processQuantizedSwitches;
pub const setPrimarySelection = session_cmd.setPrimarySelection;
pub const selectSessionSlotsInRange = session_cmd.selectSessionSlotsInRange;
pub const StopRecordingMode = rec_cmd.StopRecordingMode;
pub const OpenClipRequest = rec_cmd.OpenClipRequest;
pub const slotLengthBeats = rec_cmd.slotLengthBeats;
pub const ensureSlotPiano = rec_cmd.ensureSlotPiano;
pub const claimSlotForMidi = rec_cmd.claimSlotForMidi;
pub const startRecording = rec_cmd.startRecording;
pub const stopRecording = rec_cmd.stopRecording;
pub const cancelRecording = rec_cmd.cancelRecording;
pub const takeOpenClipRequest = rec_cmd.takeOpenClipRequest;
pub const isRecording = rec_cmd.isRecording;
pub const isActivelyRecording = rec_cmd.isActivelyRecording;
pub const hasQueuedRecording = rec_cmd.hasQueuedRecording;
pub const processRecordingQuantize = rec_cmd.processRecordingQuantize;
pub const lockSelectionToRecording = rec_cmd.lockSelectionToRecording;
pub const recordNote = rec_cmd.recordNote;
pub const setRecordingClipLength = rec_cmd.setRecordingClipLength;
pub const ArrangementLocation = arr_cmd.ArrangementLocation;
pub const arrangementLocation = arr_cmd.arrangementLocation;
pub const selectArrangementClip = arr_cmd.selectArrangementClip;
pub const selectAllArrangementClips = arr_cmd.selectAllArrangementClips;
pub const deleteArrangementClip = arr_cmd.deleteArrangementClip;
pub const duplicateArrangementClip = arr_cmd.duplicateArrangementClip;
pub const moveArrangementClip = arr_cmd.moveArrangementClip;
pub const clearArrangementSelection = arr_cmd.clearArrangementSelection;
pub const arrangementHasSelection = arr_cmd.arrangementHasSelection;
pub const arrangementClipSelected = arr_cmd.arrangementClipSelected;
pub const setArrangementClipGeometry = arr_cmd.setArrangementClipGeometry;
pub const resizeArrangementClipLeft = arr_cmd.resizeArrangementClipLeft;
pub const resizeArrangementClipRight = arr_cmd.resizeArrangementClipRight;
pub const commitArrangementEdit = arr_cmd.commitArrangementEdit;
pub const commitArrangementDrag = arr_cmd.commitArrangementDrag;
pub const duplicateArrangementClipInPlace = arr_cmd.duplicateArrangementClipInPlace;
pub const createArrangementMidiClip = arr_cmd.createArrangementMidiClip;
pub const loadAudioFileIntoSession = arr_cmd.loadAudioFileIntoSession;
pub const loadAudioFileIntoArrangement = arr_cmd.loadAudioFileIntoArrangement;
pub const deleteSelectedArrangementClips = arr_cmd.deleteSelectedArrangementClips;
pub const setArrangementSelection = arr_cmd.setArrangementSelection;
pub const midiClip = midi_cmd.midiClip;
pub const beginMidiGesture = midi_cmd.beginMidiGesture;
pub const addMidiNote = midi_cmd.addMidiNote;
pub const addMidiNotes = midi_cmd.addMidiNotes;
pub const removeMidiNote = midi_cmd.removeMidiNote;
pub const removeMidiNotes = midi_cmd.removeMidiNotes;
pub const commitMidiNoteEdit = midi_cmd.commitMidiNoteEdit;
pub const canUndoMidi = midi_cmd.canUndoMidi;
pub const canRedoMidi = midi_cmd.canRedoMidi;
pub const undoMidi = midi_cmd.undoMidi;
pub const redoMidi = midi_cmd.redoMidi;
pub const canUndo = undo_cmd.canUndo;
pub const canRedo = undo_cmd.canRedo;
pub const undo = undo_cmd.undo;
pub const redo = undo_cmd.redo;
pub const undoDescription = undo_cmd.undoDescription;
pub const redoDescription = undo_cmd.redoDescription;
pub const MidiTransform = midi_cmd.MidiTransform;
pub const transformMidiNotes = midi_cmd.transformMidiNotes;
pub const nudgeMidiNotes = midi_cmd.nudgeMidiNotes;
pub const setMidiClipLength = midi_cmd.setMidiClipLength;
pub const AutomationAddTarget = midi_cmd.AutomationAddTarget;
pub const addAutomationLane = midi_cmd.addAutomationLane;
pub const removeAutomationLane = midi_cmd.removeAutomationLane;
pub const addAutomationPoint = midi_cmd.addAutomationPoint;
pub const removeAutomationPoint = midi_cmd.removeAutomationPoint;
pub const setAutomationPointInPlace = midi_cmd.setAutomationPointInPlace;
pub const commitAutomationEdit = midi_cmd.commitAutomationEdit;
pub const clearParameterAutomation = midi_cmd.clearParameterAutomation;

test "commands mutate the store and advance its revision" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    syncArrangementTracks(&store);
    const before = store.revision;
    createClip(&store, 0, 0, 4);
    try std.testing.expect(store.revision > before);
    try std.testing.expect(!store.session.clips[0][0].clip.isNone());
}

test "persistent mixer and structure commands advance exactly on change" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();

    const initial = store.revision;
    setTrackVolume(&store, 0, store.session.tracks[0].volume);
    try std.testing.expectEqual(initial, store.revision);

    setTrackVolume(&store, 0, 0.5);
    const after_volume = store.revision;
    try std.testing.expect(after_volume > initial);

    setTrackPan(&store, 0, -0.25);
    toggleTrackMute(&store, 0);
    toggleTrackSolo(&store, 0);
    toggleTrackArm(&store, 0);
    try std.testing.expectEqual(@as(?usize, 0), store.session.armed_track);
    try std.testing.expect(store.revision >= after_volume + 4);

    const master = session_types.master_track_index;
    const before_master = store.revision;
    setTrackVolume(&store, master, 0.75);
    setTrackPan(&store, master, 0.1);
    toggleTrackMute(&store, master);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), store.session.tracks[master].volume, 0.0001);
    try std.testing.expect(store.session.tracks[master].mute);
    try std.testing.expect(store.revision >= before_master + 3);

    const before_structure = store.revision;
    try std.testing.expect(addTrack(&store));
    try std.testing.expect(addScene(&store));
    try std.testing.expect(store.revision >= before_structure + 2);
}

test "piano-roll commands mutate notes and revision" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    createClip(&store, 0, 0, 4);
    const before = store.revision;
    const index = addMidiNote(&store, 0, 0, .{ .pitch = 60, .start = 1, .duration = 0.5 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), index);
    try std.testing.expect(store.revision == before + 1);
    try std.testing.expect(removeMidiNote(&store, 0, 0, index));
    try std.testing.expect(store.revision == before + 2);
}

test "piano-roll bulk transforms preserve a single revision boundary" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    createClip(&store, 0, 0, 4);
    _ = addMidiNote(&store, 0, 0, .{ .pitch = 60, .start = 0.3, .duration = 0.5 });
    _ = addMidiNote(&store, 0, 0, .{ .pitch = 64, .start = 1.2, .duration = 0.5 });
    const before = store.revision;
    try std.testing.expect(transformMidiNotes(&store, 0, 0, &.{ 0, 1 }, .quantize, 0.5));
    try std.testing.expectEqual(before + 1, store.revision);
    try std.testing.expect(transformMidiNotes(&store, 0, 0, &.{ 0, 1 }, .duplicate, 0.5));
    try std.testing.expectEqual(@as(usize, 4), midiClip(&store, 0, 0).?.notes.items.len);
}

test "startRecording materializes MIDI and arms record_queued when playing" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();

    const before = store.revision;
    startRecording(&store, 0, 0, true, 1.5, 4.0);
    try std.testing.expect(store.revision > before);
    try std.testing.expectEqual(@as(?usize, 0), store.session.recording.track);
    try std.testing.expectEqual(@as(?usize, 0), store.session.recording.scene);
    try std.testing.expect(store.session.clips[0][0].state == .record_queued);
    try std.testing.expect(store.slotMidiClip(0, 0) != null);
    try std.testing.expect(store.session.recording.is_new_clip);

    processRecordingQuantize(&store, 2.0);
    try std.testing.expect(store.session.clips[0][0].state == .recording);
    try std.testing.expectEqual(@as(f32, 2.0), store.session.recording.start_beat);

    recordNote(&store, 0, 0, 60, 0.0, 0.5, 0.9);
    try std.testing.expectEqual(@as(usize, 1), store.slotMidiClip(0, 0).?.notes.items.len);

    stopRecording(&store, .loop);
    // Active recording defers finalize; clip leaves recording state.
    try std.testing.expect(store.session.clips[0][0].state == .playing);
    try std.testing.expectEqual(@as(?usize, 0), store.session.finalize_recording_track);
}

test "startRecording when stopped begins immediately and requests playback" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();

    startRecording(&store, 1, 2, false, 0, 4.0);
    try std.testing.expect(store.session.clips[1][2].state == .recording);
    try std.testing.expect(store.session.start_playback_request);
    try std.testing.expect(store.session.reset_playhead_request);
    try std.testing.expectEqual(@as(?usize, 1), store.session.recording.track);
    try std.testing.expectEqual(@as(?usize, 2), store.session.recording.scene);
    const open = takeOpenClipRequest(&store);
    try std.testing.expect(open != null);
    try std.testing.expectEqual(@as(usize, 1), open.?.track);
    try std.testing.expectEqual(@as(usize, 2), open.?.scene);
}

test "toggleTrackArm stops active recording" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();

    store.session.armed_track = 0;
    startRecording(&store, 0, 0, false, 0, 4.0);
    try std.testing.expect(isRecording(&store));
    toggleTrackArm(&store, 0);
    // Disarm + stop: finalize is staged for the UI tick.
    try std.testing.expectEqual(@as(?usize, null), store.session.armed_track);
    try std.testing.expectEqual(@as(?usize, 0), store.session.finalize_recording_track);
    try std.testing.expect(store.session.clips[0][0].state == .stopped);
}

test "piano-roll midi undo and redo restore notes" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    createClip(&store, 0, 0, 4);
    _ = addMidiNote(&store, 0, 0, .{ .pitch = 60, .start = 0, .duration = 1 });
    _ = addMidiNote(&store, 0, 0, .{ .pitch = 64, .start = 1, .duration = 0.5 });
    try std.testing.expect(canUndoMidi(&store));
    try std.testing.expect(undoMidi(&store));
    try std.testing.expectEqual(@as(usize, 1), midiClip(&store, 0, 0).?.notes.items.len);
    try std.testing.expect(redoMidi(&store));
    try std.testing.expectEqual(@as(usize, 2), midiClip(&store, 0, 0).?.notes.items.len);

    beginMidiGesture(&store, 0, 0);
    midiClip(&store, 0, 0).?.notes.items[0].pitch = 72;
    commitMidiNoteEdit(&store, 0, 0);
    try std.testing.expectEqual(@as(u8, 72), midiClip(&store, 0, 0).?.notes.items[0].pitch);
    try std.testing.expect(undoMidi(&store));
    try std.testing.expectEqual(@as(u8, 60), midiClip(&store, 0, 0).?.notes.items[0].pitch);
}

test "global undo covers session clips and mixer" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    createClip(&store, 0, 0, 4);
    try std.testing.expect(canUndo(&store));
    try std.testing.expect(undo(&store));
    try std.testing.expect(store.session.clips[0][0].clip.isNone());
    try std.testing.expect(redo(&store));
    try std.testing.expect(!store.session.clips[0][0].clip.isNone());

    setTrackVolume(&store, 0, 0.33);
    toggleTrackMute(&store, 0);
    try std.testing.expect(undo(&store));
    try std.testing.expect(!store.session.tracks[0].mute);
    try std.testing.expect(undo(&store));
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), store.session.tracks[0].volume, 0.0001);
}

test "piano-roll automation lanes and points advance revision" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    createClip(&store, 0, 0, 4);
    const clip = midiClip(&store, 0, 0).?;
    const before = store.revision;

    const vol = addAutomationLane(&store, 0, 0, .track_volume, 0, null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), vol);
    try std.testing.expectEqual(@as(usize, 1), clip.automation.lanes.items.len);
    try std.testing.expect(store.revision == before + 1);

    // Identical target focuses the existing lane without a second append.
    const again = addAutomationLane(&store, 0, 0, .track_volume, 0, null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(vol, again);
    try std.testing.expectEqual(@as(usize, 1), clip.automation.lanes.items.len);
    try std.testing.expectEqual(before + 1, store.revision);

    const pt = addAutomationPoint(&store, 0, 0, vol, 1.0, 0.5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), pt);
    try std.testing.expectEqual(@as(usize, 1), clip.automation.lanes.items[0].points.items.len);
    try std.testing.expectEqual(before + 2, store.revision);

    const moved = setAutomationPointInPlace(&store, 0, 0, vol, pt, 2.0, 1.5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), moved);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), clip.automation.lanes.items[0].points.items[0].time, 0.0001);
    // In-place drag does not bump until commit.
    try std.testing.expectEqual(before + 2, store.revision);
    commitAutomationEdit(&store, 0, 0);
    try std.testing.expectEqual(before + 3, store.revision);

    try std.testing.expect(removeAutomationPoint(&store, 0, 0, vol, 0));
    try std.testing.expectEqual(@as(usize, 0), clip.automation.lanes.items[0].points.items.len);
    try std.testing.expect(removeAutomationLane(&store, 0, 0, vol));
    try std.testing.expectEqual(@as(usize, 0), clip.automation.lanes.items.len);
    try std.testing.expectEqual(before + 5, store.revision);
}

test "session edit commands duplicate move copy paste and delete pooled clips" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();

    createClip(&store, 0, 0, 4);
    const original = store.session.clips[0][0].clip;
    try std.testing.expect(duplicateSessionSelection(&store));
    const duplicate = store.session.clips[0][1].clip;
    try std.testing.expect(!duplicate.isNone());
    try std.testing.expect(!duplicate.eql(original));

    try std.testing.expect(moveSessionSelection(&store, 0, 1, 1, 1));
    try std.testing.expect(store.session.clips[0][1].clip.isNone());
    try std.testing.expect(store.session.clips[1][2].clip.eql(duplicate));

    copySessionSelection(&store);
    setSessionAnchor(&store, 2, 3, true);
    try std.testing.expect(pasteSessionSelection(&store));
    const pasted = store.session.clips[2][3].clip;
    try std.testing.expect(!pasted.isNone());
    try std.testing.expect(!pasted.eql(duplicate));
    try std.testing.expect(deleteSessionSelection(&store));
    try std.testing.expect(store.session.clips[2][3].clip.isNone());
}

test "arrangement edit commands duplicate and nudge placements" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    syncArrangementTracks(&store);

    _ = try arr_ops.createClip(&store.arrangement, 0, .midi, 0, 960, "Seed");
    const duplicate = duplicateArrangementClip(&store, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), duplicate);
    try std.testing.expectEqual(@as(i64, 960), store.arrangement.tracks.items[0].clips.items[1].start_tick);

    const moved = moveArrangementClip(&store, duplicate, 1, 240) orelse return error.TestUnexpectedResult;
    const location = arrangementLocation(&store, moved) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), location.track);
    try std.testing.expectEqual(@as(i64, 1200), store.arrangement.tracks.items[1].clips.items[location.clip].start_tick);
}

test "session box range selection selects filled clips only" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    createClip(&store, 0, 0, 4);
    createClip(&store, 1, 1, 4);
    createClip(&store, 2, 2, 4);
    selectSessionSlotsInRange(&store, 0, 1, 0, 1, false);
    try std.testing.expect(sessionSlotSelected(&store, 0, 0));
    try std.testing.expect(sessionSlotSelected(&store, 1, 1));
    try std.testing.expect(!sessionSlotSelected(&store, 2, 2));
    // Empty cell in range is ignored.
    try std.testing.expect(!sessionSlotSelected(&store, 0, 1));
}

test "arrangement live geometry and box selection" {
    var store = model.Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    syncArrangementTracks(&store);

    _ = try arr_ops.createClip(&store.arrangement, 0, .midi, 0, 960, "A");
    _ = try arr_ops.createClip(&store.arrangement, 0, .midi, 1920, 960, "B");
    const rev_before = store.revision;

    const moved = setArrangementClipGeometry(&store, 0, 480, 960, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(rev_before, store.revision);
    const loc = arrangementLocation(&store, moved) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), loc.track);
    try std.testing.expectEqual(@as(i64, 480), store.arrangement.tracks.items[1].clips.items[loc.clip].start_tick);

    try std.testing.expect(resizeArrangementClipRight(&store, moved, 1440));
    try std.testing.expectEqual(@as(i64, 1440), store.arrangement.tracks.items[1].clips.items[loc.clip].duration_ticks);

    commitArrangementEdit(&store);
    try std.testing.expect(store.revision != rev_before);

    setArrangementSelection(&store, &.{ 0, 1 }, false);
    try std.testing.expect(arrangementHasSelection(&store));
    try std.testing.expect(arrangementClipSelected(&store, 0));
    try std.testing.expect(arrangementClipSelected(&store, 1));
    try std.testing.expect(deleteSelectedArrangementClips(&store));
    try std.testing.expectEqual(@as(usize, 0), store.arrangement.tracks.items[0].clips.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.arrangement.tracks.items[1].clips.items.len);

    const created = createArrangementMidiClip(&store, 0, 100) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), created);
    try std.testing.expectEqual(@as(usize, 1), store.arrangement.tracks.items[0].clips.items.len);
}
