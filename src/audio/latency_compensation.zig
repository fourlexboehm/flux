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
        const delay = self.delay;

        // True passthrough: do not touch the 128k-sample ring. Filling it on every
        // silent/zero-delay callback was pure serial RT tax for the common case
        // (no PDC plugins). When delay becomes non-zero later, cold-start history
        // emits silence until the ring refills — same as a fresh delay line.
        if (delay == 0) {
            self.history = 0;
            return;
        }

        const n: u32 = @intCast(left.len);
        const write = self.write_pos;

        // Steady-state fast path: `delay` is constant across the block and the
        // cold-start / sub-block / max-delay-alias branches don't apply, so the
        // whole block is two contiguous ring spans (≤2 @memcpy each, vectorized
        // by the backend) instead of a per-sample masked loop.
        //   - warm && n <= delay < max_frames: read region is entirely in the
        //     past (no overlap with the write region, no wrap-alias), so input
        //     can be stored first and the delayed span copied straight out.
        const warm = self.history >= delay;
        const fast = n <= max_frames and warm and delay >= n and delay < max_frames;
        if (!fast) {
            self.processScalar(left, right);
            return;
        }

        const start = write & ring_mask;
        copyToRing(self.left, start, left);
        copyToRing(self.right, start, right);
        const read = (write -% delay) & ring_mask;
        copyFromRing(left, self.left, read);
        copyFromRing(right, self.right, read);

        self.write_pos = write +% n;
        self.history = @min(self.history + n, max_frames);
    }

    /// Reference per-sample path. Handles cold-start fill, sub-block delays
    /// (output draws from current-block input), and the max_frames alias slot
    /// (read-before-write): cases the block-copy fast path can't express.
    fn processScalar(self: *StereoDelay, left: []f32, right: []f32) void {
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

    /// Copy `src` into the ring starting at masked index `start`, wrapping once.
    /// Requires `src.len <= max_frames` (guaranteed by the caller's fast-path gate).
    inline fn copyToRing(ring: []f32, start: u32, src: []const f32) void {
        const count = src.len;
        const first = @min(count, ring.len - start);
        @memcpy(ring[start..][0..first], src[0..first]);
        if (first < count) @memcpy(ring[0 .. count - first], src[first..]);
    }

    /// Copy a contiguous ring span starting at masked index `start` into `dst`,
    /// wrapping once. Requires `dst.len <= max_frames`.
    inline fn copyFromRing(dst: []f32, ring: []const f32, start: u32) void {
        const count = dst.len;
        const first = @min(count, ring.len - start);
        @memcpy(dst[0..first], ring[start..][0..first]);
        if (first < count) @memcpy(dst[first..], ring[0 .. count - first]);
    }
};

test "block-copy fast path matches per-sample reference" {
    // Independent oracle: matches StereoDelay (delay 0 = pure passthrough, no ring).
    const Ref = struct {
        buf: [max_frames]f32 = @splat(0),
        write: u32 = 0,
        history: u32 = 0,
        fn process(self: *@This(), sig: []f32, delay: u32) void {
            if (delay == 0) {
                self.history = 0;
                return;
            }
            for (sig) |*s| {
                const in = s.*;
                if (self.history < delay) {
                    s.* = 0;
                } else {
                    s.* = self.buf[(self.write -% delay) & ring_mask];
                }
                self.buf[self.write & ring_mask] = in;
                self.write +%= 1;
                if (self.history < max_frames) self.history += 1;
            }
        }
    };

    var opt = try StereoDelay.init(std.testing.allocator);
    defer opt.deinit(std.testing.allocator);
    var ref = Ref{};

    var prng = std.Random.DefaultPrng.init(0xDECAF);
    const rnd = prng.random();
    var scratch: [4096]f32 = undefined;
    var expected: [4096]f32 = undefined;

    for (0..500) |_| {
        const n = rnd.intRangeAtMost(usize, 1, scratch.len);
        // Bias toward delays >= n so the warm block-copy path is exercised often.
        const delay: u32 = switch (rnd.intRangeAtMost(u8, 0, 3)) {
            0 => 0,
            1 => rnd.intRangeAtMost(u32, 1, @intCast(n)),
            else => rnd.intRangeAtMost(u32, @intCast(n), 8192),
        };
        for (scratch[0..n]) |*s| s.* = rnd.float(f32) * 2 - 1;
        @memcpy(expected[0..n], scratch[0..n]);

        // Same signal on both channels; only left is compared (right mirrors it).
        var right = scratch;
        opt.process(scratch[0..n], right[0..n], delay);
        ref.process(expected[0..n], delay);
        try std.testing.expectEqualSlices(f32, expected[0..n], scratch[0..n]);
    }
}

test "stereo delay compensates by exact frame count" {
    var delay = try StereoDelay.init(std.testing.allocator);
    defer delay.deinit(std.testing.allocator);
    var left = [_]f32{ 1, 2, 3, 4 };
    var right = left;
    delay.process(&left, &right, 2);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 1, 2 }, &left);
}

test "delay 0 is pure passthrough without ring traffic" {
    var delay = try StereoDelay.init(std.testing.allocator);
    defer delay.deinit(std.testing.allocator);

    var left = [_]f32{ 10, 11, 12, 13 };
    var right = left;
    delay.process(&left, &right, 0);
    try std.testing.expectEqualSlices(f32, &.{ 10, 11, 12, 13 }, &left);
    try std.testing.expectEqual(@as(u32, 0), delay.history);
}

test "enabling delay after zero-delay cold-starts cleanly" {
    var delay = try StereoDelay.init(std.testing.allocator);
    defer delay.deinit(std.testing.allocator);

    // Zero-delay path does not fill the ring (serial RT optimization).
    var prime = [_]f32{ 10, 11, 12, 13, 14, 15, 16, 17 };
    var prime_r = prime;
    delay.process(&prime, &prime_r, 0);

    // First non-zero delay block: cold-start silence for `delay` samples, then
    // delayed output of the current block (no hole / reset of an already-delayed stream).
    var left = [_]f32{ 20, 21, 22, 23 };
    var right = left;
    delay.process(&left, &right, 2);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 20, 21 }, &left);

    // Steady state continues without a hole.
    var next = [_]f32{ 24, 25, 26, 27 };
    var next_r = next;
    delay.process(&next, &next_r, 2);
    try std.testing.expectEqualSlices(f32, &.{ 22, 23, 24, 25 }, &next);
}

test "maximum delay does not alias current input" {
    var delay = try StereoDelay.init(std.testing.allocator);
    defer delay.deinit(std.testing.allocator);

    // Seed the ring with a non-zero delay so history is kept (delay 0 skips the ring).
    var first = [_]f32{42};
    var first_r = first;
    delay.process(&first, &first_r, 1); // outputs silence, stores 42

    var zeros: [256]f32 = @splat(0);
    var zeros_r = zeros;
    // Fill remaining max_frames-1 slots at delay 1 so history saturates.
    var remaining = max_frames - 1;
    while (remaining > 0) {
        const count = @min(remaining, zeros.len);
        delay.process(zeros[0..count], zeros_r[0..count], 1);
        remaining -= @intCast(count);
    }

    // At max_frames delay, read slot is the same as write: must return the
    // value stored one full ring ago (42), not the current input (7).
    var current = [_]f32{7};
    var current_r = current;
    delay.process(&current, &current_r, max_frames);
    try std.testing.expectEqual(@as(f32, 42), current[0]);
    try std.testing.expectEqual(@as(f32, 42), current_r[0]);
}
