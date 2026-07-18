//! Zig bindings for the Signalsmith Stretch C ABI (offline bake only — never on audio thread).

const std = @import("std");

pub const Handle = opaque {};

pub extern fn signalsmith_stretch_create(channel_count: c_int, block_length: usize, interval: usize) ?*Handle;
pub extern fn signalsmith_stretch_create_preset_default(channel_count: c_int, sample_rate: f32) ?*Handle;
pub extern fn signalsmith_stretch_create_preset_cheaper(channel_count: c_int, sample_rate: f32) ?*Handle;
pub extern fn signalsmith_stretch_destroy(handle: ?*Handle) void;
pub extern fn signalsmith_stretch_reset(handle: ?*Handle) void;
pub extern fn signalsmith_stretch_input_latency(handle: ?*Handle) usize;
pub extern fn signalsmith_stretch_output_latency(handle: ?*Handle) usize;
pub extern fn signalsmith_stretch_seek(handle: ?*Handle, input: [*]f32, input_length: usize, playback_rate: f64) void;
pub extern fn signalsmith_stretch_set_transpose_factor(handle: ?*Handle, multiplier: f32, tonality_limit: f32) void;
pub extern fn signalsmith_stretch_set_transpose_factor_semitones(handle: ?*Handle, semitones: f32, tonality_limit: f32) void;
pub extern fn signalsmith_stretch_process(
    handle: ?*Handle,
    input: [*]f32,
    input_length: usize,
    output: [*]f32,
    output_length: usize,
) void;
pub extern fn signalsmith_stretch_exact(
    handle: ?*Handle,
    input: [*]f32,
    input_length: usize,
    output: [*]f32,
    output_length: usize,
) bool;
pub extern fn signalsmith_stretch_flush(handle: ?*Handle, output: [*]f32, output_length: usize) void;

/// Pitch-preserving time stretch of interleaved f32 PCM (offline).
/// `channels` is 1 or 2. Input/output are interleaved. Rates are for stretcher config only;
/// caller chooses frame counts to achieve the desired ratio.
pub fn stretchExact(
    allocator: std.mem.Allocator,
    channels: u8,
    sample_rate: f32,
    input_interleaved: []const f32,
    output_interleaved: []f32,
) !void {
    if (channels == 0 or channels > 2) return error.InvalidChannels;
    if (sample_rate <= 0) return error.InvalidSampleRate;

    const in_frames = input_interleaved.len / channels;
    const out_frames = output_interleaved.len / channels;
    if (in_frames == 0 or out_frames == 0) return error.EmptyBuffer;
    if (input_interleaved.len % channels != 0) return error.BadInputLayout;
    if (output_interleaved.len % channels != 0) return error.BadOutputLayout;

    const handle = signalsmith_stretch_create_preset_default(@intCast(channels), sample_rate) orelse
        return error.StretchCreateFailed;
    defer signalsmith_stretch_destroy(handle);

    // No pitch shift — pure time stretch.
    signalsmith_stretch_set_transpose_factor(handle, 1.0, 0.0);

    // exact() needs mutable input buffer for internal seeking offsets.
    const in_buf = try allocator.alloc(f32, input_interleaved.len);
    defer allocator.free(in_buf);
    @memcpy(in_buf, input_interleaved);

    const ok = signalsmith_stretch_exact(
        handle,
        in_buf.ptr,
        in_frames,
        output_interleaved.ptr,
        out_frames,
    );
    if (!ok) return error.StretchExactFailed;
}
