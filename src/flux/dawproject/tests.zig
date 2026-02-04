const std = @import("std");
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
