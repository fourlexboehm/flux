const session_view = @import("../session_view.zig");
const ops = @import("ops.zig");
const constants = @import("constants.zig");

const beats_per_bar = constants.beats_per_bar;
const default_clip_bars = constants.default_clip_bars;

/// Start recording on a clip slot
pub fn startRecording(self: *session_view.SessionView, track: usize, scene: usize, playing: bool, playhead_beat: f32) void {
    // If already recording somewhere else, stop it first
    if (self.recording.isRecording()) {
        stopRecording(self, .stop);
    }

    // Create clip if empty, set to recording state
    if (self.clips[track][scene].state == .empty) {
        self.clips[track][scene] = .{
            .state = if (playing) .record_queued else .recording,
            .length_beats = default_clip_bars * beats_per_bar,
        };
        // Request to clear any old notes in the piano clip (new recording, not overdub)
        self.clear_piano_clip_request = .{ .track = track, .scene = scene };
        self.recording.is_new_clip = true;
    } else {
        // Overdub mode - don't clear existing notes
        self.clips[track][scene].state = if (playing) .record_queued else .recording;
        self.recording.is_new_clip = false;
    }

    // Set up recording state
    self.recording.track = track;
    self.recording.scene = scene;
    self.recording.target_length_beats = self.clips[track][scene].length_beats;
    self.recording.note_start_beats = [_]?f32{null} ** 128;
    self.recording.start_beat = 0;
    self.recording.queued_at_beat = playhead_beat;

    if (!playing) {
        // Start immediately - playhead will be reset to 0
        self.start_playback_request = true;
        self.reset_playhead_request = true;
    }

    // Stop any other playing clips on this track and queue this scene
    for (0..self.scene_count) |s| {
        if (s != scene and self.clips[track][s].state == .playing) {
            self.clips[track][s].state = .stopped;
        }
    }
    self.queued_scene[track] = scene;

    // Select and focus this clip
    ops.selectOnly(self, track, scene);
    self.primary_track = track;
    self.primary_scene = scene;

    // Open clip viewer to see recording
    self.open_clip_request = .{ .track = track, .scene = scene };
}

/// Stop recording and finalize the clip
pub fn stopRecording(self: *session_view.SessionView, mode: session_view.StopRecordingMode) void {
    if (self.recording.track) |track| {
        if (self.recording.scene) |scene| {
            // Request finalization of held notes (handled in ui/recording.zig tick)
            if (self.clips[track][scene].state == .recording) {
                self.finalize_recording_track = track;
                self.finalize_recording_scene = scene;
                self.clips[track][scene].state = if (mode == .loop) .playing else .stopped;
                // Don't reset recording state yet - tick() will handle it after finalizing notes
                return;
            } else if (self.clips[track][scene].state == .record_queued) {
                // If still queued, just go back to stopped (no notes to finalize)
                self.clips[track][scene].state = .stopped;
            }
        }
    }
    // Reset recording state immediately if not actively recording
    self.recording.reset();
}

/// Cancel recording without finalizing
pub fn cancelRecording(self: *session_view.SessionView) void {
    if (self.recording.track) |track| {
        if (self.recording.scene) |scene| {
            // If the clip was empty before, reset it
            if (self.clips[track][scene].state == .record_queued) {
                self.clips[track][scene].state = .empty;
            } else if (self.clips[track][scene].state == .recording) {
                self.clips[track][scene].state = .stopped;
            }
        }
    }
    self.recording.reset();
}

/// Process quantized recording start (called from tick at quantize boundary)
pub fn processRecordingQuantize(self: *session_view.SessionView, playhead_beat: f32) void {
    if (self.recording.track) |track| {
        if (self.recording.scene) |scene| {
            if (self.clips[track][scene].state == .record_queued) {
                // Transition to recording state
                self.clips[track][scene].state = .recording;
                self.recording.start_beat = playhead_beat;
            }
        }
    }
}

/// Check if recording has completed (4 bars elapsed)
pub fn checkRecordingComplete(self: *session_view.SessionView, playhead_beat: f32) bool {
    if (!self.recording.isRecording()) return false;
    if (self.recording.track) |track| {
        if (self.recording.scene) |scene| {
            if (self.clips[track][scene].state == .recording) {
                const elapsed = playhead_beat - self.recording.start_beat;
                if (elapsed >= self.recording.target_length_beats) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Get elapsed recording beats for progress display
pub fn getRecordingProgress(self: *session_view.SessionView, playhead_beat: f32) f32 {
    if (!self.recording.isRecording()) return 0;
    if (self.clips[self.recording.track.?][self.recording.scene.?].state != .recording) return 0;
    const elapsed = playhead_beat - self.recording.start_beat;
    return @min(1.0, elapsed / self.recording.target_length_beats);
}

/// Check if we have a recording in record_queued state
pub fn hasQueuedRecording(self: *session_view.SessionView) bool {
    if (self.recording.track) |track| {
        if (self.recording.scene) |scene| {
            return self.clips[track][scene].state == .record_queued;
        }
    }
    return false;
}

/// Check if we're actively recording (includes overdub mode where clip is playing)
pub fn isActivelyRecording(self: *session_view.SessionView) bool {
    if (self.recording.track) |track| {
        if (self.recording.scene) |scene| {
            const state = self.clips[track][scene].state;
            // Recording is active if clip is in recording state OR playing with overdub
            return state == .recording or (state == .playing and self.recording.track != null);
        }
    }
    return false;
}

/// Check if we're overdubbing (playing + recording)
pub fn isOverdubbing(self: *session_view.SessionView) bool {
    if (self.recording.track) |track| {
        if (self.recording.scene) |scene| {
            return self.clips[track][scene].state == .playing;
        }
    }
    return false;
}
