const Voices = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const dsp = @import("../dsp/dsp.zig");

/// Re-export OversampleFactor for use by params
pub const OversampleFactor = dsp.OversampleFactor;

pub const Voice = struct {
    synth: dsp.Minimoog(f32),
    oversampler: dsp.GlobalOversampler(f32, 4),
    oversample_factor: OversampleFactor = .x4, // Default 4x for best quality
    output_sample_rate: f32,
    noteId: clap.events.NoteId = .unspecified,
    channel: clap.events.Channel = .unspecified,
    key: clap.events.Key = .unspecified,

    pub fn init(sample_rate: f32) Voice {
        return initWithOversample(sample_rate, .x4);
    }

    pub fn initWithOversample(sample_rate: f32, factor: OversampleFactor) Voice {
        const internal_rate = sample_rate * factor.toFloat(f32);
        var voice = Voice{
            .synth = dsp.Minimoog(f32).init(internal_rate),
            .oversampler = dsp.GlobalOversampler(f32, 4).init(),
            .oversample_factor = factor,
            .output_sample_rate = sample_rate,
        };
        // Set anti-aliasing mode based on oversample factor:
        // - 1x: Use PolyBLEP/PolyBLAMP (digital anti-aliasing)
        // - 2x/4x: Raw WDF output (oversampling handles aliasing)
        voice.synth.setDigitalAntialiasing(factor == .x1);
        return voice;
    }

    pub fn isFinished(self: *Voice) bool {
        return self.synth.isFinished();
    }

    /// Set the oversample factor (requires prepare to take effect)
    pub fn setOversampleFactor(self: *Voice, factor: OversampleFactor) void {
        if (self.oversample_factor != factor) {
            self.oversample_factor = factor;
            // Reinitialize synth at new internal rate
            const internal_rate = self.output_sample_rate * factor.toFloat(f32);
            self.synth.prepare(internal_rate);
            self.oversampler.reset();
            // Set anti-aliasing mode based on oversample factor:
            // - 1x: Use PolyBLEP/PolyBLAMP (digital anti-aliasing)
            // - 2x/4x: Raw WDF output (oversampling handles aliasing)
            self.synth.setDigitalAntialiasing(factor == .x1);
        }
    }

    /// Prepare for playback at given sample rate
    pub fn prepare(self: *Voice, sample_rate: f32) void {
        self.output_sample_rate = sample_rate;
        const internal_rate = sample_rate * self.oversample_factor.toFloat(f32);
        self.synth.prepare(internal_rate);
        self.oversampler.reset();
    }

    /// Process one output sample with oversampling
    pub inline fn processSample(self: *Voice) f32 {
        return switch (self.oversample_factor) {
            .x1 => self.synth.processSample(),
            .x2 => blk: {
                var samples: [2]f32 = undefined;
                samples[0] = self.synth.processSample();
                samples[1] = self.synth.processSample();
                break :blk self.oversampler.decimate2x(samples);
            },
            .x4 => blk: {
                var samples: [4]f32 = undefined;
                samples[0] = self.synth.processSample();
                samples[1] = self.synth.processSample();
                samples[2] = self.synth.processSample();
                samples[3] = self.synth.processSample();
                break :blk self.oversampler.decimate4x(samples);
            },
        };
    }
};

pub const RenderPayload = struct {
    start: u32,
    end: u32,
    output_left: [*]f32,
    output_right: [*]f32,
};

voices: std.ArrayList(Voice),
allocator: std.mem.Allocator,
render_payload: ?RenderPayload = null,
render_mutex: std.Thread.Mutex = .{},
current_oversample_factor: OversampleFactor = .x4,

pub fn init(allocator: std.mem.Allocator) Voices {
    return .{
        .voices = .empty,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Voices) void {
    self.voices.deinit(self.allocator);
}

pub fn getVoiceCount(self: *const Voices) usize {
    return self.voices.items.len;
}

pub fn getVoiceByKey(voices: []Voice, key: clap.events.Key) ?*Voice {
    for (voices) |*voice| {
        if (voice.key == key) {
            return voice;
        }
    }
    return null;
}

pub fn addVoice(self: *Voices, voice: Voice) !void {
    try self.voices.append(self.allocator, voice);
}

/// Set oversample factor for all voices
pub fn setOversampleFactor(self: *Voices, factor: OversampleFactor) void {
    self.current_oversample_factor = factor;
    for (self.voices.items) |*voice| {
        voice.setOversampleFactor(factor);
    }
}

/// Create a new voice with the current oversample factor
pub fn createVoice(self: *Voices, sample_rate: f32) Voice {
    return Voice.initWithOversample(sample_rate, self.current_oversample_factor);
}
