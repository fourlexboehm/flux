//! Bottom-panel audio clip viewer: high-res waveform, zoom/pan, format I/O metadata.

const std = @import("std");
const zgui = @import("zgui");
const colors = @import("../colors.zig");
const tokens = @import("../tokens.zig");
const widgets = @import("../widgets.zig");
const types = @import("types.zig");
const sample_store_mod = @import("../../audio/sample_store.zig");
const draw_waveform = @import("draw_waveform.zig");
const peaks_mod = @import("peaks.zig");

const AudioClip = types.AudioClip;
const SampleStore = sample_store_mod.SampleStore;
const SampleAsset = sample_store_mod.SampleAsset;
const SampleId = sample_store_mod.SampleId;

extern fn fluxZguiGetMouseWheelY() f32;

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

const min_span: f32 = 1.0 / 512.0; // max ~512x zoom
var view_state: ViewState = .{};

pub fn draw(
    clip: *const AudioClip,
    store: *const SampleStore,
    clip_label: []const u8,
    playhead_beat: f32,
    playing: bool,
    beats_per_bar: f32,
    ui_scale: f32,
    is_focused: bool,
) void {
    const sample_id = clip.sample_id orelse {
        widgets.emptyState("No sample", "This audio clip has no media loaded", ui_scale);
        return;
    };
    const asset = store.get(sample_id) orelse {
        widgets.emptyState("Missing sample", "Sample asset is no longer in the store", ui_scale);
        return;
    };

    if (view_state.sample_id != sample_id) {
        view_state.reset(sample_id);
    }

    drawHeader(clip, asset, clip_label, beats_per_bar, ui_scale);
    zgui.spacing();
    drawMetaRow(clip, asset, ui_scale);
    zgui.spacing();
    drawZoomToolbar(ui_scale);
    zgui.spacing();

    const avail = zgui.getContentRegionAvail();
    const wave_h = @max(tokens.s(120, ui_scale), avail[1] - tokens.s(8, ui_scale));
    const wave_w = avail[0];
    if (wave_w < 4.0 or wave_h < 4.0) return;

    _ = zgui.invisibleButton("##audio_clip_wave", .{ .w = wave_w, .h = wave_h });
    const hovered = zgui.isItemHovered(.{});
    const pmin = zgui.getItemRectMin();
    const pmax = zgui.getItemRectMax();
    const draw_list = zgui.getWindowDrawList();
    const mouse = zgui.getMousePos();

    handleZoomPan(hovered, pmin, pmax, mouse, ui_scale);

    // Background panel
    const bg = colors.Colors.current.bg_cell;
    const rounding = tokens.radius(.md, ui_scale);
    draw_list.addRectFilled(.{
        .pmin = pmin,
        .pmax = pmax,
        .col = zgui.colorConvertFloat4ToU32(bg),
        .rounding = rounding,
    });
    draw_list.addRect(.{
        .pmin = pmin,
        .pmax = pmax,
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.border),
        .rounding = rounding,
        .thickness = 1.0,
    });

    const pad = tokens.s(6, ui_scale);
    const wave_min: [2]f32 = .{ pmin[0] + pad, pmin[1] + pad };
    const wave_max: [2]f32 = .{ pmax[0] - pad, pmax[1] - pad };
    const inner_w = wave_max[0] - wave_min[0];
    const x0 = wave_min[0];

    // Center zero line
    const mid_y = (wave_min[1] + wave_max[1]) * 0.5;
    draw_list.addLine(.{
        .p1 = .{ wave_min[0], mid_y },
        .p2 = .{ wave_max[0], mid_y },
        .col = zgui.colorConvertFloat4ToU32(.{ 1, 1, 1, 0.08 }),
        .thickness = 1.0,
    });

    // High-res peaks for visible file range (1 bin/pixel)
    const frames: u64 = asset.frame_count;
    const f0: u64 = @intFromFloat(@floor(view_state.start * @as(f32, @floatFromInt(frames))));
    const f1: u64 = @intFromFloat(@ceil(view_state.end() * @as(f32, @floatFromInt(frames))));
    const frame_start = @min(f0, frames);
    const frame_end = @min(@max(f1, frame_start + 1), frames);

    // Stable vertical scale from full-file peaks (thumbnails) so zoom doesn't pump gain
    const norm = peaks_mod.peakAbs(asset.peaks[0..]);
    const wave_col = waveformInk(bg);
    draw_waveform.drawPcmRange(draw_list, .{
        .pmin = wave_min,
        .pmax = wave_max,
        .pcm = asset.pcm,
        .channels = asset.channels,
        .frame_count = asset.frame_count,
        .frame_start = frame_start,
        .frame_end = frame_end,
        .col = zgui.colorConvertFloat4ToU32(wave_col),
        .amp_frac = 0.92,
        .norm_peak = if (norm > 1.0e-8) norm else 0,
    });

    // Loop markers / playhead mapped through file-normalized zoom.
    // Clip length_beats corresponds to full file duration (linear v1).
    const length = @max(clip.length_beats, 0.001);

    const beatToX = struct {
        fn map(beat: f32, len: f32, vs: *const ViewState, origin: f32, width: f32) ?f32 {
            const t = beat / len; // 0..1 file
            if (t < vs.start or t > vs.end()) return null;
            return origin + ((t - vs.start) / vs.span) * width;
        }
    }.map;

    if (clip.loop_start_beats > 0.001) {
        if (beatToX(clip.loop_start_beats, length, &view_state, x0, inner_w)) |lx| {
            draw_list.addLine(.{
                .p1 = .{ lx, wave_min[1] },
                .p2 = .{ lx, wave_max[1] },
                .col = zgui.colorConvertFloat4ToU32(.{ 0.95, 0.78, 0.28, 0.75 }),
                .thickness = 1.5,
            });
        }
    }
    const loop_end = clip.loopEnd();
    if (loop_end > 0.001 and loop_end < length - 0.001) {
        if (beatToX(loop_end, length, &view_state, x0, inner_w)) |lx| {
            draw_list.addLine(.{
                .p1 = .{ lx, wave_min[1] },
                .p2 = .{ lx, wave_max[1] },
                .col = zgui.colorConvertFloat4ToU32(.{ 0.95, 0.78, 0.28, 0.75 }),
                .thickness = 1.5,
            });
        }
    }

    if (playing and playhead_beat >= 0 and playhead_beat <= length) {
        if (beatToX(playhead_beat, length, &view_state, x0, inner_w)) |px| {
            draw_list.addLine(.{
                .p1 = .{ px, pmin[1] + 1 },
                .p2 = .{ px, pmax[1] - 1 },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.transport_play),
                .thickness = 2.0,
            });
        }
    }

    // Time ticks: seconds across visible window
    drawTimeRuler(draw_list, wave_min, wave_max, asset, ui_scale);

    // Overview minimap when zoomed
    if (view_state.span < 0.999) {
        drawOverview(draw_list, pmin, pmax, asset, ui_scale);
    }

    widgets.focusFrame(pmin, pmax, is_focused, ui_scale);
}

fn handleZoomPan(hovered: bool, pmin: [2]f32, pmax: [2]f32, mouse: [2]f32, ui_scale: f32) void {
    _ = ui_scale;
    const inner_w = @max(pmax[0] - pmin[0], 1.0);

    // Scroll-wheel zoom toward cursor
    if (hovered) {
        const wheel = fluxZguiGetMouseWheelY();
        if (wheel != 0) {
            const rel = std.math.clamp((mouse[0] - pmin[0]) / inner_w, 0.0, 1.0);
            const anchor = view_state.start + rel * view_state.span;
            const factor: f32 = if (wheel > 0) 0.85 else 1.0 / 0.85;
            view_state.span *= factor;
            view_state.clamp();
            // Keep anchor under cursor
            view_state.start = anchor - rel * view_state.span;
            view_state.clamp();
        }
    }

    // Drag to pan (left button on waveform)
    if (hovered and zgui.isMouseClicked(.left)) {
        view_state.dragging = true;
        view_state.drag_start_x = mouse[0];
        view_state.drag_start_view = view_state.start;
    }
    if (view_state.dragging) {
        if (zgui.isMouseDown(.left)) {
            const dx = mouse[0] - view_state.drag_start_x;
            const d_norm = -(dx / inner_w) * view_state.span;
            view_state.start = view_state.drag_start_view + d_norm;
            view_state.clamp();
            zgui.setMouseCursor(.resize_all);
        } else {
            view_state.dragging = false;
        }
    } else if (hovered and view_state.span < 0.999) {
        zgui.setMouseCursor(.resize_all);
    }
}

fn drawZoomToolbar(ui_scale: f32) void {
    const zoom_x = 1.0 / view_state.span;
    var zoom_buf: [32]u8 = undefined;
    const zoom_s = std.fmt.bufPrint(&zoom_buf, "{d:.1}x", .{zoom_x}) catch "?x";
    widgets.statusPill(zoom_s, ui_scale);

    zgui.sameLine(.{ .spacing = tokens.s(8, ui_scale) });
    if (zgui.smallButton("Reset zoom")) {
        view_state.start = 0;
        view_state.span = 1;
    }
    zgui.sameLine(.{ .spacing = tokens.s(8, ui_scale) });
    if (zgui.smallButton("Zoom in")) {
        const mid = view_state.start + view_state.span * 0.5;
        view_state.span *= 0.5;
        view_state.clamp();
        view_state.start = mid - view_state.span * 0.5;
        view_state.clamp();
    }
    zgui.sameLine(.{ .spacing = tokens.s(4, ui_scale) });
    if (zgui.smallButton("Zoom out")) {
        const mid = view_state.start + view_state.span * 0.5;
        view_state.span *= 2.0;
        view_state.clamp();
        view_state.start = mid - view_state.span * 0.5;
        view_state.clamp();
    }

    zgui.sameLine(.{ .spacing = tokens.s(12, ui_scale) });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_soft });
    zgui.textUnformatted("Scroll = zoom  |  Drag = pan");
    zgui.popStyleColor(.{ .count = 1 });
}

fn drawTimeRuler(
    draw_list: zgui.DrawList,
    wave_min: [2]f32,
    wave_max: [2]f32,
    asset: *const SampleAsset,
    ui_scale: f32,
) void {
    const dur = @max(asset.duration_seconds, 0.0001);
    const t0 = view_state.start * dur;
    const t1 = view_state.end() * dur;
    const span_s = t1 - t0;
    if (span_s <= 0) return;

    // Nice step: 0.01 / 0.05 / 0.1 / 0.5 / 1 / 5 / 10 ...
    const target_ticks: f64 = 8.0;
    const raw = span_s / target_ticks;
    const exp = @floor(@log10(@max(raw, 1e-9)));
    const base = std.math.pow(f64, 10.0, exp);
    const mult = raw / base;
    const nice_mult: f64 = if (mult < 1.5) 1.0 else if (mult < 3.5) 2.0 else if (mult < 7.5) 5.0 else 10.0;
    const step: f64 = base * nice_mult;

    const inner_w = wave_max[0] - wave_min[0];
    const tick_col = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_soft);
    const label_col = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_dim);

    var t = @ceil(t0 / step) * step;
    var guard: u32 = 0;
    while (t <= t1 + step * 0.01 and guard < 64) : ({
        t += step;
        guard += 1;
    }) {
        const u = (@as(f32, @floatCast(t)) / @as(f32, @floatCast(dur)) - view_state.start) / view_state.span;
        if (u < 0 or u > 1) continue;
        const x = wave_min[0] + u * inner_w;
        draw_list.addLine(.{
            .p1 = .{ x, wave_max[1] - tokens.s(10, ui_scale) },
            .p2 = .{ x, wave_max[1] },
            .col = tick_col,
            .thickness = 1.0,
        });
        var buf: [24]u8 = undefined;
        const label = if (step >= 1.0)
            std.fmt.bufPrint(&buf, "{d:.0}s", .{t}) catch ""
        else if (step >= 0.1)
            std.fmt.bufPrint(&buf, "{d:.1}s", .{t}) catch ""
        else
            std.fmt.bufPrint(&buf, "{d:.2}s", .{t}) catch "";
        if (label.len > 0) {
            draw_list.addText(.{ x + 2, wave_max[1] - tokens.s(22, ui_scale) }, label_col, "{s}", .{label});
        }
    }
}

fn drawOverview(
    draw_list: zgui.DrawList,
    pmin: [2]f32,
    pmax: [2]f32,
    asset: *const SampleAsset,
    ui_scale: f32,
) void {
    const h = tokens.s(18, ui_scale);
    const pad = tokens.s(4, ui_scale);
    const omin: [2]f32 = .{ pmin[0] + pad, pmax[1] - h - pad };
    const omax: [2]f32 = .{ pmax[0] - pad, pmax[1] - pad };
    if (omax[0] <= omin[0]) return;

    draw_list.addRectFilled(.{
        .pmin = omin,
        .pmax = omax,
        .col = zgui.colorConvertFloat4ToU32(.{ 0, 0, 0, 0.35 }),
        .rounding = 2,
    });

    // Tiny full-file waveform
    const ink = zgui.colorConvertFloat4ToU32(.{ 1, 1, 1, 0.35 });
    draw_waveform.drawPeaks(draw_list, .{
        .pmin = omin,
        .pmax = omax,
        .peaks = asset.peaks[0..],
        .col = ink,
        .amp_frac = 0.85,
    });

    // Visible window highlight
    const ow = omax[0] - omin[0];
    const vx0 = omin[0] + view_state.start * ow;
    const vx1 = omin[0] + view_state.end() * ow;
    draw_list.addRect(.{
        .pmin = .{ vx0, omin[1] },
        .pmax = .{ vx1, omax[1] },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.selected),
        .thickness = 1.5,
    });
}

fn drawHeader(
    clip: *const AudioClip,
    asset: *const SampleAsset,
    clip_label: []const u8,
    beats_per_bar: f32,
    ui_scale: f32,
) void {
    const name = if (clip.name.len > 0) clip.name.get() else baseName(asset.path_in_project);

    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_bright });
    zgui.text("{s}", .{name});
    zgui.popStyleColor(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = tokens.s(16, ui_scale) });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
    zgui.text("Audio | {s}", .{clip_label});
    zgui.popStyleColor(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = tokens.s(16, ui_scale) });
    const bars = clip.length_beats / @max(beats_per_bar, 0.001);
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
    zgui.text("{d:.2} bars | {d:.2}s file", .{ bars, asset.duration_seconds });
    zgui.popStyleColor(.{ .count = 1 });

    if (clip.hasBaked()) {
        zgui.sameLine(.{ .spacing = tokens.s(12, ui_scale) });
        widgets.statusPill("stretch bake", ui_scale);
    } else if (clip.algorithm) |algo| {
        if (algo.len > 0) {
            zgui.sameLine(.{ .spacing = tokens.s(12, ui_scale) });
            var buf: [48]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{s}", .{algo}) catch "algo";
            widgets.statusPill(label, ui_scale);
        }
    }
}

fn drawMetaRow(clip: *const AudioClip, asset: *const SampleAsset, ui_scale: f32) void {
    const ch_label = switch (asset.channels) {
        1 => "mono",
        2 => "stereo",
        else => "ch",
    };

    var rate_buf: [32]u8 = undefined;
    const rate_s = std.fmt.bufPrint(&rate_buf, "{d} Hz", .{asset.sample_rate}) catch "? Hz";

    var ch_buf: [24]u8 = undefined;
    const ch_s = if (asset.channels <= 2)
        std.fmt.bufPrint(&ch_buf, "{s}", .{ch_label}) catch "?"
    else
        std.fmt.bufPrint(&ch_buf, "{d} ch", .{asset.channels}) catch "?";

    var bits_buf: [24]u8 = undefined;
    const bits_s = if (asset.original_bits > 0)
        std.fmt.bufPrint(&bits_buf, "{d}-bit", .{asset.original_bits}) catch "?"
    else
        "f32 decode";

    var frames_buf: [40]u8 = undefined;
    const frames_s = std.fmt.bufPrint(&frames_buf, "{d} frames", .{asset.frame_count}) catch "?";

    var size_buf: [32]u8 = undefined;
    const size_s = formatBytes(&size_buf, if (asset.source_bytes) |b| b.len else asset.file_size);

    var warp_buf: [24]u8 = undefined;
    const warp_s = std.fmt.bufPrint(&warp_buf, "{d} warps", .{clip.warps.items.len}) catch "?";

    widgets.statusPill(rate_s, ui_scale);
    zgui.sameLine(.{ .spacing = tokens.s(6, ui_scale) });
    widgets.statusPill(ch_s, ui_scale);
    zgui.sameLine(.{ .spacing = tokens.s(6, ui_scale) });
    widgets.statusPill(bits_s, ui_scale);
    zgui.sameLine(.{ .spacing = tokens.s(6, ui_scale) });
    widgets.statusPill(frames_s, ui_scale);
    zgui.sameLine(.{ .spacing = tokens.s(6, ui_scale) });
    widgets.statusPill(size_s, ui_scale);
    zgui.sameLine(.{ .spacing = tokens.s(6, ui_scale) });
    widgets.statusPill(warp_s, ui_scale);

    zgui.spacing();
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_soft });
    zgui.textWrapped("{s}", .{asset.path_in_project});
    zgui.popStyleColor(.{ .count = 1 });

    drawIoLine(asset);
}

fn drawIoLine(asset: *const SampleAsset) void {
    const src_rate: u32 = if (asset.original_sample_rate > 0) @intCast(asset.original_sample_rate) else asset.sample_rate;
    const src_ch: u32 = if (asset.original_channels > 0) @intCast(asset.original_channels) else asset.channels;

    // ASCII only: some ImGui font atlases lack arrows / mid-dots and show a missing-glyph box.
    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
    if (asset.original_bits > 0) {
        zgui.text("In  {d} Hz  {d} ch  {d}-bit  ->  Out  f32 interleaved @ {d} Hz  {d} ch", .{
            src_rate,
            src_ch,
            asset.original_bits,
            asset.sample_rate,
            asset.channels,
        });
    } else {
        zgui.text("In  {d} Hz  {d} ch  ->  Out  f32 interleaved @ {d} Hz  {d} ch (decoded)", .{
            src_rate,
            src_ch,
            asset.sample_rate,
            asset.channels,
        });
    }
    zgui.popStyleColor(.{ .count = 1 });
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

fn waveformInk(fill: [4]f32) [4]f32 {
    const on = colors.Colors.textOn(fill);
    return .{ on[0], on[1], on[2], 0.78 };
}
