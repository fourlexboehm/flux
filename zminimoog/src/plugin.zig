pub const Plugin = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");

const shared = @import("shared");

const Params = @import("ext/params.zig");
const ViewType = @import("ext/gui/view.zig");
const VoiceInfo = @import("ext/voice_info.zig");
const ThreadPool = @import("ext/thread_pool.zig");
const Undo = @import("ext/undo.zig");
const extensions = shared.plugin_extensions.Extensions(Plugin, ViewType, Params, VoiceInfo, ThreadPool, Undo);
const GUI = extensions.GUI;
pub const View = ViewType;
pub const font = shared.core.Core(Plugin, ViewType).font;
const options = @import("options");
const dsp = @import("dsp/dsp.zig");
const Voices = @import("audio/voices.zig");
const Filter = @import("audio/filter.zig");

const audio = @import("audio/audio.zig");

const Parameter = Params.Parameter;
const Voice = Voices.Voice;

sample_rate: ?f64 = null,
allocator: std.mem.Allocator,
plugin: clap.Plugin,
host: *const clap.Host,
voices: Voices,
params: Params,
filter_left: Filter,
filter_right: Filter,
gui: ?*GUI,

jobs: Jobs = .{},
job_mutex: std.Thread.Mutex,

const Jobs = packed struct(u32) {
    notify_host_params_changed: bool = false,
    _: u31 = 0,
};

pub const desc = clap.Plugin.Descriptor{
    .clap_version = clap.version,
    .id = "com.fourlex.zminimoog",
    .name = "ZMinimoog",
    .vendor = "fourlex",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "0.0.1",
    .description = "Minimoog Model D Synthesizer (WDF)",
    .features = &.{ clap.Plugin.features.stereo, clap.Plugin.features.synthesizer, clap.Plugin.features.instrument },
};

pub fn fromClapPlugin(clap_plugin: *const clap.Plugin) *Plugin {
    return @ptrCast(@alignCast(clap_plugin.plugin_data));
}

pub fn init(allocator: std.mem.Allocator, host: *const clap.Host) !*Plugin {
    const plugin = try allocator.create(Plugin);
    const voices = Voices.init(allocator);
    const params = Params.init(allocator);

    plugin.* = .{
        .allocator = allocator,
        .plugin = .{
            .descriptor = &desc,
            .plugin_data = plugin,
            .init = _init,
            .destroy = _destroy,
            .activate = _activate,
            .deactivate = _deactivate,
            .startProcessing = _startProcessing,
            .stopProcessing = _stopProcessing,
            .reset = _reset,
            .process = _process,
            .getExtension = _getExtension,
            .onMainThread = _onMainThread,
        },
        .host = host,
        .voices = voices,
        .params = params,
        .gui = null,
        .job_mutex = .{},
        .filter_left = .{},
        .filter_right = .{},
    };

    return plugin;
}

pub fn deinit(self: *Plugin) void {
    self.voices.deinit();
    self.params.deinit();
    self.allocator.destroy(self);
}

pub fn create(host: *const clap.Host, allocator: std.mem.Allocator) !*const clap.Plugin {
    const plugin = try Plugin.init(allocator, host);
    return &plugin.plugin;
}

pub fn notifyHostParamsChanged(self: *Plugin) bool {
    self.job_mutex.lock();
    defer self.job_mutex.unlock();

    if (self.jobs.notify_host_params_changed) {
        return false;
    }

    self.jobs.notify_host_params_changed = true;
    self.host.requestCallback(self.host);
    return true;
}

pub fn applyParamsToVoice(self: *Plugin, voice: *Voice) void {
    // Oscillator 1
    voice.synth.osc1_level = @floatCast(self.params.get(.Osc1Level).Float);
    applyWaveform(&voice.synth.oscillators.osc1, @intFromFloat(self.params.get(.Osc1Waveform).Float));
    voice.synth.panel.switches.osc1_range = indexToRange(@intFromFloat(self.params.get(.Osc1Range).Float));

    // Oscillator 2
    voice.synth.osc2_level = @floatCast(self.params.get(.Osc2Level).Float);
    applyWaveform(&voice.synth.oscillators.osc2, @intFromFloat(self.params.get(.Osc2Waveform).Float));
    voice.synth.panel.switches.osc2_range = indexToRange(@intFromFloat(self.params.get(.Osc2Range).Float));
    voice.synth.oscillators.osc2.setDetune(@floatCast(self.params.get(.Osc2Detune).Float));

    // Oscillator 3
    voice.synth.osc3_level = @floatCast(self.params.get(.Osc3Level).Float);
    applyWaveform(&voice.synth.oscillators.osc3, @intFromFloat(self.params.get(.Osc3Waveform).Float));
    voice.synth.panel.switches.osc3_range = indexToRange(@intFromFloat(self.params.get(.Osc3Range).Float));
    voice.synth.oscillators.osc3.setDetune(@floatCast(self.params.get(.Osc3Detune).Float));
    voice.synth.panel.switches.osc3_keyboard_control = self.params.get(.Osc3KeyboardCtrl).Float >= 0.5;

    // Noise
    voice.synth.noise_level = @floatCast(self.params.get(.NoiseLevel).Float);
    voice.synth.panel.switches.noise_on = self.params.get(.NoiseLevel).Float > 0.0;
    voice.synth.panel.switches.noise_type = if (self.params.get(.NoiseType).Float >= 0.5) dsp.NoiseType.pink else dsp.NoiseType.white;

    // Filter
    voice.synth.setFilterCutoff(@floatCast(self.params.get(.FilterCutoff).Float));
    voice.synth.setFilterEmphasis(@floatCast(self.params.get(.FilterEmphasis).Float));
    voice.synth.setFilterContourAmount(@floatCast(self.params.get(.FilterContour).Float));
    voice.synth.panel.switches.filter_keyboard_tracking = indexToTracking(@intFromFloat(self.params.get(.FilterKeyTracking).Float));

    // Modulation
    voice.synth.panel.switches.osc3_to_filter = self.params.get(.Osc3ToFilter).Float >= 0.5;
    voice.synth.panel.switches.osc3_to_osc = self.params.get(.Osc3ToOsc).Float >= 0.5;

    // Envelope
    voice.synth.setAttack(@floatCast(self.params.get(.Attack).Float));
    voice.synth.setDecay(@floatCast(self.params.get(.Decay).Float));
    voice.synth.setSustain(@floatCast(self.params.get(.Sustain).Float));
    voice.synth.setRelease(@floatCast(self.params.get(.Release).Float));

    // Controllers
    voice.synth.setGlideTime(@floatCast(self.params.get(.Glide).Float));
    voice.synth.panel.pitch_wheel.bend_range = @floatCast(self.params.get(.PitchBendRange).Float);
    voice.synth.panel.master_volume = @floatCast(self.params.get(.MasterVolume).Float);
}

fn indexToWaveform(index: usize) @import("dsp/dsp.zig").Waveform {
    const Waveform = @import("dsp/dsp.zig").Waveform;
    return switch (index) {
        0 => Waveform.triangle,
        1 => Waveform.shark_tooth,
        2 => Waveform.sawtooth,
        3 => Waveform.square,
        4 => Waveform.pulse,
        5 => Waveform.pulse,
        else => Waveform.sawtooth,
    };
}

fn applyWaveform(osc: *dsp.VCO(f32), index: usize) void {
    const waveform = indexToWaveform(index);
    osc.setWaveform(waveform);
    if (waveform == .pulse) {
        const pulse_width: f32 = switch (index) {
            4 => 0.6, // wide pulse
            5 => 0.2, // narrow pulse
            else => 0.5,
        };
        osc.setPulseWidth(pulse_width);
    }
}

fn indexToRange(index: usize) @import("dsp/dsp.zig").OscRange {
    const OscRange = @import("dsp/dsp.zig").OscRange;
    return switch (index) {
        0 => OscRange.lo,
        1 => OscRange.@"32",
        2 => OscRange.@"16",
        3 => OscRange.@"8",
        4 => OscRange.@"4",
        5 => OscRange.@"2",
        else => OscRange.@"8",
    };
}

fn indexToTracking(index: usize) @import("dsp/dsp.zig").FilterKeyboardTracking {
    const FilterKeyboardTracking = @import("dsp/dsp.zig").FilterKeyboardTracking;
    return switch (index) {
        0 => FilterKeyboardTracking.off,
        1 => FilterKeyboardTracking.half,
        2 => FilterKeyboardTracking.full,
        else => FilterKeyboardTracking.half,
    };
}

pub fn applyParamChanges(self: *Plugin, notify_host: bool) void {
    if (self.sample_rate == null) return;

    for (self.voices.voices.items) |*voice| {
        self.applyParamsToVoice(voice);
    }

    if (notify_host) {
        _ = self.notifyHostParamsChanged();
    }
}

fn _init(clap_plugin: *const clap.Plugin) callconv(.c) bool {
    const plugin = fromClapPlugin(clap_plugin);
    extensions.Undo.init(plugin.host);
    return true;
}

fn _destroy(clap_plugin: *const clap.Plugin) callconv(.c) void {
    const plugin = fromClapPlugin(clap_plugin);
    plugin.deinit();
}

fn _activate(clap_plugin: *const clap.Plugin, sample_rate: f64, _: u32, _: u32) callconv(.c) bool {
    const plugin = fromClapPlugin(clap_plugin);
    plugin.sample_rate = sample_rate;
    return true;
}

fn _deactivate(_: *const clap.Plugin) callconv(.c) void {}

fn _startProcessing(_: *const clap.Plugin) callconv(.c) bool {
    return true;
}

fn _stopProcessing(_: *const clap.Plugin) callconv(.c) void {}

fn _reset(clap_plugin: *const clap.Plugin) callconv(.c) void {
    const plugin = fromClapPlugin(clap_plugin);
    _ = plugin.notifyHostParamsChanged();
}

fn _process(clap_plugin: *const clap.Plugin, clap_process: *const clap.Process) callconv(.c) clap.Process.Status {
    const plugin = fromClapPlugin(clap_plugin);
    const frame_count = clap_process.frames_count;
    const dt: f64 = @as(f64, @floatFromInt(frame_count)) / plugin.sample_rate.?;

    extensions.Params._flush(clap_plugin, clap_process.in_events, clap_process.out_events);

    if (plugin.gui) |gui| {
        gui.tick(dt);
        if (gui.shouldUpdate()) {
            plugin.host.requestCallback(plugin.host);
        }
    }

    const input_event_count = clap_process.in_events.size(clap_process.in_events);
    const output_left = clap_process.audio_outputs[0].data32.?[0];
    const output_right = clap_process.audio_outputs[0].data32.?[1];

    for (0..frame_count) |i| {
        output_left[i] = 0;
        output_right[i] = 0;
    }

    const voice_count = plugin.voices.getVoiceCount();
    const event_count = clap_process.in_events.size(clap_process.in_events);
    if (voice_count == 0 and event_count == 0) {
        return clap.Process.Status.sleep;
    }

    var event_index: u32 = 0;
    var current_frame: u32 = 0;
    while (current_frame < frame_count) {
        while (event_index < input_event_count) {
            const event = clap_process.in_events.get(clap_process.in_events, event_index);
            if (event.sample_offset > current_frame) break;
            if (event.sample_offset == current_frame) {
                audio.processNoteChanges(plugin, event);
                event_index += 1;
            }
        }

        var next_frame: u32 = frame_count;
        if (event_index < input_event_count) {
            const next_event = clap_process.in_events.get(clap_process.in_events, event_index);
            next_frame = next_event.sample_offset;
        }

        audio.renderAudio(plugin, current_frame, next_frame, output_left, output_right);
        current_frame = next_frame;
    }

    // Remove finished voices
    var i: u32 = 0;
    while (i < plugin.voices.voices.items.len) {
        const voice = &plugin.voices.voices.items[i];
        if (voice.isFinished()) {
            const note = clap.events.Note{
                .header = .{
                    .size = @sizeOf(clap.events.Note),
                    .flags = .{},
                    .sample_offset = 0,
                    .space_id = clap.events.core_space_id,
                    .type = .note_end,
                },
                .key = voice.key,
                .note_id = voice.noteId,
                .channel = voice.channel,
                .port_index = .unspecified,
                .velocity = 1,
            };
            _ = clap_process.out_events.tryPush(clap_process.out_events, &note.header);
            _ = plugin.voices.voices.orderedRemove(i);
        } else {
            i += 1;
        }
    }

    return clap.Process.Status.@"continue";
}

const ext_audio_ports = extensions.AudioPorts.create();
const ext_note_ports = extensions.NotePorts.create();
const ext_params = extensions.Params.create();
const ext_state = extensions.State.create();
const ext_gui = extensions.GUI.create();
const ext_voice_info = extensions.VoiceInfo.create();
const ext_thread_pool = extensions.ThreadPool.create();

fn _getExtension(_: *const clap.Plugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.audio_ports.id)) return &ext_audio_ports;
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.note_ports.id)) return &ext_note_ports;
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.params.id)) return &ext_params;
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.state.id)) return &ext_state;
    if (options.enable_gui and std.mem.eql(u8, std.mem.span(id), clap.ext.gui.id)) return &ext_gui;
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.voice_info.id)) return &ext_voice_info;
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.thread_pool.id)) return &ext_thread_pool;
    return null;
}

fn _onMainThread(clap_plugin: *const clap.Plugin) callconv(.c) void {
    const plugin = fromClapPlugin(clap_plugin);

    if (plugin.jobs.notify_host_params_changed) {
        plugin.job_mutex.lock();
        defer plugin.job_mutex.unlock();
        if (plugin.host.getExtension(plugin.host, clap.ext.params.id)) |host_header| {
            var params_host: *clap.ext.params.Host = @constCast(@ptrCast(@alignCast(host_header)));
            params_host.rescan(plugin.host, .{ .text = true, .values = true });
        }
        plugin.jobs.notify_host_params_changed = false;
    }

    if (plugin.gui) |gui| {
        gui.update() catch {};
    }
}
