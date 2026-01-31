const Voices = @This();

const std = @import("std");
const clap = @import("clap-bindings");
const dsp = @import("../dsp/dsp.zig");

pub const Voice = struct {
    synth: dsp.Minimoog(f32),
    noteId: clap.events.NoteId = .unspecified,
    channel: clap.events.Channel = .unspecified,
    key: clap.events.Key = .unspecified,

    pub fn init(sample_rate: f32) Voice {
        return .{ .synth = dsp.Minimoog(f32).init(sample_rate) };
    }

    pub fn isFinished(self: *Voice) bool {
        return self.synth.isFinished();
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
