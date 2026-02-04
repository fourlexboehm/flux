const session_view = @import("../session_view.zig");
const ops = @import("ops.zig");
const recording_impl = @import("recording.zig");

pub fn launchScene(self: *session_view.SessionView, scene: usize, playing: bool) void {
    if (playing) {
        // Queue all tracks
        for (0..self.track_count) |t| {
            if (self.recording.track) |rec_track| {
                if (self.recording.scene) |rec_scene| {
                    if (rec_track == t and rec_scene != scene) {
                        recording_impl.stopRecording(self, .stop);
                    }
                }
            }
            for (0..self.scene_count) |s| {
                if (self.clips[t][s].state == .queued) {
                    self.clips[t][s].state = .stopped;
                }
            }
            if (self.clips[t][scene].state != .empty) {
                self.clips[t][scene].state = .queued;
            }
            // Always queue the scene switch - this ensures clips in other scenes
            // are stopped even if this track has no clip in the target scene
            self.queued_scene[t] = scene;
        }
    } else {
        // Immediate switch and start playback
        for (0..self.track_count) |t| {
            if (self.recording.track) |rec_track| {
                if (self.recording.scene) |rec_scene| {
                    if (rec_track == t and rec_scene != scene) {
                        recording_impl.stopRecording(self, .stop);
                    }
                }
            }
            for (0..self.scene_count) |s| {
                if (self.clips[t][s].state != .empty) {
                    self.clips[t][s].state = if (s == scene) .playing else .stopped;
                }
            }
        }
        self.start_playback_request = true;
    }
}

pub fn toggleClipPlayback(self: *session_view.SessionView, track: usize, scene: usize, playing: bool) void {
    if (self.recording.track) |rec_track| {
        if (self.recording.scene) |rec_scene| {
            if (rec_track == track and rec_scene != scene) {
                recording_impl.stopRecording(self, .stop);
            }
        }
    }

    const slot = &self.clips[track][scene];

    self.primary_track = track;
    self.primary_scene = scene;

    // Empty slot = stop this track
    if (slot.state == .empty) {
        ops.clearSelection(self);
        // Stop all clips in this track
        for (0..self.scene_count) |s| {
            if (self.clips[track][s].state == .playing or self.clips[track][s].state == .queued) {
                self.clips[track][s].state = .stopped;
            }
        }
        self.queued_scene[track] = null;
        return;
    }

    // Also select/focus this clip
    ops.selectOnly(self, track, scene);

    if (slot.state == .playing) {
        slot.state = .stopped;
        self.queued_scene[track] = null;
    } else if (slot.state == .queued) {
        slot.state = .stopped;
        self.queued_scene[track] = null;
    } else if (playing) {
        // Clear other queued
        for (0..self.scene_count) |s| {
            if (self.clips[track][s].state == .queued) {
                self.clips[track][s].state = .stopped;
            }
        }
        slot.state = .queued;
        self.queued_scene[track] = scene;
    } else {
        // Immediate switch and start playback
        for (0..self.scene_count) |s| {
            if (self.clips[track][s].state != .empty) {
                self.clips[track][s].state = if (s == scene) .playing else .stopped;
            }
        }
        self.start_playback_request = true;
    }
}

/// Process quantized scene switches (called from tick)
pub fn processQuantizedSwitches(self: *session_view.SessionView) void {
    for (0..self.track_count) |track| {
        if (self.queued_scene[track]) |queued| {
            for (0..self.scene_count) |scene| {
                const state = self.clips[track][scene].state;
                // Don't touch empty, recording, or record_queued clips
                if (state != .empty and state != .recording and state != .record_queued) {
                    self.clips[track][scene].state = if (scene == queued) .playing else .stopped;
                }
            }
            if (track == self.primary_track and queued == self.primary_scene) {
                self.reset_playhead_request = true;
            }
            self.queued_scene[track] = null;
        }
    }
}
