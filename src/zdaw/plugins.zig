const builtin = @import("builtin");
const std = @import("std");

const clap = @import("clap-bindings");

const Dir = std.Io.Dir;
const Io = std.Io;

pub const PluginKind = enum {
    none,
    builtin,
    divider,
    clap,
};

pub const PluginEntry = struct {
    kind: PluginKind,
    name: []const u8,
    path: ?[]const u8 = null,
    id: ?[]const u8 = null,
};

pub const PluginCatalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(PluginEntry) = .{},
    items_z: [:0]const u8 = &[_:0]u8{},
    divider_index: ?i32 = null,

    pub fn deinit(self: *PluginCatalog) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            if (entry.path) |path| {
                self.allocator.free(path);
            }
            if (entry.id) |id| {
                self.allocator.free(id);
            }
        }
        self.entries.deinit(self.allocator);
        if (self.items_z.len > 0) {
            self.allocator.free(self.items_z);
        }
    }

    pub fn entryForIndex(self: *const PluginCatalog, index: i32) ?PluginEntry {
        if (index < 0) return null;
        const idx: usize = @intCast(index);
        if (idx >= self.entries.items.len) return null;
        return self.entries.items[idx];
    }
};

pub fn defaultPluginPath() ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => "zig-out/lib/ZSynth.clap/Contents/MacOS/ZSynth",
        .linux => "zig-out/lib/zsynth.clap",
        else => error.UnsupportedOs,
    };
}

pub fn discover(allocator: std.mem.Allocator, io: Io) !PluginCatalog {
    var catalog = PluginCatalog{ .allocator = allocator };

    try appendStaticEntry(&catalog, .none, "None", null, null);

    const builtin_path = try defaultPluginPath();
    const before_builtin = catalog.entries.items.len;
    discoverPluginEntries(allocator, io, &catalog.entries, builtin_path, .builtin) catch {};
    if (catalog.entries.items.len == before_builtin) {
        try appendStaticEntry(&catalog, .builtin, "ZSynth", builtin_path, null);
    }

    var clap_entries: std.ArrayListUnmanaged(PluginEntry) = .{};
    defer clap_entries.deinit(allocator);
    discoverClapEntries(allocator, io, &clap_entries) catch {};

    if (clap_entries.items.len > 0) {
        try appendStaticEntry(&catalog, .divider, "---- CLAP ----", null, null);
        catalog.divider_index = @intCast(catalog.entries.items.len - 1);
        try catalog.entries.appendSlice(allocator, clap_entries.items);
    }

    try rebuildItemsZ(&catalog);
    return catalog;
}

fn appendStaticEntry(
    catalog: *PluginCatalog,
    kind: PluginKind,
    name: []const u8,
    path: ?[]const u8,
    id: ?[]const u8,
) !void {
    const name_copy = try catalog.allocator.dupe(u8, name);
    const path_copy = if (path) |p| try catalog.allocator.dupe(u8, p) else null;
    const id_copy = if (id) |i| try catalog.allocator.dupe(u8, i) else null;
    try catalog.entries.append(catalog.allocator, .{
        .kind = kind,
        .name = name_copy,
        .path = path_copy,
        .id = id_copy,
    });
}

fn rebuildItemsZ(catalog: *PluginCatalog) !void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(catalog.allocator);

    for (catalog.entries.items) |entry| {
        try buffer.appendSlice(catalog.allocator, entry.name);
        try buffer.append(catalog.allocator, 0);
    }
    try buffer.append(catalog.allocator, 0);

    const items = try catalog.allocator.dupeZ(u8, buffer.items);
    catalog.items_z = items;
}

fn discoverClapEntries(allocator: std.mem.Allocator, io: Io, entries: *std.ArrayListUnmanaged(PluginEntry)) !void {
    if (builtin.os.tag != .macos) return;

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| {
            if (!std.mem.eql(u8, path, "/Library/Audio/Plug-Ins/CLAP") and
                !std.mem.eql(u8, path, "/System/Library/Audio/Plug-Ins/CLAP"))
            {
                allocator.free(path);
            }
        }
        paths.deinit(allocator);
    }

    try paths.append(allocator, "/Library/Audio/Plug-Ins/CLAP");
    try paths.append(allocator, "/System/Library/Audio/Plug-Ins/CLAP");

    if (std.c.getenv("HOME")) |home_c| {
        const home = std.mem.span(home_c);
        const user_path = try Dir.path.join(allocator, &[_][]const u8{
            home,
            "Library/Audio/Plug-Ins/CLAP",
        });
        try paths.append(allocator, user_path);
    }

    for (paths.items) |dir_path| {
        var dir = Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory and entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".clap")) continue;
            if (std.mem.eql(u8, entry.name, "ZSynth.clap")) continue;
            const full_path = try Dir.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer allocator.free(full_path);
            discoverPluginEntries(allocator, io, entries, full_path, .clap) catch {};
        }
    }
}

fn discoverPluginEntries(
    allocator: std.mem.Allocator,
    io: Io,
    entries: *std.ArrayListUnmanaged(PluginEntry),
    plugin_path: []const u8,
    kind: PluginKind,
) !void {
    const binary_path = resolveClapBinaryPath(allocator, io, plugin_path) catch return;
    defer allocator.free(binary_path);

    var lib = std.DynLib.open(binary_path) catch return;
    defer lib.close();

    const entry = lib.lookup(*const clap.Entry, "clap_entry") orelse return;
    const plugin_path_z = try allocator.dupeZ(u8, binary_path);
    defer allocator.free(plugin_path_z);
    if (!entry.init(plugin_path_z)) return;
    defer entry.deinit();

    const factory_raw = entry.getFactory(clap.PluginFactory.id) orelse return;
    const factory: *const clap.PluginFactory = @ptrCast(@alignCast(factory_raw));
    const plugin_count = factory.getPluginCount(factory);

    for (0..plugin_count) |i| {
        const desc = factory.getPluginDescriptor(factory, @intCast(i)) orelse continue;
        const name_copy = try allocator.dupe(u8, std.mem.span(desc.name));
        const id_copy = try allocator.dupe(u8, std.mem.span(desc.id));
        const path_copy = try allocator.dupe(u8, binary_path);
        try entries.append(allocator, .{
            .kind = kind,
            .name = name_copy,
            .path = path_copy,
            .id = id_copy,
        });
    }
}

fn resolveClapBinaryPath(allocator: std.mem.Allocator, io: Io, plugin_path: []const u8) ![]const u8 {
    const stat = Dir.cwd().statFile(io, plugin_path, .{}) catch return error.PluginMissing;
    if (stat.kind == .file) {
        return allocator.dupe(u8, plugin_path);
    }
    if (stat.kind != .directory) {
        return error.PluginMissing;
    }

    const macos_dir_path = try Dir.path.join(allocator, &[_][]const u8{
        plugin_path,
        "Contents",
        "MacOS",
    });
    defer allocator.free(macos_dir_path);

    var dir = Dir.openDirAbsolute(io, macos_dir_path, .{ .iterate = true }) catch return error.PluginMissing;
    defer dir.close(io);

    const base_name = Dir.path.stem(plugin_path);
    const preferred_path = try Dir.path.join(allocator, &[_][]const u8{ macos_dir_path, base_name });
    if (Dir.cwd().statFile(io, preferred_path, .{})) |_| {
        return preferred_path;
    } else |_| {
        allocator.free(preferred_path);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        return try Dir.path.join(allocator, &[_][]const u8{ macos_dir_path, entry.name });
    }

    return error.PluginMissing;
}
