const std = @import("std");
const zgui = @import("zgui");

pub const track_count = 4;
pub const scene_count = 8;

pub const ClipState = enum {
    empty,
    stopped,
    queued,
    playing,
};

pub const ClipSlot = struct {
    label: []const u8,
    state: ClipState,
};

pub const Track = struct {
    name: []const u8,
    volume: f32,
    mute: bool,
    solo: bool,
};

pub const State = struct {
    playing: bool,
    bpm: f32,
    quantize_index: i32,
    tracks: [track_count]Track,
    clips: [track_count][scene_count]ClipSlot,

    pub fn init() State {
        const tracks: [track_count]Track = .{
            .{ .name = "Track 1", .volume = 0.8, .mute = false, .solo = false },
            .{ .name = "Track 2", .volume = 0.8, .mute = false, .solo = false },
            .{ .name = "Track 3", .volume = 0.8, .mute = false, .solo = false },
            .{ .name = "Track 4", .volume = 0.8, .mute = false, .solo = false },
        };
        var clips: [track_count][scene_count]ClipSlot = undefined;
        for (&clips, 0..) |*track_clips, t| {
            for (track_clips, 0..) |*slot, s| {
                slot.* = .{
                    .label = switch (s) {
                        0 => "Intro",
                        1 => "Verse",
                        2 => "Build",
                        3 => "Chorus",
                        4 => "Bridge",
                        5 => "Drop",
                        6 => "Outro",
                        else => "Clip",
                    },
                    .state = if (t == 0 and s == 0) .playing else .stopped,
                };
            }
        }
        return .{
            .playing = true,
            .bpm = 120.0,
            .quantize_index = 2,
            .tracks = tracks,
            .clips = clips,
        };
    }
};

const quantize_items: [:0]const u8 = "1/4\x001/2\x001\x002\x004\x00";

pub fn draw(state: *State, ui_scale: f32) void {
    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = display[1], .cond = .always });

    if (zgui.begin("zdaw##root", .{ .flags = .{
        .no_collapse = true,
        .no_resize = true,
        .no_move = true,
        .no_title_bar = true,
    } })) {
        drawTransport(state, ui_scale);
        zgui.separator();
        drawClipGrid(state, ui_scale);
    }
    zgui.end();
}

fn drawTransport(state: *State, ui_scale: f32) void {
    const spacing = 12.0 * ui_scale;
    const item_w = 160.0 * ui_scale;
    zgui.text("Transport", .{});
    zgui.sameLine(.{ .spacing = spacing });
    if (zgui.button(if (state.playing) "Stop##transport" else "Play##transport", .{ .w = 80, .h = 0 })) {
        state.playing = !state.playing;
    }
    zgui.sameLine(.{ .spacing = spacing });
    zgui.textUnformatted("BPM");
    zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
    zgui.setNextItemWidth(item_w);
    _ = zgui.sliderFloat("##transport_bpm", .{ .v = &state.bpm, .min = 40.0, .max = 200.0 });
    zgui.sameLine(.{ .spacing = spacing });
    zgui.textUnformatted("Quantize");
    zgui.sameLine(.{ .spacing = 6.0 * ui_scale });
    zgui.setNextItemWidth(120.0 * ui_scale);
    _ = zgui.combo("##transport_quantize", .{ .current_item = &state.quantize_index, .items_separated_by_zeros = quantize_items });
}

fn drawClipGrid(state: *State, ui_scale: f32) void {
    const row_height = 64.0 * ui_scale;
    if (!zgui.beginTable("clip_grid", .{
        .column = track_count + 1,
        .flags = .{ .borders = .all, .row_bg = true },
    })) {
        return;
    }
    defer zgui.endTable();

    zgui.tableNextRow(.{ .min_row_height = 0 });
    _ = zgui.tableNextColumn();
    zgui.text("Scenes", .{});
    for (state.tracks, 0..) |track, t| {
        _ = t;
        _ = zgui.tableNextColumn();
        zgui.textUnformatted(track.name);
    }

    for (0..scene_count) |scene_index| {
        zgui.tableNextRow(.{ .min_row_height = row_height });
        _ = zgui.tableNextColumn();
        zgui.text("Scene {}", .{scene_index + 1});
        zgui.sameLine(.{ .spacing = 8.0 * ui_scale });
        var launch_buf: [32]u8 = undefined;
        const launch_label = std.fmt.bufPrintZ(&launch_buf, "Launch##scene{d}", .{scene_index}) catch "Launch##scene";
        if (zgui.button(launch_label, .{ .w = 70.0 * ui_scale, .h = 0 })) {
            for (0..track_count) |track_index| {
                for (0..scene_count) |slot_index| {
                    state.clips[track_index][slot_index].state = if (slot_index == scene_index) .playing else .stopped;
                }
            }
        }

        for (0..track_count) |track_index| {
            _ = zgui.tableNextColumn();
            const slot = &state.clips[track_index][scene_index];
            if (clipButton(slot, track_index, scene_index, ui_scale)) {
                slot.state = switch (slot.state) {
                    .empty => .playing,
                    .stopped => .playing,
                    .queued => .playing,
                    .playing => .stopped,
                };
            }
        }
    }
}

fn clipButton(slot: *ClipSlot, track_index: usize, scene_index: usize, ui_scale: f32) bool {
    const base_color = switch (slot.state) {
        .empty => [4]f32{ 0.18, 0.18, 0.2, 1.0 },
        .stopped => [4]f32{ 0.25, 0.25, 0.27, 1.0 },
        .queued => [4]f32{ 0.85, 0.55, 0.15, 1.0 },
        .playing => [4]f32{ 0.2, 0.7, 0.3, 1.0 },
    };
    zgui.pushStyleColor4f(.{ .idx = .button, .c = base_color });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ base_color[0] + 0.05, base_color[1] + 0.05, base_color[2] + 0.05, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = .{ base_color[0] + 0.1, base_color[1] + 0.1, base_color[2] + 0.1, 1.0 } });
    defer zgui.popStyleColor(.{ .count = 3 });

    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(
        &label_buf,
        "{s}##t{d}s{d}",
        .{ slot.label, track_index, scene_index },
    ) catch "Clip##fallback";
    return zgui.button(label, .{ .w = 140.0 * ui_scale, .h = 56.0 * ui_scale });
}
