const std = @import("std");
const session_types = @import("../session/types.zig");
const notes = @import("../session/notes.zig");

pub const ClipKind = enum {
    audio,
    midi,
};

pub const ArrangementClip = struct {
    start_tick: i64 = 0,
    duration_ticks: i64 = 960 * 4 * 4, // 4 bars at 4/4 default
    color: [4]f32 = .{ 0.35, 0.35, 0.45, 1.0 },
    name: session_types.NameField = .{},
    enabled: bool = true,
    kind: ClipKind = .audio,
    selected: bool = false,

    audio_path: ?[]u8 = null,

    midi_session_track: usize = 0,
    midi_session_scene: usize = 0,
    midi: ?notes.PianoRollClip = null,

    // Request flags
    duplicate_request: bool = false,
    delete_request: bool = false,

    pub fn init(allocator: std.mem.Allocator, kind: ClipKind, start_tick: i64, duration_ticks: i64) ArrangementClip {
        var clip: ArrangementClip = .{
            .kind = kind,
            .start_tick = start_tick,
            .duration_ticks = duration_ticks,
        };
        if (kind == .midi) {
            clip.midi = notes.PianoRollClip.init(allocator);
            clip.midi.?.length_beats = @as(f32, @floatFromInt(duration_ticks)) / 960.0;
        }
        return clip;
    }

    pub fn deinit(self: *ArrangementClip, allocator: std.mem.Allocator) void {
        if (self.audio_path) |path| {
            allocator.free(path);
            self.audio_path = null;
        }
        if (self.midi) |*midi| {
            midi.deinit();
            self.midi = null;
        }
    }

    pub fn endTick(self: *const ArrangementClip) i64 {
        return self.start_tick + self.duration_ticks;
    }
};
