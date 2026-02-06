const Voices = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const ADSR = @import("adsr.zig");
const polyblep = @import("polyblep.zig");

pub const Expression = clap.events.NoteExpression.Id;
pub const ExpressionValues = std.EnumArray(Expression, f64);
const expression_values_default: std.enums.EnumFieldStruct(Expression, f64, null) = .{
    .volume = 1,
    .pan = 0.5,
    .tuning = 0,
    .vibrato = 0,
    .expression = 0,
    .brightness = 0,
    .pressure = 0,
};

// Work payload for multi-threaded jobs
const VoiceRenderPayload = struct {
    start: u32,
    end: u32,
    output_left: [*]f32,
    output_right: [*]f32,
};

voices: std.ArrayList(Voice),
allocator: std.mem.Allocator,
render_payload: ?VoiceRenderPayload = null,
render_mutex: std.Io.Mutex = .init,

pub fn init(allocator: std.mem.Allocator) Voices {
    return .{
        .voices = .empty,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Voices) void {
    self.voices.deinit(self.allocator);
}

pub const Voice = struct {
    noteId: clap.events.NoteId = .unspecified,
    channel: clap.events.Channel = .unspecified,
    key: clap.events.Key = .unspecified,
    velocity: f64 = 0,
    expression_values: ExpressionValues = ExpressionValues.init(expression_values_default),
    adsr: ADSR = ADSR.init(0, 0, 1, 0),
    osc1: polyblep.PolyBLEP = polyblep.PolyBLEP.init(1.0, .Sine, 0.0, 0.0),
    osc2: polyblep.PolyBLEP = polyblep.PolyBLEP.init(1.0, .Sine, 0.0, 0.0),

    pub fn getTunedKey(self: *const Voice, oscillator_detune: f64, oscillator_octave: f64) f64 {
        const base_key: f64 = @floatFromInt(@intFromEnum(self.key));
        // The octave is from -2 to 3, where -2 is 32' and 3 is 1'
        // the base value of 440Hz is at 8', or an integer value of 0
        const octave_offset = oscillator_octave * 12;
        return base_key + self.expression_values.get(.tuning) + oscillator_detune + octave_offset;
    }

    pub fn init(sample_rate: f64) Voice {
        return .{
            .osc1 = polyblep.PolyBLEP.init(sample_rate, .Sine, 0.0, 0.0),
            .osc2 = polyblep.PolyBLEP.init(sample_rate, .Sine, 0.0, 0.0),
        };
    }
};

pub fn getVoice(self: *Voices, index: usize) ?*Voice {
    if (index > self.getVoiceCount()) return null;

    return &self.voices.items[index];
}

pub fn getVoiceByKey(voices: []Voice, key: clap.events.Key) ?*Voice {
    for (voices) |*voice| {
        if (voice.key == key) {
            return voice;
        }
    }

    return null;
}

pub fn getVoiceCount(self: *const Voices) usize {
    return self.voices.items.len;
}

pub fn getVoiceCapacity(self: *const Voices) usize {
    return self.voices.capacity;
}

pub fn addVoice(self: *Voices, voice: Voice) !void {
    try self.voices.append(self.allocator, voice);
}

pub fn getVoices(self: *Voices) []Voice {
    return self.voices.items;
}
