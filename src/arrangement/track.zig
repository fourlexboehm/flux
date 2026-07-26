const std = @import("std");
const arr_clip = @import("clip.zig");
const session_types = @import("../session/types.zig");

pub const ArrangementTrack = struct {
    session_track_index: usize = 0,
    clips: std.ArrayListUnmanaged(arr_clip.ArrangementClip) = .empty,
    color: [4]f32 = .{ 0.28, 0.28, 0.30, 1.0 },
    enabled: bool = true,
    name: session_types.NameField = .{},

    pub fn init(name: []const u8, session_index: usize, color: [4]f32) ArrangementTrack {
        var t = ArrangementTrack{
            .session_track_index = session_index,
            .color = color,
        };
        t.name.set(name);
        return t;
    }

    pub fn deinit(self: *ArrangementTrack, allocator: std.mem.Allocator) void {
        for (self.clips.items) |*clip| {
            clip.deinit(allocator);
        }
        self.clips.deinit(allocator);
    }
};
