//! Test entry — package root is src/flux so tests/ can import siblings.
test {
    _ = @import("tests/audio_clip_playback_test.zig");
}
