//! Unified CLAP audio FX plugin for Flux stock builtins (DAWproject schema params).

const std = @import("std");
const clap = @import("clap-bindings");

const Kind = @import("kind.zig").Kind;
const params_mod = @import("params.zig");
const Params = params_mod.Params;
const eq_dsp = @import("dsp/equalizer.zig");
const dynamics = @import("dsp/dynamics.zig");

pub const Plugin = struct {
    allocator: std.mem.Allocator,
    host: *const clap.Host,
    plugin: clap.Plugin,
    kind: Kind,
    params: Params,
    sample_rate: f64 = 44100,
    eq: eq_dsp.Equalizer = .{},
    comp: dynamics.Compressor = .{},
    gate: dynamics.NoiseGate = .{},
    lim: dynamics.Limiter = .{},
    scratch_l: [8192]f32 = undefined,
    scratch_r: [8192]f32 = undefined,

    pub fn fromClapPlugin(clap_plugin: *const clap.Plugin) *Plugin {
        return @ptrCast(@alignCast(clap_plugin.plugin_data));
    }

    pub fn init(allocator: std.mem.Allocator, host: *const clap.Host, kind: Kind) !*Plugin {
        const self = try allocator.create(Plugin);
        self.* = .{
            .allocator = allocator,
            .host = host,
            .kind = kind,
            .params = Params.init(kind),
            .plugin = .{
                .descriptor = descriptorFor(kind),
                .plugin_data = self,
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
        };
        self.applyParamsToDsp();
        return self;
    }

    pub fn deinit(self: *Plugin) void {
        self.allocator.destroy(self);
    }

    pub fn applyParamsToDsp(self: *Plugin) void {
        switch (self.kind) {
            .compressor => {
                self.comp.threshold_db = self.params.get(params_mod.id_threshold);
                self.comp.ratio = self.params.get(params_mod.id_ratio);
                self.comp.attack_s = self.params.get(params_mod.id_attack);
                self.comp.release_s = self.params.get(params_mod.id_release);
                self.comp.input_gain_db = self.params.get(params_mod.id_input_gain);
                self.comp.output_gain_db = self.params.get(params_mod.id_output_gain);
                self.comp.auto_makeup = self.params.getBool(params_mod.id_auto_makeup);
                self.comp.configure();
            },
            .noise_gate => {
                self.gate.threshold_db = self.params.get(params_mod.id_threshold);
                self.gate.ratio = self.params.get(params_mod.id_ratio);
                self.gate.attack_s = self.params.get(params_mod.id_attack);
                self.gate.release_s = self.params.get(params_mod.id_release);
                self.gate.range_db = self.params.get(params_mod.id_range);
            },
            .limiter => {
                self.lim.threshold_db = self.params.get(params_mod.id_threshold);
                self.lim.attack_s = self.params.get(params_mod.id_attack);
                self.lim.release_s = self.params.get(params_mod.id_release);
                self.lim.input_gain_db = self.params.get(params_mod.id_input_gain);
                self.lim.output_gain_db = self.params.get(params_mod.id_output_gain);
                self.lim.configure();
            },
            .equalizer => {
                self.eq.input_gain_db = self.params.get(params_mod.id_eq_input_gain);
                self.eq.output_gain_db = self.params.get(params_mod.id_eq_output_gain);
                for (0..self.eq.band_count) |b| {
                    const base = params_mod.eqBandBase(b);
                    const t: u32 = @intFromFloat(self.params.get(base + 0));
                    self.eq.bands[b].type = std.enums.fromInt(eq_dsp.BandType, t) orelse .bell;
                    self.eq.bands[b].freq_hz = self.params.get(base + 1);
                    self.eq.bands[b].gain_db = self.params.get(base + 2);
                    self.eq.bands[b].q = self.params.get(base + 3);
                    self.eq.bands[b].enabled = self.params.get(base + 4) >= 0.5;
                }
                self.eq.markDirty();
            },
        }
        self.params.dirty = false;
    }

    fn setSampleRateAll(self: *Plugin, sr: f64) void {
        self.sample_rate = sr;
        self.eq.setSampleRate(sr);
        self.comp.setSampleRate(sr);
        self.gate.setSampleRate(sr);
        self.lim.setSampleRate(sr);
    }
};

const desc_eq = clap.Plugin.Descriptor{
    .clap_version = clap.version,
    .id = Kind.equalizer.id(),
    .name = Kind.equalizer.name(),
    .vendor = "Flux",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "0.2.0",
    .description = "Flux stock parametric equalizer (DAWproject Equalizer)",
    .features = &.{ clap.Plugin.features.audio_effect, clap.Plugin.features.stereo, clap.Plugin.features.equalizer },
};
const desc_comp = clap.Plugin.Descriptor{
    .clap_version = clap.version,
    .id = Kind.compressor.id(),
    .name = Kind.compressor.name(),
    .vendor = "Flux",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "0.2.0",
    .description = "Flux stock compressor (DAWproject Compressor)",
    .features = &.{ clap.Plugin.features.audio_effect, clap.Plugin.features.stereo, clap.Plugin.features.compressor },
};
const desc_gate = clap.Plugin.Descriptor{
    .clap_version = clap.version,
    .id = Kind.noise_gate.id(),
    .name = Kind.noise_gate.name(),
    .vendor = "Flux",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "0.2.0",
    .description = "Flux stock noise gate (DAWproject NoiseGate)",
    .features = &.{ clap.Plugin.features.audio_effect, clap.Plugin.features.stereo },
};
const desc_lim = clap.Plugin.Descriptor{
    .clap_version = clap.version,
    .id = Kind.limiter.id(),
    .name = Kind.limiter.name(),
    .vendor = "Flux",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "0.2.0",
    .description = "Flux stock limiter (DAWproject Limiter)",
    .features = &.{ clap.Plugin.features.audio_effect, clap.Plugin.features.stereo, clap.Plugin.features.limiter },
};

fn descriptorFor(kind: Kind) *const clap.Plugin.Descriptor {
    return switch (kind) {
        .equalizer => &desc_eq,
        .compressor => &desc_comp,
        .noise_gate => &desc_gate,
        .limiter => &desc_lim,
    };
}

fn _init(_: *const clap.Plugin) callconv(.c) bool {
    return true;
}

fn _destroy(clap_plugin: *const clap.Plugin) callconv(.c) void {
    Plugin.fromClapPlugin(clap_plugin).deinit();
}

fn _activate(clap_plugin: *const clap.Plugin, sample_rate: f64, _: u32, _: u32) callconv(.c) bool {
    const self = Plugin.fromClapPlugin(clap_plugin);
    self.setSampleRateAll(sample_rate);
    self.applyParamsToDsp();
    return true;
}

fn _deactivate(_: *const clap.Plugin) callconv(.c) void {}
fn _startProcessing(_: *const clap.Plugin) callconv(.c) bool {
    return true;
}
fn _stopProcessing(_: *const clap.Plugin) callconv(.c) void {}

fn _reset(clap_plugin: *const clap.Plugin) callconv(.c) void {
    const self = Plugin.fromClapPlugin(clap_plugin);
    self.eq.reset();
    self.comp.reset();
    self.gate.reset();
    self.lim.reset();
}

fn _onMainThread(_: *const clap.Plugin) callconv(.c) void {}

fn _process(clap_plugin: *const clap.Plugin, process: *const clap.Process) callconv(.c) clap.Process.Status {
    const self = Plugin.fromClapPlugin(clap_plugin);
    const frames = process.frames_count;
    if (frames == 0) return .@"continue";

    if (process.audio_inputs_count == 0 or process.audio_outputs_count == 0) return .@"continue";
    const in_ports = process.audio_inputs;
    const out_ports = process.audio_outputs;
    if (in_ports[0].data32 == null or out_ports[0].data32 == null) return .@"continue";

    const in_ch = in_ports[0].data32.?;
    const out_ch = out_ports[0].data32.?;
    const in_l = in_ch[0][0..frames];
    const in_r = if (in_ports[0].channel_count > 1) in_ch[1][0..frames] else in_l;
    const out_l = out_ch[0][0..frames];
    const out_r = if (out_ports[0].channel_count > 1) out_ch[1][0..frames] else out_l;

    const n = @min(frames, self.scratch_l.len);
    @memcpy(self.scratch_l[0..n], in_l[0..n]);
    @memcpy(self.scratch_r[0..n], in_r[0..n]);

    if (self.params.dirty) self.applyParamsToDsp();
    var cursor: usize = 0;
    const events = process.in_events;
    const event_count = events.size(events);
    var event_index: u32 = 0;
    while (event_index < event_count) : (event_index += 1) {
        const hdr = events.get(events, event_index);
        if (hdr.type != .param_value) continue;
        const pe: *const clap.events.ParamValue = @ptrCast(@alignCast(hdr));
        const offset = @max(cursor, @min(@as(usize, hdr.sample_offset), n));
        if (offset > cursor) {
            if (self.params.dirty) self.applyParamsToDsp();
            processRange(self, cursor, offset);
        }
        self.params.set(@intFromEnum(pe.param_id), pe.value);
        cursor = offset;
    }
    if (self.params.dirty) self.applyParamsToDsp();
    if (cursor < n) processRange(self, cursor, n);

    @memcpy(out_l[0..n], self.scratch_l[0..n]);
    @memcpy(out_r[0..n], self.scratch_r[0..n]);
    return .@"continue";
}

fn processRange(self: *Plugin, start: usize, end: usize) void {
    const left = self.scratch_l[start..end];
    const right = self.scratch_r[start..end];
    switch (self.kind) {
        .equalizer => self.eq.process(left, right),
        .compressor => self.comp.process(left, right),
        .noise_gate => self.gate.process(left, right),
        .limiter => self.lim.process(left, right),
    }
}

const audio_ports = clap.ext.audio_ports.Plugin{
    .count = audioPortsCount,
    .get = audioPortsGet,
};

fn audioPortsCount(_: *const clap.Plugin, _: bool) callconv(.c) u32 {
    return 1;
}

fn audioPortsGet(_: *const clap.Plugin, index: u32, is_input: bool, info: *clap.ext.audio_ports.Info) callconv(.c) bool {
    if (index != 0) return false;
    const name = if (is_input) "Input" else "Output";
    @memset(&info.name, 0);
    @memcpy(info.name[0..name.len], name);
    info.id = @enumFromInt(if (is_input) @as(u32, 0) else 1);
    info.channel_count = 2;
    info.flags = .{ .is_main = true, .supports_64bits = false };
    info.port_type = "stereo";
    info.in_place_pair = .invalid_id;
    return true;
}

const ext_params = Params.createExt(Plugin);

const state_ext = clap.ext.state.Plugin{
    .save = stateSave,
    .load = stateLoad,
};

fn stateSave(clap_plugin: *const clap.Plugin, stream: *const clap.OStream) callconv(.c) bool {
    const self = Plugin.fromClapPlugin(clap_plugin);
    var buf: [params_mod.max_params * 12 + 4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], self.params.count, .little);
    var off: usize = 4;
    for (0..self.params.count) |i| {
        std.mem.writeInt(u32, buf[off..][0..4], self.params.defs[i].id, .little);
        off += 4;
        std.mem.writeInt(u64, buf[off..][0..8], @bitCast(self.params.values[i]), .little);
        off += 8;
    }
    return stream.write(stream, &buf, off) != .write_error;
}

fn stateLoad(clap_plugin: *const clap.Plugin, stream: *const clap.IStream) callconv(.c) bool {
    const self = Plugin.fromClapPlugin(clap_plugin);
    var buf: [params_mod.max_params * 12 + 4]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const res = stream.read(stream, buf[total..].ptr, @intCast(buf.len - total));
        if (res == .read_error) return false;
        if (res == .end_of_file) break;
        const n: usize = @intCast(@intFromEnum(res));
        if (n == 0) break;
        total += n;
    }
    if (total < 4) return false;
    const count = std.mem.readInt(u32, buf[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count and off + 12 <= total) : (i += 1) {
        const id = std.mem.readInt(u32, buf[off..][0..4], .little);
        off += 4;
        const bits = std.mem.readInt(u64, buf[off..][0..8], .little);
        off += 8;
        self.params.set(id, @bitCast(bits));
    }
    self.applyParamsToDsp();
    return true;
}

fn _getExtension(_: *const clap.Plugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    const sid = std.mem.span(id);
    if (std.mem.eql(u8, sid, clap.ext.audio_ports.id)) return &audio_ports;
    if (std.mem.eql(u8, sid, clap.ext.params.id)) return &ext_params;
    if (std.mem.eql(u8, sid, clap.ext.state.id)) return &state_ext;
    return null;
}
