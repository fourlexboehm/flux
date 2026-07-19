pub const ppq: i64 = 960;

pub fn tickToPixel(tick: i64, zoom: f32, pixels_per_beat: f32) f32 {
    const beats = @as(f32, @floatFromInt(tick)) / @as(f32, ppq);
    return beats * pixels_per_beat * zoom;
}

pub fn pixelToTick(pixel: f32, zoom: f32, pixels_per_beat: f32) i64 {
    const beats = pixel / (pixels_per_beat * zoom);
    return @intFromFloat(@round(beats * @as(f32, ppq)));
}

pub fn snapToGrid(tick: i64, grid_ticks: i64) i64 {
    if (grid_ticks <= 0) return tick;
    const half = grid_ticks >> 1;
    return @divFloor(tick + half, grid_ticks) * grid_ticks;
}

pub const MusicalTime = struct {
    bars: i32,
    beat: u8,
    ticks: i32,
};

pub fn ticksToMusicalTime(tick: i64, beats_per_bar: u8) MusicalTime {
    const ticks_per_beat: i64 = ppq;
    const ticks_per_bar = @as(i64, @intCast(beats_per_bar)) * ticks_per_beat;
    const bars = @divFloor(tick, ticks_per_bar);
    const remainder = @mod(tick, ticks_per_bar);
    return .{
        .bars = @intCast(bars),
        .beat = @intCast(@divFloor(remainder, ticks_per_beat)),
        .ticks = @intCast(@mod(remainder, ticks_per_beat)),
    };
}

pub fn musicalTimeToTicks(mt: MusicalTime, beats_per_bar: u8) i64 {
    const ticks_per_beat: i64 = ppq;
    const ticks_per_bar = @as(i64, @intCast(beats_per_bar)) * ticks_per_beat;
    return @as(i64, mt.bars) * ticks_per_bar + @as(i64, mt.beat) * ticks_per_beat + @as(i64, mt.ticks);
}

pub fn ticksToSeconds(tick: i64, bpm: f32) f64 {
    const beats = @as(f64, @floatFromInt(tick)) / @as(f64, ppq);
    return (beats / @as(f64, @floatCast(bpm))) * 60.0;
}

pub fn secondsToTicks(seconds: f64, bpm: f32) i64 {
    const beats = seconds / 60.0 * @as(f64, @floatCast(bpm));
    return @intFromFloat(beats * @as(f64, ppq));
}

pub fn gridTickForDivision(division: u8, beats_per_bar: u8) i64 {
    const ticks_per_quarter = ppq;
    const ticks_per_bar = @as(i64, @intCast(beats_per_bar)) * ticks_per_quarter;
    return ticks_per_bar / division;
}
