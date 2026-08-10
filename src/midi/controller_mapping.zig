//! Axiom-class MIDI control surface mapping (CC transport / mute / faders / knobs).
//!
//! Domain mutations go through `document/*`; RT param writes go through
//! `audio_runtime.pushControllerParamWrite`. Chrome holds only controller tables.

const std = @import("std");
const clap = @import("clap-bindings");

const midi_input = @import("input.zig");
const smart_params = @import("smart_params.zig");
const chrome = @import("../ui/state.zig");
const document_model = @import("../document/model.zig");
const document_commands = @import("../document/commands.zig");
const audio_runtime = @import("../ui/audio_runtime.zig");
const param_flush = @import("../plugin/param_flush.zig");

const knob_cc = [_]u8{ 74, 71, 76, 77, 93, 73, 75, 72 };
const fader_cc = [_]u8{ 33, 34, 35, 36, 37, 38, 39, 40 };
const mute_cc = [_]u8{ 49, 50, 51, 52, 53, 54, 55, 56 };

const cc_play: u8 = 115;
const cc_stop: u8 = 114;
const cc_record: u8 = 117;
const cc_loop: u8 = 116;
const cc_page_prev: u8 = 98;
const cc_page_next: u8 = 99;

/// Apply control-surface events (CC + pad scene launches). Note-on MIDI for
/// performance is handled separately by the live-key path / recording.
pub fn applyMidiEvents(
    state: *chrome.State,
    events: []const midi_input.MidiEvent,
    device_plugin: ?*const clap.Plugin,
) void {
    if (!document_model.ready()) return;
    const store = &document_model.g;
    const allocator = store.allocator;

    const target_track = state.deviceTrack();
    const target_kind = state.device_target_kind;
    const target_fx = state.device_target_fx;
    smart_params.rebuildIfNeeded(state, allocator, device_plugin, target_track, target_kind, target_fx);

    for (events) |event| {
        const msg = event.message();
        switch (msg) {
            0xB0 => handleCc(state, store, device_plugin, event),
            0x90 => handleNoteOn(state, store, event),
            else => {},
        }
    }
}

pub fn smartPageCount(state: *const chrome.State) usize {
    return smart_params.pageCount(state);
}

pub fn smartParamLabel(state: *const chrome.State, slot_index: usize) []const u8 {
    const slot = smart_params.slotForKnob(state, slot_index) orelse return "-";
    return slot.label[0..slot.label_len];
}

fn handleCc(
    state: *chrome.State,
    store: *document_model.Store,
    device_plugin: ?*const clap.Plugin,
    event: midi_input.MidiEvent,
) void {
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
            handleRecordButton(state, store);
            return;
        }
        if (cc == cc_loop) {
            if (document_commands.isRecording(store)) {
                document_commands.stopRecording(store, .loop);
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
            if (track_index < store.session.track_count) {
                document_commands.toggleTrackMute(store, track_index);
            }
            return;
        }
    }

    if (matchIndex(fader_cc[0..], cc)) |track_index| {
        if (track_index < store.session.track_count) {
            // Continuous CC: live volume without flooding undo (zgui parity).
            const normalized = @as(f32, @floatFromInt(value)) / 127.0;
            const vol = normalized * 1.5;
            if (store.session.tracks[track_index].volume != vol) {
                store.session.tracks[track_index].volume = vol;
                store.markChanged();
            }
        }
        return;
    }

    if (matchIndex(knob_cc[0..], cc)) |knob_index| {
        handleKnob(state, device_plugin, knob_index, value);
    }
}

fn handleNoteOn(state: *chrome.State, store: *document_model.Store, event: midi_input.MidiEvent) void {
    if (event.data2 == 0) return;
    // Reserve channel 10 notes for scene launches (Axiom pads default to drum channel).
    if (event.channel() != 9) return;
    if (event.data1 < 36 or event.data1 > 43) return;
    const scene_index: usize = event.data1 - 36;
    if (scene_index >= store.session.scene_count) return;
    document_commands.launchScene(store, scene_index, state.playing);
}

fn handleKnob(
    state: *chrome.State,
    device_plugin: ?*const clap.Plugin,
    knob_index: usize,
    value: u8,
) void {
    const slot = smart_params.slotForKnob(state, knob_index) orelse return;

    const t = @as(f64, @floatFromInt(value)) / 127.0;
    const mapped = slot.min_value + t * (slot.max_value - slot.min_value);

    const track_idx = state.deviceTrack();
    const target_fx: i8 = switch (state.device_target_kind) {
        .instrument => -1,
        .fx => @intCast(state.device_target_fx),
    };

    if (audio_runtime.ready()) {
        audio_runtime.g.pushControllerParamWrite(.{
            .track_index = @intCast(track_idx),
            .target_fx_index = target_fx,
            .param_id = slot.param_id,
            .value = mapped,
        });
    }

    // Immediate main-thread flush so plugin GUIs/getValue update before next process.
    if (device_plugin) |plugin| {
        _ = param_flush.flushParamValue(plugin, slot.param_id, mapped);
    }
}

fn handleRecordButton(state: *chrome.State, store: *document_model.Store) void {
    if (document_commands.isRecording(store)) {
        document_commands.stopRecording(store, .stop);
        return;
    }

    const track = store.session.armed_track orelse state.selectedTrack();
    store.session.armed_track = track;
    state.armed_track = track;
    const scene = state.selectedScene();
    document_commands.startRecording(
        store,
        track,
        scene,
        state.playing,
        state.playhead_beat,
        state.beatsPerBar(),
    );
}

fn matchIndex(list: []const u8, value: u8) ?usize {
    for (list, 0..) |item, idx| {
        if (item == value) return idx;
    }
    return null;
}

fn isEdgePress(state: *chrome.State, cc: u8, value: u8) bool {
    const was_down = state.controller.cc_button_down[cc];
    const now_down = value >= 64;
    state.controller.cc_button_down[cc] = now_down;
    return !was_down and now_down;
}
