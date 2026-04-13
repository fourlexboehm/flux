pub const Plugin = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const shared = @import("shared");
const mutex_io: std.Io = std.Io.Threaded.global_single_threaded.io();

const Params = @import("ext/params.zig");
const ViewType = @import("ext/gui/view.zig");
const bridge = @import("bridge.zig");

const options = @import("options");

pub const View = ViewType;
pub const font = shared.core.Core(Plugin, ViewType).font;

const tail_seconds = 24.0;

sample_rate: ?f64 = null,
allocator: std.mem.Allocator,
plugin: clap.Plugin,
host: *const clap.Host,
params: Params,
engine: ?*bridge.Engine,
tail_frames_remaining: u64,

jobs: Jobs = .{},
job_mutex: std.Io.Mutex,

const Jobs = packed struct(u32) {
    notify_host_params_changed: bool = false,
    _: u31 = 0,
};

pub const desc = clap.Plugin.Descriptor{
    .clap_version = clap.version,
    .id = "com.fourlex.zportafm",
    .name = "ZPortaFM",
    .vendor = "fourlex",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "0.0.1",
    .description = "PSS-inspired YM2413 portable FM synth",
    .features = &.{
        clap.Plugin.features.stereo,
        clap.Plugin.features.synthesizer,
        clap.Plugin.features.instrument,
    },
};

pub fn fromClapPlugin(clap_plugin: *const clap.Plugin) *Plugin {
    return @ptrCast(@alignCast(clap_plugin.plugin_data));
}

pub fn init(allocator: std.mem.Allocator, host: *const clap.Host) !*Plugin {
    const plugin = try allocator.create(Plugin);
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
        .params = Params.init(allocator),
        .engine = null,
        .tail_frames_remaining = 0,
        .job_mutex = .init,
    };
    return plugin;
}

pub fn deinit(self: *Plugin) void {
    if (self.engine) |engine| {
        bridge.zportafm_engine_destroy(engine);
    }
    self.params.deinit();
    self.allocator.destroy(self);
}

pub fn create(host: *const clap.Host, allocator: std.mem.Allocator) !*const clap.Plugin {
    const plugin = try Plugin.init(allocator, host);
    return &plugin.plugin;
}

pub fn notifyHostParamsChanged(self: *Plugin) bool {
    self.job_mutex.lockUncancelable(mutex_io);
    defer self.job_mutex.unlock(mutex_io);

    if (self.jobs.notify_host_params_changed) {
        return false;
    }

    self.jobs.notify_host_params_changed = true;
    self.host.requestCallback(self.host);
    return true;
}

fn patchParamValue(self: *Plugin, param: Params.Parameter) f32 {
    return @floatCast(self.params.get(param).Float);
}

fn touchTail(self: *Plugin) void {
    if (self.sample_rate) |sample_rate| {
        self.tail_frames_remaining = @intFromFloat(sample_rate * tail_seconds);
    }
}

fn setPatchParams(self: *Plugin, engine: *bridge.Engine) void {
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.mod_attack), patchParamValue(self, .ModAttack));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.car_attack), patchParamValue(self, .CarAttack));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.mod_decay), patchParamValue(self, .ModDecay));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.car_decay), patchParamValue(self, .CarDecay));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.mod_sustain), patchParamValue(self, .ModSustain));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.car_sustain), patchParamValue(self, .CarSustain));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.mod_release), patchParamValue(self, .ModRelease));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.car_release), patchParamValue(self, .CarRelease));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.mod_multiplier), patchParamValue(self, .ModMultiplier));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.car_multiplier), patchParamValue(self, .CarMultiplier));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.feedback), patchParamValue(self, .Feedback));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.mod_level), patchParamValue(self, .ModLevel));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.mod_wave), patchParamValue(self, .ModWave));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.car_wave), patchParamValue(self, .CarWave));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.mod_tremolo), patchParamValue(self, .ModTremolo));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.car_tremolo), patchParamValue(self, .CarTremolo));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.mod_vibrato), patchParamValue(self, .ModVibrato));
    bridge.zportafm_engine_set_patch_param(engine, @intFromEnum(bridge.PatchParam.car_vibrato), patchParamValue(self, .CarVibrato));
}

pub fn applyParamChanges(self: *Plugin, notify_host: bool) void {
    const engine = self.engine orelse return;

    const preset_mode = self.params.get(.VoiceMode).Float >= 0.5;
    const bank: i32 = @intFromFloat(std.math.clamp(
        @round(self.params.get(.Bank).Float),
        0.0,
        @as(f64, @floatFromInt(bridge.tone_bank_names.len - 1)),
    ));
    const instrument: i32 = @intFromFloat(std.math.clamp(@round(self.params.get(.Instrument).Float), 1.0, 15.0));

    bridge.zportafm_engine_set_tone_bank(engine, bank);
    bridge.zportafm_engine_set_preset_mode(engine, preset_mode);
    bridge.zportafm_engine_set_program(engine, instrument);
    bridge.zportafm_engine_set_wheel_range(engine, @floatCast(self.params.get(.PitchWheelRange).Float));
    bridge.zportafm_engine_set_fine_tune(engine, @floatCast(self.params.get(.FineTune).Float));
    setPatchParams(self, engine);
    touchTail(self);

    if (notify_host) {
        _ = self.notifyHostParamsChanged();
    }
}

fn ensureEngine(self: *Plugin, sample_rate: f64) bool {
    if (self.engine == null) {
        self.engine = bridge.zportafm_engine_create(@intFromFloat(@round(sample_rate))) orelse return false;
    } else {
        bridge.zportafm_engine_set_sample_rate(self.engine.?, @intFromFloat(@round(sample_rate)));
        bridge.zportafm_engine_reset(self.engine.?);
    }
    self.applyParamChanges(false);
    return true;
}

fn handleNote(engine: *bridge.Engine, note_event: *align(1) const clap.events.Note, on: bool) void {
    if (note_event.key == .unspecified) {
        if (!on) {
            bridge.zportafm_engine_all_notes_off(engine);
        }
        return;
    }

    const note: i32 = @intFromEnum(note_event.key);
    if (on) {
        bridge.zportafm_engine_note_on(engine, note, @floatCast(std.math.clamp(note_event.velocity, 0.0, 1.0)));
    } else {
        bridge.zportafm_engine_note_off(engine, note);
    }
}

fn handleMidi(engine: *bridge.Engine, midi_event: *align(1) const clap.events.Midi) void {
    const status = midi_event.data[0] & 0xf0;
    switch (status) {
        0x80 => bridge.zportafm_engine_note_off(engine, midi_event.data[1] & 0x7f),
        0x90 => {
            if ((midi_event.data[2] & 0x7f) == 0) {
                bridge.zportafm_engine_note_off(engine, midi_event.data[1] & 0x7f);
            } else {
                const velocity = @as(f32, @floatFromInt(midi_event.data[2] & 0x7f)) / 127.0;
                bridge.zportafm_engine_note_on(engine, midi_event.data[1] & 0x7f, velocity);
            }
        },
        0xb0 => {
            if (midi_event.data[1] == 0x7e or midi_event.data[1] == 0x7b) {
                bridge.zportafm_engine_all_notes_off(engine);
            }
        },
        0xe0 => {
            const position = (@as(i32, midi_event.data[2] & 0x7f) << 7) | @as(i32, midi_event.data[1] & 0x7f);
            const normalized = @as(f32, @floatFromInt(position - 0x2000)) / 8192.0;
            bridge.zportafm_engine_set_pitch_bend(engine, normalized);
        },
        else => {},
    }
}

fn handleEvent(self: *Plugin, event: *const clap.events.Header) void {
    const engine = self.engine orelse return;
    if (event.space_id != clap.events.core_space_id) return;

    switch (event.type) {
        .note_on => {
            const note_event: *align(1) const clap.events.Note = @ptrCast(event);
            handleNote(engine, note_event, true);
            touchTail(self);
        },
        .note_off, .note_choke => {
            const note_event: *align(1) const clap.events.Note = @ptrCast(event);
            handleNote(engine, note_event, false);
            touchTail(self);
        },
        .midi => {
            const midi_event: *align(1) const clap.events.Midi = @ptrCast(event);
            handleMidi(engine, midi_event);
            touchTail(self);
        },
        else => {},
    }
}

fn _init(_: *const clap.Plugin) callconv(.c) bool {
    return true;
}

fn _destroy(clap_plugin: *const clap.Plugin) callconv(.c) void {
    const plugin = fromClapPlugin(clap_plugin);
    plugin.deinit();
}

fn _activate(clap_plugin: *const clap.Plugin, sample_rate: f64, _: u32, _: u32) callconv(.c) bool {
    const plugin = fromClapPlugin(clap_plugin);
    plugin.sample_rate = sample_rate;
    plugin.tail_frames_remaining = 0;
    return plugin.ensureEngine(sample_rate);
}

fn _deactivate(clap_plugin: *const clap.Plugin) callconv(.c) void {
    const plugin = fromClapPlugin(clap_plugin);
    if (plugin.engine) |engine| {
        bridge.zportafm_engine_all_notes_off(engine);
        bridge.zportafm_engine_reset(engine);
    }
    plugin.sample_rate = null;
    plugin.tail_frames_remaining = 0;
}

fn _startProcessing(_: *const clap.Plugin) callconv(.c) bool {
    return true;
}

fn _stopProcessing(_: *const clap.Plugin) callconv(.c) void {}

fn _reset(clap_plugin: *const clap.Plugin) callconv(.c) void {
    const plugin = fromClapPlugin(clap_plugin);
    if (plugin.engine) |engine| {
        bridge.zportafm_engine_reset(engine);
    }
    plugin.applyParamChanges(false);
    plugin.tail_frames_remaining = 0;
    _ = plugin.notifyHostParamsChanged();
}

fn _process(clap_plugin: *const clap.Plugin, clap_process: *const clap.Process) callconv(.c) clap.Process.Status {
    const plugin = fromClapPlugin(clap_plugin);
    const engine = plugin.engine orelse return .sleep;

    std.debug.assert(clap_process.audio_outputs_count == 1);

    Params._flush(clap_plugin, clap_process.in_events, clap_process.out_events);

    const frame_count = clap_process.frames_count;
    const output_left = clap_process.audio_outputs[0].data32.?[0];
    const output_right = clap_process.audio_outputs[0].data32.?[1];
    const gain: f32 = @floatCast(plugin.params.get(.OutputLevel).Float);

    for (0..frame_count) |i| {
        output_left[i] = 0;
        output_right[i] = 0;
    }

    const input_event_count = clap_process.in_events.size(clap_process.in_events);
    if (!bridge.hasActiveNotes(engine) and plugin.tail_frames_remaining == 0 and input_event_count == 0) {
        return .sleep;
    }

    var event_index: u32 = 0;
    var current_frame: u32 = 0;

    while (current_frame < frame_count) {
        while (event_index < input_event_count) {
            const event = clap_process.in_events.get(clap_process.in_events, event_index);
            if (event.sample_offset > current_frame) break;
            if (event.sample_offset == current_frame) {
                handleEvent(plugin, event);
                event_index += 1;
            }
        }

        var next_frame: u32 = frame_count;
        if (event_index < input_event_count) {
            next_frame = clap_process.in_events.get(clap_process.in_events, event_index).sample_offset;
        }

        for (current_frame..next_frame) |frame| {
            const sample = bridge.render(engine) * gain;
            output_left[frame] = sample;
            output_right[frame] = sample;
        }

        current_frame = next_frame;
    }

    if (bridge.hasActiveNotes(engine)) {
        touchTail(plugin);
        return .@"continue";
    }

    if (plugin.tail_frames_remaining > frame_count) {
        plugin.tail_frames_remaining -= frame_count;
        return .@"continue";
    }

    plugin.tail_frames_remaining = 0;
    return if (input_event_count > 0) .@"continue" else .sleep;
}

const ext_audio_ports = shared.ext.audioports.create();
const ext_note_ports = shared.ext.noteports.create();
const ext_params = Params.create();
const ext_state = shared.ext.state.create(Params, Plugin);

fn _getExtension(_: *const clap.Plugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.audio_ports.id)) return &ext_audio_ports;
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.note_ports.id)) return &ext_note_ports;
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.params.id)) return &ext_params;
    if (std.mem.eql(u8, std.mem.span(id), clap.ext.state.id)) return &ext_state;
    _ = options;
    return null;
}

fn _onMainThread(clap_plugin: *const clap.Plugin) callconv(.c) void {
    const plugin = fromClapPlugin(clap_plugin);

    if (plugin.jobs.notify_host_params_changed) {
        plugin.job_mutex.lockUncancelable(mutex_io);
        defer plugin.job_mutex.unlock(mutex_io);
        if (plugin.host.getExtension(plugin.host, clap.ext.params.id)) |host_header| {
            var params_host: *clap.ext.params.Host = @constCast(@ptrCast(@alignCast(host_header)));
            params_host.rescan(plugin.host, .{ .text = true, .values = true });
        }
        plugin.jobs.notify_host_params_changed = false;
    }
}
