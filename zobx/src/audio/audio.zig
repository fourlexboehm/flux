const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");
const mutex_io: std.Io = std.Io.Threaded.global_single_threaded.ioBasic();

const Plugin = @import("../plugin.zig");
const Voices = @import("voices.zig");

pub fn processNoteChanges(plugin: *Plugin, event: *const clap.events.Header) void {
    if (event.space_id != clap.events.core_space_id) return;

    const engine = plugin.voices.engine orelse return;

    switch (event.type) {
        .note_on => {
            const note_event: *align(1) const clap.events.Note = @ptrCast(event);
            const midi_note: i32 = @intFromEnum(note_event.key);
            const velocity: f32 = @floatCast(note_event.velocity);
            engine.noteOn(midi_note, velocity);
        },
        .note_off => {
            const note_event: *align(1) const clap.events.Note = @ptrCast(event);
            const midi_note: i32 = @intFromEnum(note_event.key);
            engine.noteOff(midi_note);
        },
        .note_choke => {
            engine.allSoundOff();
        },
        .midi => {
            const midi_event: *align(1) const clap.events.Midi = @ptrCast(event);
            const status = midi_event.data[0] & 0xF0;

            // CC messages
            if (status == 0xB0) {
                const cc = midi_event.data[1];
                const val: f32 = @as(f32, @floatFromInt(midi_event.data[2])) / 127.0;

                switch (cc) {
                    1 => engine.processModWheel(val), // Mod wheel
                    64 => { // Sustain pedal
                        if (val >= 0.5) engine.sustainOn() else engine.sustainOff();
                    },
                    120, 123 => engine.allSoundOff(), // All sound off / All notes off
                    else => {},
                }
            }
            // Pitch bend
            else if (status == 0xE0) {
                const lsb: f32 = @floatFromInt(midi_event.data[1]);
                const msb: f32 = @floatFromInt(midi_event.data[2]);
                const bend = ((msb * 128.0 + lsb) - 8192.0) / 8192.0;
                engine.processPitchWheel(bend);
            }
        },
        else => {},
    }
}

pub fn renderAudio(plugin: *Plugin, start: u32, end: u32, output_left: [*]f32, output_right: [*]f32) void {
    const engine = plugin.voices.engine orelse return;

    for (start..end) |i| {
        var left: f32 = 0;
        var right: f32 = 0;
        engine.processSample(&left, &right);
        output_left[i] += left;
        output_right[i] += right;
    }
}

// This is called by the thread pool but for the OB-X we do all processing
// in renderAudio since the engine is monolithic. This is a no-op.
pub fn processVoice(plugin: *Plugin, voice_index: u32) void {
    _ = plugin;
    _ = voice_index;
}
