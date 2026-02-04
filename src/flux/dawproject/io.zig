const std = @import("std");
const ui_state = @import("../ui/state.zig");
const plugins = @import("../plugins.zig");
const undo = @import("../undo/root.zig");
const types = @import("types.zig");
const convert = @import("convert.zig");
const xml_writer = @import("xml_writer.zig");
const zip_writer = @import("zip_writer.zig");
const parse = @import("parse.zig");
const io_types = @import("io_types.zig");

const Project = types.Project;
const TrackPluginInfo = io_types.TrackPluginInfo;
const PluginStateFile = io_types.PluginStateFile;
const PluginParamInfo = io_types.PluginParamInfo;
const ZipWriter = zip_writer.ZipWriter;
const fromFluxProject = convert.fromFluxProject;
const toXml = xml_writer.toXml;

pub const LoadedProject = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    project: Project,
    plugin_states: std.StringHashMap([]const u8),

    pub fn deinit(self: *LoadedProject) void {
        self.plugin_states.deinit();
        self.arena.deinit();
    }
};

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: *const ui_state.State,
    catalog: *const plugins.PluginCatalog,
    plugin_states: []const PluginStateFile,
    track_plugin_info: []const TrackPluginInfo,
    track_fx_plugin_info: []const [ui_state.max_fx_slots]TrackPluginInfo,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const daw_project = try fromFluxProject(arena.allocator(), state, catalog, track_plugin_info, track_fx_plugin_info);
    const xml = try toXml(arena.allocator(), &daw_project);

    // Debug: also write raw XML for inspection
    if (std.Io.Dir.cwd().createFile(io, "debug_project.xml", .{ .truncate = true })) |*debug_file| {
        defer debug_file.close(io);
        var dbuf: [8192]u8 = undefined;
        var dw = debug_file.writer(io, &dbuf);
        dw.interface.writeAll(xml) catch {};
        dw.interface.flush() catch {};
    } else |_| {}

    // Build ZIP in memory
    var zip = ZipWriter.init(arena.allocator());
    defer zip.deinit();

    // Add project.xml
    try zip.addFile("project.xml", xml);

    // Bitwig expects metadata.xml to exist; include an empty template.
    const metadata_xml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
        "<MetaData>\n" ++
        "    <Title></Title>\n" ++
        "    <Artist></Artist>\n" ++
        "    <Album></Album>\n" ++
        "    <OriginalArtist></OriginalArtist>\n" ++
        "    <Songwriter></Songwriter>\n" ++
        "    <Producer></Producer>\n" ++
        "    <Year></Year>\n" ++
        "    <Genre></Genre>\n" ++
        "    <Copyright></Copyright>\n" ++
        "    <Comment></Comment>\n" ++
        "</MetaData>\n";
    try zip.addFile("metadata.xml", metadata_xml);

    const undo_xml = undo.serializeToXml(arena.allocator(), &state.undo_history) catch |err| blk: {
        std.log.warn("Failed to serialize undo history: {}", .{err});
        break :blk null;
    };
    if (undo_xml) |data| {
        try zip.addFile("flux_undo.xml", data);
    }

    // Add plugin state files
    for (plugin_states) |ps| {
        try zip.addFile(ps.path, ps.data);
    }

    const zip_data = try zip.finish();

    // Write to file
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var fw = file.writer(io, &write_buf);
    try fw.interface.writeAll(zip_data);
    try fw.interface.flush();
}

/// Load project from a .dawproject file (ZIP archive)
/// Returns the parsed Project structure
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !LoadedProject {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    return loadFromFile(allocator, io, file);
}

fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !LoadedProject {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // Create a File.Reader for the ZIP
    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);

    // Create temp directory for extraction
    var tmp_dir = try std.Io.Dir.cwd().createDirPathOpen(io, ".dawproject_tmp", .{});
    defer {
        tmp_dir.close(io);
        // Clean up temp directory
        std.Io.Dir.cwd().deleteTree(io, ".dawproject_tmp") catch {};
    }

    // Extract ZIP contents
    std.zip.extract(tmp_dir, &file_reader, .{
        .allow_backslashes = true,
    }) catch |err| {
        std.log.err("ZIP extract failed: {}", .{err});
        return error.ZipExtractFailed;
    };

    // Read project.xml
    var project_xml_file = tmp_dir.openFile(io, "project.xml", .{}) catch {
        return error.MissingProjectXml;
    };
    defer project_xml_file.close(io);

    const xml_stat = try project_xml_file.stat(io);
    const project_xml = try arena.allocator().alloc(u8, xml_stat.size);
    const xml_bytes = try project_xml_file.readPositionalAll(io, project_xml, 0);
    if (xml_bytes != xml_stat.size) return error.UnexpectedEof;

    // Read plugin state files from plugins/ directory
    var plugin_states = std.StringHashMap([]const u8).init(arena.allocator());

    if (tmp_dir.openDir(io, "plugins", .{})) |*plugins_dir| {
        defer plugins_dir.close(io);

        var dir_iter = plugins_dir.iterate();
        while (try dir_iter.next(io)) |entry| {
            if (entry.kind == .file) {
                const full_path = try std.fmt.allocPrint(arena.allocator(), "plugins/{s}", .{entry.name});

                var plugin_file = try plugins_dir.openFile(io, entry.name, .{});
                defer plugin_file.close(io);

                const plugin_stat = try plugin_file.stat(io);
                const plugin_data = try arena.allocator().alloc(u8, plugin_stat.size);
                const bytes = try plugin_file.readPositionalAll(io, plugin_data, 0);
                if (bytes != plugin_stat.size) return error.UnexpectedEof;

                try plugin_states.put(full_path, plugin_data);
            }
        }
    } else |_| {
        // No plugins directory, that's OK
    }

    // Parse the XML
    const parsed_project = try parse.parseProjectXml(arena.allocator(), project_xml);

    return .{
        .allocator = allocator,
        .arena = arena,
        .project = parsed_project,
        .plugin_states = plugin_states,
    };
}
