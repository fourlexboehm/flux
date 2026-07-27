const std = @import("std");
const clip_pool = @import("../session/clip_pool.zig");

pub const ClipId = clip_pool.ClipId;
pub const ClipKind = clip_pool.ClipKind;

/// An arrangement timeline placement. It references a pooled `Clip` by handle
/// and owns only *where/how* it plays; the clip's content, intrinsic length,
/// name, color and kind live on the pooled `Clip` (resolve via the owning
/// `ArrangementView`'s `clip_pool`). Each placement holds one reference to its
/// clip (retain on create, release on remove); arrangement placements are
/// independent copies — dragging/duplicating `dupe`s into a fresh `ClipId`.
pub const ArrangementClip = struct {
    clip: ClipId = ClipId.none,
    start_tick: i64 = 0,
    duration_ticks: i64 = 960 * 4 * 4, // 4 bars at 4/4 default
    source_offset_ticks: i64 = 0,
    enabled: bool = true,
    selected: bool = false,

    pub fn endTick(self: *const ArrangementClip) i64 {
        return self.start_tick + self.duration_ticks;
    }
};
