//! Piano-roll automation header, overlay, and param helpers (legacy zgui).
const zgui = @import("zgui");
const colors = @import("../../theme/colors.zig");
const widgets = @import("../../theme/widgets.zig");
const selection = @import("../../input/selection.zig");
const edit_actions = @import("../../input/edit_actions.zig");
const std = @import("std");
const clap = @import("clap-bindings");

const types = @import("../../../session/notes.zig");
const ops = @import("ops.zig");
const PianoRollState = types.PianoRollState;
const PianoRollClip = types.PianoRollClip;
const AutomationPoint = types.AutomationPoint;
const AutomationLane = types.AutomationLane;
const AutomationTargetKind = types.AutomationTargetKind;
const quantizeIndexToBeats = types.quantizeIndexToBeats;

pub fn drawAutomationHeader(
    state: *PianoRollState,
    clip: *PianoRollClip,
    ui_scale: f32,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
) void {
    const lane_count = clip.automation.lanes.items.len;
    if (lane_count == 0) {
        state.automation_lane_index = null;
    } else if (state.automation_lane_index == null or state.automation_lane_index.? >= lane_count) {
        state.automation_lane_index = 0;
    }

    zgui.pushStyleColor4f(.{ .idx = .text, .c = colors.Colors.current.text_dim });
    zgui.textUnformatted("Automation:");
    zgui.popStyleColor(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
    zgui.setNextItemWidth(260.0 * ui_scale);

    var preview_buf: [256]u8 = undefined;
    const preview = if (state.automation_lane_index) |idx|
        automationLaneLabel(&preview_buf, &clip.automation.lanes.items[idx], instrument_plugin, fx_plugins)
    else
        (std.fmt.bufPrintSentinel(&preview_buf, "None", .{}, 0) catch "None");

    if (zgui.beginCombo("##automation_lane", .{ .preview_value = preview })) {
        for (clip.automation.lanes.items, 0..) |*lane, idx| {
            var lane_buf: [256]u8 = undefined;
            const label = automationLaneLabel(&lane_buf, lane, instrument_plugin, fx_plugins);
            const selected = state.automation_lane_index != null and state.automation_lane_index.? == idx;
            if (zgui.selectable(label, .{ .selected = selected })) {
                state.automation_lane_index = idx;
                state.automation_selected_point = null;
            }
        }
        zgui.endCombo();
    }

    zgui.sameLine(.{ .spacing = 10.0 * ui_scale });
    if (zgui.button("Add Lane##automation_add", .{ .w = 0, .h = 0 })) {
        state.automation_add_param_id = null;
        zgui.openPopup("automation_add", .{});
    }

    if (state.automation_lane_index) |idx| {
        zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
        if (zgui.button("Remove##automation_remove", .{ .w = 0, .h = 0 })) {
            if (idx < clip.automation.lanes.items.len) {
                var lane = &clip.automation.lanes.items[idx];
                if (lane.target_id.len > 0) {
                    clip.allocator.free(lane.target_id);
                }
                if (lane.param_id) |param_id| {
                    clip.allocator.free(param_id);
                }
                if (lane.unit) |unit| {
                    clip.allocator.free(unit);
                }
                lane.points.deinit(clip.allocator);
                _ = clip.automation.lanes.orderedRemove(idx);
                state.automation_lane_index = if (clip.automation.lanes.items.len > 0) @min(idx, clip.automation.lanes.items.len - 1) else null;
                state.automation_selected_point = null;
            }
        }
    }

    zgui.sameLine(.{ .spacing = 10.0 * ui_scale });
    _ = zgui.checkbox("Edit##automation_edit", .{ .v = &state.automation_edit });

    if (zgui.beginPopup("automation_add", .{})) {
        const targets = "Track Volume\x00Track Pan\x00Instrument Param\x00FX Param\x00\x00";
        var target_index: i32 = @intFromEnum(state.automation_add_target);
        if (zgui.combo("Target", .{
            .current_item = &target_index,
            .items_separated_by_zeros = targets,
        })) {
            state.automation_add_target = @enumFromInt(target_index);
            state.automation_add_param_id = null;
        }

        if (state.automation_add_target == .fx_param) {
            if (fx_plugins.len == 0) {
                zgui.textUnformatted("No FX slots on this track.");
            } else {
                var fx_label_buf: [64]u8 = undefined;
                const current_fx = @min(state.automation_add_fx_index, fx_plugins.len - 1);
                state.automation_add_fx_index = current_fx;
                const fx_preview = std.fmt.bufPrintSentinel(&fx_label_buf, "FX {d}", .{current_fx + 1}, 0) catch "FX";
                if (zgui.beginCombo("FX Slot", .{ .preview_value = fx_preview })) {
                    for (0..fx_plugins.len) |fx_index| {
                        var slot_buf: [32]u8 = undefined;
                        const slot_label = std.fmt.bufPrintSentinel(&slot_buf, "FX {d}", .{fx_index + 1}, 0) catch "FX";
                        const selected = fx_index == state.automation_add_fx_index;
                        if (zgui.selectable(slot_label, .{ .selected = selected })) {
                            state.automation_add_fx_index = fx_index;
                            state.automation_add_param_id = null;
                        }
                    }
                    zgui.endCombo();
                }
            }
        }

        const target_plugin = switch (state.automation_add_target) {
            .instrument_param => instrument_plugin,
            .fx_param => if (fx_plugins.len > 0) fx_plugins[@min(state.automation_add_fx_index, fx_plugins.len - 1)] else null,
            else => null,
        };

        var has_param_selection = true;
        if (state.automation_add_target == .instrument_param or state.automation_add_target == .fx_param) {
            has_param_selection = drawParamCombo("Parameter", target_plugin, &state.automation_add_param_id);
        }

        const allow_add = switch (state.automation_add_target) {
            .track_volume, .track_pan => true,
            else => has_param_selection and state.automation_add_param_id != null,
        };

        zgui.beginDisabled(.{ .disabled = !allow_add });
        if (zgui.button("Create Lane", .{ .w = 0, .h = 0 })) {
            addAutomationLane(state, clip, instrument_plugin, fx_plugins);
            zgui.closeCurrentPopup();
        }
        zgui.endDisabled();

        zgui.endPopup();
    }
}

pub fn addAutomationLane(
    state: *PianoRollState,
    clip: *PianoRollClip,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
) void {
    var target_kind: AutomationTargetKind = .parameter;
    var target_id_buf: [32]u8 = undefined;
    var target_id: []const u8 = "";
    var param_id_buf: [32]u8 = undefined;
    var param_id: []const u8 = "";

    switch (state.automation_add_target) {
        .track_volume => {
            target_kind = .track;
            target_id = "track";
            param_id = "volume";
        },
        .track_pan => {
            target_kind = .track;
            target_id = "track";
            param_id = "pan";
        },
        .instrument_param => {
            target_kind = .parameter;
            target_id = "instrument";
            if (state.automation_add_param_id) |pid| {
                param_id = std.fmt.bufPrint(&param_id_buf, "{d}", .{pid}) catch "";
            }
        },
        .fx_param => {
            target_kind = .parameter;
            target_id = std.fmt.bufPrint(&target_id_buf, "fx{d}", .{state.automation_add_fx_index}) catch "fx0";
            if (state.automation_add_param_id) |pid| {
                param_id = std.fmt.bufPrint(&param_id_buf, "{d}", .{pid}) catch "";
            }
        },
    }

    if (param_id.len == 0 and (state.automation_add_target == .instrument_param or state.automation_add_target == .fx_param)) {
        return;
    }

    if (findAutomationLaneIndex(clip, target_kind, target_id, param_id)) |existing| {
        state.automation_lane_index = existing;
        state.automation_selected_point = null;
        return;
    }

    const target_id_copy = if (target_id.len > 0) clip.allocator.dupe(u8, target_id) catch "" else "";
    const param_id_copy = if (param_id.len > 0) (clip.allocator.dupe(u8, param_id) catch null) else null;

    _ = instrument_plugin;
    _ = fx_plugins;

    clip.automation.lanes.append(clip.allocator, .{
        .target_kind = target_kind,
        .target_id = target_id_copy,
        .param_id = param_id_copy,
        .unit = null,
        .points = .empty,
    }) catch return;

    state.automation_lane_index = clip.automation.lanes.items.len - 1;
    state.automation_selected_point = null;
}

fn findAutomationLaneIndex(
    clip: *PianoRollClip,
    target_kind: AutomationTargetKind,
    target_id: []const u8,
    param_id: []const u8,
) ?usize {
    for (clip.automation.lanes.items, 0..) |lane, idx| {
        if (lane.target_kind != target_kind) continue;
        if (!automationTargetIdMatch(lane.target_id, target_id)) continue;
        const lane_param = lane.param_id orelse "";
        if (!std.mem.eql(u8, lane_param, param_id)) continue;
        return idx;
    }
    return null;
}

fn automationTargetIdMatch(existing: []const u8, desired: []const u8) bool {
    if (std.mem.eql(u8, existing, desired)) return true;
    if (existing.len == 0 and std.mem.eql(u8, desired, "instrument")) return true;
    if (desired.len == 0 and std.mem.eql(u8, existing, "instrument")) return true;
    return false;
}

pub fn drawParamCombo(
    label: []const u8,
    plugin: ?*const clap.Plugin,
    selected_param: *?u32,
) bool {
    if (plugin == null) {
        zgui.textUnformatted("No plugin loaded.");
        return false;
    }
    const ext_raw = plugin.?.getExtension(plugin.?, clap.ext.params.id) orelse {
        zgui.textUnformatted("No parameters exposed.");
        return false;
    };
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const count = params.count(plugin.?);
    if (count == 0) {
        zgui.textUnformatted("No parameters exposed.");
        return false;
    }

    var preview_buf: [256]u8 = undefined;
    const preview_label = if (selected_param.*) |pid|
        getParamLabelById(&preview_buf, plugin.?, params, pid)
    else
        (std.fmt.bufPrintSentinel(&preview_buf, "Select parameter", .{}, 0) catch "Select parameter");

    var label_buf: [64]u8 = undefined;
    const label_z: [:0]const u8 = std.fmt.bufPrintSentinel(&label_buf, "{s}", .{label}, 0) catch "Parameter";
    if (zgui.beginCombo(label_z, .{ .preview_value = preview_label })) {
        for (0..count) |i| {
            var info: clap.ext.params.Info = undefined;
            if (!params.getInfo(plugin.?, @intCast(i), &info)) continue;
            var name_buf: [256]u8 = undefined;
            const name = formatParamLabelZ(&name_buf, &info);
            const selected = selected_param.* != null and selected_param.*.? == @intFromEnum(info.id);
            if (zgui.selectable(name, .{ .selected = selected })) {
                selected_param.* = @intFromEnum(info.id);
            }
        }
        zgui.endCombo();
    }
    return true;
}

pub fn drawAutomationOverlay(
    state: *PianoRollState,
    clip: *PianoRollClip,
    lane_index: usize,
    mouse: [2]f32,
    mouse_down: bool,
    grid_window_pos: [2]f32,
    grid_view_width: f32,
    grid_view_height: f32,
    pixels_per_beat: f32,
    quantize_beats: f32,
    automation_mode: bool,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
    draw_list: zgui.DrawList,
) void {
    if (lane_index >= clip.automation.lanes.items.len) return;
    var lane = &clip.automation.lanes.items[lane_index];
    if (lane.points.items.len == 0 and !automation_mode) return;

    const range = getAutomationRange(lane, instrument_plugin, fx_plugins);
    const min_value = range.min_value;
    const max_value = range.max_value;

    const in_grid = mouse[0] >= grid_window_pos[0] and mouse[0] < grid_window_pos[0] + grid_view_width and
        mouse[1] >= grid_window_pos[1] and mouse[1] < grid_window_pos[1] + grid_view_height;

    const point_radius = 4.0;
    var hovered_point: ?usize = null;

    for (lane.points.items, 0..) |point, idx| {
        const x = grid_window_pos[0] + point.time * pixels_per_beat - state.scroll_x;
        const y = valueToY(point.value, min_value, max_value, grid_window_pos[1], grid_view_height);
        if (@abs(mouse[0] - x) <= point_radius and @abs(mouse[1] - y) <= point_radius) {
            hovered_point = idx;
            break;
        }
    }

    if (automation_mode) {
        if (state.automation_drag_active) {
            if (mouse_down) {
                if (state.automation_drag_lane == lane_index and state.automation_drag_point < lane.points.items.len) {
                    const drag_time = selection.snapToStep(
                        std.math.clamp(mouseToBeat(mouse[0], grid_window_pos[0], state.scroll_x, pixels_per_beat), 0, clip.length_beats),
                        quantize_beats,
                    );
                    const drag_value = valueFromY(mouse[1], min_value, max_value, grid_window_pos[1], grid_view_height);
                    lane.points.items[state.automation_drag_point] = .{ .time = drag_time, .value = drag_value };
                    sortAutomationPoints(&lane.points);
                    state.automation_drag_point = findPointIndex(&lane.points, drag_time, drag_value);
                    state.automation_selected_point = state.automation_drag_point;
                }
            } else {
                state.automation_drag_active = false;
            }
        } else if (hovered_point) |idx| {
            if (zgui.isMouseClicked(.left)) {
                state.automation_drag_active = true;
                state.automation_drag_lane = lane_index;
                state.automation_drag_point = idx;
                state.automation_selected_point = idx;
            } else if (zgui.isMouseClicked(.right)) {
                _ = lane.points.orderedRemove(idx);
                if (state.automation_selected_point) |sel| {
                    if (sel == idx or sel >= lane.points.items.len) {
                        state.automation_selected_point = null;
                    }
                }
            }
        } else if (in_grid and zgui.isMouseClicked(.left)) {
            if (lane.points.items.len < 64) {
                const new_time = selection.snapToStep(
                    std.math.clamp(mouseToBeat(mouse[0], grid_window_pos[0], state.scroll_x, pixels_per_beat), 0, clip.length_beats),
                    quantize_beats,
                );
                const new_value = valueFromY(mouse[1], min_value, max_value, grid_window_pos[1], grid_view_height);
                lane.points.append(clip.allocator, .{ .time = new_time, .value = new_value }) catch {};
                sortAutomationPoints(&lane.points);
                state.automation_selected_point = findPointIndex(&lane.points, new_time, new_value);
            }
        }
    }

    sortAutomationPoints(&lane.points);

    if (lane.points.items.len > 1) {
        const line_color = zgui.colorConvertFloat4ToU32(colors.Colors.current.accent);
        for (lane.points.items, 0..) |point, idx| {
            if (idx == 0) continue;
            const prev = lane.points.items[idx - 1];
            const x1 = grid_window_pos[0] + prev.time * pixels_per_beat - state.scroll_x;
            const y1 = valueToY(prev.value, min_value, max_value, grid_window_pos[1], grid_view_height);
            const x2 = grid_window_pos[0] + point.time * pixels_per_beat - state.scroll_x;
            const y2 = valueToY(point.value, min_value, max_value, grid_window_pos[1], grid_view_height);
            draw_list.addLine(.{ .p1 = .{ x1, y1 }, .p2 = .{ x2, y2 }, .col = line_color, .thickness = 2.0 });
        }
    }

    for (lane.points.items, 0..) |point, idx| {
        const x = grid_window_pos[0] + point.time * pixels_per_beat - state.scroll_x;
        const y = valueToY(point.value, min_value, max_value, grid_window_pos[1], grid_view_height);
        const is_selected = state.automation_selected_point != null and state.automation_selected_point.? == idx;
        const point_color = if (is_selected) colors.Colors.current.note_handle_selected else colors.Colors.current.note_handle;
        draw_list.addCircleFilled(.{ .p = .{ x, y }, .r = point_radius, .col = zgui.colorConvertFloat4ToU32(point_color) });
    }
}

const AutomationRange = struct {
    min_value: f32,
    max_value: f32,
};

pub fn getAutomationRange(
    lane: *const AutomationLane,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
) AutomationRange {
    if (lane.target_kind == .track) {
        if (lane.param_id) |param_id| {
            if (std.mem.eql(u8, param_id, "volume")) {
                return .{ .min_value = 0.0, .max_value = 2.0 };
            }
            if (std.mem.eql(u8, param_id, "pan")) {
                return .{ .min_value = 0.0, .max_value = 1.0 };
            }
        }
    }

    const plugin = getLanePlugin(lane, instrument_plugin, fx_plugins) orelse return .{ .min_value = 0.0, .max_value = 1.0 };
    const param_id = lane.param_id orelse return .{ .min_value = 0.0, .max_value = 1.0 };
    const pid = std.fmt.parseInt(u32, param_id, 10) catch return .{ .min_value = 0.0, .max_value = 1.0 };

    var info: clap.ext.params.Info = undefined;
    if (findParamInfo(plugin, pid, &info)) {
        const min_value: f32 = @floatCast(info.min_value);
        const max_value: f32 = @floatCast(info.max_value);
        if (max_value > min_value) {
            return .{ .min_value = min_value, .max_value = max_value };
        }
    }
    return .{ .min_value = 0.0, .max_value = 1.0 };
}

fn getLanePlugin(
    lane: *const AutomationLane,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
) ?*const clap.Plugin {
    if (lane.target_kind != .parameter) return null;
    if (lane.target_id.len == 0 or std.mem.eql(u8, lane.target_id, "instrument")) {
        return instrument_plugin;
    }
    if (parseFxIndex(lane.target_id)) |fx_index| {
        if (fx_index < fx_plugins.len) {
            return fx_plugins[fx_index];
        }
    }
    return null;
}

pub fn valueToY(value: f32, min_value: f32, max_value: f32, top: f32, height: f32) f32 {
    const clamped = std.math.clamp(value, min_value, max_value);
    const t = if (max_value > min_value) (clamped - min_value) / (max_value - min_value) else 0.0;
    return top + (1.0 - t) * height;
}

pub fn valueFromY(y: f32, min_value: f32, max_value: f32, top: f32, height: f32) f32 {
    const t = 1.0 - std.math.clamp((y - top) / height, 0.0, 1.0);
    return min_value + t * (max_value - min_value);
}

fn sortAutomationPoints(points: *std.ArrayListUnmanaged(AutomationPoint)) void {
    std.mem.sort(AutomationPoint, points.items, {}, struct {
        fn lessThan(_: void, a: AutomationPoint, b: AutomationPoint) bool {
            return a.time < b.time;
        }
    }.lessThan);
}

fn findPointIndex(points: *const std.ArrayListUnmanaged(AutomationPoint), time: f32, value: f32) usize {
    for (points.items, 0..) |point, idx| {
        if (std.math.approxEqAbs(f32, point.time, time, 0.0001) and std.math.approxEqAbs(f32, point.value, value, 0.0001)) {
            return idx;
        }
    }
    return 0;
}

fn parseFxIndex(target_id: []const u8) ?usize {
    if (!std.mem.startsWith(u8, target_id, "fx")) return null;
    var idx_str = target_id["fx".len..];
    if (std.mem.startsWith(u8, idx_str, ":")) {
        idx_str = idx_str[1..];
    }
    return std.fmt.parseInt(usize, idx_str, 10) catch null;
}

fn automationLaneLabel(
    buf: []u8,
    lane: *const AutomationLane,
    instrument_plugin: ?*const clap.Plugin,
    fx_plugins: []const ?*const clap.Plugin,
) [:0]const u8 {
    if (lane.target_kind == .track) {
        if (lane.param_id) |param_id| {
            if (std.mem.eql(u8, param_id, "volume")) {
                return std.fmt.bufPrintSentinel(buf, "Track Volume", .{}, 0) catch "Track Volume";
            }
            if (std.mem.eql(u8, param_id, "pan")) {
                return std.fmt.bufPrintSentinel(buf, "Track Pan", .{}, 0) catch "Track Pan";
            }
        }
        return std.fmt.bufPrintSentinel(buf, "Track Automation", .{}, 0) catch "Track Automation";
    }

    var target_buf: [64]u8 = undefined;
    const target_label = if (lane.target_id.len == 0 or std.mem.eql(u8, lane.target_id, "instrument")) blk: {
        break :blk "Instrument";
    } else if (parseFxIndex(lane.target_id)) |fx_index| blk: {
        break :blk std.fmt.bufPrint(&target_buf, "FX {d}", .{fx_index + 1}) catch "FX";
    } else blk: {
        break :blk "Device";
    };

    const param_label = if (lane.param_id) |param_id| blk: {
        const pid = std.fmt.parseInt(u32, param_id, 10) catch break :blk param_id;
        const plugin = getLanePlugin(lane, instrument_plugin, fx_plugins) orelse break :blk param_id;
        const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse break :blk param_id;
        const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
        var label_buf: [256]u8 = undefined;
        break :blk getParamLabelById(&label_buf, plugin, params, pid);
    } else "Param";

    return std.fmt.bufPrintSentinel(buf, "{s}: {s}", .{ target_label, param_label }, 0) catch "Automation";
}

fn findParamInfo(plugin: *const clap.Plugin, param_id: u32, out: *clap.ext.params.Info) bool {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse return false;
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const count = params.count(plugin);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (!params.getInfo(plugin, @intCast(i), out)) continue;
        if (@intFromEnum(out.id) == param_id) return true;
    }
    return false;
}

fn getParamLabelById(
    buf: []u8,
    plugin: *const clap.Plugin,
    params: *const clap.ext.params.Plugin,
    param_id: u32,
) [:0]const u8 {
    const count = params.count(plugin);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var info: clap.ext.params.Info = undefined;
        if (!params.getInfo(plugin, @intCast(i), &info)) continue;
        if (@intFromEnum(info.id) != param_id) continue;
        return formatParamLabelZ(buf, &info);
    }
    return std.fmt.bufPrintSentinel(buf, "Param {d}", .{param_id}, 0) catch "Param";
}

fn formatParamLabelZ(buf: []u8, info: *const clap.ext.params.Info) [:0]const u8 {
    const name = selection.sliceToNull(info.name[0..]);
    const module = selection.sliceToNull(info.module[0..]);
    if (module.len > 0) {
        return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ module, name }, 0) catch "Param";
    }
    return std.fmt.bufPrintSentinel(buf, "{s}", .{name}, 0) catch "Param";
}
