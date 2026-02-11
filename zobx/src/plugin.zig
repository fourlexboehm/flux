pub const Plugin = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");
const mutex_io: std.Io = std.Io.Threaded.global_single_threaded.ioBasic();

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
const audio = @import("audio/audio.zig");

const Parameter = Params.Parameter;

sample_rate: ?f64 = null,
allocator: std.mem.Allocator,
plugin: clap.Plugin,
host: *const clap.Host,
voices: Voices,
params: Params,
gui: ?*GUI,

jobs: Jobs = .{},
job_mutex: std.Io.Mutex,

const Jobs = packed struct(u32) {
    notify_host_params_changed: bool = false,
    _: u31 = 0,
};

pub const desc = clap.Plugin.Descriptor{
    .clap_version = clap.version,
    .id = "com.fourlex.zobx",
    .name = "ZObx",
    .vendor = "fourlex",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "0.0.1",
    .description = "OB-X Polyphonic Synthesizer",
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
        .job_mutex = .init,
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
    self.job_mutex.lockUncancelable(mutex_io);
    defer self.job_mutex.unlock(mutex_io);

    if (self.jobs.notify_host_params_changed) {
        return false;
    }

    self.jobs.notify_host_params_changed = true;
    self.host.requestCallback(self.host);
    return true;
}

pub fn applyParamChanges(self: *Plugin, notify_host: bool) void {
    if (self.sample_rate == null) return;

    const engine = self.voices.engine orelse return;
    const au = dsp.audio_utils;

    // Oscillators
    const saw1 = self.params.get(.Osc1Saw).Float >= 0.5;
    const pulse1 = self.params.get(.Osc1Pulse).Float >= 0.5;
    const saw2 = self.params.get(.Osc2Saw).Float >= 0.5;
    const pulse2 = self.params.get(.Osc2Pulse).Float >= 0.5;
    const osc1_pitch = self.params.get(.Osc1Pitch).Float * 48.0;
    const osc2_pitch = self.params.get(.Osc2Pitch).Float * 48.0;
    const osc2_detune_val = self.params.get(.Osc2Detune).Float;
    const osc2_detune = au.logsc(@floatCast(osc2_detune_val), 0.001, 0.6, 19);
    const pw_val = self.params.get(.PulseWidth).Float;
    const pw = au.linsc(@floatCast(pw_val), 0, 0.95);
    const osc_sync = self.params.get(.OscSync).Float >= 0.5;
    const crossmod_val = self.params.get(.Crossmod).Float;
    const crossmod = crossmod_val * 48.0;
    const brightness_val = self.params.get(.OscBrightness).Float;
    const brightness = au.linsc(@floatCast(brightness_val), 7000, 26000);

    // Mixer
    const osc1_vol: f32 = @floatCast(self.params.get(.Osc1Volume).Float);
    const osc2_vol: f32 = @floatCast(self.params.get(.Osc2Volume).Float);
    const noise_vol: f32 = @floatCast(self.params.get(.NoiseVolume).Float);
    const noise_color: f32 = @floatCast(self.params.get(.NoiseColor).Float);
    const ring_mod_vol: f32 = @floatCast(self.params.get(.RingModVolume).Float);

    // Filter
    engine.processFilterCutoff(@floatCast(self.params.get(.FilterCutoff).Float));
    engine.processFilterResonance(@floatCast(self.params.get(.FilterResonance).Float));
    engine.processFilterMode(@floatCast(self.params.get(.FilterMode).Float));
    const four_pole = self.params.get(.Filter4Pole).Float >= 0.5;
    const bp_blend = self.params.get(.FilterBPBlend).Float >= 0.5;
    const xpander = self.params.get(.FilterXpander).Float >= 0.5;
    const xpander_mode_val: f32 = @floatCast(self.params.get(.FilterXpanderMode).Float);
    const xpander_mode: u8 = @intFromFloat(@round(@min(14.0, @max(0.0, xpander_mode_val))));
    const filter_env_amt_val = self.params.get(.FilterEnvAmount).Float;
    const filter_env_amt = au.linsc(@floatCast(filter_env_amt_val), 0, 140);
    const filter_env_invert = self.params.get(.FilterEnvInvert).Float >= 0.5;
    const filter_env_scale: f32 = if (filter_env_invert) -1.0 else 1.0;
    const filter_keytrack: f32 = @floatCast(self.params.get(.FilterKeyTrack).Float);
    const filter_push = self.params.get(.Filter2PolePush).Float >= 0.5;

    // Envelopes
    const amp_atk = au.logsc(@floatCast(self.params.get(.AmpAttack).Float), 4, 60000, 900);
    const amp_dec = au.logsc(@floatCast(self.params.get(.AmpDecay).Float), 4, 60000, 900);
    const amp_sus: f32 = @floatCast(self.params.get(.AmpSustain).Float);
    const amp_rel = au.logsc(@floatCast(self.params.get(.AmpRelease).Float), 8, 60000, 900);
    const amp_curve: f32 = @floatCast(self.params.get(.AmpAttackCurve).Float);

    const flt_atk = au.logsc(@floatCast(self.params.get(.FilterAttack).Float), 1, 60000, 900);
    const flt_dec = au.logsc(@floatCast(self.params.get(.FilterDecay).Float), 1, 60000, 900);
    const flt_sus: f32 = @floatCast(self.params.get(.FilterSustain).Float);
    const flt_rel = au.logsc(@floatCast(self.params.get(.FilterRelease).Float), 1, 60000, 900);
    const flt_curve: f32 = @floatCast(self.params.get(.FilterAttackCurve).Float);

    // LFO 1
    const lfo1_rate_val: f32 = @floatCast(self.params.get(.LFO1Rate).Float);
    engine.global_lfo.setRate(au.logsc(lfo1_rate_val, 0, 250, 3775));
    engine.global_lfo.setRateNormalized(lfo1_rate_val);
    engine.global_lfo.setTempoSync(self.params.get(.LFO1Sync).Float >= 0.5);
    engine.global_lfo.par.wave1blend = au.linsc(@floatCast(self.params.get(.LFO1Wave1).Float), -1, 1);
    engine.global_lfo.par.wave2blend = au.linsc(@floatCast(self.params.get(.LFO1Wave2).Float), -1, 1);
    engine.global_lfo.par.wave3blend = au.linsc(@floatCast(self.params.get(.LFO1Wave3).Float), -1, 1);
    engine.global_lfo.par.pw = @floatCast(self.params.get(.LFO1PW).Float);

    const lfo1_amt1_val: f32 = @floatCast(self.params.get(.LFO1ModAmt1).Float);
    const lfo1_amt1 = au.logsc(au.logsc(lfo1_amt1_val, 0, 1, 60), 0, 60, 10);
    const lfo1_amt2_val: f32 = @floatCast(self.params.get(.LFO1ModAmt2).Float);
    const lfo1_amt2 = au.linsc(lfo1_amt2_val, 0, 0.7);

    // LFO 2
    const lfo2_rate_val: f32 = @floatCast(self.params.get(.LFO2Rate).Float);

    // Envelope modulation
    const env_pitch_amt_val: f32 = @floatCast(self.params.get(.EnvToPitchAmt).Float);
    const env_pitch_amt = env_pitch_amt_val * 40.0;
    const env_pitch_invert = self.params.get(.EnvToPitchInvert).Float >= 0.5;
    const env_pitch_both = self.params.get(.EnvToPitchBothOscs).Float >= 0.5;
    const env_pw_amt_val: f32 = @floatCast(self.params.get(.EnvToPWAmt).Float);
    const env_pw_amt = au.linsc(env_pw_amt_val, 0, 1.055555555555555);
    const env_pw_invert = self.params.get(.EnvToPWInvert).Float >= 0.5;
    const env_pw_both = self.params.get(.EnvToPWBothOscs).Float >= 0.5;

    // Performance
    engine.processVolume(@floatCast(self.params.get(.Volume).Float));
    const porta_val: f32 = @floatCast(self.params.get(.Portamento).Float);
    const porta = au.logsc(1.0 - porta_val, 0.14, 250, 150);
    const tune_val: f32 = @floatCast(self.params.get(.Tune).Float);
    const tune = tune_val * 2.0 - 1.0;
    const transpose_val: f32 = @floatCast(self.params.get(.Transpose).Float);
    const transpose: i32 = @intFromFloat(@round((transpose_val * 2.0 - 1.0) * 24.0));

    const unison = self.params.get(.Unison).Float >= 0.5;
    engine.unison = unison;
    const unison_detune_val: f32 = @floatCast(self.params.get(.UnisonDetune).Float);
    const unison_detune = au.logsc(unison_detune_val, 0.001, 1, 19);

    const bend_up: f32 = @floatCast(self.params.get(.BendUpRange).Float * au.max_bend_range);
    const bend_down: f32 = @floatCast(self.params.get(.BendDownRange).Float * au.max_bend_range);
    const bend_osc2 = self.params.get(.BendOsc2Only).Float >= 0.5;
    const vel_amp: f32 = @floatCast(self.params.get(.VelToAmp).Float);
    const vel_filter: f32 = @floatCast(self.params.get(.VelToFilter).Float);
    const legato_val: f32 = @floatCast(self.params.get(.EnvLegatoMode).Float);
    const legato_mode: i32 = @intFromFloat(legato_val * 3.0);

    // Slop
    const env_slop: f32 = @floatCast(self.params.get(.EnvSlop).Float);
    const filter_slop = au.linsc(@floatCast(self.params.get(.FilterSlop).Float), 0, 18);
    const porta_slop = au.linsc(@floatCast(self.params.get(.PortamentoSlop).Float), 0, 0.75);
    const level_slop = au.linsc(@floatCast(self.params.get(.LevelSlop).Float), 0, 0.67);

    // LFO1 routing (tri-state: 0 = off, 0.5 = +, 1.0 = -)
    const lfo1_osc1_pitch = remapTriState(@floatCast(self.params.get(.LFO1ToOsc1Pitch).Float));
    const lfo1_osc2_pitch = remapTriState(@floatCast(self.params.get(.LFO1ToOsc2Pitch).Float));
    const lfo1_cutoff = remapTriState(@floatCast(self.params.get(.LFO1ToCutoff).Float));
    const lfo1_osc1_pw = remapTriState(@floatCast(self.params.get(.LFO1ToOsc1PW).Float));
    const lfo1_osc2_pw = remapTriState(@floatCast(self.params.get(.LFO1ToOsc2PW).Float));
    const lfo1_volume_raw = remapTriState(@floatCast(self.params.get(.LFO1ToVolume).Float));

    // LFO2 routing
    const lfo2_osc1_pitch = remapTriState(@floatCast(self.params.get(.LFO2ToOsc1Pitch).Float));
    const lfo2_osc2_pitch = remapTriState(@floatCast(self.params.get(.LFO2ToOsc2Pitch).Float));
    const lfo2_cutoff = remapTriState(@floatCast(self.params.get(.LFO2ToCutoff).Float));
    const lfo2_osc1_pw = remapTriState(@floatCast(self.params.get(.LFO2ToOsc1PW).Float));
    const lfo2_osc2_pw = remapTriState(@floatCast(self.params.get(.LFO2ToOsc2PW).Float));
    const lfo2_volume_raw = remapTriState(@floatCast(self.params.get(.LFO2ToVolume).Float));

    // LFO2 rate and wave settings
    const lfo2_amt1_val: f32 = @floatCast(self.params.get(.LFO2ModAmt1).Float);
    const lfo2_amt1 = au.logsc(au.logsc(lfo2_amt1_val, 0, 1, 60), 0, 60, 10);
    const lfo2_amt2_val: f32 = @floatCast(self.params.get(.LFO2ModAmt2).Float);
    const lfo2_amt2 = au.linsc(lfo2_amt2_val, 0, 0.7);

    // Vibrato
    const vib_rate: f32 = @floatCast(self.params.get(.VibratoRate).Float);
    engine.vibrato_lfo.setRate(au.linsc(vib_rate, 2, 12));
    const vib_wave: f32 = @floatCast(self.params.get(.VibratoWave).Float);
    engine.vibrato_lfo.par.wave1blend = if (vib_wave >= 0.5) 0.0 else -1.0;
    engine.vibrato_lfo.par.wave2blend = if (vib_wave >= 0.5) -1.0 else 0.0;

    // HQ Mode
    const hq = self.params.get(.HQMode).Float >= 0.5;
    if (hq != engine.oversample) {
        engine.allSoundOff();
        engine.setHQMode(hq, false);
    }

    // Osc2 PW offset
    const osc2_pw_offset = au.linsc(@floatCast(self.params.get(.Osc2PWOffset).Float), 0, 0.95);

    // Apply to all voices
    for (&engine.voices) |*v| {
        // Oscillator settings
        v.oscs.par.osc.saw1 = saw1;
        v.oscs.par.osc.pulse1 = pulse1;
        v.oscs.par.osc.saw2 = saw2;
        v.oscs.par.osc.pulse2 = pulse2;
        v.oscs.par.osc.pitch1 = @floatCast(osc1_pitch);
        v.oscs.par.osc.pitch2 = @floatCast(osc2_pitch);
        v.oscs.par.osc.detune = osc2_detune;
        v.oscs.par.osc.pw = pw;
        v.oscs.par.osc.sync = osc_sync;
        v.oscs.par.osc.crossmod = @floatCast(crossmod);
        v.oscs.par.pitch.tune = tune;
        v.oscs.par.pitch.transpose = transpose;
        v.oscs.par.pitch.unison_detune = unison_detune;
        v.setBrightness(brightness);

        // Mixer
        v.oscs.par.mix.osc1 = osc1_vol;
        v.oscs.par.mix.osc2 = osc2_vol;
        v.oscs.par.mix.noise = noise_vol;
        v.oscs.par.mix.noise_color = noise_color;
        v.oscs.par.mix.ring_mod = ring_mod_vol;

        // Filter
        v.par.filter.four_pole = four_pole;
        v.filter.par.bp_blend_2pole = bp_blend;
        v.filter.par.xpander_4pole = xpander;
        v.filter.par.xpander_mode = xpander_mode;
        v.par.filter.env_amt = filter_env_amt;
        v.par.filter.invert_env = filter_env_invert;
        v.par.filter.invert_env_scale = filter_env_scale;
        v.par.filter.keytrack = filter_keytrack;
        v.setFilter2PolePush(filter_push);

        // Amp envelope
        v.amp_env.setAttack(amp_atk);
        v.amp_env.setDecay(amp_dec);
        v.amp_env.setSustain(amp_sus);
        v.amp_env.setRelease(amp_rel);
        v.amp_env.setAttackCurve(amp_curve);

        // Filter envelope
        v.filter_env.setAttack(flt_atk);
        v.filter_env.setDecay(flt_dec);
        v.filter_env.setSustain(flt_sus);
        v.filter_env.setRelease(flt_rel);
        v.filter_env.setAttackCurve(flt_curve);

        // Performance
        v.par.osc.portamento = porta;
        v.par.extmod.pb_up = bend_up;
        v.par.extmod.pb_down = bend_down;
        v.par.extmod.pb_osc2_only = bend_osc2;
        v.par.extmod.vel_to_amp = vel_amp;
        v.par.extmod.vel_to_filter = vel_filter;
        v.par.extmod.env_legato_mode = legato_mode;

        // Envelope modulation
        v.par.osc.env_pitch_amt = env_pitch_amt;
        v.oscs.par.mod.env_to_pitch_invert = env_pitch_invert;
        v.par.osc.env_pitch_both_oscs = env_pitch_both;
        v.par.osc.env_pw_amt = env_pw_amt;
        v.oscs.par.mod.env_to_pw_invert = env_pw_invert;
        v.par.osc.env_pw_both_oscs = env_pw_both;
        v.par.osc.pw_osc2_offset = osc2_pw_offset;

        // Slop
        v.setEnvTimingOffset(env_slop);
        v.par.slop.cutoff = filter_slop;
        v.par.slop.portamento = porta_slop;
        v.par.slop.level = level_slop;

        // LFO 1 routing
        v.par.lfo1.amt1 = lfo1_amt1;
        v.par.lfo1.amt2 = lfo1_amt2;
        v.par.lfo1.osc1_pitch = lfo1_osc1_pitch;
        v.par.lfo1.osc2_pitch = lfo1_osc2_pitch;
        v.par.lfo1.cutoff = lfo1_cutoff;
        v.par.lfo1.osc1_pw = lfo1_osc1_pw;
        v.par.lfo1.osc2_pw = lfo1_osc2_pw;
        v.par.lfo1.volume = lfo1_volume_raw;
        v.par.lfo1.abs_volume = @abs(lfo1_volume_raw);

        // LFO 2 settings
        v.lfo2.setRate(au.logsc(lfo2_rate_val, 0, 250, 3775));
        v.lfo2.setRateNormalized(lfo2_rate_val);
        v.lfo2.setTempoSync(self.params.get(.LFO2Sync).Float >= 0.5);
        v.lfo2.par.wave1blend = au.linsc(@floatCast(self.params.get(.LFO2Wave1).Float), -1, 1);
        v.lfo2.par.wave2blend = au.linsc(@floatCast(self.params.get(.LFO2Wave2).Float), -1, 1);
        v.lfo2.par.wave3blend = au.linsc(@floatCast(self.params.get(.LFO2Wave3).Float), -1, 1);
        v.lfo2.par.pw = @floatCast(self.params.get(.LFO2PW).Float);
        v.par.lfo2.amt1 = lfo2_amt1;
        v.par.lfo2.amt2 = lfo2_amt2;
        v.par.lfo2.osc1_pitch = lfo2_osc1_pitch;
        v.par.lfo2.osc2_pitch = lfo2_osc2_pitch;
        v.par.lfo2.cutoff = lfo2_cutoff;
        v.par.lfo2.osc1_pw = lfo2_osc1_pw;
        v.par.lfo2.osc2_pw = lfo2_osc2_pw;
        v.par.lfo2.volume = lfo2_volume_raw;
        v.par.lfo2.abs_volume = @abs(lfo2_volume_raw);
    }

    if (notify_host) {
        _ = self.notifyHostParamsChanged();
    }
}

// Maps tri-state parameter (0 = off, 0.5 = +1, 1.0 = -1)
// Same as OB-Xf's remapZeroHalfOneToZeroOneMinusOne
fn remapTriState(x: f32) f32 {
    const xr = @round(x * 2.0) * 0.5;
    const res = (5.0 * xr) - (6.0 * xr * xr);
    return @round(res);
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
    // Initialize the synth engine
    _ = plugin.voices.ensureEngine(@floatCast(sample_rate)) catch return false;
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
        plugin.job_mutex.lockUncancelable(mutex_io);
        defer plugin.job_mutex.unlock(mutex_io);
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
