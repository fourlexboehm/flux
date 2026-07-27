const std = @import("std");
const arr_clip = @import("clip.zig");
const session_types = @import("../session/types.zig");
const clip_pool = @import("../session/clip_pool.zig");
const SampleStore = @import("../audio/sample_store.zig").SampleStore;

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

    /// Release every placement's pooled clip reference, then free the list.
    /// `pool`/`store` may be null for standalone (unit-test) views.
    pub fn deinit(
        self: *ArrangementTrack,
        allocator: std.mem.Allocator,
        pool: ?*clip_pool.ClipPool,
        store: ?*SampleStore,
    ) void {
        if (pool) |p| {
            for (self.clips.items) |*clip| {
                if (!clip.clip.isNone()) p.release(clip.clip, store);
            }
        }
        self.clips.deinit(allocator);
    }
};
