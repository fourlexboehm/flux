const std = @import("std");

const c = @cImport({
    @cInclude("emu2413/emu2413.h");
});

pub const PatchParam = enum(u8) {
    mod_attack = 0,
    car_attack,
    mod_decay,
    car_decay,
    mod_sustain,
    car_sustain,
    mod_release,
    car_release,
    mod_multiplier,
    car_multiplier,
    feedback,
    mod_level,
    mod_wave,
    car_wave,
    mod_tremolo,
    car_tremolo,
    mod_vibrato,
    car_vibrato,
};

const SynthParameter = enum(u8) {
    ar0,
    ar1,
    dr0,
    dr1,
    sl0,
    sl1,
    rr0,
    rr1,
    mul0,
    mul1,
    fb,
    tl,
    dm,
    dc,
    am0,
    am1,
    vib0,
    vib1,
    wheel_range,
    fine_tune,
};

const synth_parameter_count = std.meta.fields(SynthParameter).len;
const channel_count = 9;
const master_clock: u32 = 3_579_545;
const program_first_preset = 1;
const program_count = 16;

const ChannelInfo = struct {
    active: bool = false,
    note: i32 = 0,
    velocity: f32 = 0.0,
};

pub const Engine = struct {
    opll: *c.OPLL,
    program: u8,
    parameters: [synth_parameter_count]f32,
    channels: [channel_count]ChannelInfo,
    last_channel: usize,
    wheel: f32,
    preset_mode: bool,
    preset_program: u8,

    fn create(sample_rate: u32) ?*Engine {
        const opll = c.OPLL_new(master_clock, sample_rate) orelse return null;
        const engine = std.heap.page_allocator.create(Engine) catch {
            c.OPLL_delete(opll);
            return null;
        };

        engine.* = .{
            .opll = opll,
            .program = 0,
            .parameters = defaultParameters(),
            .channels = [_]ChannelInfo{.{}} ** channel_count,
            .last_channel = 0,
            .wheel = 0.0,
            .preset_mode = false,
            .preset_program = program_first_preset,
        };
        engine.reset();
        return engine;
    }

    fn destroy(self: *Engine) void {
        c.OPLL_delete(self.opll);
        std.heap.page_allocator.destroy(self);
    }

    fn setSampleRate(self: *Engine, sample_rate: u32) void {
        c.OPLL_set_rate(self.opll, sample_rate);
    }

    fn reset(self: *Engine) void {
        c.OPLL_reset(self.opll);
        c.OPLL_reset_patch(self.opll, 0);

        self.channels = [_]ChannelInfo{.{}} ** channel_count;
        self.last_channel = 0;
        self.wheel = 0.0;
        self.applyProgram();
        self.sendPatchState();
    }

    fn applyProgram(self: *Engine) void {
        self.program = if (self.preset_mode) self.preset_program else 0;
    }

    fn setPresetMode(self: *Engine, enabled: bool) void {
        self.preset_mode = enabled;
        self.applyProgram();
    }

    fn setProgram(self: *Engine, program: i32) void {
        const clamped = std.math.clamp(program, program_first_preset, program_count - 1);
        self.preset_program = @intCast(clamped);
        self.applyProgram();
    }

    fn keyOn(self: *Engine, note: i32, velocity: f32) void {
        const index = self.chooseChannelIndex();
        const info = &self.channels[index];
        sendKeyOn(self.opll, &self.parameters, index, self.program, note, self.wheel, clampUnit(velocity));
        info.note = note;
        info.velocity = velocity;
        info.active = true;
        self.last_channel = index;
    }

    fn keyOff(self: *Engine, note: i32) void {
        for (&self.channels, 0..) |*info, i| {
            if (info.active and info.note == note) {
                sendKeyOff(self.opll, &self.parameters, i, self.program, note, self.wheel);
                info.active = false;
                break;
            }
        }
    }

    fn allNotesOff(self: *Engine) void {
        for (&self.channels, 0..) |*info, i| {
            if (info.active) {
                sendKeyOff(self.opll, &self.parameters, i, self.program, info.note, self.wheel);
                info.active = false;
            }
        }
    }

    fn hasActiveNotes(self: *const Engine) bool {
        for (self.channels) |info| {
            if (info.active) return true;
        }
        return false;
    }

    fn setPitchWheel(self: *Engine, value: f32) void {
        self.wheel = std.math.clamp(value, -1.0, 1.0);
        for (self.channels, 0..) |info, i| {
            adjustPitch(self.opll, &self.parameters, i, info.note, self.wheel, info.active);
        }
    }

    fn setWheelRange(self: *Engine, semitones: f32) void {
        self.setParameter(.wheel_range, std.math.clamp(semitones, 0.0, 12.0) / 12.0);
    }

    fn setFineTune(self: *Engine, cents: f32) void {
        self.setParameter(.fine_tune, (std.math.clamp(cents, -50.0, 50.0) / 100.0) + 0.5);
    }

    fn setPatchParam(self: *Engine, patch_param: PatchParam, value: f32) void {
        self.setParameter(patchParamToSynthParam(patch_param), clampUnit(value));
    }

    fn render(self: *Engine) f32 {
        return (4.0 / 32767.0) * @as(f32, @floatFromInt(c.OPLL_calc(self.opll)));
    }

    fn setParameter(self: *Engine, param: SynthParameter, value: f32) void {
        const index = @intFromEnum(param);
        self.parameters[index] = value;

        switch (param) {
            .ar0, .dr0 => sendARDR(self.opll, &self.parameters, 0),
            .ar1, .dr1 => sendARDR(self.opll, &self.parameters, 1),
            .sl0, .rr0 => sendSLRR(self.opll, &self.parameters, 0),
            .sl1, .rr1 => sendSLRR(self.opll, &self.parameters, 1),
            .mul0, .vib0, .am0 => sendMUL(self.opll, &self.parameters, 0),
            .mul1, .vib1, .am1 => sendMUL(self.opll, &self.parameters, 1),
            .fb, .dm, .dc => sendFB(self.opll, &self.parameters),
            .tl => sendTL(self.opll, &self.parameters),
            .wheel_range, .fine_tune => self.setPitchWheel(self.wheel),
        }
    }

    fn sendPatchState(self: *Engine) void {
        sendARDR(self.opll, &self.parameters, 0);
        sendARDR(self.opll, &self.parameters, 1);
        sendSLRR(self.opll, &self.parameters, 0);
        sendSLRR(self.opll, &self.parameters, 1);
        sendMUL(self.opll, &self.parameters, 0);
        sendMUL(self.opll, &self.parameters, 1);
        sendFB(self.opll, &self.parameters);
        sendTL(self.opll, &self.parameters);
        self.setPitchWheel(self.wheel);
    }

    fn chooseChannelIndex(self: *const Engine) usize {
        var index = self.last_channel;
        for (0..channel_count - 1) |_| {
            index += 1;
            if (index == channel_count) index = 0;
            if (!self.channels[index].active) return index;
        }
        return (self.last_channel + 1) % channel_count;
    }
};

const program_names = [_][]const u8{
    "User",
    "Violin",
    "Guitar",
    "Piano",
    "Flute",
    "Clarinet",
    "Oboe",
    "Trumpet",
    "Organ",
    "Horn",
    "Synthesizer",
    "Harpsichord",
    "Vibraphone",
    "S.Bass",
    "A.Bass",
    "E.Guitar",
};

const multiplier_texts = [_][]const u8{
    "1/2", "1", "2", "3",
    "4", "5", "6", "7",
    "8", "9", "10", "10",
    "12", "12", "15", "15",
};

const feedback_texts = [_][]const u8{
    "0", "n/16", "n/8", "n/4", "n/2", "n", "2n", "4n",
};

const attack_texts = [_][]const u8{
    "0", "0.28", "0.50", "0.84",
    "1.69", "3.30", "6.76", "13.52",
    "27.03", "54.87", "108.13", "216.27",
    "432.54", "865.88", "1730.15", "inf",
};

const decay_texts = [_][]const u8{
    "1.27", "2.55", "5.11", "10.22",
    "20.44", "40.07", "81.74", "163.49",
    "326.98", "653.95", "1307.91", "2615.82",
    "5231.64", "10463.30", "20926.60", "inf",
};

fn defaultParameters() [synth_parameter_count]f32 {
    var values = [_]f32{0.0} ** synth_parameter_count;
    values[@intFromEnum(SynthParameter.sl0)] = 1.0;
    values[@intFromEnum(SynthParameter.sl1)] = 1.0;
    values[@intFromEnum(SynthParameter.mul0)] = 1.1 / 15.0;
    values[@intFromEnum(SynthParameter.mul1)] = 1.1 / 15.0;
    values[@intFromEnum(SynthParameter.wheel_range)] = 3.0 / 12.0;
    values[@intFromEnum(SynthParameter.fine_tune)] = 0.5;
    return values;
}

fn clampUnit(value: f32) f32 {
    return std.math.clamp(value, 0.0, 1.0);
}

fn synthValue(parameters: *const [synth_parameter_count]f32, param: SynthParameter) f32 {
    return parameters[@intFromEnum(param)];
}

fn calculateFNumber(note: i32, tune: f32) i32 {
    const interval_from_a: f32 = @floatFromInt(@rem(note - 9, 12));
    return @intFromFloat(144.1792 * @exp2((interval_from_a + tune) / 12.0));
}

fn noteToBlock(note: i32) i32 {
    return std.math.clamp(@divTrunc(note - 9, 12), 0, 7);
}

fn calculateBlockAndFNumber(note: i32, parameters: *const [synth_parameter_count]f32, wheel: f32) i32 {
    const range = synthValue(parameters, .wheel_range) * 12.0;
    const tune = synthValue(parameters, .fine_tune) - 0.5;
    return (noteToBlock(note) << 9) + calculateFNumber(note, (wheel * range) + tune);
}

fn sendKeyOn(opll: *c.OPLL, parameters: *const [synth_parameter_count]f32, channel: usize, program: u8, note: i32, wheel: f32, velocity: f32) void {
    const bf = calculateBlockAndFNumber(note, parameters, wheel);
    const vl: u32 = @intFromFloat(15.0 - (velocity * 15.0));
    c.OPLL_writeReg(opll, @intCast(0x10 + channel), @intCast(bf & 0xff));
    c.OPLL_writeReg(opll, @intCast(0x20 + channel), @intCast(0x10 + (bf >> 8)));
    c.OPLL_writeReg(opll, @intCast(0x30 + channel), (@as(u32, program) << 4) + vl);
}

fn sendKeyOff(opll: *c.OPLL, parameters: *const [synth_parameter_count]f32, channel: usize, program: u8, note: i32, wheel: f32) void {
    _ = program;
    const bf = calculateBlockAndFNumber(note, parameters, wheel);
    c.OPLL_writeReg(opll, @intCast(0x20 + channel), @intCast(bf >> 8));
}

fn adjustPitch(opll: *c.OPLL, parameters: *const [synth_parameter_count]f32, channel: usize, note: i32, wheel: f32, key_on: bool) void {
    const bf = calculateBlockAndFNumber(note, parameters, wheel);
    const key_flag: i32 = if (key_on) 0x10 else 0;
    c.OPLL_writeReg(opll, @intCast(0x10 + channel), @intCast(bf & 0xff));
    c.OPLL_writeReg(opll, @intCast(0x20 + channel), @intCast(key_flag + (bf >> 8)));
}

fn sendARDR(opll: *c.OPLL, parameters: *const [synth_parameter_count]f32, op: usize) void {
    const ar_index = if (op == 0) SynthParameter.ar0 else SynthParameter.ar1;
    const dr_index = if (op == 0) SynthParameter.dr0 else SynthParameter.dr1;
    const ar: u32 = @intFromFloat((1.0 - synthValue(parameters, ar_index)) * 15.0);
    const dr: u32 = @intFromFloat((1.0 - synthValue(parameters, dr_index)) * 15.0);
    c.OPLL_writeReg(opll, @intCast(4 + op), (ar << 4) + dr);
}

fn sendSLRR(opll: *c.OPLL, parameters: *const [synth_parameter_count]f32, op: usize) void {
    const sl_index = if (op == 0) SynthParameter.sl0 else SynthParameter.sl1;
    const rr_index = if (op == 0) SynthParameter.rr0 else SynthParameter.rr1;
    const sl: u32 = @intFromFloat((1.0 - synthValue(parameters, sl_index)) * 15.0);
    const rr: u32 = @intFromFloat((1.0 - synthValue(parameters, rr_index)) * 15.0);
    c.OPLL_writeReg(opll, @intCast(6 + op), (sl << 4) + rr);
}

fn sendMUL(opll: *c.OPLL, parameters: *const [synth_parameter_count]f32, op: usize) void {
    const am_index = if (op == 0) SynthParameter.am0 else SynthParameter.am1;
    const vib_index = if (op == 0) SynthParameter.vib0 else SynthParameter.vib1;
    const mul_index = if (op == 0) SynthParameter.mul0 else SynthParameter.mul1;
    const am: u32 = if (synthValue(parameters, am_index) < 0.5) 0 else 0x80;
    const vib: u32 = if (synthValue(parameters, vib_index) < 0.5) 0 else 0x40;
    const mul: u32 = @intFromFloat(synthValue(parameters, mul_index) * 15.0);
    c.OPLL_writeReg(opll, @intCast(op), am + vib + 0x20 + mul);
}

fn sendFB(opll: *c.OPLL, parameters: *const [synth_parameter_count]f32) void {
    const dc: u32 = if (synthValue(parameters, .dc) < 0.5) 0 else 0x10;
    const dm: u32 = if (synthValue(parameters, .dm) < 0.5) 0 else 0x08;
    const fb: u32 = @intFromFloat(synthValue(parameters, .fb) * 7.0);
    c.OPLL_writeReg(opll, 3, dc + dm + fb);
}

fn sendTL(opll: *c.OPLL, parameters: *const [synth_parameter_count]f32) void {
    const tl: u32 = @intFromFloat((1.0 - synthValue(parameters, .tl)) * 63.0);
    c.OPLL_writeReg(opll, 2, tl);
}

fn patchParamToSynthParam(param: PatchParam) SynthParameter {
    return switch (param) {
        .mod_attack => .ar0,
        .car_attack => .ar1,
        .mod_decay => .dr0,
        .car_decay => .dr1,
        .mod_sustain => .sl0,
        .car_sustain => .sl1,
        .mod_release => .rr0,
        .car_release => .rr1,
        .mod_multiplier => .mul0,
        .car_multiplier => .mul1,
        .feedback => .fb,
        .mod_level => .tl,
        .mod_wave => .dm,
        .car_wave => .dc,
        .mod_tremolo => .am0,
        .car_tremolo => .am1,
        .mod_vibrato => .vib0,
        .car_vibrato => .vib1,
    };
}

fn writeText(buffer: []u8, text: []const u8) bool {
    _ = std.fmt.bufPrintZ(buffer, "{s}", .{text}) catch return false;
    return true;
}

fn parameterText(param: SynthParameter, value: f32, buffer: []u8) bool {
    const clamped = clampUnit(value);
    switch (param) {
        .ar0, .ar1 => {
            const index: usize = @intFromFloat(clamped * 15.0);
            return writeText(buffer, attack_texts[index]);
        },
        .dr0, .dr1, .rr0, .rr1 => {
            const index: usize = @intFromFloat(clamped * 15.0);
            return writeText(buffer, decay_texts[index]);
        },
        .sl0, .sl1, .tl => {
            const level: i32 = @intFromFloat((1.0 - clamped) * 45.0);
            _ = std.fmt.bufPrintZ(buffer, "{d}", .{level}) catch return false;
            return true;
        },
        .mul0, .mul1 => {
            const index: usize = @intFromFloat(clamped * 15.0);
            return writeText(buffer, multiplier_texts[index]);
        },
        .fb => {
            const index: usize = @intFromFloat(clamped * 7.0);
            return writeText(buffer, feedback_texts[index]);
        },
        .wheel_range => {
            const semitones: i32 = @intFromFloat(clamped * 12.0);
            _ = std.fmt.bufPrintZ(buffer, "{d}", .{semitones}) catch return false;
            return true;
        },
        .fine_tune => {
            _ = std.fmt.bufPrintZ(buffer, "{d:.2}", .{(clamped - 0.5) * 100.0}) catch return false;
            return true;
        },
        else => return writeText(buffer, if (clamped < 0.5) "off" else "on"),
    }
}

pub fn patchValueToText(param: PatchParam, value: f32, buffer: []u8) bool {
    if (buffer.len == 0) return false;
    return parameterText(patchParamToSynthParam(param), value, buffer);
}

pub fn render(engine: *Engine) f32 {
    return engine.render();
}

pub fn hasActiveNotes(engine: *const Engine) bool {
    return engine.hasActiveNotes();
}

pub fn zportafm_engine_create(sample_rate: c_uint) ?*Engine {
    return Engine.create(sample_rate);
}

pub fn zportafm_engine_destroy(engine: *Engine) void {
    engine.destroy();
}

pub fn zportafm_engine_set_sample_rate(engine: *Engine, sample_rate: c_uint) void {
    engine.setSampleRate(sample_rate);
}

pub fn zportafm_engine_reset(engine: *Engine) void {
    engine.reset();
}

pub fn zportafm_engine_note_on(engine: *Engine, note: c_int, velocity: f32) void {
    engine.keyOn(note, velocity);
}

pub fn zportafm_engine_note_off(engine: *Engine, note: c_int) void {
    engine.keyOff(note);
}

pub fn zportafm_engine_all_notes_off(engine: *Engine) void {
    engine.allNotesOff();
}

pub fn zportafm_engine_set_pitch_bend(engine: *Engine, value: f32) void {
    engine.setPitchWheel(value);
}

pub fn zportafm_engine_set_preset_mode(engine: *Engine, enabled: bool) void {
    engine.setPresetMode(enabled);
}

pub fn zportafm_engine_set_program(engine: *Engine, program: c_int) void {
    engine.setProgram(program);
}

pub fn zportafm_engine_set_wheel_range(engine: *Engine, semitones: f32) void {
    engine.setWheelRange(semitones);
}

pub fn zportafm_engine_set_fine_tune(engine: *Engine, cents: f32) void {
    engine.setFineTune(cents);
}

pub fn zportafm_engine_set_patch_param(engine: *Engine, param_id: c_int, value: f32) void {
    const patch_param: PatchParam = @enumFromInt(@as(u8, @intCast(param_id)));
    engine.setPatchParam(patch_param, value);
}

pub fn zportafm_engine_render(engine: *Engine) f32 {
    return engine.render();
}

pub fn zportafm_engine_has_active_notes(engine: *const Engine) bool {
    return engine.hasActiveNotes();
}

pub fn zportafm_patch_value_to_text(param_id: c_int, value: f32, buffer: [*]u8, capacity: usize) bool {
    if (capacity == 0) return false;
    const patch_param: PatchParam = @enumFromInt(@as(u8, @intCast(param_id)));
    return patchValueToText(patch_param, value, buffer[0..capacity]);
}
