//! Host test root. Zig only discovers tests in explicitly imported modules.

test {
    _ = @import("arrangement/undo.zig");
    _ = @import("audio/audio_clip_source.zig");
    _ = @import("audio/audio_graph_test.zig");
    _ = @import("ui/panels/browser_files.zig");
    _ = @import("audio/audio_mix.zig");
    _ = @import("audio/clip_bake.zig");
    _ = @import("audio/latency_compensation.zig");
    _ = @import("builtins/dsp/equalizer.zig");
    _ = @import("project/io.zig");
    // DVUI host chrome state (pure; no zgui/dvui imports)
    _ = @import("ui/state.zig");
    _ = @import("ui/gain.zig");
    // Document host (session + arrangement + clip pool projection)
    _ = @import("ui/host.zig");
    _ = @import("document/model.zig");
    _ = @import("document/midi_history.zig");
    _ = @import("document/commands.zig");
    _ = @import("document/cmd_undo.zig");
    // UI-neutral DAWproject save/load adapter for the document host.
    _ = @import("document/project_view.zig");
    _ = @import("ui/piano_roll_math.zig");
    // Transport audio runtime (publish/metronome unit tests; no device required)
    _ = @import("ui/audio_runtime.zig");
    // DynLib CLAP handle primitives (no device)
    _ = @import("plugin/handle.zig");
    // Static stock FX load path (no DynLib)
    _ = @import("plugin/builtin_load.zig");
    // DVUI plugin host (catalog optional; no device)
    _ = @import("ui/plugin_host.zig");
}
