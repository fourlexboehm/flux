//! Host test root. Zig only discovers tests in explicitly imported modules.

test {
    _ = @import("arrangement/undo.zig");
    _ = @import("audio/audio_clip_source.zig");
    _ = @import("audio/audio_mix.zig");
    _ = @import("audio/clip_bake.zig");
    _ = @import("audio/latency_compensation.zig");
    _ = @import("builtins/dsp/equalizer.zig");
    _ = @import("project/io.zig");
    // DVUI host chrome state (pure; no zgui/dvui imports)
    _ = @import("ui/state.zig");
    // Document host (session + arrangement + clip pool projection)
    _ = @import("ui/host.zig");
    // Transport audio runtime (publish/metronome unit tests; no device required)
    _ = @import("ui/audio_runtime.zig");
    // DynLib CLAP handle primitives (no device)
    _ = @import("plugin/handle.zig");
    // DVUI plugin host (catalog optional; no device)
    _ = @import("ui/plugin_host.zig");
}
