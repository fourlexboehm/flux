const Voices = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const dsp = @import("../dsp/dsp.zig");

pub const Voice = struct {
    engine: dsp.SynthEngine,
    noteId: clap.events.NoteId = .unspecified,
    channel: clap.events.Channel = .unspecified,
    key: clap.events.Key = .unspecified,

    pub fn init(sample_rate: f32) Voice {
        var voice = Voice{
            .engine = dsp.SynthEngine.init(),
        };
        voice.engine.setSampleRate(sample_rate);
        return voice;
    }

    pub fn isFinished(self: *const Voice) bool {
        // Check if any voice in the engine is still sounding
        for (self.engine.voices[0..self.engine.total_voice_count]) |*v| {
            if (v.isSounding()) return false;
        }
        return true;
    }
};

// For the OB-X, we use a single Voice (which contains the full polyphonic SynthEngine)
// rather than individual voices like zminimoog.
// This is because the OB-X engine manages its own voice allocation internally.

pub const RenderPayload = struct {
    start: u32,
    end: u32,
    output_left: [*]f32,
    output_right: [*]f32,
};

engine: ?*dsp.SynthEngine = null,
allocator: std.mem.Allocator,
render_payload: ?RenderPayload = null,
render_mutex: std.Io.Mutex = .init,

pub fn init(allocator: std.mem.Allocator) Voices {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Voices) void {
    if (self.engine) |engine| {
        self.allocator.destroy(engine);
        self.engine = null;
    }
}

pub fn getVoiceCount(self: *const Voices) usize {
    if (self.engine) |engine| {
        var count: usize = 0;
        for (engine.voices[0..engine.total_voice_count]) |*v| {
            if (v.isSounding()) count += 1;
        }
        return count;
    }
    return 0;
}

pub fn ensureEngine(self: *Voices, sample_rate: f32) !*dsp.SynthEngine {
    if (self.engine) |engine| {
        return engine;
    }
    const engine = try self.allocator.create(dsp.SynthEngine);
    engine.* = dsp.SynthEngine.init();
    engine.setSampleRate(sample_rate);
    self.engine = engine;
    return engine;
}
