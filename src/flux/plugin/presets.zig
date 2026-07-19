const std = @import("std");
const clap = @import("clap-bindings");
const preset_db = @import("preset_db.zig");
const plugins = @import("plugins.zig");

const Dir = std.Io.Dir;
const Io = std.Io;

pub const PresetEntry = struct {
    name: []const u8,
    plugin_id: []const u8,
    plugin_name: []const u8,
    provider_id: []const u8,
    location_kind: clap.preset_discovery.Location.Kind,
    location_z: [:0]const u8,
    load_key_z: ?[:0]const u8,
    catalog_index: i32,
};

pub const PresetCatalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(PresetEntry) = .empty,

    pub fn deinit(self: *PresetCatalog) void {
        self.arena.deinit();
    }
};

const CachedPreset = preset_db.Record;

fn catalogInfoForPluginId(catalog: *const plugins.PluginCatalog, plugin_id: []const u8) ?struct { name: []const u8, index: i32 } {
    for (catalog.entries.items, 0..) |entry, idx| {
        if (entry.id) |id| {
            if (std.mem.eql(u8, id, plugin_id)) {
                return .{ .name = entry.name, .index = @intCast(idx) };
            }
        }
    }
    return null;
}

fn appendCachedPresets(
    allocator: std.mem.Allocator,
    catalog: *const plugins.PluginCatalog,
    entries: *std.ArrayListUnmanaged(PresetEntry),
    presets: []CachedPreset,
) !void {
    for (presets) |preset| {
        const info = catalogInfoForPluginId(catalog, preset.plugin_id);
        try entries.append(allocator, .{
            .name = preset.name,
            .plugin_id = preset.plugin_id,
            .plugin_name = preset.plugin_name,
            .provider_id = preset.provider_id,
            .location_kind = @enumFromInt(preset.location_kind),
            .location_z = preset.location,
            .load_key_z = preset.load_key,
            .catalog_index = if (info) |val| val.index else -1,
        });
    }
}

const PresetLocation = struct {
    kind: clap.preset_discovery.Location.Kind,
    location_z: [:0]const u8,
};

const PresetFiletype = struct {
    extension: []const u8,
};

const PresetIndexer = struct {
    allocator: std.mem.Allocator,
    locations: std.ArrayListUnmanaged(PresetLocation) = .empty,
    filetypes: std.ArrayListUnmanaged(PresetFiletype) = .empty,

    fn deinit(self: *PresetIndexer) void {
        for (self.locations.items) |loc| {
            self.allocator.free(@constCast(loc.location_z));
        }
        self.locations.deinit(self.allocator);
        for (self.filetypes.items) |ft| {
            self.allocator.free(@constCast(ft.extension));
        }
        self.filetypes.deinit(self.allocator);
    }

    fn declareLocation(indexer: *const clap.preset_discovery.Indexer, location: *const clap.preset_discovery.Location) callconv(.c) bool {
        const self: *PresetIndexer = @ptrCast(@alignCast(indexer.indexer_data));
        const loc_ptr = location.location;
        const loc_z = if (loc_ptr) |ptr|
            self.allocator.dupeSentinel(u8, std.mem.span(ptr), 0) catch return false
        else
            self.allocator.dupeSentinel(u8, "", 0) catch return false;
        self.locations.append(self.allocator, .{
            .kind = location.kind,
            .location_z = loc_z,
        }) catch return false;
        return true;
    }

    fn declareFiletype(indexer: *const clap.preset_discovery.Indexer, filetype: *const clap.preset_discovery.Filetype) callconv(.c) bool {
        const self: *PresetIndexer = @ptrCast(@alignCast(indexer.indexer_data));
        const ext_ptr = filetype.file_extension;
        const ext = if (ext_ptr) |ptr| std.mem.span(ptr) else "";
        const ext_copy = self.allocator.dupe(u8, ext) catch return false;
        self.filetypes.append(self.allocator, .{ .extension = ext_copy }) catch return false;
        return true;
    }

    fn declareSoundpack(_: *const clap.preset_discovery.Indexer, _: *const clap.preset_discovery.Soundpack) callconv(.c) bool {
        return true;
    }

    fn getExtension(_: *const clap.preset_discovery.Indexer, _: [*:0]const u8) callconv(.c) ?*anyopaque {
        return null;
    }
};

const PresetMetadataCollector = struct {
    allocator: std.mem.Allocator,
    catalog: *const plugins.PluginCatalog,
    entries: *std.ArrayListUnmanaged(PresetEntry),
    provider_id: []const u8,
    location_kind: clap.preset_discovery.Location.Kind,
    location_z: [:0]const u8,
    default_name: ?[]const u8 = null,
    current_name: ?[]const u8 = null,
    current_load_key: ?[]const u8 = null,
    current_plugin_ids: std.ArrayListUnmanaged([]const u8) = .empty,

    fn reset(self: *PresetMetadataCollector) void {
        for (self.current_plugin_ids.items) |pid| {
            self.allocator.free(@constCast(pid));
        }
        self.current_plugin_ids.deinit(self.allocator);
        self.current_plugin_ids = .empty;
        if (self.current_name) |name| {
            self.allocator.free(@constCast(name));
        }
        if (self.current_load_key) |key| {
            self.allocator.free(@constCast(key));
        }
        if (self.default_name) |name| {
            self.allocator.free(@constCast(name));
        }
        self.current_name = null;
        self.current_load_key = null;
        self.default_name = null;
    }

    fn setDefaultName(self: *PresetMetadataCollector, name: []const u8) void {
        if (self.default_name) |old| {
            self.allocator.free(@constCast(old));
        }
        self.default_name = self.allocator.dupe(u8, name) catch null;
    }

    fn sanitizeName(_: *PresetMetadataCollector, name: []const u8) []const u8 {
        const slash_pos = std.mem.lastIndexOfScalar(u8, name, '/');
        const backslash_pos = std.mem.lastIndexOfScalar(u8, name, '\\');
        const start = if (slash_pos != null and backslash_pos != null)
            @max(slash_pos.?, backslash_pos.?) + 1
        else if (slash_pos) |idx|
            idx + 1
        else if (backslash_pos) |idx|
            idx + 1
        else
            0;
        const base = name[start..];
        const ext = std.fs.path.extension(base);
        if (ext.len == 0) return base;
        return base[0 .. base.len - ext.len];
    }

    fn flush(self: *PresetMetadataCollector) void {
        if (self.current_name == null or self.current_plugin_ids.items.len == 0) return;
        for (self.current_plugin_ids.items) |pid| {
            const info = catalogInfoForPluginId(self.catalog, pid);
            if (info == null) continue;
            const name_copy = self.allocator.dupe(u8, self.current_name.?) catch continue;
            const plugin_id_copy = self.allocator.dupe(u8, pid) catch continue;
            const plugin_name_copy = self.allocator.dupe(u8, info.?.name) catch continue;
            const provider_id_copy = self.allocator.dupe(u8, self.provider_id) catch continue;
            const location_copy = self.allocator.dupeSentinel(u8, self.location_z[0..], 0) catch continue;
            const load_key_copy = if (self.current_load_key) |key| self.allocator.dupeSentinel(u8, key, 0) catch null else null;
            self.entries.append(self.allocator, .{
                .name = name_copy,
                .plugin_id = plugin_id_copy,
                .plugin_name = plugin_name_copy,
                .provider_id = provider_id_copy,
                .location_kind = self.location_kind,
                .location_z = location_copy,
                .load_key_z = load_key_copy,
                .catalog_index = info.?.index,
            }) catch {};
        }
    }

    fn onError(receiver: *const clap.preset_discovery.MetadataReceiver, _: i32, error_message: [*:0]const u8) callconv(.c) void {
        const self: *PresetMetadataCollector = @ptrCast(@alignCast(receiver.receiver_data));
        std.log.warn("Preset discovery error: {s}", .{std.mem.span(error_message)});
        _ = self;
    }

    fn beginPreset(receiver: *const clap.preset_discovery.MetadataReceiver, name: ?[*:0]const u8, load_key: ?[*:0]const u8) callconv(.c) bool {
        const self: *PresetMetadataCollector = @ptrCast(@alignCast(receiver.receiver_data));
        self.flush();
        self.reset();
        const preset_name = if (name) |n| self.sanitizeName(std.mem.span(n)) else if (self.default_name) |d| d else "Preset";
        self.current_name = self.allocator.dupe(u8, preset_name) catch return false;
        if (load_key) |key| {
            self.current_load_key = self.allocator.dupe(u8, std.mem.span(key)) catch return false;
        }
        return true;
    }

    fn addPluginId(receiver: *const clap.preset_discovery.MetadataReceiver, plugin_id: *const clap.UniversalPluginId) callconv(.c) void {
        const self: *PresetMetadataCollector = @ptrCast(@alignCast(receiver.receiver_data));
        const abi = std.mem.span(plugin_id.abi);
        if (!std.mem.eql(u8, abi, "clap")) return;
        const id = std.mem.span(plugin_id.id);
        const id_copy = self.allocator.dupe(u8, id) catch return;
        self.current_plugin_ids.append(self.allocator, id_copy) catch {};
    }

    fn setSoundpackId(_: *const clap.preset_discovery.MetadataReceiver, _: [*:0]const u8) callconv(.c) void {}
    fn setFlags(_: *const clap.preset_discovery.MetadataReceiver, _: clap.preset_discovery.Flags) callconv(.c) void {}
    fn addCreator(_: *const clap.preset_discovery.MetadataReceiver, _: [*:0]const u8) callconv(.c) void {}
    fn setDescription(_: *const clap.preset_discovery.MetadataReceiver, _: [*:0]const u8) callconv(.c) void {}
    fn setTimestamps(_: *const clap.preset_discovery.MetadataReceiver, _: clap.Timestamp, _: clap.Timestamp) callconv(.c) void {}
    fn addFeature(_: *const clap.preset_discovery.MetadataReceiver, _: [*:0]const u8) callconv(.c) void {}
    fn addExtraInfo(_: *const clap.preset_discovery.MetadataReceiver, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) void {}
};

fn scanPresetsForBinary(
    allocator: std.mem.Allocator,
    io: Io,
    catalog: *const plugins.PluginCatalog,
    entries: *std.ArrayListUnmanaged(PresetEntry),
    binary_path: []const u8,
) ![]CachedPreset {
    var lib = std.DynLib.open(binary_path) catch return &[_]CachedPreset{};
    defer lib.close();

    const entry = lib.lookup(*const clap.Entry, "clap_entry") orelse return &[_]CachedPreset{};
    const bundle_path = blk: {
        const marker = ".clap/Contents/MacOS/";
        if (std.mem.indexOf(u8, binary_path, marker)) |idx| {
            const end = idx + ".clap".len;
            break :blk binary_path[0..end];
        }
        break :blk binary_path;
    };
    const plugin_path_z = try allocator.dupeSentinel(u8, bundle_path, 0);
    defer allocator.free(plugin_path_z);
    if (!entry.init(plugin_path_z)) return &[_]CachedPreset{};
    defer entry.deinit();

    const factory_raw = entry.getFactory(clap.preset_discovery.Factory.id) orelse return &[_]CachedPreset{};
    const factory: *const clap.preset_discovery.Factory = @ptrCast(@alignCast(factory_raw));
    const provider_count = factory.count(factory);

    var cached: std.ArrayList(CachedPreset) = .empty;
    defer cached.deinit(allocator);

    const start_index = entries.items.len;
    for (0..provider_count) |i| {
        const descriptor = factory.getDescriptor(factory, @intCast(i)) orelse continue;
        var indexer_state = PresetIndexer{ .allocator = allocator };
        defer indexer_state.deinit();
        const indexer = clap.preset_discovery.Indexer{
            .clap_version = clap.version,
            .name = "flux",
            .vendor = "gearmulator",
            .url = null,
            .version = "0.1",
            .indexer_data = &indexer_state,
            .declareFiletype = PresetIndexer.declareFiletype,
            .declareLocation = PresetIndexer.declareLocation,
            .declareSoundpack = PresetIndexer.declareSoundpack,
            .getExtension = PresetIndexer.getExtension,
        };

        const provider = factory.create(factory, &indexer, descriptor.id) orelse continue;
        if (!provider.init(provider)) {
            provider.destroy(provider);
            continue;
        }

        for (indexer_state.locations.items) |loc| {
            var collector = PresetMetadataCollector{
                .allocator = allocator,
                .catalog = catalog,
                .entries = entries,
                .provider_id = std.mem.span(descriptor.id),
                .location_kind = loc.kind,
                .location_z = loc.location_z,
            };
            defer collector.reset();

            const receiver = clap.preset_discovery.MetadataReceiver{
                .receiver_data = &collector,
                .onError = PresetMetadataCollector.onError,
                .beginPreset = PresetMetadataCollector.beginPreset,
                .addPluginId = PresetMetadataCollector.addPluginId,
                .setSoundpackId = PresetMetadataCollector.setSoundpackId,
                .setFlags = PresetMetadataCollector.setFlags,
                .addCreator = PresetMetadataCollector.addCreator,
                .setDescription = PresetMetadataCollector.setDescription,
                .setTimestamps = PresetMetadataCollector.setTimestamps,
                .addFeature = PresetMetadataCollector.addFeature,
                .addExtraInfo = PresetMetadataCollector.addExtraInfo,
            };

            if (loc.kind == .plugin) {
                const location_ptr: ?[*:0]const u8 = null;
                if (provider.getMetadata(provider, loc.kind, location_ptr, &receiver)) {
                    collector.flush();
                }
                collector.reset();
            } else {
                const location_path = loc.location_z[0..];
                const stat = Dir.cwd().statFile(io, location_path, .{}) catch {
                    continue;
                };
                if (stat.kind == .file) {
                    if (fileExtensionMatches(location_path, indexer_state.filetypes.items)) {
                        const location_ptr: ?[*:0]const u8 = loc.location_z.ptr;
                        if (provider.getMetadata(provider, loc.kind, location_ptr, &receiver)) {
                            collector.flush();
                        }
                    }
                    collector.reset();
                } else if (stat.kind == .directory) {
                    scanPresetDir(allocator, io, location_path, indexer_state.filetypes.items, provider, &receiver, &collector);
                }
            }
        }

        provider.destroy(provider);
    }

    for (entries.items[start_index..]) |preset| {
        const name_copy = try allocator.dupe(u8, preset.name);
        const plugin_id_copy = try allocator.dupe(u8, preset.plugin_id);
        const plugin_name_copy = try allocator.dupe(u8, preset.plugin_name);
        const provider_id_copy = try allocator.dupe(u8, preset.provider_id);
        const location_copy = try allocator.dupeSentinel(u8, preset.location_z[0..], 0);
        const load_key_copy = if (preset.load_key_z) |key| try allocator.dupeSentinel(u8, key[0..], 0) else null;
        try cached.append(allocator, .{
            .name = name_copy,
            .plugin_id = plugin_id_copy,
            .plugin_name = plugin_name_copy,
            .provider_id = provider_id_copy,
            .location_kind = @intFromEnum(preset.location_kind),
            .location = location_copy,
            .load_key = load_key_copy,
        });
    }

    return try cached.toOwnedSlice(allocator);
}

fn presetEntryLessThan(_: void, a: PresetEntry, b: PresetEntry) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn fileExtensionMatches(path: []const u8, filetypes: []const PresetFiletype) bool {
    if (filetypes.len == 0) return true;
    const ext_with_dot = std.fs.path.extension(path);
    var ext = ext_with_dot;
    if (ext.len > 0 and ext[0] == '.') {
        ext = ext[1..];
    }
    for (filetypes) |ft| {
        if (ft.extension.len == 0) return true;
        if (std.ascii.eqlIgnoreCase(ext, ft.extension)) return true;
    }
    return false;
}

fn scanPresetDir(
    allocator: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    filetypes: []const PresetFiletype,
    provider: *const clap.preset_discovery.Provider,
    receiver: *const clap.preset_discovery.MetadataReceiver,
    collector: *PresetMetadataCollector,
) void {
    var dir = Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const next_entry = it.next(io) catch break;
        if (next_entry == null) break;
        const entry = next_entry.?;
        if (entry.kind != .file and entry.kind != .directory) continue;
        const entry_path = Dir.path.join(allocator, &[_][]const u8{ dir_path, entry.name }) catch continue;
        defer allocator.free(entry_path);

        if (entry.kind == .directory) {
            scanPresetDir(allocator, io, entry_path, filetypes, provider, receiver, collector);
            continue;
        }

        if (!fileExtensionMatches(entry.name, filetypes)) continue;
        const entry_path_z = allocator.dupeSentinel(u8, entry_path, 0) catch continue;
        defer allocator.free(entry_path_z);

        const base = std.fs.path.basename(entry_path);
        const ext = std.fs.path.extension(base);
        const display = if (ext.len == 0) base else base[0 .. base.len - ext.len];
        collector.setDefaultName(display);
        const prev_location = collector.location_z;
        collector.location_z = entry_path_z;
        if (provider.getMetadata(provider, .file, entry_path_z.ptr, receiver)) {
            collector.flush();
        }
        collector.location_z = prev_location;
        collector.reset();
    }
}

pub fn build(
    allocator: std.mem.Allocator,
    io: Io,
    catalog: *const plugins.PluginCatalog,
    environ_map: *std.process.Environ.Map,
) !PresetCatalog {
    var preset_catalog = PresetCatalog{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer preset_catalog.deinit();
    const catalog_allocator = preset_catalog.arena.allocator();

    var db = try preset_db.Db.open(allocator, io);
    defer db.deinit();
    const debug = if (environ_map.get("FLUX_PRESET_DEBUG")) |env| env.len > 0 and env[0] == '1' else false;
    const rescan_all = if (environ_map.get("FLUX_PRESET_RESCAN")) |env| env.len > 0 and env[0] == '1' else false;
    var total_presets: usize = 0;
    var total_providers: usize = 0;

    var seen_paths: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = seen_paths.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        seen_paths.deinit(allocator);
    }

    for (catalog.entries.items) |entry| {
        if (entry.kind != .clap and entry.kind != .builtin) continue;
        const path = entry.path orelse continue;
        var resolved_path: ?[]const u8 = null;
        const scan_path = if (entry.kind == .clap) blk: {
            resolved_path = plugins.resolveClapBinaryPath(allocator, io, path) catch break :blk path;
            break :blk resolved_path.?;
        } else path;
        defer if (resolved_path) |value| allocator.free(value);

        if (seen_paths.contains(scan_path)) continue;
        try seen_paths.put(allocator, try allocator.dupe(u8, scan_path), {});

        const mtime_ns = plugins.statMtimeNs(io, scan_path) orelse continue;
        if (!rescan_all) {
            if (try db.matches(scan_path, mtime_ns)) {
                const cached_presets = try db.load(catalog_allocator, scan_path);
                try appendCachedPresets(catalog_allocator, catalog, &preset_catalog.entries, cached_presets);
                if (debug) {
                    std.log.info("Preset cache hit: {s} ({d} presets)", .{ scan_path, cached_presets.len });
                }
                continue;
            }
        }

        const presets = try scanPresetsForBinary(catalog_allocator, io, catalog, &preset_catalog.entries, scan_path);
        total_providers += 1;
        total_presets += presets.len;
        if (debug) {
            std.log.info("Preset scan: {s} ({d} presets)", .{ scan_path, presets.len });
        }
        try db.replace(scan_path, mtime_ns, presets);
    }

    if (preset_catalog.entries.items.len > 0) {
        std.mem.sort(PresetEntry, preset_catalog.entries.items, {}, presetEntryLessThan);
    }

    if (debug) {
        std.log.info("Preset scan summary: {d} presets across {d} providers", .{ total_presets, total_providers });
    }
    return preset_catalog;
}
