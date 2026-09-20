const std = @import("std");
const clap = @import("clap-bindings");
const Graph = @import("audio_graph.zig").Graph;
const SharedState = @import("audio_engine.zig").SharedState;
const master_track = @import("../session/types.zig").master_track_index;

const TestFx = struct {
    plugin: clap.Plugin = undefined,
    calls: usize = 0,
    value: f32 = 0,
    sleep: bool = true,

    fn wire(self: *TestFx) void {
        self.plugin.plugin_data = self;
        self.plugin.process = process;
        self.plugin.startProcessing = start;
    }

    fn start(_: *const clap.Plugin) callconv(.c) bool {
        return true;
    }

    fn process(plugin: *const clap.Plugin, ctx: *const clap.Process) callconv(.c) clap.Process.Status {
        const self: *TestFx = @ptrCast(@alignCast(plugin.plugin_data));
        self.calls += 1;
        for (0..2) |channel| @memset(ctx.audio_outputs[0].data32.?[channel][0..ctx.frames_count], self.value);
        return if (self.sleep) .sleep else .@"continue";
    }
};

test "master FX replacement and restart wake a sleeping slot" {
    var shared = try SharedState.init(std.testing.allocator);
    defer shared.deinit(std.testing.allocator);
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();
    const mixer = try graph.addMixer();
    const fx = try graph.addFx(master_track, 0);
    const master = try graph.addMaster();
    try graph.connect(mixer, 0, fx, 0, .audio);
    try graph.connect(fx, 0, master, 0, .audio);
    try graph.prepare(48000, 16);
    const snapshot = &shared.snapshots[0];
    snapshot.tracks[master_track].volume = 1;

    var old = TestFx{};
    old.wire();
    snapshot.track_fx_plugins[master_track][0] = &old.plugin;
    graph.process(snapshot, &shared, null, 16, 0);
    graph.process(snapshot, &shared, null, 16, 16);
    try std.testing.expectEqual(@as(usize, 1), old.calls);

    // Replace between quanta: no intervening null-slot render or wake request.
    var replacement = TestFx{ .value = 0.25, .sleep = false };
    replacement.wire();
    snapshot.track_fx_plugins[master_track][0] = &replacement.plugin;
    graph.process(snapshot, &shared, null, 16, 32);
    try std.testing.expectEqual(@as(usize, 1), replacement.calls);
    try std.testing.expectEqual(@as(f32, 0.25), graph.getMasterOutput().?.left[0]);

    replacement.value = 0;
    replacement.sleep = true;
    graph.process(snapshot, &shared, null, 16, 48);
    graph.process(snapshot, &shared, null, 16, 64);
    try std.testing.expectEqual(@as(usize, 2), replacement.calls);
    // Restart the same address (also covers allocator address reuse).
    shared.requestStartProcessingFx(master_track, 0);
    replacement.value = 0.5;
    replacement.sleep = false;
    graph.process(snapshot, &shared, null, 16, 80);
    try std.testing.expectEqual(@as(usize, 3), replacement.calls);
    try std.testing.expectEqual(@as(f32, 0.5), graph.getMasterOutput().?.left[0]);
}
