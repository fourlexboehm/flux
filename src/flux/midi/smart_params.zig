const std = @import("std");
const clap = @import("clap-bindings");

const state_mod = @import("../ui/state.zig");

const State = state_mod.State;
const ControllerSmartParam = state_mod.ControllerSmartParam;
const controller_smart_slots = state_mod.controller_smart_slots;

const RankedParam = struct {
    order: u32,
    score: i32,
    param_id: u32,
    min_value: f64,
    max_value: f64,
    label: [96]u8,
    label_len: usize,
};

pub fn pageCount(state: *const State) usize {
    if (state.controller.smart_param_count == 0) return 0;
    return std.math.divCeil(usize, state.controller.smart_param_count, controller_smart_slots) catch 0;
}

pub fn setPageDelta(state: *State, delta: i32) void {
    const pages = pageCount(state);
    if (pages == 0) {
        state.controller.smart_page = 0;
        return;
    }
    const current: i32 = @intCast(state.controller.smart_page);
    const next = std.math.clamp(current + delta, 0, @as(i32, @intCast(pages - 1)));
    state.controller.smart_page = @intCast(next);
}

pub fn slotForKnob(state: *const State, knob_index: usize) ?ControllerSmartParam {
    if (knob_index >= controller_smart_slots) return null;
    const idx = state.controller.smart_page * controller_smart_slots + knob_index;
    if (idx >= state.controller.smart_param_count) return null;
    return state.controller.smart_params[idx];
}

pub fn rebuildIfNeeded(state: *State) void {
    const plugin = state.device_clap_plugin;
    const target_track = state.device_target_track;
    const target_kind = state.device_target_kind;
    const target_fx = state.device_target_fx;

    if (state.controller.smart_target_plugin == plugin and
        state.controller.smart_target_track == target_track and
        state.controller.smart_target_kind == target_kind and
        state.controller.smart_target_fx == target_fx)
    {
        return;
    }

    state.controller.smart_target_plugin = plugin;
    state.controller.smart_target_track = target_track;
    state.controller.smart_target_kind = target_kind;
    state.controller.smart_target_fx = target_fx;
    state.controller.smart_param_count = 0;
    state.controller.smart_page = 0;

    const plug = plugin orelse return;
    const ext_raw = plug.getExtension(plug, clap.ext.params.id) orelse return;
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));

    const count = params.count(plug);
    if (count == 0) return;

    var ranked: std.ArrayListUnmanaged(RankedParam) = .{};
    defer ranked.deinit(state.allocator);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var info: clap.ext.params.Info = undefined;
        if (!params.getInfo(plug, i, &info)) continue;
        if (info.flags.is_hidden or info.flags.is_read_only) continue;

        const label = buildLabel(&info);
        const score = scoreParam(label[0..labelLen(label)]);

        ranked.append(state.allocator, .{
            .order = i,
            .score = score,
            .param_id = @intFromEnum(info.id),
            .min_value = info.min_value,
            .max_value = info.max_value,
            .label = label,
            .label_len = labelLen(label),
        }) catch break;
    }

    if (ranked.items.len == 0) return;

    std.mem.sort(RankedParam, ranked.items, {}, struct {
        fn lessThan(_: void, a: RankedParam, b: RankedParam) bool {
            if (a.score == b.score) return a.order < b.order;
            return a.score > b.score;
        }
    }.lessThan);

    const copy_count = @min(ranked.items.len, state.controller.smart_params.len);
    for (0..copy_count) |idx| {
        const item = ranked.items[idx];
        state.controller.smart_params[idx] = .{
            .param_id = item.param_id,
            .min_value = item.min_value,
            .max_value = item.max_value,
            .label = item.label,
            .label_len = item.label_len,
        };
    }
    state.controller.smart_param_count = copy_count;
}

fn buildLabel(info: *const clap.ext.params.Info) [96]u8 {
    var out = [_]u8{0} ** 96;
    const name = sliceToNull(info.name[0..]);
    const module = sliceToNull(info.module[0..]);
    var idx: usize = 0;
    appendLabel(&out, &idx, module);
    if (module.len > 0) appendByte(&out, &idx, '/');
    appendLabel(&out, &idx, name);
    return out;
}

fn labelLen(label: [96]u8) usize {
    return std.mem.indexOfScalar(u8, label[0..], 0) orelse label.len;
}

fn scoreParam(label: []const u8) i32 {
    var score: i32 = 0;

    if (containsAsciiIgnoreCase(label, "bypass")) score -= 100;
    if (containsAsciiIgnoreCase(label, "master") and containsAsciiIgnoreCase(label, "vol")) score -= 40;
    if (containsAsciiIgnoreCase(label, "output") and containsAsciiIgnoreCase(label, "gain")) score -= 30;

    if (containsAsciiIgnoreCase(label, "cutoff")) score += 80;
    if (containsAsciiIgnoreCase(label, "res") or containsAsciiIgnoreCase(label, "resonance")) score += 72;
    if (containsAsciiIgnoreCase(label, "attack")) score += 62;
    if (containsAsciiIgnoreCase(label, "decay")) score += 60;
    if (containsAsciiIgnoreCase(label, "sustain")) score += 58;
    if (containsAsciiIgnoreCase(label, "release")) score += 56;
    if (containsAsciiIgnoreCase(label, "env")) score += 40;
    if (containsAsciiIgnoreCase(label, "filter")) score += 38;
    if (containsAsciiIgnoreCase(label, "osc")) score += 34;
    if (containsAsciiIgnoreCase(label, "shape") or containsAsciiIgnoreCase(label, "wave")) score += 28;
    if (containsAsciiIgnoreCase(label, "pulse") or containsAsciiIgnoreCase(label, "pwm")) score += 26;
    if (containsAsciiIgnoreCase(label, "drive") or containsAsciiIgnoreCase(label, "dist")) score += 30;
    if (containsAsciiIgnoreCase(label, "mix")) score += 24;
    if (containsAsciiIgnoreCase(label, "time") or containsAsciiIgnoreCase(label, "rate")) score += 22;
    if (containsAsciiIgnoreCase(label, "feedback")) score += 22;
    if (containsAsciiIgnoreCase(label, "detune") or containsAsciiIgnoreCase(label, "tune")) score += 20;

    if (containsAsciiIgnoreCase(label, "gain") or containsAsciiIgnoreCase(label, "volume")) score += 6;

    return score;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (toLowerAscii(haystack[i + j]) != toLowerAscii(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn toLowerAscii(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + 32;
    return ch;
}

fn sliceToNull(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

fn appendLabel(dst: *[96]u8, idx: *usize, src: []const u8) void {
    for (src) |ch| {
        if (idx.* >= dst.len - 1) break;
        dst[idx.*] = ch;
        idx.* += 1;
    }
}

fn appendByte(dst: *[96]u8, idx: *usize, ch: u8) void {
    if (idx.* >= dst.len - 1) return;
    dst[idx.*] = ch;
    idx.* += 1;
}
