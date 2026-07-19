//! Flux stock FX kinds mapped to DAWproject portable device types.

pub const Kind = enum {
    equalizer,
    compressor,
    noise_gate,
    limiter,

    pub fn id(self: Kind) [:0]const u8 {
        return switch (self) {
            .equalizer => "com.flux.builtin.equalizer",
            .compressor => "com.flux.builtin.compressor",
            .noise_gate => "com.flux.builtin.noise_gate",
            .limiter => "com.flux.builtin.limiter",
        };
    }

    pub fn name(self: Kind) [:0]const u8 {
        return switch (self) {
            .equalizer => "Equalizer",
            .compressor => "Compressor",
            .noise_gate => "Noise Gate",
            .limiter => "Limiter",
        };
    }

    /// DAWproject XML element name.
    pub fn xmlTag(self: Kind) []const u8 {
        return switch (self) {
            .equalizer => "Equalizer",
            .compressor => "Compressor",
            .noise_gate => "NoiseGate",
            .limiter => "Limiter",
        };
    }

    pub fn fromId(plugin_id: []const u8) ?Kind {
        if (std.mem.eql(u8, plugin_id, Kind.equalizer.id())) return .equalizer;
        if (std.mem.eql(u8, plugin_id, Kind.compressor.id())) return .compressor;
        if (std.mem.eql(u8, plugin_id, Kind.noise_gate.id())) return .noise_gate;
        if (std.mem.eql(u8, plugin_id, Kind.limiter.id())) return .limiter;
        return null;
    }

    pub fn fromXmlTag(tag: []const u8) ?Kind {
        if (std.mem.eql(u8, tag, "Equalizer")) return .equalizer;
        if (std.mem.eql(u8, tag, "Compressor")) return .compressor;
        if (std.mem.eql(u8, tag, "NoiseGate")) return .noise_gate;
        if (std.mem.eql(u8, tag, "Limiter")) return .limiter;
        return null;
    }

    pub const all = [_]Kind{ .equalizer, .compressor, .noise_gate, .limiter };
};

const std = @import("std");
