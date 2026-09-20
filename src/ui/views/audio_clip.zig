//! Bottom-panel audio clip viewer for the DVUI host.
//! Waveform zoom/pan, markers, and peak thumbnails for the Clip panel.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const state_mod = @import("../state.zig");
const document_model = @import("../../document/model.zig");
const audio_clip_types = @import("../../session/audio_clip.zig");
const sample_store_mod = @import("../../audio/sample_store.zig");
const peaks_mod = @import("../../session/peaks.zig");

const AudioClip = audio_clip_types.AudioClip;
const SampleAsset = sample_store_mod.SampleAsset;
const SampleId = sample_store_mod.SampleId;
const PeakBin = peaks_mod.PeakBin;

const max_detail_cols: usize = 2048;
const min_span: f32 = 1.0 / 512.0;
const wave_min_h: f32 = 120;

/// Per-viewer zoom state (single bottom-panel instance).
const ViewState = struct {
    sample_id: SampleId = sample_store_mod.invalid_sample_id,
    /// Visible window start in file-normalized [0, 1)
    start: f32 = 0,
    /// Visible window length in file-normalized (0, 1]
    span: f32 = 1,
    dragging: bool = false,
    drag_start_x: f32 = 0,
    drag_start_view: f32 = 0,

    fn reset(self: *ViewState, id: SampleId) void {
        self.sample_id = id;
        self.start = 0;
        self.span = 1;
        self.dragging = false;
    }

    fn clamp(self: *ViewState) void {
        self.span = std.math.clamp(self.span, min_span, 1.0);
        self.start = std.math.clamp(self.start, 0.0, 1.0 - self.span);
    }

    fn end(self: *const ViewState) f32 {
        return self.start + self.span;
    }
};

var view_state: ViewState = .{};

pub fn draw(state: *state_mod.State) void {
    const clip = selectedAudioClip(state) orelse {
        dvui.label(@src(), "Selected audio clip is unavailable.", .{}, .{
            .color_text = theme.text_soft,
        });
        return;
    };
    const store = if (document_model.ready()) &document_model.g.sample_store else {
        dvui.label(@src(), "Document sample store is not ready.", .{}, .{
            .color_text = theme.text_soft,
        });
        return;
    };
    const sample_id = clip.sample_id orelse {
        dvui.label(@src(), "No sample — this audio clip has no media loaded.", .{}, .{
            .color_text = theme.text_soft,
            .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        });
        return;
    };
    const asset = store.get(sample_id) orelse {
        dvui.label(@src(), "Missing sample — asset is no longer in the store.", .{}, .{
            .color_text = theme.text_soft,
            .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        });
        return;
    };

    if (view_state.sample_id != sample_id) view_state.reset(sample_id);

    drawHeader(state, clip, asset);
    drawMetaRow(clip, asset);
    drawZoomToolbar();

    var canvas = dvui.box(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.cell,
        .corners = .round(tokens.radius_md),
        .border = dvui.Rect.all(1),
        .color_border = theme.grid,
        .min_size_content = .{ .h = wave_min_h },
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
    });
    defer canvas.deinit();

    const rs = canvas.data().contentRectScale();
    const area = rs.r;
    if (area.w < 4 or area.h < 4) return;

    handleWaveEvents(canvas.data(), area);

    const pad = 6 * rs.s;
    const wave: dvui.Rect.Physical = .{
        .x = area.x + pad,
        .y = area.y + pad,
        .w = area.w - 2 * pad,
        .h = area.h - 2 * pad,
    };
    if (wave.w < 2 or wave.h < 2) return;

    // Zero line
    const mid_y = wave.y + wave.h * 0.5;
    const zero: dvui.Rect.Physical = .{
        .x = wave.x,
        .y = mid_y,
        .w = wave.w,
        .h = @max(1.0, rs.s),
    };
    zero.fill(.all(0), .{ .color = theme.alpha(theme.text, 0.12) });

    const frames: u64 = asset.frame_count;
    const f0: u64 = @intFromFloat(@floor(view_state.start * @as(f32, @floatFromInt(frames))));
    const f1: u64 = @intFromFloat(@ceil(view_state.end() * @as(f32, @floatFromInt(frames))));
    const frame_start = @min(f0, frames);
    const frame_end = @min(@max(f1, frame_start + 1), frames);
    const norm = peaks_mod.peakAbs(asset.peaks[0..]);
    const wave_col = theme.alpha(theme.accent, 0.85);

    drawPcmRange(wave, asset, frame_start, frame_end, wave_col, if (norm > 1.0e-8) norm else 0);

    drawMarkers(state, clip, wave, rs.s);
    drawTimeRuler(asset, wave, rs.s);

    if (view_state.span < 0.999) {
        drawOverview(asset, area, rs.s);
    }
}

fn selectedAudioClip(state: *const state_mod.State) ?*const AudioClip {
    if (!document_model.ready()) return null;
    return document_model.g.slotAudioClipConst(state.selected_track, state.selected_scene);
}

fn drawHeader(state: *const state_mod.State, clip: *const AudioClip, asset: *const SampleAsset) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_xs },
    });
    defer row.deinit();

    const name = if (clip.name.len > 0) clip.name.get() else baseName(asset.path_in_project);
    const bars = clip.length_beats / @max(state.beatsPerBar(), 0.001);

    dvui.label(@src(), "{s}", .{name}, .{
        .font = .theme(.heading),
        .color_text = theme.text,
        .gravity_y = 0.5,
    });
    dvui.label(@src(), "  Audio  ·  {d:.2} bars  ·  {d:.2}s file", .{ bars, asset.duration_seconds }, .{
        .color_text = theme.text_dim,
        .gravity_y = 0.5,
    });

    if (clip.hasBaked()) {
        statusPill("stretch bake", 10);
    } else if (clip.algorithm) |algo| {
        if (algo.len > 0) statusPill(algo, 11);
    }
}

fn drawMetaRow(clip: *const AudioClip, asset: *const SampleAsset) void {
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_xs },
        });
        defer row.deinit();

        var rate_buf: [32]u8 = undefined;
        const rate_s = std.fmt.bufPrint(&rate_buf, "{d} Hz", .{asset.sample_rate}) catch "? Hz";
        statusPill(rate_s, 0);

        var ch_buf: [24]u8 = undefined;
        const ch_s = switch (asset.channels) {
            1 => "mono",
            2 => "stereo",
            else => std.fmt.bufPrint(&ch_buf, "{d} ch", .{asset.channels}) catch "?",
        };
        statusPill(ch_s, 1);

        var bits_buf: [24]u8 = undefined;
        const bits_s = if (asset.original_bits > 0)
            std.fmt.bufPrint(&bits_buf, "{d}-bit", .{asset.original_bits}) catch "?"
        else
            "f32 decode";
        statusPill(bits_s, 2);

        var frames_buf: [40]u8 = undefined;
        const frames_s = std.fmt.bufPrint(&frames_buf, "{d} frames", .{asset.frame_count}) catch "?";
        statusPill(frames_s, 3);

        var size_buf: [32]u8 = undefined;
        const size_s = formatBytes(&size_buf, if (asset.source_bytes) |b| b.len else asset.file_size);
        statusPill(size_s, 4);

        var warp_buf: [24]u8 = undefined;
        const warp_s = std.fmt.bufPrint(&warp_buf, "{d} warps", .{clip.warps.items.len}) catch "?";
        statusPill(warp_s, 5);
    }

    dvui.label(@src(), "{s}", .{asset.path_in_project}, .{
        .color_text = theme.text_soft,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_xs },
    });

    const src_rate: u32 = if (asset.original_sample_rate > 0) @intCast(asset.original_sample_rate) else asset.sample_rate;
    const src_ch: u32 = if (asset.original_channels > 0) @intCast(asset.original_channels) else asset.channels;
    if (asset.original_bits > 0) {
        dvui.label(@src(), "In  {d} Hz  {d} ch  {d}-bit  ->  Out  f32 interleaved @ {d} Hz  {d} ch", .{
            src_rate,
            src_ch,
            asset.original_bits,
            asset.sample_rate,
            asset.channels,
        }, .{
            .color_text = theme.text_dim,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_xs },
        });
    } else {
        dvui.label(@src(), "In  {d} Hz  {d} ch  ->  Out  f32 interleaved @ {d} Hz  {d} ch (decoded)", .{
            src_rate,
            src_ch,
            asset.sample_rate,
            asset.channels,
        }, .{
            .color_text = theme.text_dim,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_xs },
        });
    }
}

fn drawZoomToolbar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_xs },
    });
    defer row.deinit();

    var zoom_buf: [32]u8 = undefined;
    const zoom_s = std.fmt.bufPrint(&zoom_buf, "{d:.1}x", .{1.0 / view_state.span}) catch "?x";
    statusPill(zoom_s, 20);

    if (dvui.button(@src(), "Reset", .{}, .{
        .min_size_content = .{ .h = tokens.control_h },
        .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
        .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
        .corners = .round(tokens.radius_sm),
    })) {
        view_state.start = 0;
        view_state.span = 1;
    }
    if (dvui.button(@src(), "Zoom in", .{}, .{
        .min_size_content = .{ .h = tokens.control_h },
        .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
        .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
        .corners = .round(tokens.radius_sm),
    })) {
        zoomAboutMid(0.5);
    }
    if (dvui.button(@src(), "Zoom out", .{}, .{
        .min_size_content = .{ .h = tokens.control_h },
        .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
        .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
        .corners = .round(tokens.radius_sm),
    })) {
        zoomAboutMid(2.0);
    }

    dvui.label(@src(), "  Scroll = zoom  ·  Drag = pan", .{}, .{
        .color_text = theme.text_soft,
        .gravity_y = 0.5,
    });
}

fn zoomAboutMid(factor: f32) void {
    const mid = view_state.start + view_state.span * 0.5;
    view_state.span *= factor;
    view_state.clamp();
    view_state.start = mid - view_state.span * 0.5;
    view_state.clamp();
}

fn zoomAboutAnchor(anchor: f32, factor: f32, rel: f32) void {
    view_state.span *= factor;
    view_state.clamp();
    view_state.start = anchor - rel * view_state.span;
    view_state.clamp();
}

fn handleWaveEvents(wd: *dvui.WidgetData, area: dvui.Rect.Physical) void {
    for (dvui.events()) |*event| {
        if (!dvui.eventMatchSimple(event, wd) or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        switch (mouse.action) {
            .press => if (mouse.button.pointer()) {
                event.handle(@src(), wd);
                view_state.dragging = true;
                view_state.drag_start_x = mouse.p.x;
                view_state.drag_start_view = view_state.start;
                dvui.captureMouse(wd, event.num);
                dvui.cursorSet(.arrow_all);
                dvui.refresh(null, @src(), wd.id);
            },
            .motion => if (view_state.dragging and dvui.captured(wd.id)) {
                event.handle(@src(), wd);
                const inner_w = @max(area.w, 1.0);
                const dx = mouse.p.x - view_state.drag_start_x;
                const d_norm = -(dx / inner_w) * view_state.span;
                view_state.start = view_state.drag_start_view + d_norm;
                view_state.clamp();
                dvui.cursorSet(.arrow_all);
                dvui.refresh(null, @src(), wd.id);
            },
            .release => if (mouse.button.pointer() and dvui.captured(wd.id)) {
                event.handle(@src(), wd);
                view_state.dragging = false;
                dvui.captureMouse(null, event.num);
                dvui.refresh(null, @src(), wd.id);
            },
            .wheel_y => |ticks| {
                event.handle(@src(), wd);
                const inner_w = @max(area.w, 1.0);
                const rel = std.math.clamp((mouse.p.x - area.x) / inner_w, 0.0, 1.0);
                const anchor = view_state.start + rel * view_state.span;
                // Positive ticks = zoom in (match zgui scroll-up).
                const factor: f32 = if (ticks > 0) 0.85 else 1.0 / 0.85;
                zoomAboutAnchor(anchor, factor, rel);
                dvui.refresh(null, @src(), wd.id);
            },
            .position => if (view_state.span < 0.999) dvui.cursorSet(.arrow_all),
            else => {},
        }
    }
}

fn drawPcmRange(
    wave: dvui.Rect.Physical,
    asset: *const SampleAsset,
    frame_start: u64,
    frame_end: u64,
    col: dvui.Color,
    norm_peak: f32,
) void {
    var cols: usize = @intFromFloat(@floor(wave.w));
    if (cols == 0) return;
    if (cols > max_detail_cols) cols = max_detail_cols;

    var bins: [max_detail_cols]PeakBin = undefined;
    const slice = bins[0..cols];
    peaks_mod.buildPeaksRange(
        asset.pcm,
        asset.channels,
        asset.frame_count,
        frame_start,
        frame_end,
        slice,
    );
    drawPeaks(wave, slice, col, 0.92, norm_peak);
}

/// Draw classic DAW column peaks into a physical rect (session thumbnails + detail view).
///
/// Sparse peak tables (e.g. 128 bins) are not supersampled to one fill per pixel —
/// column count is capped at `2 * peaks.len` and columns span the full width.
pub fn drawPeaks(
    wave: dvui.Rect.Physical,
    peaks: []const PeakBin,
    col: dvui.Color,
    amp_frac: f32,
    norm_peak: f32,
) void {
    if (wave.w < 2 or wave.h < 2 or peaks.len == 0) return;
    const peak = if (norm_peak > 1.0e-8) norm_peak else peaks_mod.peakAbs(peaks);
    if (peak < 1.0e-8) return;
    const inv = 1.0 / peak;
    const mid_y = wave.y + wave.h * 0.5;
    const amp = wave.h * 0.5 * amp_frac;
    var cols: usize = @intFromFloat(@floor(wave.w));
    if (cols == 0) return;
    // Cap supersampling: dense multi-clip arrangements were O(pixels) fills.
    const col_cap = peaks.len * 2;
    if (cols > col_cap) cols = col_cap;
    const col_w = wave.w / @as(f32, @floatFromInt(cols));
    const use_direct = peaks.len == cols or peaks.len == cols + 1;

    var x: usize = 0;
    while (x < cols) : (x += 1) {
        const b = if (use_direct and x < peaks.len)
            peaks[x]
        else blk: {
            const t = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(cols));
            var bin_i: usize = @intFromFloat(t * @as(f32, @floatFromInt(peaks.len)));
            if (bin_i >= peaks.len) bin_i = peaks.len - 1;
            break :blk peaks[bin_i];
        };

        const y_hi = mid_y - (b.max * inv) * amp;
        const y_lo = mid_y - (b.min * inv) * amp;
        var top = @min(y_hi, y_lo);
        var bot = @max(y_hi, y_lo);
        if (bot - top < 1.0) {
            top = mid_y - 0.5;
            bot = mid_y + 0.5;
        }
        const col_rect: dvui.Rect.Physical = .{
            .x = wave.x + @as(f32, @floatFromInt(x)) * col_w,
            .y = top,
            .w = @max(1.0, col_w),
            .h = bot - top,
        };
        col_rect.fill(.all(0), .{ .color = col });
    }
}

fn beatToX(beat: f32, length: f32, origin: f32, width: f32) ?f32 {
    const t = beat / length;
    if (t < view_state.start or t > view_state.end()) return null;
    return origin + ((t - view_state.start) / view_state.span) * width;
}

fn drawMarkers(
    state: *const state_mod.State,
    clip: *const AudioClip,
    wave: dvui.Rect.Physical,
    scale: f32,
) void {
    const length = @max(clip.length_beats, 0.001);
    const loop_col = theme.colorFA(0.95, 0.78, 0.28, 0.85);
    const line_w = @max(1.5, 1.5 * scale);
    const flag_half = 5.0 * scale;

    if (clip.loop_start_beats > 0.001) {
        if (beatToX(clip.loop_start_beats, length, wave.x, wave.w)) |lx| {
            verticalLine(lx, wave.y, wave.h, line_w, loop_col);
        }
    }
    const loop_end = clip.loopEnd();
    if (loop_end > 0.001 and loop_end < length - 0.001) {
        if (beatToX(loop_end, length, wave.x, wave.w)) |lx| {
            verticalLine(lx, wave.y, wave.h, line_w, loop_col);
        }
    }

    if (clip.play_start_beats > 0.001 and clip.play_start_beats < length - 0.001) {
        if (beatToX(clip.play_start_beats, length, wave.x, wave.w)) |px| {
            verticalLine(px, wave.y, wave.h, line_w, theme.play);
            // Small down flag
            const flag: dvui.Rect.Physical = .{
                .x = px - flag_half,
                .y = wave.y,
                .w = flag_half * 2,
                .h = flag_half * 1.2,
            };
            flag.fill(.all(0), .{ .color = theme.play });
        }
    }

    // Clip-relative playhead when this slot is playing (session launcher position).
    if (state.playing) {
        const slot = state.selectedSlot();
        if ((slot.play == .playing or slot.play == .recording) and state.playhead_beat >= 0 and state.playhead_beat <= length) {
            if (beatToX(state.playhead_beat, length, wave.x, wave.w)) |px| {
                verticalLine(px, wave.y, wave.h, @max(2.0, 2.0 * scale), theme.play);
            }
        }
    }
}

fn verticalLine(x: f32, y: f32, h: f32, w: f32, color: dvui.Color) void {
    const line: dvui.Rect.Physical = .{
        .x = x - w * 0.5,
        .y = y,
        .w = w,
        .h = h,
    };
    line.fill(.all(0), .{ .color = color });
}

fn drawTimeRuler(asset: *const SampleAsset, wave: dvui.Rect.Physical, scale: f32) void {
    const dur = @max(asset.duration_seconds, 0.0001);
    const t0 = view_state.start * dur;
    const t1 = view_state.end() * dur;
    const span_s = t1 - t0;
    if (span_s <= 0) return;

    const target_ticks: f64 = 8.0;
    const raw = span_s / target_ticks;
    const exp = @floor(@log10(@max(raw, 1e-9)));
    const base = std.math.pow(f64, 10.0, exp);
    const mult = raw / base;
    const nice_mult: f64 = if (mult < 1.5) 1.0 else if (mult < 3.5) 2.0 else if (mult < 7.5) 5.0 else 10.0;
    const step: f64 = base * nice_mult;

    const tick_h = 10.0 * scale;
    var t = @ceil(t0 / step) * step;
    var guard: u32 = 0;
    while (t <= t1 + step * 0.01 and guard < 64) : ({
        t += step;
        guard += 1;
    }) {
        const u = (@as(f32, @floatCast(t)) / @as(f32, @floatCast(dur)) - view_state.start) / view_state.span;
        if (u < 0 or u > 1) continue;
        const x = wave.x + u * wave.w;
        const tick: dvui.Rect.Physical = .{
            .x = x,
            .y = wave.y + wave.h - tick_h,
            .w = @max(1.0, scale),
            .h = tick_h,
        };
        tick.fill(.all(0), .{ .color = theme.text_soft });
    }
}

fn drawOverview(asset: *const SampleAsset, area: dvui.Rect.Physical, scale: f32) void {
    const h = 18.0 * scale;
    const pad = 4.0 * scale;
    const overview: dvui.Rect.Physical = .{
        .x = area.x + pad,
        .y = area.y + area.h - h - pad,
        .w = area.w - 2 * pad,
        .h = h,
    };
    if (overview.w <= 0) return;

    overview.fill(.all(2), .{ .color = theme.colorFA(0, 0, 0, 0.35) });
    drawPeaks(overview, asset.peaks[0..], theme.alpha(theme.text, 0.4), 0.85, 0);

    const ow = overview.w;
    const vx0 = overview.x + view_state.start * ow;
    const vx1 = overview.x + view_state.end() * ow;
    const border_w = @max(1.5, 1.5 * scale);
    // Top/bottom/left/right outline for visible window
    const top: dvui.Rect.Physical = .{ .x = vx0, .y = overview.y, .w = vx1 - vx0, .h = border_w };
    const bot: dvui.Rect.Physical = .{ .x = vx0, .y = overview.y + overview.h - border_w, .w = vx1 - vx0, .h = border_w };
    const left: dvui.Rect.Physical = .{ .x = vx0, .y = overview.y, .w = border_w, .h = overview.h };
    const right: dvui.Rect.Physical = .{ .x = vx1 - border_w, .y = overview.y, .w = border_w, .h = overview.h };
    top.fill(.all(0), .{ .color = theme.selected });
    bot.fill(.all(0), .{ .color = theme.selected });
    left.fill(.all(0), .{ .color = theme.selected });
    right.fill(.all(0), .{ .color = theme.selected });
}

fn statusPill(text: []const u8, id_extra: usize) void {
    var pill = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = theme.panel,
        .margin = .{ .x = 0, .y = 0, .w = tokens.gap_xs, .h = 0 },
        .padding = .{ .x = 4, .y = 1, .w = 4, .h = 1 },
        .corners = .round(tokens.radius_sm),
        .id_extra = id_extra,
    });
    defer pill.deinit();
    dvui.labelNoFmt(@src(), text, .{}, .{
        .color_text = theme.text_dim,
        .id_extra = id_extra,
    });
}

fn formatBytes(buf: []u8, n: usize) []const u8 {
    if (n >= 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(n)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "?";
    }
    if (n >= 1024) {
        const kb = @as(f64, @floatFromInt(n)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
}

fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        if (i + 1 < path.len) return path[i + 1 ..];
    }
    if (std.mem.lastIndexOfScalar(u8, path, '\\')) |i| {
        if (i + 1 < path.len) return path[i + 1 ..];
    }
    return path;
}
