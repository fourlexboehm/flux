// UI module root - re-exports all UI components
pub const colors = @import("colors.zig");
pub const selection = @import("selection.zig");
pub const session_view = @import("session_view.zig");
pub const piano_roll = @import("piano_roll.zig");

// Re-export commonly used types
pub const Colors = colors.Colors;
pub const SessionView = session_view.SessionView;
pub const ClipState = session_view.ClipState;
pub const ClipSlot = session_view.ClipSlot;
pub const Track = session_view.Track;
pub const Scene = session_view.Scene;
pub const PianoRollClip = piano_roll.PianoRollClip;
pub const PianoRollState = piano_roll.PianoRollState;
pub const Note = piano_roll.Note;
pub const AutomationTargetKind = piano_roll.AutomationTargetKind;
pub const AutomationPoint = piano_roll.AutomationPoint;
pub const AutomationLane = piano_roll.AutomationLane;
pub const ClipAutomation = piano_roll.ClipAutomation;

// Constants
pub const max_tracks = session_view.max_tracks;
pub const max_scenes = session_view.max_scenes;
pub const beats_per_bar = session_view.beats_per_bar;
pub const default_clip_bars = session_view.default_clip_bars;
pub const total_pitches = piano_roll.total_pitches;

// Helper re-exports
pub const quantizeIndexToBeats = piano_roll.quantizeIndexToBeats;
pub const isModifierDown = selection.isModifierDown;
pub const isShiftDown = selection.isShiftDown;
pub const snapToStep = selection.snapToStep;
