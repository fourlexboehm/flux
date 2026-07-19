const std = @import("std");
const zgui = @import("zgui");
const colors = @import("../../theme/colors.zig");
const tokens = @import("../../theme/tokens.zig");
const widgets = @import("../../theme/widgets.zig");
const arr_types = @import("../../../arrangement/types.zig");
const arr_track = @import("../../../arrangement/track.zig");
const session_types = @import("../../../session/types.zig");
const session_constants = @import("../../../session/constants.zig");

pub fn drawHeader(width: f32, height: f32, ui_scale: f32) void {
    if (zgui.beginChild("##arr_mixer_header", .{
        .w = width,
        .h = height,
        .child_flags = .{ .border = true },
        .window_flags = .{ .no_scrollbar = true },
    })) {
        zgui.setCursorPosX(tokens.s(7, ui_scale));
        zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
        zgui.textUnformatted("MIXER");
        zgui.popStyleColor(.{ .count = 1 });
    }
    zgui.endChild();
}

pub fn draw(
    view: *arr_types.ArrangementView,
    session: *session_types.SessionView,
    track_levels: *const [session_constants.max_tracks][2]f32,
    scroll_y: f32,
    width: f32,
    height: f32,
    lane_height: f32,
    ui_scale: f32,
    allow_mouse: bool,
) void {
    if (zgui.beginChild("##arr_mixer", .{
        .w = width,
        .h = height,
        .child_flags = .{ .border = true },
        .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true },
    })) {
        const origin = zgui.getCursorScreenPos();
        const content_width = zgui.getContentRegionAvail()[0];
        for (view.tracks.items, 0..) |*track, index| {
            zgui.setCursorScreenPos(.{ origin[0], origin[1] + @as(f32, @floatFromInt(index)) * lane_height - scroll_y });
            const levels = if (track.session_track_index < session_constants.max_tracks) track_levels[track.session_track_index] else .{ 0, 0 };
            drawRow(track, index, session, levels, content_width, lane_height, ui_scale, allow_mouse);
        }
    }
    zgui.endChild();
}

fn drawRow(track: *arr_track.ArrangementTrack, index: usize, session: *session_types.SessionView, levels: [2]f32, width: f32, height: f32, ui_scale: f32, enabled: bool) void {
    const row_pos = zgui.getCursorScreenPos();
    const row_cursor = zgui.getCursorPos();
    const dl = zgui.getWindowDrawList();
    dl.pushClipRect(.{
        .pmin = row_pos,
        .pmax = .{ row_pos[0] + width, row_pos[1] + height },
    });
    defer dl.popClipRect();
    dl.addRectFilled(.{
        .pmin = row_pos,
        .pmax = .{ row_pos[0] + width, row_pos[1] + height },
        .col = zgui.colorConvertFloat4ToU32(if (index % 2 == 0) colors.Colors.current.bg_cell else colors.Colors.current.bg_header),
    });
    dl.addRectFilled(.{
        .pmin = row_pos,
        .pmax = .{ row_pos[0] + tokens.s(3, ui_scale), row_pos[1] + height },
        .col = zgui.colorConvertFloat4ToU32(track.color),
    });

    const pad = tokens.s(7, ui_scale);
    const button_w = tokens.s(32, ui_scale);
    const gap = tokens.s(3, ui_scale);
    const slider_w = tokens.s(64, ui_scale);
    const pan_w = tokens.s(58, ui_scale);
    const meter_w = tokens.s(22, ui_scale);
    const control_h = @min(tokens.controlH(.sm, ui_scale), height - tokens.s(6, ui_scale));
    const y = row_cursor[1] + (height - control_h) * 0.5;
    const name_w = @max(tokens.s(35, ui_scale), width - pad * 2 - button_w * 4 - slider_w - pan_w - meter_w - gap * 7);
    const name = track.name.get();
    const name_size = zgui.calcTextSize(name, .{});
    dl.pushClipRect(.{
        .pmin = .{ row_pos[0] + pad, row_pos[1] },
        .pmax = .{ row_pos[0] + name_w, row_pos[1] + height },
    });
    dl.addText(
        .{ row_pos[0] + pad, row_pos[1] + (height - name_size[1]) * 0.5 },
        zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright),
        "{s}",
        .{name},
    );
    dl.popClipRect();

    const mapped = track.session_track_index;
    if (mapped < session.track_count) {
        const mix_track = &session.tracks[mapped];
        zgui.setCursorPos(.{ row_cursor[0] + name_w + gap, y });
        var enable_buf: [32]u8 = undefined;
        const enable_id = std.fmt.bufPrintSentinel(&enable_buf, "E##arr_enable{d}", .{index}, 0) catch "E";
        if (toggleButton(enable_id, &track.enabled, button_w, control_h, colors.Colors.current.selected, enabled)) {
            mix_track.mute = !track.enabled;
        }
        widgets.itemTooltip("Track enabled");

        zgui.sameLine(.{ .spacing = gap });
        var id_buf: [32]u8 = undefined;
        const mute_id = std.fmt.bufPrintSentinel(&id_buf, "M##arr_mute{d}", .{index}, 0) catch "M";
        _ = toggleButton(mute_id, &mix_track.mute, button_w, control_h, colors.Colors.current.mute_on, enabled);
        widgets.itemTooltip("Mute");

        zgui.sameLine(.{ .spacing = gap });
        var solo_buf: [32]u8 = undefined;
        const solo_id = std.fmt.bufPrintSentinel(&solo_buf, "S##arr_solo{d}", .{index}, 0) catch "S";
        _ = toggleButton(solo_id, &mix_track.solo, button_w, control_h, colors.Colors.current.solo_on, enabled);
        widgets.itemTooltip("Solo");

        zgui.sameLine(.{ .spacing = gap });
        var arm_buf: [32]u8 = undefined;
        const arm_id = std.fmt.bufPrintSentinel(&arm_buf, "R##arr_arm{d}", .{index}, 0) catch "R";
        var armed = session.armed_track == mapped;
        if (toggleButton(arm_id, &armed, button_w, control_h, colors.Colors.current.arm_on, enabled)) {
            session.armed_track = if (armed) mapped else null;
        }
        widgets.itemTooltip("Record arm");

        zgui.sameLine(.{ .spacing = gap });
        var volume_buf: [32]u8 = undefined;
        const volume_id = std.fmt.bufPrintSentinel(&volume_buf, "##arr_vol{d}", .{index}, 0) catch "##arr_vol";
        zgui.setNextItemWidth(slider_w);
        zgui.beginDisabled(.{ .disabled = !enabled });
        _ = zgui.sliderFloat(volume_id, .{ .v = &mix_track.volume, .min = 0, .max = 1.5, .cfmt = "%.2f" });
        zgui.endDisabled();
        if (enabled and zgui.isItemActivated()) {
            session.primary_track = mapped;
            session.mixer_target = .track;
        }

        zgui.sameLine(.{ .spacing = gap });
        var pan_buf: [32]u8 = undefined;
        const pan_id = std.fmt.bufPrintSentinel(&pan_buf, "##arr_pan{d}", .{index}, 0) catch "##arr_pan";
        zgui.setNextItemWidth(pan_w);
        zgui.beginDisabled(.{ .disabled = !enabled });
        _ = zgui.sliderFloat(pan_id, .{ .v = &mix_track.pan, .min = -1, .max = 1, .cfmt = "P %.2f" });
        zgui.endDisabled();
        widgets.itemTooltip("Pan");

        const meter_x = row_pos[0] + width - pad - meter_w;
        drawMeter(dl, meter_x, row_pos[1] + tokens.s(7, ui_scale), meter_w, height - tokens.s(14, ui_scale), levels);
    }

    dl.addLine(.{
        .p1 = .{ row_pos[0], row_pos[1] + height - 1 },
        .p2 = .{ row_pos[0] + width, row_pos[1] + height - 1 },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.border),
    });
    zgui.dummy(.{ .w = width, .h = height });
}

fn toggleButton(id: [:0]const u8, value: *bool, width: f32, height: f32, active: [4]f32, enabled: bool) bool {
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (value.*) active else colors.Colors.current.bg_cell });
    zgui.beginDisabled(.{ .disabled = !enabled });
    const clicked = zgui.button(id, .{ .w = width, .h = height });
    if (clicked) value.* = !value.*;
    zgui.endDisabled();
    zgui.popStyleColor(.{ .count = 1 });
    return clicked;
}

fn drawMeter(dl: zgui.DrawList, x: f32, y: f32, width: f32, height: f32, levels: [2]f32) void {
    const gap: f32 = 2;
    const channel_w = (width - gap) * 0.5;
    for (levels, 0..) |level, channel| {
        const x0 = x + @as(f32, @floatFromInt(channel)) * (channel_w + gap);
        dl.addRectFilled(.{ .pmin = .{ x0, y }, .pmax = .{ x0 + channel_w, y + height }, .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.bg_cell_active) });
        const amount = std.math.clamp(level, 0, 1);
        dl.addRectFilled(.{
            .pmin = .{ x0, y + height * (1 - amount) },
            .pmax = .{ x0 + channel_w, y + height },
            .col = zgui.colorConvertFloat4ToU32(if (amount > 0.9) colors.Colors.current.arm_on else colors.Colors.current.solo_on),
        });
    }
}
