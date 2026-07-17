const std = @import("std");
const parse = @import("parse.zig");
const xml_writer = @import("xml_writer.zig");
const types = @import("types.zig");

const XmlWriter = xml_writer.XmlWriter;
const toXml = xml_writer.toXml;
const Project = types.Project;

test "xml escaping" {
    const allocator = std.testing.allocator;
    var writer = XmlWriter.init(allocator);
    defer writer.deinit();

    try writer.writeEscaped("Hello <World> & \"Test\"");
    const result = try writer.toOwnedSlice();
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello &lt;World&gt; &amp; &quot;Test&quot;", result);
}

test "basic project xml" {
    const allocator = std.testing.allocator;

    const proj = Project{
        .application = .{ .name = "Test", .version = "1.0" },
        .transport = .{
            .tempo = .{
                .id = "id0",
                .name = "Tempo",
                .value = 120.0,
                .unit = .bpm,
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<?xml version=\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Project version=\"1.0\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "Tempo") != null);
}

test "CLAP identity and embedded state path round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1.0" },
        .tracks = &.{
            .{
                .id = "track0",
                .name = "Track 1",
                .channel = .{
                    .id = "channel0",
                    .devices = &.{
                        .{
                            .id = "device0",
                            .name = "Portable Synth",
                            .device_id = "org.example.portable-synth",
                            .device_name = "Portable Synth",
                            .device_role = .instrument,
                            .state = .{ .path = "plugins/track0.clap-preset" },
                        },
                    },
                },
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    const parsed = try parse.parseProjectXml(allocator, xml);

    const device = parsed.tracks[0].channel.?.devices[0];
    try std.testing.expectEqualStrings("org.example.portable-synth", device.device_id);
    try std.testing.expectEqualStrings("plugins/track0.clap-preset", device.state.?.path);
    try std.testing.expect(!device.state.?.external);
}
