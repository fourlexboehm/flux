//! Fixed-size peak bins for audio clip waveform thumbnails (main thread only).

const std = @import("std");

/// Bins stored per sample asset. Enough for session-cell width; detail panel can resample later.
pub const peak_bin_count: usize = 128;

pub const PeakBin = struct {
    min: f32 = 0,
    max: f32 = 0,
};

/// Build min/max peak bins over mono-mixed PCM (interleaved).
/// Covers the full sample; warp-aware windows can come later.
pub fn buildPeaks(
    pcm: []const f32,
    channels: u8,
    frame_count: u64,
    out: *[peak_bin_count]PeakBin,
) void {
    @memset(out, PeakBin{});
    if (frame_count == 0 or channels == 0 or pcm.len == 0) return;

    const ch: usize = channels;
    const frames: usize = @intCast(@min(frame_count, pcm.len / ch));
    if (frames == 0) return;

    for (0..peak_bin_count) |i| {
        const start = (i * frames) / peak_bin_count;
        var end = ((i + 1) * frames) / peak_bin_count;
        if (end <= start) end = start + 1;
        if (end > frames) end = frames;

        var lo: f32 = 0;
        var hi: f32 = 0;
        var has = false;
        var f = start;
        while (f < end) : (f += 1) {
            var sum: f32 = 0;
            var c: usize = 0;
            while (c < ch) : (c += 1) {
                sum += pcm[f * ch + c];
            }
            const mono = sum / @as(f32, @floatFromInt(ch));
            if (!has) {
                lo = mono;
                hi = mono;
                has = true;
            } else {
                lo = @min(lo, mono);
                hi = @max(hi, mono);
            }
        }
        if (has) {
            out[i] = .{ .min = lo, .max = hi };
        }
    }
}

/// Peak absolute amplitude across bins (for draw normalization).
pub fn peakAbs(peaks: []const PeakBin) f32 {
    var p: f32 = 0;
    for (peaks) |b| {
        p = @max(p, @abs(b.min));
        p = @max(p, @abs(b.max));
    }
    return p;
}

/// Build `out.len` min/max bins over a frame sub-range (for zoomed high-res viewports).
/// `out` is filled left→right across [frame_start, frame_end).
pub fn buildPeaksRange(
    pcm: []const f32,
    channels: u8,
    frame_count: u64,
    frame_start: u64,
    frame_end: u64,
    out: []PeakBin,
) void {
    @memset(out, PeakBin{});
    if (out.len == 0 or frame_count == 0 or channels == 0 or pcm.len == 0) return;

    const ch: usize = channels;
    const frames: u64 = @min(frame_count, @as(u64, @intCast(pcm.len / ch)));
    if (frames == 0) return;

    const start = @min(frame_start, frames);
    const end = @min(@max(frame_end, start + 1), frames);
    const span = end - start;
    if (span == 0) return;

    // Cap work per column so huge zooms stay interactive (~4k frames/col max average via stride)
    const max_samples_total: u64 = @as(u64, @intCast(out.len)) * 4096;

    for (out, 0..) |*bin, i| {
        const i_u: u64 = @intCast(i);
        const n_u: u64 = @intCast(out.len);
        const b0 = start + (i_u * span) / n_u;
        var b1 = start + ((i_u + 1) * span) / n_u;
        if (b1 <= b0) b1 = b0 + 1;
        if (b1 > end) b1 = end;

        const col_span = b1 - b0;
        // Adaptive stride so total samples stay bounded
        const stride: u64 = if (span > max_samples_total)
            @max(@as(u64, 1), col_span / 4096)
        else
            1;

        var lo: f32 = 0;
        var hi: f32 = 0;
        var has = false;
        var f = b0;
        while (f < b1) : (f += stride) {
            const fi: usize = @intCast(f);
            var sum: f32 = 0;
            var c: usize = 0;
            while (c < ch) : (c += 1) {
                sum += pcm[fi * ch + c];
            }
            const mono = sum / @as(f32, @floatFromInt(ch));
            if (!has) {
                lo = mono;
                hi = mono;
                has = true;
            } else {
                lo = @min(lo, mono);
                hi = @max(hi, mono);
            }
        }
        // Always include last frame in the bin for accurate min/max at edges
        if (b1 > b0 + 1) {
            const last: usize = @intCast(b1 - 1);
            var sum: f32 = 0;
            var c: usize = 0;
            while (c < ch) : (c += 1) {
                sum += pcm[last * ch + c];
            }
            const mono = sum / @as(f32, @floatFromInt(ch));
            if (!has) {
                lo = mono;
                hi = mono;
                has = true;
            } else {
                lo = @min(lo, mono);
                hi = @max(hi, mono);
            }
        }
        if (has) bin.* = .{ .min = lo, .max = hi };
    }
}

test "buildPeaksRange zooms into second half" {
    var pcm: [256]f32 = undefined;
    for (&pcm, 0..) |*s, i| {
        s.* = @as(f32, @floatFromInt(i)) / 256.0;
    }
    var bins: [8]PeakBin = undefined;
    buildPeaksRange(&pcm, 1, 256, 128, 256, &bins);
    try std.testing.expect(bins[0].min >= 0.45);
    try std.testing.expect(bins[7].max > 0.9);
}

test "buildPeaks empty" {
    var bins: [peak_bin_count]PeakBin = undefined;
    buildPeaks(&.{}, 2, 0, &bins);
    try std.testing.expectEqual(@as(f32, 0), bins[0].min);
    try std.testing.expectEqual(@as(f32, 0), bins[0].max);
}

test "buildPeaks mono ramp" {
    // 256 frames, mono: 0 .. almost 1
    var pcm: [256]f32 = undefined;
    for (&pcm, 0..) |*s, i| {
        s.* = @as(f32, @floatFromInt(i)) / 256.0;
    }
    var bins: [peak_bin_count]PeakBin = undefined;
    buildPeaks(&pcm, 1, 256, &bins);

    try std.testing.expect(bins[0].min >= 0);
    try std.testing.expect(bins[0].max < 0.1);
    try std.testing.expect(bins[peak_bin_count - 1].max > 0.9);
    try std.testing.expect(peakAbs(&bins) > 0.9);
}

test "buildPeaks stereo uses mono mix" {
    // L = 1, R = -1 → mono 0
    var pcm: [8]f32 = .{ 1, -1, 1, -1, 1, -1, 1, -1 };
    var bins: [peak_bin_count]PeakBin = undefined;
    buildPeaks(&pcm, 2, 4, &bins);
    // All bins covering frames should be ~0
    try std.testing.expect(@abs(bins[0].min) < 0.001);
    try std.testing.expect(@abs(bins[0].max) < 0.001);
}
