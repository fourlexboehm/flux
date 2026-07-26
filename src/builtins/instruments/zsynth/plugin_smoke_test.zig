const std = @import("std");
const clap = @import("clap-bindings");
const Plugin = @import("plugin.zig");

const MockHost = struct {
    clap_host: clap.Host,

    fn init() MockHost {
        const host = MockHost{
            .clap_host = .{
                .clap_version = clap.version,
                .host_data = undefined,
                .name = "ZSynth Smoke Test",
                .vendor = "flux",
                .url = null,
                .version = "0.1",
                .getExtension = getExtension,
                .requestRestart = requestRestart,
                .requestProcess = requestProcess,
                .requestCallback = requestCallback,
            },
        };
        return host;
    }

    fn clapHost(self: *MockHost) *const clap.Host {
        self.clap_host.host_data = self;
        return &self.clap_host;
    }

    fn getExtension(_: *const clap.Host, _: [*:0]const u8) callconv(.c) ?*const anyopaque {
        return null;
    }

    fn requestRestart(_: *const clap.Host) callconv(.c) void {}
    fn requestProcess(_: *const clap.Host) callconv(.c) void {}
    fn requestCallback(_: *const clap.Host) callconv(.c) void {}
};

const TestInputEvents = struct {
    events: []const clap.events.Note,

    fn size(list: *const clap.events.InputEvents) callconv(.c) u32 {
        const self: *const TestInputEvents = @ptrCast(@alignCast(list.context));
        return @intCast(self.events.len);
    }

    fn get(list: *const clap.events.InputEvents, index: u32) callconv(.c) *const clap.events.Header {
        const self: *const TestInputEvents = @ptrCast(@alignCast(list.context));
        return &self.events[index].header;
    }
};

const TestOutputEvents = struct {
    fn tryPush(_: *const clap.events.OutputEvents, _: *const clap.events.Header) callconv(.c) bool {
        return true;
    }
};

fn processBlock(
    plugin: *Plugin,
    input: *TestInputEvents,
    left: []f32,
    right: []f32,
) clap.Process.Status {
    var input_events = clap.events.InputEvents{
        .context = input,
        .size = TestInputEvents.size,
        .get = TestInputEvents.get,
    };
    var output_events = clap.events.OutputEvents{
        .context = undefined,
        .tryPush = TestOutputEvents.tryPush,
    };
    var channel_ptrs = [2][*]f32{ left.ptr, right.ptr };
    var audio_out = clap.AudioBuffer{
        .data32 = &channel_ptrs,
        .data64 = null,
        .channel_count = 2,
        .latency = 0,
        .constant_mask = 0,
    };
    const empty_input = clap.AudioBuffer{
        .data32 = null,
        .data64 = null,
        .channel_count = 0,
        .latency = 0,
        .constant_mask = 0,
    };
    var transport = clap.events.Transport{
        .header = .{
            .size = @sizeOf(clap.events.Transport),
            .sample_offset = 0,
            .space_id = clap.events.core_space_id,
            .type = .transport,
            .flags = .{},
        },
        .flags = .{
            .has_tempo = true,
            .has_beats_timeline = true,
            .has_seconds_timeline = true,
            .has_time_signature = true,
            .is_playing = false,
            .is_recording = false,
            .is_loop_active = false,
            .is_within_pre_roll = false,
        },
        .song_pos_beats = clap.BeatTime.fromBeats(0),
        .song_pos_seconds = clap.SecTime.fromSecs(0),
        .tempo = 120,
        .tempo_increment = 0,
        .loop_start_beats = clap.BeatTime.fromBeats(0),
        .loop_end_beats = clap.BeatTime.fromBeats(0),
        .loop_start_seconds = clap.SecTime.fromSecs(0),
        .loop_end_seconds = clap.SecTime.fromSecs(0),
        .bar_start = clap.BeatTime.fromBeats(0),
        .bar_number = 1,
        .time_signature_numerator = 4,
        .time_signature_denominator = 4,
    };
    var process = clap.Process{
        .steady_time = @enumFromInt(0),
        .frames_count = @intCast(left.len),
        .transport = &transport,
        .audio_inputs = @as([*]const clap.AudioBuffer, @ptrCast(&empty_input)),
        .audio_outputs = @as([*]clap.AudioBuffer, @ptrCast(&audio_out)),
        .audio_inputs_count = 0,
        .audio_outputs_count = 1,
        .in_events = &input_events,
        .out_events = &output_events,
    };
    return plugin.plugin.process(&plugin.plugin, &process);
}

test "zsynth produces audio after note on" {
    const allocator = std.testing.allocator;
    var host = MockHost.init();
    const plugin = try Plugin.init(allocator, host.clapHost());
    defer plugin.deinit();

    try std.testing.expect(plugin.plugin.init(&plugin.plugin));
    try std.testing.expect(plugin.plugin.activate(&plugin.plugin, 44100.0, 1, 128));
    defer plugin.plugin.deactivate(&plugin.plugin);
    try std.testing.expect(plugin.plugin.startProcessing(&plugin.plugin));
    defer plugin.plugin.stopProcessing(&plugin.plugin);

    var note_on = clap.events.Note{
        .header = .{
            .size = @sizeOf(clap.events.Note),
            .sample_offset = 0,
            .space_id = clap.events.core_space_id,
            .type = .note_on,
            .flags = .{},
        },
        .note_id = .unspecified,
        .port_index = @enumFromInt(0),
        .channel = @enumFromInt(0),
        .key = @enumFromInt(60),
        .velocity = 1.0,
    };
    var input = TestInputEvents{ .events = (&note_on)[0..1] };
    var left: [128]f32 = @splat(0);
    var right: [128]f32 = @splat(0);

    const status = processBlock(plugin, &input, &left, &right);
    try std.testing.expect(status == .@"continue" or status == .sleep);

    var peak: f32 = 0;
    for (left, right) |l, r| {
        peak = @max(peak, @abs(l));
        peak = @max(peak, @abs(r));
    }
    try std.testing.expect(peak > 0.00001);
}
