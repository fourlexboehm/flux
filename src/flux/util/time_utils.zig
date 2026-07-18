const std = @import("std");

pub fn sleepNs(io: std.Io, ns: u64) void {
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromNanoseconds(@intCast(ns)) }, io) catch {};
}

pub inline fn nsSince(from: std.Io.Timestamp, to: std.Io.Timestamp) u64 {
    const ns = from.durationTo(to).toNanoseconds();
    return if (ns > 0) @intCast(ns) else 0;
}
