//! No-op Tracy zone API for hosts that don't enable profiling (DVUI flux-host).
//! Matches the subset of ztracy used by `audio/audio_graph.zig` / note_source.

pub const ZoneCtx = struct {
    pub fn End(_: @This()) void {}
    pub fn end(_: @This()) void {}
};

pub fn ZoneN(comptime _: anytype, comptime _: []const u8) ZoneCtx {
    return .{};
}
