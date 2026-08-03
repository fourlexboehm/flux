//! Shared audio/plugin drop application for browser drags and native OS drops.
//! Hit-testing uses chrome slot/lane rects; mutations go through document commands.

const std = @import("std");
const dvui = @import("dvui");
const state_mod = @import("state.zig");
const host_mod = @import("host.zig");
const plugin_host = @import("plugin_host.zig");
const document_model = @import("../document/model.zig");
const document_commands = @import("../document/commands.zig");
const native_drop = @import("../app/native_drop.zig");

const io: std.Io = std.Io.Threaded.global_single_threaded.io();

/// Load an audio path into the current view selection (session slot or arr playhead).
pub fn loadAudioAtSelection(state: *state_mod.State, abs_path: []const u8) bool {
    if (!document_model.ready() or abs_path.len == 0) return false;
    const store = &document_model.g;
    if (state.view_mode == .arrangement) {
        const start_tick: i64 = @intFromFloat(state.playhead_beat * 960.0);
        if (document_commands.loadAudioFileIntoArrangement(
            store,
            state.selected_track,
            abs_path,
            start_tick,
            state.bpm,
            io,
        )) |idx| {
            state.selected_arr_clip = idx;
            if (host_mod.ready()) host_mod.g.projectChrome(state);
            return true;
        }
        return false;
    }
    if (document_commands.loadAudioFileIntoSession(
        store,
        state.selected_track,
        state.selected_scene,
        abs_path,
        state.beatsPerBar(),
        io,
    )) {
        state.selectSlot(state.selected_track, state.selected_scene);
        if (host_mod.ready()) host_mod.g.projectChrome(state);
        return true;
    }
    return false;
}

/// Apply browser drag payload at a physical point (session slots / arrangement lanes).
pub fn applyBrowserDropAt(state: *state_mod.State, point: dvui.Point.Physical) bool {
    switch (state.browser_drag_kind) {
        .none => return false,
        .audio_file => {
            const path = state.browserDragPath();
            if (path.len == 0) return false;
            return applyAudioAtPoint(state, point, path);
        },
        .plugin_instrument, .plugin_fx => {
            if (!plugin_host.ready()) return false;
            const choice = state.browser_drag_catalog_index;
            if (choice <= 0) return false;
            const is_fx = state.browser_drag_kind == .plugin_fx;
            const track = trackAtPoint(state, point) orelse return false;
            if (is_fx) {
                if (plugin_host.g.addFxSlot(track, choice)) {
                    state.selectTrack(track);
                    state.bottom_mode = .device;
                    state.selectDeviceFx(plugin_host.g.fx_counts[track] - 1);
                    return true;
                }
            } else {
                plugin_host.g.setInstrumentChoice(track, choice);
                state.selectTrack(track);
                state.bottom_mode = .device;
                state.selectDeviceInstrument();
                return true;
            }
            return false;
        },
    }
}

pub fn applyAudioAtPoint(state: *state_mod.State, point: dvui.Point.Physical, path: []const u8) bool {
    if (!document_model.ready() or path.len == 0) return false;
    const store = &document_model.g;

    if (state.view_mode == .session) {
        if (slotAtPoint(state, point)) |ts| {
            if (document_commands.loadAudioFileIntoSession(
                store,
                ts[0],
                ts[1],
                path,
                state.beatsPerBar(),
                io,
            )) {
                state.selectSlot(ts[0], ts[1]);
                if (host_mod.ready()) host_mod.g.projectChrome(state);
                return true;
            }
            return false;
        }
        return false;
    }

    if (state.view_mode == .arrangement) {
        if (laneAtPoint(state, point)) |hit| {
            const scale = @max(0.001, dvui.currentWindow().natural_scale);
            const beat = @max(0, (point.x - hit.rect.x) / (state.arr_pixels_per_beat * scale));
            const start_tick: i64 = @intFromFloat(beat * 960.0);
            if (document_commands.loadAudioFileIntoArrangement(
                store,
                hit.track,
                path,
                start_tick,
                state.bpm,
                io,
            )) |idx| {
                state.selected_arr_clip = idx;
                state.selectTrack(hit.track);
                if (host_mod.ready()) host_mod.g.projectChrome(state);
                return true;
            }
            return false;
        }
    }
    return false;
}

const LaneHit = struct { track: usize, rect: dvui.Rect.Physical };

fn slotAtPoint(state: *const state_mod.State, point: dvui.Point.Physical) ?[2]usize {
    for (0..state.track_count) |t| {
        for (0..state.scene_count) |s| {
            const r = state.session_slot_rects[t][s];
            if (r[2] <= 0 or r[3] <= 0) continue;
            const rect: dvui.Rect.Physical = .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] };
            if (rect.contains(point)) return .{ t, s };
        }
    }
    return null;
}

fn laneAtPoint(state: *const state_mod.State, point: dvui.Point.Physical) ?LaneHit {
    for (0..state.track_count) |t| {
        const r = state.arr_lane_rects[t];
        if (r[2] <= 0 or r[3] <= 0) continue;
        const rect: dvui.Rect.Physical = .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] };
        if (rect.contains(point)) return .{ .track = t, .rect = rect };
    }
    return null;
}

fn trackAtPoint(state: *const state_mod.State, point: dvui.Point.Physical) ?usize {
    if (state.view_mode == .session) {
        if (slotAtPoint(state, point)) |ts| return ts[0];
        return null;
    }
    if (laneAtPoint(state, point)) |hit| return hit.track;
    return null;
}

fn isAudioPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    inline for (.{
        ".wav", ".mp3", ".ogg", ".flac", ".aiff", ".aif",
        ".WAV", ".MP3", ".OGG", ".FLAC", ".AIFF", ".AIF",
    }) |e| {
        if (std.mem.eql(u8, ext, e)) return true;
    }
    return false;
}

/// Poll OS file drops (macOS native / Linux queue) and load audio into selection.
pub fn pollNativeDrops(state: *state_mod.State) void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const path = native_drop.pollMac(buf[0..]) orelse native_drop.pollLinux(buf[0..]) orelse break;
        if (!isAudioPath(path)) continue;
        // Prefer drop under cursor when over session/arr chrome.
        const pt = dvui.currentWindow().mouse_pt;
        if (!applyAudioAtPoint(state, pt, path)) {
            _ = loadAudioAtSelection(state, path);
        }
    }
}
