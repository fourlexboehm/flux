//! Draw a peak-bin waveform into a screen rect (main thread / UI only).

const zgui = @import("zgui");
const peaks_mod = @import("peaks.zig");

const PeakBin = peaks_mod.PeakBin;

/// Max pixel columns for high-res PCM rebuild (stack buffer).
pub const max_detail_cols: usize = 4096;

pub const DrawArgs = struct {
    /// Top-left of waveform area
    pmin: [2]f32,
    /// Bottom-right of waveform area
    pmax: [2]f32,
    peaks: []const PeakBin,
    /// ImGui packed color (u32)
    col: u32,
    /// Vertical scale fill (0–1 of half-height)
    amp_frac: f32 = 0.88,
    /// Optional fixed peak for stable amp when comparing ranges (0 = auto)
    norm_peak: f32 = 0,
};

/// Classic DAW column style: one vertical stroke per pixel column from min/max.
pub fn drawPeaks(draw_list: zgui.DrawList, args: DrawArgs) void {
    const w = args.pmax[0] - args.pmin[0];
    const h = args.pmax[1] - args.pmin[1];
    if (w < 2.0 or h < 2.0 or args.peaks.len == 0) return;

    const peak = if (args.norm_peak > 1.0e-8) args.norm_peak else peaks_mod.peakAbs(args.peaks);
    if (peak < 1.0e-8) return;
    const inv = 1.0 / peak;

    const mid_y = args.pmin[1] + h * 0.5;
    const amp = h * 0.5 * args.amp_frac;
    const cols: usize = @intFromFloat(@floor(w));
    if (cols == 0) return;

    // Prefer 1:1 peak→column when peaks were built for this width; else interpolate
    const use_direct = args.peaks.len == cols or args.peaks.len == cols + 1;

    var x: usize = 0;
    while (x < cols) : (x += 1) {
        const b = if (use_direct and x < args.peaks.len)
            args.peaks[x]
        else blk: {
            const t = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(cols));
            var bin_i: usize = @intFromFloat(t * @as(f32, @floatFromInt(args.peaks.len)));
            if (bin_i >= args.peaks.len) bin_i = args.peaks.len - 1;
            break :blk args.peaks[bin_i];
        };

        const y_hi = mid_y - (b.max * inv) * amp;
        const y_lo = mid_y - (b.min * inv) * amp;
        var top = @min(y_hi, y_lo);
        var bot = @max(y_hi, y_lo);
        // At least 1px so silence still shows a baseline tick
        if (bot - top < 1.0) {
            top = mid_y - 0.5;
            bot = mid_y + 0.5;
        }

        const px = args.pmin[0] + @as(f32, @floatFromInt(x));
        draw_list.addLine(.{
            .p1 = .{ px, top },
            .p2 = .{ px, bot },
            .col = args.col,
            .thickness = 1.0,
        });
    }
}

/// High-res draw: rebuild one peak bin per pixel column from PCM in [frame_start, frame_end).
pub fn drawPcmRange(
    draw_list: zgui.DrawList,
    args: struct {
        pmin: [2]f32,
        pmax: [2]f32,
        pcm: []const f32,
        channels: u8,
        frame_count: u64,
        frame_start: u64,
        frame_end: u64,
        col: u32,
        amp_frac: f32 = 0.92,
        norm_peak: f32 = 0,
    },
) void {
    const w = args.pmax[0] - args.pmin[0];
    const h = args.pmax[1] - args.pmin[1];
    if (w < 2.0 or h < 2.0) return;

    var cols: usize = @intFromFloat(@floor(w));
    if (cols == 0) return;
    if (cols > max_detail_cols) cols = max_detail_cols;

    var bins: [max_detail_cols]PeakBin = undefined;
    const slice = bins[0..cols];
    peaks_mod.buildPeaksRange(
        args.pcm,
        args.channels,
        args.frame_count,
        args.frame_start,
        args.frame_end,
        slice,
    );

    drawPeaks(draw_list, .{
        .pmin = args.pmin,
        .pmax = args.pmax,
        .peaks = slice,
        .col = args.col,
        .amp_frac = args.amp_frac,
        .norm_peak = args.norm_peak,
    });
}
