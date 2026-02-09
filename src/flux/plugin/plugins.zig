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
    is_audio_effect: bool = false,
};

pub const PluginCatalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(PluginEntry) = .{},
    items_z: [:0]const u8 = &[_:0]u8{},
    fx_items_z: [:0]const u8 = &[_:0]u8{},
    fx_indices: []i32 = &[_]i32{},
    instrument_items_z: [:0]const u8 = &[_:0]u8{},
    instrument_indices: []i32 = &[_]i32{},
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
        if (self.fx_items_z.len > 0) {
            self.allocator.free(self.fx_items_z);
        }
        if (self.fx_indices.len > 0) {
            self.allocator.free(self.fx_indices);
        }
        if (self.instrument_items_z.len > 0) {
            self.allocator.free(self.instrument_items_z);
        }
        if (self.instrument_indices.len > 0) {
            self.allocator.free(self.instrument_indices);
        }
    }

    pub fn entryForIndex(self: *const PluginCatalog, index: i32) ?PluginEntry {
        if (index < 0) return null;
        const idx: usize = @intCast(index);
        if (idx >= self.entries.items.len) return null;
        return self.entries.items[idx];
    }
};

const CachedPlugin = struct {
    id: []const u8,
    name: []const u8,
    mtime_ns: i64,
    is_audio_effect: bool,
};

const PluginCache = struct {
    allocator: std.mem.Allocator,
    libs: std.StringHashMapUnmanaged([]CachedPlugin) = .{},
    dirty: bool = false,
    loaded: bool = false,

    pub fn deinit(self: *PluginCache) void {
        var it = self.libs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |plugin| {
                self.allocator.free(plugin.id);
                self.allocator.free(plugin.name);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.libs.deinit(self.allocator);
    }

    pub fn get(self: *PluginCache, path: []const u8, mtime_ns: i64) ?[]CachedPlugin {
        const plugins = self.libs.get(path) orelse return null;
        if (plugins.len == 0) return null;
        if (plugins[0].mtime_ns != mtime_ns) return null;
        return plugins;
    }

    pub fn hasPath(self: *PluginCache, path: []const u8) bool {
        return self.libs.contains(path);
    }

    pub fn set(self: *PluginCache, path: []const u8, plugins: []CachedPlugin) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        const gop = try self.libs.getOrPut(self.allocator, path_copy);
        if (gop.found_existing) {
            self.allocator.free(path_copy);
            for (gop.value_ptr.*) |plugin| {
                self.allocator.free(plugin.id);
                self.allocator.free(plugin.name);
            }
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = plugins;
        self.dirty = true;
    }
};

fn cacheDirPath(allocator: std.mem.Allocator) ![]const u8 {
    const home_c = std.c.getenv("HOME") orelse return error.MissingHome;
    const home = std.mem.span(home_c);
    return Dir.path.join(allocator, &[_][]const u8{ home, ".cache", "flux" });
}

fn cacheFilePath(allocator: std.mem.Allocator) ![]const u8 {
    const dir_path = try cacheDirPath(allocator);
    defer allocator.free(dir_path);
    return Dir.path.join(allocator, &[_][]const u8{ dir_path, "cache.json" });
}

fn statMtimeNs(io: Io, path: []const u8) ?i64 {
    const stat = Dir.cwd().statFile(io, path, .{}) catch return null;
    return @intCast(stat.mtime.toNanoseconds());
}

fn parseCachedPlugins(allocator: std.mem.Allocator, value: std.json.Value) ![]CachedPlugin {
    if (value != .array) return &[_]CachedPlugin{};

    var plugins: std.ArrayList(CachedPlugin) = .empty;
    defer plugins.deinit(allocator);

    for (value.array.items) |item| {
        if (item != .object) continue;

        var id: ?[]const u8 = null;
        var name: ?[]const u8 = null;
        var mtime: ?i64 = null;
        var is_audio_effect: ?bool = null;

        var it = item.object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (std.mem.eql(u8, key, "id")) {
                if (field.value_ptr.* == .string) {
                    id = field.value_ptr.*.string;
                }
                continue;
            }
            if (std.mem.eql(u8, key, "name")) {
                if (field.value_ptr.* == .string) {
                    name = field.value_ptr.*.string;
                }
                continue;
            }
            if (std.mem.eql(u8, key, "mtime")) {
                switch (field.value_ptr.*) {
                    .integer => |val| mtime = val,
                    .number_string => |val| mtime = std.fmt.parseInt(i64, val, 10) catch null,
                    .float => |val| mtime = @intFromFloat(val),
                    else => {},
                }
                continue;
            }
            if (std.mem.eql(u8, key, "audio_effect")) {
                if (field.value_ptr.* == .bool) {
                    is_audio_effect = field.value_ptr.*.bool;
                }
                continue;
            }
        }

        if (id == null or name == null or mtime == null) continue;

        const id_copy = try allocator.dupe(u8, id.?);
        const name_copy = try allocator.dupe(u8, name.?);
        try plugins.append(allocator, .{
            .id = id_copy,
            .name = name_copy,
            .mtime_ns = mtime.?,
            .is_audio_effect = is_audio_effect orelse false,
        });
    }

    return try plugins.toOwnedSlice(allocator);
}

fn loadPluginCache(allocator: std.mem.Allocator, io: Io) !PluginCache {
    var cache = PluginCache{ .allocator = allocator };

    const cache_path = cacheFilePath(allocator) catch return cache;
    defer allocator.free(cache_path);

    const file = Dir.cwd().openFile(io, cache_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return cache,
        else => return err,
    };
    cache.loaded = true;
    defer file.close(io);

    const stat = try file.stat(io);
    const max_size: u64 = 8 * 1024 * 1024;
    const size = @min(stat.size, max_size);
    const data = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(data);
    const read_len = try file.readPositionalAll(io, data, 0);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data[0..read_len], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
        .parse_numbers = true,
    }) catch return cache;
    defer parsed.deinit();

    if (parsed.value != .object) return cache;

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const plugins = try parseCachedPlugins(allocator, entry.value_ptr.*);
        if (plugins.len == 0) continue;
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        try cache.libs.put(allocator, key_copy, plugins);
    }

    return cache;
}

fn writePluginCache(cache: *PluginCache, io: Io) !void {
    if (!cache.dirty) return;

    const cache_dir = cacheDirPath(cache.allocator) catch return;
    defer cache.allocator.free(cache_dir);
    try Dir.cwd().createDirPath(io, cache_dir);

    const cache_path = try Dir.path.join(cache.allocator, &[_][]const u8{ cache_dir, "cache.json" });
    defer cache.allocator.free(cache_path);

    var arena = std.heap.ArenaAllocator.init(cache.allocator);
    defer arena.deinit();

    var root = std.json.ObjectMap.init(arena.allocator());
    var it = cache.libs.iterator();
    while (it.next()) |entry| {
        var plugin_array = std.json.Array.init(arena.allocator());
        for (entry.value_ptr.*) |plugin| {
            var plugin_obj = std.json.ObjectMap.init(arena.allocator());
            try plugin_obj.put("id", .{ .string = plugin.id });
            try plugin_obj.put("name", .{ .string = plugin.name });
            try plugin_obj.put("mtime", .{ .integer = plugin.mtime_ns });
            try plugin_obj.put("audio_effect", .{ .bool = plugin.is_audio_effect });
            try plugin_array.append(.{ .object = plugin_obj });
        }
        try root.put(entry.key_ptr.*, .{ .array = plugin_array });
    }

    const json_value = std.json.Value{ .object = root };
    const json = try std.json.Stringify.valueAlloc(cache.allocator, json_value, .{ .whitespace = .indent_2 });
    defer cache.allocator.free(json);

    var file = try Dir.cwd().createFile(io, cache_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, json);

    cache.dirty = false;
}

fn appendCachedPluginEntries(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(PluginEntry),
    binary_path: []const u8,
    plugins: []CachedPlugin,
) !void {
    for (plugins) |plugin| {
        const name_copy = try allocator.dupe(u8, plugin.name);
        const path_copy = try allocator.dupe(u8, binary_path);
        const id_copy = try allocator.dupe(u8, plugin.id);
        try entries.append(allocator, .{
            .kind = .clap,
            .name = name_copy,
            .path = path_copy,
            .id = id_copy,
            .is_audio_effect = plugin.is_audio_effect,
        });
    }
}

pub fn defaultPluginPath() ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => "zig-out/lib/ZSynth.clap/Contents/MacOS/ZSynth",
        .linux => "zig-out/lib/zsynth.clap",
        else => error.UnsupportedOs,
    };
}

pub fn zminimoogPluginPath() ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => "zig-out/lib/ZMinimoog.clap/Contents/MacOS/ZMinimoog",
        .linux => "zig-out/lib/zminimoog.clap",
        else => error.UnsupportedOs,
    };
}

pub fn discover(allocator: std.mem.Allocator, io: Io) !PluginCatalog {
    var catalog = PluginCatalog{ .allocator = allocator };

    try appendStaticEntry(&catalog, .none, "None", null, null);

    const builtin_path = try defaultPluginPath();
    try appendStaticEntry(&catalog, .builtin, "ZSynth", builtin_path, "com.juge.zsynth");

    const zminimoog_path = try zminimoogPluginPath();
    try appendStaticEntry(&catalog, .builtin, "ZMinimoog", zminimoog_path, "com.fourlex.zminimoog");

    var clap_entries: std.ArrayListUnmanaged(PluginEntry) = .{};
    defer clap_entries.deinit(allocator);
    discoverClapEntries(allocator, io, &clap_entries) catch {};

    if (clap_entries.items.len > 0) {
        std.mem.sort(PluginEntry, clap_entries.items, {}, pluginEntryLessThan);
        try appendStaticEntry(&catalog, .divider, "---- CLAP ----", null, null);
        catalog.divider_index = @intCast(catalog.entries.items.len - 1);
        try catalog.entries.appendSlice(allocator, clap_entries.items);
    }

    try rebuildItemsZ(&catalog);
    try rebuildFxItemsZ(&catalog);
    try rebuildInstrumentItemsZ(&catalog);
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
    if (catalog.items_z.len > 0) {
        catalog.allocator.free(catalog.items_z);
    }
    catalog.items_z = items;
}

fn rebuildFxItemsZ(catalog: *PluginCatalog) !void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(catalog.allocator);
    var indices: std.ArrayList(i32) = .empty;
    defer indices.deinit(catalog.allocator);

    for (catalog.entries.items, 0..) |entry, idx| {
        switch (entry.kind) {
            .none => {
                try buffer.appendSlice(catalog.allocator, entry.name);
                try buffer.append(catalog.allocator, 0);
                try indices.append(catalog.allocator, @intCast(idx));
            },
            .clap => {
                if (entry.is_audio_effect) {
                    try buffer.appendSlice(catalog.allocator, entry.name);
                    try buffer.append(catalog.allocator, 0);
                    try indices.append(catalog.allocator, @intCast(idx));
                }
            },
            else => {},
        }
    }
    try buffer.append(catalog.allocator, 0);

    const items = try catalog.allocator.dupeZ(u8, buffer.items);
    if (catalog.fx_items_z.len > 0) {
        catalog.allocator.free(catalog.fx_items_z);
    }
    catalog.fx_items_z = items;
    if (catalog.fx_indices.len > 0) {
        catalog.allocator.free(catalog.fx_indices);
    }
    catalog.fx_indices = try indices.toOwnedSlice(catalog.allocator);
}

fn rebuildInstrumentItemsZ(catalog: *PluginCatalog) !void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(catalog.allocator);
    var indices: std.ArrayList(i32) = .empty;
    defer indices.deinit(catalog.allocator);

    for (catalog.entries.items, 0..) |entry, idx| {
        switch (entry.kind) {
            .none => {
                try buffer.appendSlice(catalog.allocator, entry.name);
                try buffer.append(catalog.allocator, 0);
                try indices.append(catalog.allocator, @intCast(idx));
            },
            .builtin => {
                // Built-in plugins (like ZSynth) are instruments
                try buffer.appendSlice(catalog.allocator, entry.name);
                try buffer.append(catalog.allocator, 0);
                try indices.append(catalog.allocator, @intCast(idx));
            },
            .clap => {
                // Only include non-audio-effect plugins (instruments)
                if (!entry.is_audio_effect) {
                    try buffer.appendSlice(catalog.allocator, entry.name);
                    try buffer.append(catalog.allocator, 0);
                    try indices.append(catalog.allocator, @intCast(idx));
                }
            },
            .divider => {},
        }
    }
    try buffer.append(catalog.allocator, 0);

    const items = try catalog.allocator.dupeZ(u8, buffer.items);
    if (catalog.instrument_items_z.len > 0) {
        catalog.allocator.free(catalog.instrument_items_z);
    }
    catalog.instrument_items_z = items;
    if (catalog.instrument_indices.len > 0) {
        catalog.allocator.free(catalog.instrument_indices);
    }
    catalog.instrument_indices = try indices.toOwnedSlice(catalog.allocator);
}

fn pluginEntryLessThan(_: void, a: PluginEntry, b: PluginEntry) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn clapDescriptorHasFeature(desc: *const clap.Plugin.Descriptor, feature: []const u8) bool {
    var index: usize = 0;
    while (true) {
        const feature_ptr = desc.features[index] orelse break;
        if (std.mem.eql(u8, std.mem.span(feature_ptr), feature)) {
            return true;
        }
        index += 1;
    }
    return false;
}

fn isAudioEffectDescriptor(desc: *const clap.Plugin.Descriptor) bool {
    return clapDescriptorHasFeature(desc, clap.Plugin.features.audio_effect) or
        clapDescriptorHasFeature(desc, clap.Plugin.features.analyzer) or
        clapDescriptorHasFeature(desc, clap.Plugin.features.note_detector);
}

fn discoverClapEntries(allocator: std.mem.Allocator, io: Io, entries: *std.ArrayListUnmanaged(PluginEntry)) !void {
    if (builtin.os.tag != .macos) return;

    const full_scan_env = std.c.getenv("FLUX_CLAP_FULL_SCAN");
    const full_scan = if (full_scan_env) |val| val[0] == '1' else false;

    var cache = try loadPluginCache(allocator, io);
    defer cache.deinit();

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
        scanClapDir(allocator, io, entries, dir_path, full_scan, &cache) catch {};
    }

    writePluginCache(&cache, io) catch {};
}

fn scanClapDir(
    allocator: std.mem.Allocator,
    io: Io,
    entries: *std.ArrayListUnmanaged(PluginEntry),
    dir_path: []const u8,
    full_scan: bool,
    cache: *PluginCache,
) !void {
    var dir = Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory and entry.kind != .file) continue;

        const entry_path = try Dir.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(entry_path);

        const is_clap = std.mem.endsWith(u8, entry.name, ".clap");
        if (is_clap) {
            if (std.mem.eql(u8, entry.name, "ZSynth.clap")) continue;
            if (full_scan) {
                discoverPluginEntries(allocator, io, entries, entry_path, .clap, cache) catch {};
            } else {
                appendClapBundleEntry(allocator, io, entries, entry_path, cache) catch {};
            }
            continue;
        }

        if (entry.kind == .directory) {
            scanClapDir(allocator, io, entries, entry_path, full_scan, cache) catch {};
        }
    }
}

fn discoverPluginEntries(
    allocator: std.mem.Allocator,
    io: Io,
    entries: *std.ArrayListUnmanaged(PluginEntry),
    plugin_path: []const u8,
    kind: PluginKind,
    cache: ?*PluginCache,
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

    var cached_plugins: std.ArrayList(CachedPlugin) = .empty;
    defer cached_plugins.deinit(allocator);
    const mtime_ns = if (cache != null) statMtimeNs(io, binary_path) else null;

    for (0..plugin_count) |i| {
        const desc = factory.getPluginDescriptor(factory, @intCast(i)) orelse continue;
        const is_audio_effect = isAudioEffectDescriptor(desc);
        const name_copy = try allocator.dupe(u8, std.mem.span(desc.name));
        const id_copy = try allocator.dupe(u8, std.mem.span(desc.id));
        const path_copy = try allocator.dupe(u8, binary_path);
        try entries.append(allocator, .{
            .kind = kind,
            .name = name_copy,
            .path = path_copy,
            .id = id_copy,
            .is_audio_effect = is_audio_effect,
        });

        if (cache != null and mtime_ns != null) {
            const cached_id = try allocator.dupe(u8, std.mem.span(desc.id));
            const cached_name = try allocator.dupe(u8, std.mem.span(desc.name));
            try cached_plugins.append(allocator, .{
                .id = cached_id,
                .name = cached_name,
                .mtime_ns = mtime_ns.?,
                .is_audio_effect = is_audio_effect,
            });
        }
    }

    if (cache) |cache_ptr| {
        if (mtime_ns != null and cached_plugins.items.len > 0) {
            const plugins_slice = try cached_plugins.toOwnedSlice(allocator);
            try cache_ptr.set(binary_path, plugins_slice);
        }
    }
}

fn appendClapBundleEntry(
    allocator: std.mem.Allocator,
    io: Io,
    entries: *std.ArrayListUnmanaged(PluginEntry),
    bundle_path: []const u8,
    cache: ?*PluginCache,
) !void {
    const binary_path = resolveClapBinaryPath(allocator, io, bundle_path) catch return;
    defer allocator.free(binary_path);
    if (cache) |cache_ptr| {
        if (statMtimeNs(io, binary_path)) |mtime| {
            if (cache_ptr.get(binary_path, mtime)) |plugins| {
                try appendCachedPluginEntries(allocator, entries, binary_path, plugins);
                return;
            }
        }
    }

    discoverPluginEntries(allocator, io, entries, bundle_path, .clap, cache) catch {};
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
