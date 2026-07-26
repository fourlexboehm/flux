// Session domain model — no zgui.
pub const constants = @import("constants.zig");
pub const types = @import("types.zig");
pub const ops = @import("ops.zig");
pub const playback = @import("playback.zig");
pub const recording = @import("recording.zig");
pub const notes = @import("notes.zig");
pub const audio_clip = @import("audio_clip.zig");
pub const peaks = @import("peaks.zig");
pub const selection = @import("selection.zig");

pub const max_tracks = constants.max_tracks;
pub const max_scenes = constants.max_scenes;
pub const SessionView = types.SessionView;
pub const Track = types.Track;
pub const ClipSlot = types.ClipSlot;
pub const master_track_index = types.master_track_index;
