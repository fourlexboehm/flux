//! Mixer presentation mapping. Audio/document values remain linear gain.
const std = @import("std");
pub const floor_db: f32 = -60;
pub const ceiling_db: f32 = 20 * @log10(@as(f32, 1.5));

pub fn toDb(gain: f32) f32 {
    return if (gain <= 0.001) floor_db else @min(ceiling_db, 20 * @log10(gain));
}
pub fn fromDb(db: f32) f32 {
    return if (db <= floor_db) 0 else @min(1.5, std.math.pow(f32, 10, db / 20));
}
pub fn fraction(gain: f32) f32 {
    return @max(0, @min(1, (toDb(gain) - floor_db) / (ceiling_db - floor_db)));
}
pub fn fromFraction(value: f32) f32 {
    return fromDb(floor_db + @max(0, @min(1, value)) * (ceiling_db - floor_db));
}

test "fader endpoints, unity and gain round trips" {
    try std.testing.expectEqual(@as(f32, 0), fromFraction(0));
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), fromFraction(1), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), toDb(1), 0.00001);
    for ([_]f32{ 0.01, 0.1, 0.5, 0.8, 1, 1.5 }) |value| {
        try std.testing.expectApproxEqAbs(value, fromFraction(fraction(value)), 0.00001);
    }
}
