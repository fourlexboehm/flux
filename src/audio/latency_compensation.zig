const std = @import("std");
const clap = @import("clap-bindings");

/// Power-of-two ring size so RT indexing is a mask, not integer modulo.
/// ~2.97s at 44.1 kHz; plugin reports above this are clamped.
pub const max_frames: u32 = 131_072;
const ring_mask: u32 = max_frames - 1;

pub fn pluginFrames(plugin: ?*const clap.Plugin) u32 {
    const p = plugin orelse return 0;
    const raw = p.getExtension(p, clap.ext.latency.id) orelse return 0;
    const ext: *const clap.ext.latency.Plugin = @ptrCast(@alignCast(raw));
    return @min(ext.get(p), max_frames);
}

/// Per-track PDC delay line.
pub const StereoDelay = struct {
    left: []f32 = &.{},
    right: []f32 = &.{},
    write_pos: u32 = 0,
    delay: u32 = 0,
    /// Samples written since init (saturates at max_frames). Used only for cold-start fill.
    history: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !StereoDelay {
        // No full-ring memset — cold-start uses `history` to output silence until filled.
        const left = try allocator.alloc(f32, max_frames);
        errdefer allocator.free(left);
        const right = try allocator.alloc(f32, max_frames);
        return .{ .left = left, .right = right };
    }

    pub fn deinit(self: *StereoDelay, allocator: std.mem.Allocator) void {
        if (self.left.len > 0) allocator.free(self.left);
        if (self.right.len > 0) allocator.free(self.right);
        self.* = .{};
    }

    pub fn process(self: *StereoDelay, left: []f32, right: []f32, requested_delay: u32) void {
        // Accept new delay immediately without resetting the ring. A reset+warmup
        // silence was causing buffer-length (or worse) audio holes whenever latency
        // fluttered or a clip/plugin enabled state changed mid-playback.
        self.delay = @min(requested_delay, max_frames);

        var write = self.write_pos;
        var history = self.history;
        const delay = self.delay;

        for (left, right) |*l, *r| {
            const w = write & ring_mask;
            const in_l = l.*;
            const in_r = r.*;

            if (delay == 0) {
                // Pass-through; ring still advanced so a later non-zero delay is continuous.
            } else if (history < delay) {
                // Cold start only — not used on delay *changes* once history is deep enough.
                l.* = 0;
                r.* = 0;
            } else {
                const read = (write -% delay) & ring_mask;
                l.* = self.left[read];
                r.* = self.right[read];
            }

            // Read first: at max_frames delay, read and write intentionally share a slot.
            self.left[w] = in_l;
            self.right[w] = in_r;
            write +%= 1;
            if (history < max_frames) history += 1;
        }

        self.write_pos = write;
        self.history = history;
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

test "delay change does not insert silence hole" {
    var delay = try StereoDelay.init(std.testing.allocator);
    defer delay.deinit(std.testing.allocator);

    // Prime history at delay 0 (pass-through, ring still fills).
    var prime = [_]f32{ 10, 11, 12, 13, 14, 15, 16, 17 };
    var prime_r = prime;
    delay.process(&prime, &prime_r, 0);

    // Switch to delay 2: must NOT zero the whole block (old bug).
    var left = [_]f32{ 20, 21, 22, 23 };
    var right = left;
    delay.process(&left, &right, 2);
    // Ring had 10..17 then 20..; read is 2 behind write → 16,17,20,21 after writing 20..23
    // write positions after prime: 8 samples. Then write 20 at pos 8, read pos 6 → 16
    try std.testing.expectEqual(@as(f32, 16), left[0]);
    try std.testing.expectEqual(@as(f32, 17), left[1]);
    try std.testing.expectEqual(@as(f32, 20), left[2]);
    try std.testing.expectEqual(@as(f32, 21), left[3]);
}

test "maximum delay does not alias current input" {
    var delay = try StereoDelay.init(std.testing.allocator);
    defer delay.deinit(std.testing.allocator);

    var first = [_]f32{42};
    var first_r = first;
    delay.process(&first, &first_r, 0);

    var zeros: [256]f32 = @splat(0);
    var zeros_r = zeros;
    var remaining = max_frames - 1;
    while (remaining > 0) {
        const count = @min(remaining, zeros.len);
        delay.process(zeros[0..count], zeros_r[0..count], 0);
        remaining -= @intCast(count);
    }

    var current = [_]f32{7};
    var current_r = current;
    delay.process(&current, &current_r, max_frames);
    try std.testing.expectEqual(@as(f32, 42), current[0]);
    try std.testing.expectEqual(@as(f32, 42), current_r[0]);
}
