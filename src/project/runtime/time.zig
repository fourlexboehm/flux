const types = @import("../format/types.zig");

pub fn timeToBeats(value: f64, unit: types.TimeUnit, bpm: f32) f64 {
    return switch (unit) {
        .beats => value,
        .seconds => value * @as(f64, bpm) / 60.0,
    };
}

pub fn timeToSeconds(value: f64, unit: types.TimeUnit, bpm: f32) f64 {
    return switch (unit) {
        .seconds => value,
        .beats => value * 60.0 / @as(f64, bpm),
    };
}
