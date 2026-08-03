//! Piano-roll automation lanes: header, add dialog, overlay, edit gestures.
const std = @import("std");
const dvui = @import("dvui");
const clap = @import("clap-bindings");
const theme = @import("../theme.zig");
const state_mod = @import("../state.zig");
const document_model = @import("../../document/model.zig");
const document_commands = @import("../../document/commands.zig");
const notes_mod = @import("../../session/notes.zig");
const plugin_host = @import("../plugin_host.zig");
const layout = @import("piano_roll_layout.zig");

pub fn syncAutomationLaneIndex(state: *state_mod.State, clip: *const notes_mod.PianoRollClip) void {
    const lane_count = clip.automation.lanes.items.len;
    if (lane_count == 0) {
        state.piano_automation_lane_index = null;
        state.piano_automation_selected_point = null;
        return;
    }
    if (state.piano_automation_lane_index == null or state.piano_automation_lane_index.? >= lane_count) {
        state.piano_automation_lane_index = 0;
        state.piano_automation_selected_point = null;
    }
}

pub fn drawAutomationHeader(state: *state_mod.State, clip: *notes_mod.PianoRollClip) void {
    syncAutomationLaneIndex(state, clip);

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    dvui.label(@src(), "Automation:", .{}, .{ .color_text = theme.text_dim, .gravity_y = 0.5 });

    var label_bufs: [layout.max_automation_lane_ui][160]u8 = undefined;
    var labels: [layout.max_automation_lane_ui][]const u8 = undefined;
    const lane_count = @min(clip.automation.lanes.items.len, layout.max_automation_lane_ui);
    if (lane_count == 0) {
        labels[0] = "None";
        var choice: usize = 0;
        _ = dvui.dropdown(@src(), labels[0..1], .{ .choice = &choice }, .{}, .{
            .min_size_content = .{ .w = 180, .h = 22 },
            .gravity_y = 0.5,
        });
    } else {
        for (0..lane_count) |i| {
            labels[i] = automationLaneLabel(&label_bufs[i], &clip.automation.lanes.items[i], state.selected_track);
        }
        var choice: usize = @min(state.piano_automation_lane_index orelse 0, lane_count - 1);
        if (dvui.dropdown(@src(), labels[0..lane_count], .{ .choice = &choice }, .{}, .{
            .min_size_content = .{ .w = 200, .h = 22 },
            .gravity_y = 0.5,
        })) {
            state.piano_automation_lane_index = choice;
            state.piano_automation_selected_point = null;
        } else {
            state.piano_automation_lane_index = choice;
        }
    }

    if (dvui.button(@src(), "Add Lane", .{}, .{ .gravity_y = 0.5 })) {
        state.piano_automation_add_param_id = null;
        state.piano_automation_add_open = true;
    }
    if (state.piano_automation_lane_index) |idx| {
        if (dvui.button(@src(), "Remove", .{}, .{ .gravity_y = 0.5 })) {
            removeAutomationLaneAt(state, clip, idx);
        }
    }
    _ = dvui.checkbox(@src(), &state.piano_automation_edit, "Edit", .{ .gravity_y = 0.5 });
}

pub fn drawAutomationAddDialog(state: *state_mod.State, clip: *notes_mod.PianoRollClip) void {
    _ = clip;
    if (!state.piano_automation_add_open) return;

    var fw = dvui.floatingWindow(@src(), .{
        .open_flag = &state.piano_automation_add_open,
        .modal = false,
        .resize = .none,
        .stay_above_parent_window = true,
    }, .{
        .min_size_content = .{ .w = 280, .h = 200 },
        .max_size_content = .{ .w = 320, .h = 360 },
        .background = true,
        .color_fill = theme.panel,
        .border = dvui.Rect.all(1),
        .color_border = theme.accent,
        .padding = dvui.Rect.all(10),
    });
    defer fw.deinit();
    fw.dragAreaSet(dvui.windowHeader("Add automation lane", "", &state.piano_automation_add_open));

    const target_labels = [_][]const u8{ "Track Volume", "Track Pan", "Instrument Param", "FX Param" };
    var target_choice: usize = @intFromEnum(state.piano_automation_add_target);
    if (dvui.dropdown(@src(), &target_labels, .{ .choice = &target_choice }, .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 22 },
    })) {
        state.piano_automation_add_target = @enumFromInt(target_choice);
        state.piano_automation_add_param_id = null;
    } else {
        state.piano_automation_add_target = @enumFromInt(@min(target_choice, target_labels.len - 1));
    }

    const track = state.selected_track;
    const fx_count = if (plugin_host.ready() and track < plugin_host.track_count) plugin_host.g.fx_counts[track] else 0;

    if (state.piano_automation_add_target == .fx_param) {
        if (fx_count == 0) {
            dvui.label(@src(), "No FX slots on this track.", .{}, .{ .color_text = theme.text_soft });
        } else {
            var fx_labels: [plugin_host.max_fx_slots][]const u8 = undefined;
            var fx_bufs: [plugin_host.max_fx_slots][24]u8 = undefined;
            const n = @min(fx_count, plugin_host.max_fx_slots);
            for (0..n) |i| {
                fx_labels[i] = std.fmt.bufPrint(&fx_bufs[i], "FX {d}", .{i + 1}) catch "FX";
            }
            var fx_choice: usize = @min(state.piano_automation_add_fx_index, n - 1);
            if (dvui.dropdown(@src(), fx_labels[0..n], .{ .choice = &fx_choice }, .{}, .{
                .expand = .horizontal,
                .min_size_content = .{ .h = 22 },
            })) {
                state.piano_automation_add_fx_index = fx_choice;
                state.piano_automation_add_param_id = null;
            } else {
                state.piano_automation_add_fx_index = fx_choice;
            }
        }
    }

    var has_param_selection = true;
    if (state.piano_automation_add_target == .instrument_param or state.piano_automation_add_target == .fx_param) {
        has_param_selection = drawParamPicker(state);
    }

    const allow_add = switch (state.piano_automation_add_target) {
        .track_volume, .track_pan => true,
        .instrument_param, .fx_param => has_param_selection and state.piano_automation_add_param_id != null,
    };

    if (allow_add) {
        if (dvui.button(@src(), "Create Lane", .{}, .{ .expand = .horizontal })) {
            createAutomationLane(state);
            state.piano_automation_add_open = false;
        }
    } else {
        dvui.label(@src(), "Select a parameter to continue.", .{}, .{ .color_text = theme.text_soft });
    }
}

pub fn drawParamPicker(state: *state_mod.State) bool {
    const plugin = switch (state.piano_automation_add_target) {
        .instrument_param => instrumentPlugin(state.selected_track),
        .fx_param => fxPlugin(state.selected_track, state.piano_automation_add_fx_index),
        else => null,
    };
    if (plugin == null) {
        dvui.label(@src(), "No plugin loaded.", .{}, .{ .color_text = theme.text_soft });
        return false;
    }
    const ext_raw = plugin.?.getExtension(plugin.?, clap.ext.params.id) orelse {
        dvui.label(@src(), "No parameters exposed.", .{}, .{ .color_text = theme.text_soft });
        return false;
    };
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    const count = params.count(plugin.?);
    if (count == 0) {
        dvui.label(@src(), "No parameters exposed.", .{}, .{ .color_text = theme.text_soft });
        return false;
    }

    var label_bufs: [layout.max_param_choices][128]u8 = undefined;
    var labels: [layout.max_param_choices][]const u8 = undefined;
    var ids: [layout.max_param_choices]u32 = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < count and n < layout.max_param_choices) : (i += 1) {
        var info: clap.ext.params.Info = undefined;
        if (!params.getInfo(plugin.?, i, &info)) continue;
        if (info.flags.is_hidden) continue;
        ids[n] = @intFromEnum(info.id);
        labels[n] = formatParamLabel(&label_bufs[n], &info);
        n += 1;
    }
    if (n == 0) {
        dvui.label(@src(), "No automatable parameters.", .{}, .{ .color_text = theme.text_soft });
        return false;
    }

    var choice: usize = 0;
    if (state.piano_automation_add_param_id) |pid| {
        for (ids[0..n], 0..) |id, idx| {
            if (id == pid) {
                choice = idx;
                break;
            }
        }
    }
    if (dvui.dropdown(@src(), labels[0..n], .{ .choice = &choice }, .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 22 },
    })) {
        state.piano_automation_add_param_id = ids[choice];
    } else if (state.piano_automation_add_param_id == null) {
        // Keep null until the user opens the dropdown so "Select" is intentional.
    } else {
        state.piano_automation_add_param_id = ids[@min(choice, n - 1)];
    }
    return true;
}

pub fn createAutomationLane(state: *state_mod.State) void {
    if (!document_model.ready()) return;
    const target: document_commands.AutomationAddTarget = switch (state.piano_automation_add_target) {
        .track_volume => .track_volume,
        .track_pan => .track_pan,
        .instrument_param => .instrument_param,
        .fx_param => .fx_param,
    };
    if (document_commands.addAutomationLane(
        &document_model.g,
        state.selected_track,
        state.selected_scene,
        target,
        state.piano_automation_add_fx_index,
        state.piano_automation_add_param_id,
    )) |idx| {
        state.piano_automation_lane_index = idx;
        state.piano_automation_selected_point = null;
    }
}

pub fn removeAutomationLaneAt(state: *state_mod.State, clip: *const notes_mod.PianoRollClip, idx: usize) void {
    if (!document_model.ready()) return;
    if (!document_commands.removeAutomationLane(&document_model.g, state.selected_track, state.selected_scene, idx)) return;
    if (clip.automation.lanes.items.len == 0) {
        state.piano_automation_lane_index = null;
    } else {
        state.piano_automation_lane_index = @min(idx, clip.automation.lanes.items.len - 1);
    }
    state.piano_automation_selected_point = null;
}

pub fn deleteSelectedAutomationPoint(state: *state_mod.State, clip: *const notes_mod.PianoRollClip) void {
    const lane_index = state.piano_automation_lane_index orelse return;
    const point_index = state.piano_automation_selected_point orelse return;
    removeAutomationPointAt(state, clip, lane_index, point_index);
}

pub fn removeAutomationPointAt(state: *state_mod.State, clip: *const notes_mod.PianoRollClip, lane_index: usize, point_index: usize) void {
    _ = clip;
    if (!document_model.ready()) return;
    if (!document_commands.removeAutomationPoint(
        &document_model.g,
        state.selected_track,
        state.selected_scene,
        lane_index,
        point_index,
    )) return;
    state.piano_automation_selected_point = null;
}

pub fn drawAutomationOverlay(
    state: *const state_mod.State,
    clip: *const notes_mod.PianoRollClip,
    lane_index: usize,
    area: dvui.Rect.Physical,
    scale: f32,
) void {
    if (lane_index >= clip.automation.lanes.items.len) return;
    const lane = &clip.automation.lanes.items[lane_index];
    if (lane.points.items.len == 0 and !state.piano_automation_edit) return;

    const range = automationRange(state, clip, lane_index);
    const radius = layout.automation_point_radius * scale;

    if (lane.points.items.len > 1) {
        var i: usize = 1;
        while (i < lane.points.items.len) : (i += 1) {
            const prev = lane.points.items[i - 1];
            const point = lane.points.items[i];
            const x1 = layout.beatX(state, prev.time, area, scale);
            const y1 = valueToY(prev.value, range.min_value, range.max_value, area.y, area.h);
            const x2 = layout.beatX(state, point.time, area, scale);
            const y2 = valueToY(point.value, range.min_value, range.max_value, area.y, area.h);
            // Skip segments fully outside the horizontal viewport.
            if ((x1 < area.x and x2 < area.x) or (x1 > area.x + area.w and x2 > area.x + area.w)) continue;
            const path: dvui.Path = .{ .points = &.{
                .{ .x = x1, .y = y1 },
                .{ .x = x2, .y = y2 },
            } };
            path.stroke(.{ .thickness = 2 * scale, .color = theme.accent });
        }
    }

    for (lane.points.items, 0..) |point, idx| {
        const x = layout.beatX(state, point.time, area, scale);
        const y = valueToY(point.value, range.min_value, range.max_value, area.y, area.h);
        if (x < area.x - radius or x > area.x + area.w + radius) continue;
        if (y < area.y - radius or y > area.y + area.h + radius) continue;
        const selected = state.piano_automation_selected_point != null and state.piano_automation_selected_point.? == idx;
        const color = if (selected) theme.play else theme.accent;
        const rect: dvui.Rect.Physical = .{
            .x = x - radius,
            .y = y - radius,
            .w = radius * 2,
            .h = radius * 2,
        };
        rect.fill(.all(radius), .{ .color = color });
    }
}

pub fn hitAutomationPoint(
    state: *const state_mod.State,
    clip: *const notes_mod.PianoRollClip,
    lane_index: usize,
    point: dvui.Point.Physical,
    area: dvui.Rect.Physical,
    scale: f32,
) ?usize {
    if (lane_index >= clip.automation.lanes.items.len) return null;
    const lane = &clip.automation.lanes.items[lane_index];
    const range = automationRange(state, clip, lane_index);
    const radius = layout.automation_point_radius * scale + 2 * scale;
    for (lane.points.items, 0..) |pt, idx| {
        const x = layout.beatX(state, pt.time, area, scale);
        const y = valueToY(pt.value, range.min_value, range.max_value, area.y, area.h);
        if (@abs(point.x - x) <= radius and @abs(point.y - y) <= radius) return idx;
    }
    return null;
}

pub fn dragAutomationPoint(
    state: *state_mod.State,
    clip: *notes_mod.PianoRollClip,
    point: dvui.Point.Physical,
    area: dvui.Rect.Physical,
    scale: f32,
) void {
    if (!document_model.ready()) return;
    const lane_index = state.piano_automation_drag_lane;
    if (lane_index >= clip.automation.lanes.items.len) return;
    if (state.piano_automation_drag_point >= clip.automation.lanes.items[lane_index].points.items.len) return;

    const range = automationRange(state, clip, lane_index);
    const time = layout.quantize(
        std.math.clamp(layout.beatAtX(state, point.x, area, scale), 0, clip.length_beats),
        layout.quantizeStep(state),
    );
    const value = valueFromY(point.y, range.min_value, range.max_value, area.y, area.h);
    if (document_commands.setAutomationPointInPlace(
        &document_model.g,
        state.selected_track,
        state.selected_scene,
        lane_index,
        state.piano_automation_drag_point,
        time,
        value,
    )) |new_idx| {
        state.piano_automation_drag_point = new_idx;
        state.piano_automation_selected_point = new_idx;
        state.piano_automation_drag_changed = true;
    }
}

pub const AutomationRange = struct { min_value: f32, max_value: f32 };

pub fn automationRange(
    state: *const state_mod.State,
    clip: *const notes_mod.PianoRollClip,
    lane_index: usize,
) AutomationRange {
    if (lane_index >= clip.automation.lanes.items.len) return .{ .min_value = 0, .max_value = 1 };
    const lane = &clip.automation.lanes.items[lane_index];
    if (lane.target_kind == .track) {
        if (lane.param_id) |param_id| {
            if (std.mem.eql(u8, param_id, "volume")) return .{ .min_value = 0, .max_value = 2 };
            if (std.mem.eql(u8, param_id, "pan")) return .{ .min_value = 0, .max_value = 1 };
        }
        return .{ .min_value = 0, .max_value = 1 };
    }

    const plugin = lanePlugin(lane, state.selected_track) orelse return .{ .min_value = 0, .max_value = 1 };
    const param_id = lane.param_id orelse return .{ .min_value = 0, .max_value = 1 };
    const pid = std.fmt.parseInt(u32, param_id, 10) catch return .{ .min_value = 0, .max_value = 1 };
    var info: clap.ext.params.Info = undefined;
    if (findParamInfo(plugin, pid, &info)) {
        const min_value: f32 = @floatCast(info.min_value);
        const max_value: f32 = @floatCast(info.max_value);
        if (max_value > min_value) return .{ .min_value = min_value, .max_value = max_value };
    }
    return .{ .min_value = 0, .max_value = 1 };
}

pub fn valueToY(value: f32, min_value: f32, max_value: f32, top: f32, height: f32) f32 {
    const clamped = std.math.clamp(value, min_value, max_value);
    const t = if (max_value > min_value) (clamped - min_value) / (max_value - min_value) else 0.0;
    return top + (1.0 - t) * height;
}

pub fn valueFromY(y: f32, min_value: f32, max_value: f32, top: f32, height: f32) f32 {
    const t = 1.0 - std.math.clamp((y - top) / @max(1, height), 0.0, 1.0);
    return min_value + t * (max_value - min_value);
}

pub fn instrumentPlugin(track: usize) ?*const clap.Plugin {
    if (!plugin_host.ready() or track >= plugin_host.track_count) return null;
    return plugin_host.g.instruments[track].getPlugin();
}

pub fn fxPlugin(track: usize, fx_index: usize) ?*const clap.Plugin {
    if (!plugin_host.ready() or track >= plugin_host.track_count) return null;
    if (fx_index >= plugin_host.max_fx_slots) return null;
    return plugin_host.g.fx[track][fx_index].getPlugin();
}

pub fn lanePlugin(lane: *const notes_mod.AutomationLane, track: usize) ?*const clap.Plugin {
    if (lane.target_kind != .parameter) return null;
    if (lane.target_id.len == 0 or std.mem.eql(u8, lane.target_id, "instrument")) {
        return instrumentPlugin(track);
    }
    if (parseFxIndex(lane.target_id)) |fx_index| {
        return fxPlugin(track, fx_index);
    }
    return null;
}

pub fn parseFxIndex(target_id: []const u8) ?usize {
    if (!std.mem.startsWith(u8, target_id, "fx")) return null;
    var idx_str = target_id["fx".len..];
    if (std.mem.startsWith(u8, idx_str, ":")) idx_str = idx_str[1..];
    return std.fmt.parseInt(usize, idx_str, 10) catch null;
}

pub fn automationLaneLabel(buf: []u8, lane: *const notes_mod.AutomationLane, track: usize) []const u8 {
    if (lane.target_kind == .track) {
        if (lane.param_id) |param_id| {
            if (std.mem.eql(u8, param_id, "volume")) return "Track Volume";
            if (std.mem.eql(u8, param_id, "pan")) return "Track Pan";
        }
        return "Track Automation";
    }

    const target_label: []const u8 = if (lane.target_id.len == 0 or std.mem.eql(u8, lane.target_id, "instrument"))
        "Instrument"
    else if (parseFxIndex(lane.target_id)) |fx_index|
        std.fmt.bufPrint(buf[0..32], "FX {d}", .{fx_index + 1}) catch "FX"
    else
        "Device";

    var param_buf: [96]u8 = undefined;
    const param_label: []const u8 = if (lane.param_id) |param_id| blk: {
        const pid = std.fmt.parseInt(u32, param_id, 10) catch break :blk param_id;
        const plugin = lanePlugin(lane, track) orelse break :blk param_id;
        const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse break :blk param_id;
        const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
        break :blk getParamLabelById(&param_buf, plugin, params, pid);
    } else "Param";

    // When target_label was written into buf, rebuild carefully.
    if (std.mem.startsWith(u8, target_label, "FX ")) {
        var scratch: [160]u8 = undefined;
        const full = std.fmt.bufPrint(&scratch, "{s}: {s}", .{ target_label, param_label }) catch "Automation";
        const n = @min(full.len, buf.len);
        @memcpy(buf[0..n], full[0..n]);
        return buf[0..n];
    }
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ target_label, param_label }) catch "Automation";
}

pub fn findParamInfo(plugin: *const clap.Plugin, param_id: u32, out: *clap.ext.params.Info) bool {
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

pub fn getParamLabelById(
    buf: []u8,
    plugin: *const clap.Plugin,
    params: *const clap.ext.params.Plugin,
    param_id: u32,
) []const u8 {
    const count = params.count(plugin);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var info: clap.ext.params.Info = undefined;
        if (!params.getInfo(plugin, @intCast(i), &info)) continue;
        if (@intFromEnum(info.id) != param_id) continue;
        return formatParamLabel(buf, &info);
    }
    return std.fmt.bufPrint(buf, "Param {d}", .{param_id}) catch "Param";
}

pub fn formatParamLabel(buf: []u8, info: *const clap.ext.params.Info) []const u8 {
    const name = std.mem.sliceTo(info.name[0..], 0);
    const module = std.mem.sliceTo(info.module[0..], 0);
    if (module.len > 0) {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ module, name }) catch name;
    }
    if (name.len == 0) return "Param";
    const n = @min(name.len, buf.len);
    @memcpy(buf[0..n], name[0..n]);
    return buf[0..n];
}
