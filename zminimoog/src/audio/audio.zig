const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");

const Plugin = @import("../plugin.zig");
const Voices = @import("voices.zig");
const Voice = Voices.Voice;

pub fn processNoteChanges(plugin: *Plugin, event: *const clap.events.Header) void {
    if (event.space_id != clap.events.core_space_id) return;

    switch (event.type) {
        .note_on => {
            const note_event: *align(1) const clap.events.Note = @ptrCast(event);

            // Voice stealing - retrigger existing voice for same key
            if (Voices.getVoiceByKey(plugin.voices.voices.items, note_event.key)) |voice| {
                const midi_note: u8 = @intCast(@intFromEnum(note_event.key));
                const velocity: f32 = @floatCast(note_event.velocity);
                voice.synth.noteOn(midi_note, velocity);
                return;
            }

            // Create new voice
            var new_voice = Voice.init(@floatCast(plugin.sample_rate.?));
            new_voice.noteId = note_event.note_id;
            new_voice.channel = note_event.channel;
            new_voice.key = note_event.key;

            const midi_note: u8 = @intCast(@intFromEnum(note_event.key));
            const velocity: f32 = @floatCast(note_event.velocity);
            new_voice.synth.noteOn(midi_note, velocity);

            plugin.applyParamsToVoice(&new_voice);
            plugin.voices.addVoice(new_voice) catch unreachable;
        },
        .note_off => {
            const note_event: *align(1) const clap.events.Note = @ptrCast(event);
            for (plugin.voices.voices.items) |*voice| {
                if ((voice.channel == note_event.channel or note_event.channel == .unspecified) and
                    (voice.key == note_event.key or note_event.key == .unspecified) and
                    (voice.noteId == note_event.note_id or note_event.note_id == .unspecified))
                {
                    voice.synth.noteOff();
                }
            }
        },
        .note_choke => {
            const note_event: *align(1) const clap.events.Note = @ptrCast(event);
            var i: usize = 0;
            while (i < plugin.voices.voices.items.len) {
                const voice = &plugin.voices.voices.items[i];
                if ((voice.channel == note_event.channel or note_event.channel == .unspecified) and
                    (voice.key == note_event.key or note_event.key == .unspecified) and
                    (voice.noteId == note_event.note_id or note_event.note_id == .unspecified))
                {
                    _ = plugin.voices.voices.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        },
        else => {},
    }
}

pub fn renderAudio(plugin: *Plugin, start: u32, end: u32, output_left: [*]f32, output_right: [*]f32) void {
    const voice_count = plugin.voices.getVoiceCount();
    if (voice_count == 0) return;

    plugin.voices.render_payload = .{
        .start = start,
        .end = end,
        .output_left = output_left,
        .output_right = output_right,
    };

    // Try thread pool first
    var did_render = false;
    if (plugin.host.getExtension(plugin.host, clap.ext.thread_pool.id)) |ext_raw| {
        const thread_pool: *const clap.ext.thread_pool.Host = @ptrCast(@alignCast(ext_raw));
        did_render = thread_pool.requestExec(plugin.host, @intCast(voice_count));
    }

    // Fallback to sequential rendering
    if (!did_render) {
        for (0..voice_count) |i| {
            processVoice(plugin, @intCast(i));
        }
    }
}

pub fn processVoice(plugin: *Plugin, voice_index: u32) void {
    const payload = plugin.voices.render_payload orelse return;
    if (voice_index >= plugin.voices.voices.items.len) return;

    const voice = &plugin.voices.voices.items[voice_index];
    const voice_count = plugin.voices.getVoiceCount();
    const scale: f32 = 1.0 / @max(1.0, std.math.sqrt(@as(f32, @floatFromInt(voice_count))));

    for (payload.start..payload.end) |i| {
        const sample = voice.synth.processSample() * scale;

        plugin.voices.render_mutex.lock();
        payload.output_left[i] += sample;
        payload.output_right[i] += sample;
        plugin.voices.render_mutex.unlock();
    }
}
