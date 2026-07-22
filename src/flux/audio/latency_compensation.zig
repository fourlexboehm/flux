const std = @import("std");
const clap = @import("clap-bindings");

/// Upper bound keeps all delay storage allocated before audio processing.
/// About 2.7 seconds at 48 kHz; excessive reports are safely clamped.
pub const max_frames: u32 = 131_072;

pub fn pluginFrames(plugin: ?*const clap.Plugin) u32 {
    const p = plugin orelse return 0;
    const raw = p.getExtension(p, clap.ext.latency.id) orelse return 0;
    const ext: *const clap.ext.latency.Plugin = @ptrCast(@alignCast(raw));
    return @min(ext.get(p), max_frames);
}

pub const StereoDelay = struct {
    left: []f32 = &.{},
    right: []f32 = &.{},
    write_pos: u32 = 0,
    delay: u32 = 0,
    warmup: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !StereoDelay {
        const left = try allocator.alloc(f32, max_frames + 1);
        errdefer allocator.free(left);
        const right = try allocator.alloc(f32, max_frames + 1);
        @memset(left, 0);
        @memset(right, 0);
        return .{ .left = left, .right = right };
    }

    pub fn deinit(self: *StereoDelay, allocator: std.mem.Allocator) void {
        if (self.left.len > 0) allocator.free(self.left);
        if (self.right.len > 0) allocator.free(self.right);
        self.* = .{};
    }

    pub fn process(self: *StereoDelay, left: []f32, right: []f32, requested_delay: u32) void {
        const new_delay = @min(requested_delay, max_frames);
        if (new_delay == 0) {
            self.delay = 0;
            self.warmup = 0;
            return;
        }
        if (new_delay != self.delay) {
            self.delay = new_delay;
            self.write_pos = 0;
            self.warmup = new_delay;
        }

        const capacity: u32 = @intCast(self.left.len);
        for (left, right) |*l, *r| {
            const write = self.write_pos;
            const read = (write + capacity - self.delay) % capacity;
            const delayed_l = self.left[read];
            const delayed_r = self.right[read];
            self.left[write] = l.*;
            self.right[write] = r.*;
            if (self.warmup > 0) {
                l.* = 0;
                r.* = 0;
                self.warmup -= 1;
            } else {
                l.* = delayed_l;
                r.* = delayed_r;
            }
            self.write_pos = (write + 1) % capacity;
        }
    }
};

test "stereo delay compensates by exact frame count" {
    var delay = try StereoDelay.init(std.testing.allocator);
    defer delay.deinit(std.testing.allocator);
    var left = [_]f32{ 1, 2, 3, 4 };
    var right = left;
    delay.process(&left, &right, 2);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 1, 2 }, &left);
}
