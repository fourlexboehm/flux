const zgui = @import("zgui");
const colors = @import("colors.zig");
const tokens = @import("tokens.zig");
const Colors = colors.Colors;

/// Content-fit combo width: label + arrow chevron area + frame padding.
pub fn comboContentWidth(max_label_w: f32, ui_scale: f32) f32 {
    const frame_height = zgui.getFrameHeight();
    const frame_padding = zgui.getStyle().frame_padding;
    return max_label_w + frame_height + frame_padding[0] * 2.0 + tokens.s(4, ui_scale);
}

pub fn comboContentWidthForLabels(labels: []const []const u8, ui_scale: f32) f32 {
    var max_w: f32 = 0.0;
    for (labels) |label| {
        max_w = @max(max_w, zgui.calcTextSize(label, .{})[0]);
    }
    return comboContentWidth(max_w, ui_scale);
}

pub fn iconButtonSize(ui_scale: f32) f32 {
    // Match frame height so icons sit flush with combos/sliders on toolbars.
    _ = ui_scale;
    return zgui.getFrameHeight();
}

pub fn itemTooltip(text: []const u8) void {
    if (!zgui.isItemHovered(.{})) return;
    if (!zgui.beginTooltip()) return;
    zgui.textUnformatted(text);
    zgui.endTooltip();
}

pub fn dimLabel(text: []const u8) void {
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
    zgui.textUnformatted(text);
    zgui.popStyleColor(.{ .count = 1 });
}

pub fn sectionChrome(title: []const u8, ui_scale: f32) void {
    zgui.spacing();
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_soft });
    zgui.textUnformatted(title);
    zgui.popStyleColor(.{ .count = 1 });
    const draw_list = zgui.getWindowDrawList();
    const p = zgui.getCursorScreenPos();
    const w = zgui.getContentRegionAvail()[0];
    draw_list.addLine(.{
        .p1 = .{ p[0], p[1] },
        .p2 = .{ p[0] + w, p[1] },
        .col = zgui.colorConvertFloat4ToU32(Colors.current.border),
        .thickness = 1.0,
    });
    zgui.dummy(.{ .w = 0, .h = tokens.s(6, ui_scale) });
}

pub fn emptyState(title: []const u8, hint: []const u8, ui_scale: f32) void {
    zgui.spacing();
    zgui.dummy(.{ .w = 0, .h = tokens.s(12, ui_scale) });
    const avail = zgui.getContentRegionAvail();
    const title_sz = zgui.calcTextSize(title, .{});
    const hint_sz = zgui.calcTextSize(hint, .{});
    zgui.setCursorPosX(zgui.getCursorPosX() + @max(0.0, (avail[0] - title_sz[0]) * 0.5));
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_dim });
    zgui.textUnformatted(title);
    zgui.popStyleColor(.{ .count = 1 });
    zgui.setCursorPosX(zgui.getCursorPosX() + @max(0.0, (avail[0] - hint_sz[0]) * 0.5));
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_soft });
    zgui.textUnformatted(hint);
    zgui.popStyleColor(.{ .count = 1 });
}

pub fn focusFrame(pmin: [2]f32, pmax: [2]f32, active: bool, ui_scale: f32) void {
    if (!active) return;
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRect(.{
        .pmin = pmin,
        .pmax = pmax,
        .col = zgui.colorConvertFloat4ToU32(Colors.current.focus_ring),
        .rounding = tokens.radius(.md, ui_scale),
        .thickness = tokens.s(1.5, ui_scale),
    });
}

/// Quiet vertical rule used as a toolbar group separator.
pub fn toolbarSeparator(ui_scale: f32, bar_h: f32) void {
    zgui.sameLine(.{ .spacing = tokens.gapTight(ui_scale) });
    const pos = zgui.getCursorScreenPos();
    const draw_list = zgui.getWindowDrawList();
    const mid = pos[1] + bar_h * 0.5;
    const half = bar_h * 0.28;
    draw_list.addLine(.{
        .p1 = .{ pos[0], mid - half },
        .p2 = .{ pos[0], mid + half },
        .col = zgui.colorConvertFloat4ToU32(Colors.current.border),
        .thickness = 1.0,
    });
    zgui.dummy(.{ .w = tokens.s(1, ui_scale), .h = 1 });
    zgui.sameLine(.{ .spacing = tokens.gapTight(ui_scale) });
}

pub const Icon = enum {
    folder,
    save,
    save_as,
    open_window,
    device,
    clip,
    play,
    stop,
    plus,
};

/// Square icon button. Returns true when clicked.
pub fn iconButton(id: [:0]const u8, kind: Icon, ui_scale: f32, tooltip: []const u8) bool {
    return iconButtonEx(id, kind, ui_scale, tooltip, false, false, null);
}

/// Icon toggle: `active` tints accent when on.
pub fn iconToggle(id: [:0]const u8, kind: Icon, ui_scale: f32, tooltip: []const u8, active: bool, disabled: bool) bool {
    return iconButtonEx(id, kind, ui_scale, tooltip, active, disabled, null);
}

/// Icon button with explicit size (e.g. transport bar matching frame height).
pub fn iconButtonSized(id: [:0]const u8, kind: Icon, size: f32, ui_scale: f32, tooltip: []const u8, active: bool) bool {
    return iconButtonEx(id, kind, ui_scale, tooltip, active, false, size);
}

fn iconButtonEx(id: [:0]const u8, kind: Icon, ui_scale: f32, tooltip: []const u8, active: bool, disabled: bool, size_override: ?f32) bool {
    const size = size_override orelse iconButtonSize(ui_scale);
    const bg = if (active) Colors.current.accent_dim else Colors.current.bg_cell;
    const bg_hover = if (active) Colors.current.accent else Colors.current.bg_cell_hover;
    const bg_active = Colors.current.accent_dim;

    zgui.pushStyleColor4f(.{ .idx = .button, .c = bg });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = bg_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = bg_active });
    defer zgui.popStyleColor(.{ .count = 3 });

    zgui.beginDisabled(.{ .disabled = disabled });
    const pos = zgui.getCursorScreenPos();
    const clicked = zgui.button(id, .{ .w = size, .h = size });
    zgui.endDisabled();
    itemTooltip(tooltip);

    const col = if (disabled)
        Colors.current.text_soft
    else if (active)
        Colors.current.text_bright
    else
        Colors.current.text_dim;

    drawIcon(kind, pos, size, ui_scale, col);
    return clicked and !disabled;
}

/// Segmented tab: filled pill when active, icon + label.
pub fn segmentedTab(id: [:0]const u8, kind: Icon, label: []const u8, ui_scale: f32, active: bool) bool {
    const h = iconButtonSize(ui_scale);
    const icon_pad = tokens.s(6, ui_scale);
    const label_sz = zgui.calcTextSize(label, .{});
    const w = h + tokens.s(4, ui_scale) + label_sz[0] + tokens.s(10, ui_scale);

    const bg = if (active) Colors.current.accent_dim else Colors.current.bg_cell;
    const bg_hover = if (active) Colors.current.accent else Colors.current.bg_cell_hover;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = bg });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = bg_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.current.accent_dim });
    defer zgui.popStyleColor(.{ .count = 3 });

    const pos = zgui.getCursorScreenPos();
    const clicked = zgui.button(id, .{ .w = w, .h = h });
    const icon_col = if (active) Colors.current.text_bright else Colors.current.text_dim;
    drawIcon(kind, .{ pos[0] + icon_pad * 0.5, pos[1] }, h, ui_scale, icon_col);

    const text_col = if (active) Colors.current.text_bright else Colors.current.text_dim;
    const draw_list = zgui.getWindowDrawList();
    const tx = pos[0] + h + tokens.s(2, ui_scale);
    const ty = pos[1] + (h - label_sz[1]) * 0.5;
    draw_list.addText(.{ tx, ty }, zgui.colorConvertFloat4ToU32(text_col), "{s}", .{label});
    return clicked;
}

/// Soft status pill (track/scene context).
pub fn statusPill(text: []const u8, ui_scale: f32) void {
    const pad_x = tokens.s(10, ui_scale);
    const pad_y = tokens.s(4, ui_scale);
    const sz = zgui.calcTextSize(text, .{});
    const pos = zgui.getCursorScreenPos();
    const h = sz[1] + pad_y * 2;
    const w = sz[0] + pad_x * 2;
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{
        .pmin = pos,
        .pmax = .{ pos[0] + w, pos[1] + h },
        .col = zgui.colorConvertFloat4ToU32(Colors.current.bg_cell),
        .rounding = tokens.radius(.lg, ui_scale),
    });
    draw_list.addText(.{ pos[0] + pad_x, pos[1] + pad_y }, zgui.colorConvertFloat4ToU32(Colors.current.text_dim), "{s}", .{text});
    zgui.dummy(.{ .w = w, .h = h });
}

fn drawIcon(kind: Icon, pos: [2]f32, size: f32, ui_scale: f32, col4: [4]f32) void {
    const draw_list = zgui.getWindowDrawList();
    const col = zgui.colorConvertFloat4ToU32(col4);
    const pad = size * 0.28;
    const x0 = pos[0] + pad;
    const y0 = pos[1] + pad;
    const x1 = pos[0] + size - pad;
    const y1 = pos[1] + size - pad;
    const cx = pos[0] + size * 0.5;
    const cy = pos[1] + size * 0.5;
    const t = @max(1.15 * ui_scale, 1.0);

    switch (kind) {
        .folder => {
            const tab_h = (y1 - y0) * 0.28;
            draw_list.addRectFilled(.{
                .pmin = .{ x0, y0 + tab_h * 0.55 },
                .pmax = .{ x1, y1 },
                .col = col,
                .rounding = tokens.s(2, ui_scale),
            });
            draw_list.addRectFilled(.{
                .pmin = .{ x0, y0 },
                .pmax = .{ x0 + (x1 - x0) * 0.42, y0 + tab_h },
                .col = col,
                .rounding = tokens.s(1.5, ui_scale),
            });
        },
        .save, .save_as => {
            draw_list.addRect(.{
                .pmin = .{ x0, y0 },
                .pmax = .{ x1, y1 },
                .col = col,
                .thickness = t,
                .rounding = tokens.s(2, ui_scale),
            });
            draw_list.addRectFilled(.{
                .pmin = .{ x0 + size * 0.12, y0 + size * 0.08 },
                .pmax = .{ x1 - size * 0.12, y0 + (y1 - y0) * 0.38 },
                .col = col,
            });
            draw_list.addRectFilled(.{
                .pmin = .{ cx - (x1 - x0) * 0.16, y1 - (y1 - y0) * 0.32 },
                .pmax = .{ cx + (x1 - x0) * 0.16, y1 - size * 0.08 },
                .col = col,
            });
            if (kind == .save_as) {
                const p = size * 0.12;
                draw_list.addLine(.{ .p1 = .{ x1 - p, y1 - p * 2.0 }, .p2 = .{ x1 - p, y1 }, .col = col, .thickness = t });
                draw_list.addLine(.{ .p1 = .{ x1 - p * 2.0, y1 - p }, .p2 = .{ x1, y1 - p }, .col = col, .thickness = t });
            }
        },
        .open_window => {
            draw_list.addRect(.{
                .pmin = .{ x0, y0 + size * 0.08 },
                .pmax = .{ x1 - size * 0.14, y1 },
                .col = col,
                .thickness = t,
                .rounding = tokens.s(1.5, ui_scale),
            });
            draw_list.addLine(.{
                .p1 = .{ x0, y0 + size * 0.22 },
                .p2 = .{ x1 - size * 0.14, y0 + size * 0.22 },
                .col = col,
                .thickness = t,
            });
            const ax = x1 - size * 0.04;
            const ay = y0 + size * 0.04;
            draw_list.addLine(.{ .p1 = .{ ax - size * 0.2, ay + size * 0.2 }, .p2 = .{ ax, ay }, .col = col, .thickness = t });
            draw_list.addLine(.{ .p1 = .{ ax - size * 0.18, ay }, .p2 = .{ ax, ay }, .col = col, .thickness = t });
            draw_list.addLine(.{ .p1 = .{ ax, ay }, .p2 = .{ ax, ay + size * 0.18 }, .col = col, .thickness = t });
        },
        .device => {
            const bar_w = size * 0.1;
            const gap = (x1 - x0) / 4.0;
            const heights = [_]f32{ 0.55, 0.85, 0.4, 0.7 };
            for (heights, 0..) |h, i| {
                const bx = x0 + gap * (@as(f32, @floatFromInt(i)) + 0.5) - bar_w * 0.5;
                const bh = (y1 - y0) * h;
                draw_list.addRectFilled(.{
                    .pmin = .{ bx, y1 - bh },
                    .pmax = .{ bx + bar_w, y1 },
                    .col = col,
                    .rounding = tokens.s(1, ui_scale),
                });
            }
        },
        .clip => {
            const key_w = (x1 - x0) * 0.28;
            draw_list.addRectFilled(.{
                .pmin = .{ x0, y0 + (y1 - y0) * 0.15 },
                .pmax = .{ x0 + key_w, y1 },
                .col = col,
                .rounding = tokens.s(1, ui_scale),
            });
            draw_list.addRectFilled(.{
                .pmin = .{ cx - key_w * 0.35, y0 },
                .pmax = .{ cx + key_w * 0.65, y1 - (y1 - y0) * 0.2 },
                .col = col,
                .rounding = tokens.s(1, ui_scale),
            });
        },
        .play => {
            draw_list.addTriangleFilled(.{
                .p1 = .{ cx - size * 0.16, cy - size * 0.2 },
                .p2 = .{ cx - size * 0.16, cy + size * 0.2 },
                .p3 = .{ cx + size * 0.22, cy },
                .col = col,
            });
        },
        .stop => {
            const half = size * 0.16;
            draw_list.addRectFilled(.{
                .pmin = .{ cx - half, cy - half },
                .pmax = .{ cx + half, cy + half },
                .col = col,
            });
        },
        .plus => {
            draw_list.addLine(.{ .p1 = .{ cx, y0 + size * 0.08 }, .p2 = .{ cx, y1 - size * 0.08 }, .col = col, .thickness = t * 1.2 });
            draw_list.addLine(.{ .p1 = .{ x0 + size * 0.08, cy }, .p2 = .{ x1 - size * 0.08, cy }, .col = col, .thickness = t * 1.2 });
        },
    }
}
