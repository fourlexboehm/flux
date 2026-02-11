const std = @import("std");

const midi_input = @import("../midi_input.zig");
const smart_params = @import("smart_params.zig");
const ui_state = @import("../ui/state.zig");
const session_playback = @import("../ui/session_view/playback.zig");
const session_recording = @import("../ui/session_view/recording.zig");

const State = ui_state.State;

const knob_cc = [_]u8{ 74, 71, 76, 77, 93, 73, 75, 72 };
const fader_cc = [_]u8{ 33, 34, 35, 36, 37, 38, 39, 40 };
const mute_cc = [_]u8{ 49, 50, 51, 52, 53, 54, 55, 56 };

const cc_play: u8 = 115;
const cc_stop: u8 = 114;
const cc_record: u8 = 117;
const cc_loop: u8 = 116;
const cc_page_prev: u8 = 98;
const cc_page_next: u8 = 99;

pub fn applyMidiEvents(state: *State, events: []const midi_input.MidiEvent) void {
    state.clearControllerParamWrites();
    smart_params.rebuildIfNeeded(state);

    for (events) |event| {
        const msg = event.message();
        switch (msg) {
            0xB0 => handleCc(state, event),
            0x90 => handleNoteOn(state, event),
            else => {},
        }
    }
}

pub fn smartPageCount(state: *const State) usize {
    return smart_params.pageCount(state);
}

pub fn smartParamLabel(state: *const State, slot_index: usize) []const u8 {
    const slot = smart_params.slotForKnob(state, slot_index) orelse return "-";
    return slot.label[0..slot.label_len];
}

fn handleCc(state: *State, event: midi_input.MidiEvent) void {
    const cc = event.data1;
    const value = event.data2;

    state.controller.last_cc_values[cc] = value;

    if (isEdgePress(state, cc, value)) {
        if (cc == cc_play) {
            state.playing = true;
            return;
        }
        if (cc == cc_stop) {
            state.playing = false;
            state.playhead_beat = 0;
            return;
        }
        if (cc == cc_record) {
            handleRecordButton(state);
            return;
        }
        if (cc == cc_loop) {
            if (state.session.recording.isRecording()) {
                session_recording.stopRecording(&state.session, .loop);
            } else {
                state.playhead_beat = 0;
            }
            return;
        }
        if (cc == cc_page_prev) {
            smart_params.setPageDelta(state, -1);
            return;
        }
        if (cc == cc_page_next) {
            smart_params.setPageDelta(state, 1);
            return;
        }

        if (matchIndex(mute_cc[0..], cc)) |track_index| {
            if (track_index < state.session.track_count) {
                state.session.tracks[track_index].mute = !state.session.tracks[track_index].mute;
            }
            return;
        }
    }

    if (matchIndex(fader_cc[0..], cc)) |track_index| {
        if (track_index < state.session.track_count) {
            const normalized = @as(f32, @floatFromInt(value)) / 127.0;
            state.session.tracks[track_index].volume = normalized * 1.5;
        }
        return;
    }

    if (matchIndex(knob_cc[0..], cc)) |knob_index| {
        handleKnob(state, knob_index, value);
    }
}

fn handleNoteOn(state: *State, event: midi_input.MidiEvent) void {
    if (event.data2 == 0) return;
    // Reserve channel 10 notes for scene launches (Axiom pads default to drum channel).
    if (event.channel() != 9) return;
    if (event.data1 < 36 or event.data1 > 43) return;
    const scene_index: usize = event.data1 - 36;
    if (scene_index >= state.session.scene_count) return;
    session_playback.launchScene(&state.session, scene_index, state.playing);
}

fn handleKnob(state: *State, knob_index: usize, value: u8) void {
    const slot = smart_params.slotForKnob(state, knob_index) orelse return;

    const t = @as(f64, @floatFromInt(value)) / 127.0;
    const mapped = slot.min_value + t * (slot.max_value - slot.min_value);

    const track_idx = state.device_target_track;
    const target_fx: i8 = switch (state.device_target_kind) {
        .instrument => -1,
        .fx => @intCast(state.device_target_fx),
    };

    state.pushControllerParamWrite(.{
        .track_index = @intCast(track_idx),
        .target_fx_index = target_fx,
        .param_id = slot.param_id,
        .value = mapped,
    });
}

fn handleRecordButton(state: *State) void {
    if (state.session.recording.isRecording()) {
        session_recording.stopRecording(&state.session, .stop);
        return;
    }

    const track = state.session.armed_track orelse state.selectedTrack();
    state.session.armed_track = track;
    const scene = state.selectedScene();
    session_recording.startRecording(&state.session, track, scene, state.playing, state.playhead_beat);
}

fn matchIndex(list: []const u8, value: u8) ?usize {
    for (list, 0..) |item, idx| {
        if (item == value) return idx;
    }
    return null;
}

fn isEdgePress(state: *State, cc: u8, value: u8) bool {
    const was_down = state.controller.cc_button_down[cc];
    const now_down = value >= 64;
    state.controller.cc_button_down[cc] = now_down;
    return !was_down and now_down;
}
