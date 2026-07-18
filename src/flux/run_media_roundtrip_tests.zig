//! Test entry — package root is src/flux so tests/ can import siblings.
test {
    _ = @import("tests/media_roundtrip_test.zig");
}
