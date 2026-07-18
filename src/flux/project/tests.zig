//! Project unit tests entry (format codec + media helpers).
//! Root must be this file so format/tests can import ../media.
test {
    _ = @import("format/tests.zig");
}
