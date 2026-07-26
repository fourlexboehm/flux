//! Host test root. Zig only discovers tests in explicitly imported modules.

test {
    _ = @import("arrangement/undo.zig");
    _ = @import("audio/audio_clip_source.zig");
    _ = @import("audio/audio_mix.zig");
    _ = @import("audio/clip_bake.zig");
    _ = @import("audio/latency_compensation.zig");
    _ = @import("builtins/dsp/equalizer.zig");
    _ = @import("project/io.zig");
}
