//! Engine-facing UI feed — decouples `AudioEngine` from zgui / DVUI chrome.
//!
//! Both hosts (legacy `ui_zgui/state` and DVUI `ui/host` + chrome) project into
//! `EngineUiView` each frame. The engine only reads this view + session/sample
//! data; it never imports UI modules.

const std = @import("std");
const session_view = @import("../session/types.zig");
const session_constants = @import("../session/constants.zig");
const clip_pool_mod = @import("../session/clip_pool.zig");
const audio_clip_types = @import("../session/audio_clip.zig");
const piano_roll_types = @import("../session/notes.zig");
const sample_store_mod = @import("sample_store.zig");

pub const max_tracks = session_constants.max_tracks;
pub const max_scenes = session_constants.max_scenes;
/// Engine / graph FX chain depth (zgui path used 4).
pub const max_fx_slots: usize = 4;
pub const max_controller_param_writes: usize = 64;

pub const ControllerParamWrite = struct {
    track_index: u8,
    target_fx_index: i8, // -1 for instrument
    param_id: u32,
    value: f64,
};

pub const SessionView = session_view.SessionView;
pub const SampleStore = sample_store_mod.SampleStore;
pub const AudioClip = audio_clip_types.AudioClip;
pub const PianoRollClip = piano_roll_types.PianoRollClip;
pub const ClipPool = clip_pool_mod.ClipPool;

/// Main-thread snapshot published into the RT double-buffer each frame.
/// Pointers must remain valid for the duration of `updateFromUi`.
pub const EngineUiView = struct {
    playing: bool,
    metronome_enabled: bool,
    bpm: f32,
    time_signature_numerator: u8,
    time_signature_denominator: u8,
    playhead_beat: f32,

    session: *SessionView,
    sample_store: *SampleStore,

    track_instrument_enabled: *const [max_tracks]bool,
    track_fx_enabled: *const [max_tracks][max_fx_slots]bool,

    live_key_states: *const [max_tracks][128]bool,
    live_key_velocities: *const [max_tracks][128]f32,

    controller_param_writes: []const ControllerParamWrite,

    /// Pooled clip for a session slot, or null when empty/stale.
    pub fn slotClip(self: *EngineUiView, track: usize, scene: usize) ?*clip_pool_mod.Clip {
        return self.session.clip_pool.get(self.session.clips[track][scene].clip);
    }

    pub fn slotPiano(self: *EngineUiView, track: usize, scene: usize) ?*PianoRollClip {
        if (self.slotClip(track, scene)) |c| {
            if (c.content == .midi) return &c.content.midi;
        }
        return null;
    }

    pub fn slotAudio(self: *EngineUiView, track: usize, scene: usize) ?*AudioClip {
        if (self.slotClip(track, scene)) |c| {
            if (c.content == .audio) return &c.content.audio;
        }
        return null;
    }
};
