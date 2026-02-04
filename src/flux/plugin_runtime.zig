const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");
const objc = if (builtin.os.tag == .macos) @import("objc") else struct {};

const audio_constants = @import("audio_constants.zig");
const audio_engine = @import("audio_engine.zig");
const plugins = @import("plugins.zig");
const session_constants = @import("ui/session_view/constants.zig");
const session_view = @import("ui/session_view.zig");
const ui_state = @import("ui/state.zig");
const thread_context = @import("thread_context.zig");
const zsynth = @import("zsynth-core");
const zminimoog = @import("zminimoog-core");

const track_count = session_constants.max_tracks;
const master_track_index = session_view.master_track_index;

pub const PluginHandle = struct {
    lib: std.DynLib,
    entry: *const clap.Entry,
    factory: *const clap.PluginFactory,
    plugin: *const clap.Plugin,
    plugin_path_z: [:0]u8,
    activated: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        host: *const clap.Host,
        plugin_path: []const u8,
        plugin_id: ?[]const u8,
        max_frames: u32,
    ) !PluginHandle {
        const plugin_path_z = try allocator.dupeZ(u8, plugin_path);
        errdefer allocator.free(plugin_path_z);

        var lib = try std.DynLib.open(plugin_path);
        errdefer lib.close();

        const entry = lib.lookup(*const clap.Entry, "clap_entry") orelse return error.MissingClapEntry;
        if (!entry.init(plugin_path_z)) return error.EntryInitFailed;
        errdefer entry.deinit();

        const factory_raw = entry.getFactory(clap.PluginFactory.id) orelse return error.MissingPluginFactory;
        const factory: *const clap.PluginFactory = @ptrCast(@alignCast(factory_raw));
        const plugin = blk: {
            if (plugin_id) |id| {
                const id_z = try allocator.dupeZ(u8, id);
                defer allocator.free(id_z);
                break :blk factory.createPlugin(factory, host, id_z) orelse return error.PluginCreateFailed;
            }

            const plugin_count = factory.getPluginCount(factory);
            if (plugin_count == 0) return error.NoPluginsFound;
            const desc = factory.getPluginDescriptor(factory, 0) orelse return error.MissingPluginDescriptor;
            break :blk factory.createPlugin(factory, host, desc.id) orelse return error.PluginCreateFailed;
        };

        if (!plugin.init(plugin)) return error.PluginInitFailed;

        if (!plugin.activate(plugin, audio_constants.sample_rate, 1, max_frames)) return error.PluginActivateFailed;

        return .{
            .lib = lib,
            .entry = entry,
            .factory = factory,
            .plugin = plugin,
            .plugin_path_z = plugin_path_z,
            .activated = true,
        };
    }

    pub fn deinit(self: *PluginHandle, allocator: std.mem.Allocator) void {
        // Note: stopProcessing is called by unloadPlugin before this, using SharedState tracking
        if (self.activated) {
            self.plugin.deactivate(self.plugin);
        }
        self.plugin.destroy(self.plugin);
        self.entry.deinit();
        self.lib.close();
        allocator.free(self.plugin_path_z);
    }
};

/// Handle for a builtin (statically linked) plugin
pub const BuiltinHandle = struct {
    plugin: *clap.Plugin,

    pub fn deinit(self: *BuiltinHandle) void {
        self.plugin.deactivate(self.plugin);
        // Note: destroy() calls the CLAP _destroy callback which already calls plugin.deinit()
        self.plugin.destroy(self.plugin);
    }
};

pub const TrackPlugin = struct {
    /// External CLAP plugin loaded from disk
    handle: ?PluginHandle = null,
    /// Builtin plugin (statically linked)
    builtin: ?BuiltinHandle = null,
    gui_ext: ?*const clap.ext.gui.Plugin = null,
    gui_window: ?*anyopaque = null,
    gui_view: ?*anyopaque = null,
    gui_open: bool = false,
    choice_index: i32 = -1,

    /// Get the CLAP plugin pointer, whether external or builtin
    pub fn getPlugin(self: *const TrackPlugin) ?*const clap.Plugin {
        if (self.handle) |h| return h.plugin;
        if (self.builtin) |b| return b.plugin;
        return null;
    }
};

pub const PluginSnapshot = struct {
    instruments: [track_count]?*const clap.Plugin,
    fx: [track_count][ui_state.max_fx_slots]?*const clap.Plugin,
};

fn pluginHasAudioInput(plugin: *const clap.Plugin) bool {
    const ext_raw = plugin.getExtension(plugin, clap.ext.audio_ports.id) orelse return false;
    const ports: *const clap.ext.audio_ports.Plugin = @ptrCast(@alignCast(ext_raw));
    return ports.count(plugin, true) > 0;
}

pub fn collectPlugins(
    track_plugins: *const [track_count]TrackPlugin,
    track_fx: *const [track_count][ui_state.max_fx_slots]TrackPlugin,
) PluginSnapshot {
    var instruments: [track_count]?*const clap.Plugin = [_]?*const clap.Plugin{null} ** track_count;
    var fx: [track_count][ui_state.max_fx_slots]?*const clap.Plugin =
        [_][ui_state.max_fx_slots]?*const clap.Plugin{[_]?*const clap.Plugin{null} ** ui_state.max_fx_slots} ** track_count;

    for (0..track_count) |t| {
        // All plugins (builtin and external) are now in TrackPlugin
        instruments[t] = track_plugins[t].getPlugin();

        for (0..ui_state.max_fx_slots) |fx_index| {
            fx[t][fx_index] = track_fx[t][fx_index].getPlugin();
        }
    }

    return .{
        .instruments = instruments,
        .fx = fx,
    };
}

pub fn updateUiPluginPointers(
    state: *ui_state.State,
    track_plugins: *const [track_count]TrackPlugin,
    track_fx: *const [track_count][ui_state.max_fx_slots]TrackPlugin,
) void {
    for (track_plugins, 0..) |track, t| {
        state.track_plugin_ptrs[t] = track.getPlugin();
    }
    for (track_fx, 0..) |track_slots, t| {
        for (track_slots, 0..) |slot, fx_index| {
            state.track_fx_plugin_ptrs[t][fx_index] = slot.getPlugin();
        }
    }
}

pub fn syncTrackPlugins(
    allocator: std.mem.Allocator,
    host: *const clap.Host,
    track_plugins: *[track_count]TrackPlugin,
    track_fx: *[track_count][ui_state.max_fx_slots]TrackPlugin,
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    shared: ?*audio_engine.SharedState,
    io: std.Io,
    max_frames: u32,
    start_processing: bool,
) !void {
    const prepareUnload = struct {
        fn call(shared_state: ?*audio_engine.SharedState, track_index: usize, io_ctx: std.Io) void {
            if (shared_state) |shared_ref| {
                shared_ref.setTrackPlugin(track_index, null);
                shared_ref.waitForIdle(io_ctx);
            }
        }
    }.call;

    const selected_track = state.selectedTrack();
    for (track_plugins, 0..) |*track, t| {
        const choice = state.track_plugins[t].choice_index;
        // Only show GUI for the selected track (if that track has gui_open enabled)
        const wants_gui = state.track_plugins[t].gui_open and (t == selected_track);

        const entry = catalog.entryForIndex(choice);
        const kind = if (entry) |item| item.kind else .none;

        // Handle none/divider - unload any existing plugin
        if (kind == .none or kind == .divider) {
            if (track.handle != null or track.builtin != null) {
                closePluginGui(track);
                prepareUnload(shared, t, io);
                unloadPlugin(track, allocator, shared, t);
            }
            track.choice_index = choice;
            continue;
        }

        // Plugin choice changed - unload old plugin
        if (track.choice_index != choice) {
            if (track.handle != null or track.builtin != null) {
                closePluginGui(track);
                prepareUnload(shared, t, io);
                unloadPlugin(track, allocator, shared, t);
            }
            track.choice_index = choice;
        }

        // Load new plugin if needed
        if (track.handle == null and track.builtin == null) {
            switch (kind) {
                .builtin => {
                    // Instantiate builtin plugin directly (statically linked)
                    const plugin_id = entry.?.id orelse "";
                    if (std.mem.eql(u8, plugin_id, "com.fourlex.zminimoog")) {
                        const plugin = try zminimoog.Plugin.init(allocator, host);
                        if (!plugin.plugin.init(&plugin.plugin)) return error.PluginInitFailed;
                        if (!plugin.plugin.activate(&plugin.plugin, audio_constants.sample_rate, 1, max_frames)) {
                            return error.PluginActivateFailed;
                        }
                        track.builtin = .{ .plugin = &plugin.plugin };
                    } else {
                        const plugin = try zsynth.Plugin.init(allocator, host);
                        if (!plugin.plugin.init(&plugin.plugin)) return error.PluginInitFailed;
                        if (!plugin.plugin.activate(&plugin.plugin, audio_constants.sample_rate, 1, max_frames)) {
                            return error.PluginActivateFailed;
                        }
                        track.builtin = .{ .plugin = &plugin.plugin };
                    }
                    // Builtins don't have external GUIs - they use embedded zgui views
                    track.gui_ext = null;
                },
                .clap => {
                    const path = entry.?.path orelse return error.PluginMissingPath;
                    track.handle = try PluginHandle.init(allocator, host, path, entry.?.id, max_frames);
                    track.gui_ext = getGuiExt(track.handle.?);
                },
                else => {},
            }
            // Request startProcessing from audio thread (CLAP requires audio thread for this call)
            if (start_processing) {
                if (shared) |s| {
                    s.requestStartProcessing(t);
                }
            }
        }

        // GUI handling for external CLAP plugins only (builtins use embedded views)
        if (kind == .clap) {
            if (wants_gui and !track.gui_open) {
                if (track.gui_ext) |gui_ext| {
                    closeAllPluginGuis(track_plugins, track_fx);
                    openPluginGui(track, gui_ext) catch |err| {
                        std.log.err("Failed to open plugin gui: {}", .{err});
                        state.track_plugins[t].gui_open = false;
                    };
                } else {
                    state.track_plugins[t].gui_open = false;
                }
            } else if (!wants_gui and track.gui_open) {
                closePluginGui(track);
            }
        }
    }
}

pub fn syncFxPlugins(
    allocator: std.mem.Allocator,
    host: *const clap.Host,
    track_plugins: *[track_count]TrackPlugin,
    track_fx: *[track_count][ui_state.max_fx_slots]TrackPlugin,
    state: *ui_state.State,
    catalog: *const plugins.PluginCatalog,
    shared: ?*audio_engine.SharedState,
    io: std.Io,
    max_frames: u32,
    start_processing: bool,
) !void {
    const prepareUnload = struct {
        fn call(shared_state: ?*audio_engine.SharedState, track_index: usize, fx_index: usize, io_ctx: std.Io) void {
            if (shared_state) |shared_ref| {
                shared_ref.setTrackFxPlugin(track_index, fx_index, null);
                shared_ref.waitForIdle(io_ctx);
            }
        }
    }.call;

    const selected_track = state.selectedTrack();
    const master_selected = state.session.mixer_target == .master;
    for (track_fx, 0..) |*track_slots, t| {
        for (track_slots, 0..) |*slot, fx_index| {
            const choice = state.track_fx[t][fx_index].choice_index;
            const entry = catalog.entryForIndex(choice);
            const kind = if (entry) |item| item.kind else .none;
            const wants_gui = state.track_fx[t][fx_index].gui_open and ((t == selected_track) or (master_selected and t == master_track_index));

            if (kind != .clap) {
                if (slot.handle != null) {
                    closePluginGui(slot);
                    prepareUnload(shared, t, fx_index, io);
                    unloadFxPlugin(slot, allocator, shared, t, fx_index);
                }
                if (kind == .builtin or kind == .divider) {
                    state.track_fx[t][fx_index].choice_index = 0;
                    state.track_fx[t][fx_index].last_valid_choice = 0;
                }
                slot.choice_index = state.track_fx[t][fx_index].choice_index;
                continue;
            }

            if (slot.choice_index != choice) {
                if (slot.handle != null) {
                    closePluginGui(slot);
                    prepareUnload(shared, t, fx_index, io);
                    unloadFxPlugin(slot, allocator, shared, t, fx_index);
                }
                slot.choice_index = choice;
            }

            if (slot.handle == null) {
                const path = entry.?.path orelse return error.PluginMissingPath;
                slot.handle = try PluginHandle.init(allocator, host, path, entry.?.id, max_frames);
                slot.gui_ext = getGuiExt(slot.handle.?);
                if (start_processing) {
                    if (shared) |s| {
                        s.requestStartProcessingFx(t, fx_index);
                    }
                }
            }

            if (slot.handle != null and !pluginHasAudioInput(slot.handle.?.plugin)) {
                std.log.warn("FX plugin has no audio input: {s}", .{entry.?.name});
                closePluginGui(slot);
                prepareUnload(shared, t, fx_index, io);
                unloadFxPlugin(slot, allocator, shared, t, fx_index);
                state.track_fx[t][fx_index].gui_open = false;
                const fallback = if (state.track_fx[t][fx_index].last_valid_choice != choice)
                    state.track_fx[t][fx_index].last_valid_choice
                else
                    0;
                state.track_fx[t][fx_index].choice_index = fallback;
                slot.choice_index = fallback;
                continue;
            }
            state.track_fx[t][fx_index].last_valid_choice = choice;

            if (wants_gui and !slot.gui_open) {
                if (slot.gui_ext) |gui_ext| {
                    closeAllPluginGuis(track_plugins, track_fx);
                    openPluginGui(slot, gui_ext) catch |err| {
                        std.log.err("Failed to open fx plugin gui: {}", .{err});
                        state.track_fx[t][fx_index].gui_open = false;
                    };
                } else {
                    state.track_fx[t][fx_index].gui_open = false;
                }
            } else if (!wants_gui and slot.gui_open) {
                closePluginGui(slot);
            }
        }
    }
}

pub fn unloadPlugin(track: *TrackPlugin, allocator: std.mem.Allocator, shared: ?*audio_engine.SharedState, track_index: usize) void {
    // Get the CLAP plugin pointer (works for both handle and builtin)
    const plugin_ptr = track.getPlugin();

    if (plugin_ptr) |plugin| {
        // Check if plugin was started via shared state and call stopProcessing if needed
        if (shared) |s| {
            if (s.isPluginStarted(track_index)) {
                // Set audio thread flag for stopProcessing (per CLAP spec, host controls
                // which thread is "audio thread" and can designate any thread when only
                // one is active. The audio device is already stopped at this point.)
                const was_audio = thread_context.is_audio_thread;
                thread_context.is_audio_thread = true;
                defer thread_context.is_audio_thread = was_audio;
                plugin.stopProcessing(plugin);
                s.clearPluginStarted(track_index);
            }
        }
    }

    // Deinit external plugin handle
    if (track.handle) |*handle| {
        handle.deinit(allocator);
    }
    // Deinit builtin plugin
    if (track.builtin) |*b| {
        b.deinit();
    }

    track.handle = null;
    track.builtin = null;
    track.gui_ext = null;
    track.gui_window = null;
    track.gui_view = null;
    track.gui_open = false;
}

pub fn unloadFxPlugin(
    track: *TrackPlugin,
    allocator: std.mem.Allocator,
    shared: ?*audio_engine.SharedState,
    track_index: usize,
    fx_index: usize,
) void {
    if (track.handle) |*handle| {
        if (shared) |s| {
            if (s.isFxPluginStarted(track_index, fx_index)) {
                const was_audio = thread_context.is_audio_thread;
                thread_context.is_audio_thread = true;
                defer thread_context.is_audio_thread = was_audio;
                handle.plugin.stopProcessing(handle.plugin);
                s.clearFxPluginStarted(track_index, fx_index);
            }
        }
        handle.deinit(allocator);
    }
    track.handle = null;
    track.gui_ext = null;
    track.gui_window = null;
    track.gui_view = null;
    track.gui_open = false;
}

fn getGuiExt(handle: PluginHandle) ?*const clap.ext.gui.Plugin {
    const ext_raw = handle.plugin.getExtension(handle.plugin, clap.ext.gui.id) orelse return null;
    return @ptrCast(@alignCast(ext_raw));
}

fn openPluginGui(track: *TrackPlugin, gui_ext: *const clap.ext.gui.Plugin) !void {
    if (track.handle == null) return;
    if (track.gui_open) return;

    const plugin = track.handle.?.plugin;
    var is_floating: bool = false;
    var api_ptr: [*:0]const u8 = switch (builtin.os.tag) {
        .linux => clap.ext.gui.window_api.wayland,
        else => clap.ext.gui.window_api.cocoa,
    };
    _ = gui_ext.getPreferredApi(plugin, &api_ptr, &is_floating);

    // CLAP Wayland embedding isn't supported (floating only), so on Linux force floating and
    // pick the best supported API (prefer Wayland).
    if (builtin.os.tag == .linux) {
        is_floating = true;
        if (gui_ext.isApiSupported(plugin, clap.ext.gui.window_api.wayland, true)) {
            api_ptr = clap.ext.gui.window_api.wayland;
        } else if (gui_ext.isApiSupported(plugin, clap.ext.gui.window_api.x11, true)) {
            api_ptr = clap.ext.gui.window_api.x11;
        } else if (gui_ext.isApiSupported(plugin, api_ptr, true)) {
            // keep plugin preference
        } else {
            return error.GuiUnsupported;
        }
    }

    if (!gui_ext.isApiSupported(plugin, api_ptr, is_floating)) {
        return error.GuiUnsupported;
    }

    if (!gui_ext.create(plugin, api_ptr, is_floating)) {
        return error.GuiCreateFailed;
    }

    switch (builtin.os.tag) {
        .macos => {
            if (!is_floating) {
                var width: u32 = 0;
                var height: u32 = 0;
                if (!gui_ext.getSize(plugin, &width, &height)) {
                    width = 800;
                    height = 500;
                }
                const rect = objc.app_kit.Rect{
                    .origin = .{ .x = 0, .y = 0 },
                    .size = .{
                        .width = @floatFromInt(width),
                        .height = @floatFromInt(height),
                    },
                };
                const style = objc.app_kit.WindowStyleMaskTitled |
                    objc.app_kit.WindowStyleMaskClosable |
                    objc.app_kit.WindowStyleMaskResizable |
                    objc.app_kit.WindowStyleMaskMiniaturizable;
                const window = objc.app_kit.Window.alloc().initWithContentRect_styleMask_backing_defer_screen(
                    rect,
                    style,
                    objc.app_kit.BackingStoreBuffered,
                    false,
                    null,
                );
                window.setReleasedWhenClosed(false);
                const title = objc.foundation.String.stringWithUTF8String("Plugin");
                window.setTitle(title);

                // Get main window BEFORE showing plugin window (otherwise plugin becomes mainWindow)
                const main_window: ?*objc.app_kit.Window = objc.objc.msgSend(
                    objc.app_kit.Application.sharedApplication(),
                    "mainWindow",
                    ?*objc.app_kit.Window,
                    .{},
                );

                const view = objc.app_kit.View.alloc().initWithFrame(rect);
                window.setContentView(view);
                window.makeKeyAndOrderFront(null);

                // Add as child window of main app window - stays above main window but not above other apps
                if (main_window) |mw| {
                    const NSWindowAbove: c_long = 1;
                    objc.objc.msgSend(mw, "addChildWindow:ordered:", void, .{ window, NSWindowAbove });
                }
                const window_handle = clap.ext.gui.Window{
                    .api = clap.ext.gui.window_api.cocoa,
                    .data = .{ .cocoa = @ptrCast(view) },
                };
                if (!gui_ext.setParent(plugin, &window_handle)) {
                    view.release();
                    window.release();
                    gui_ext.destroy(plugin);
                    return error.GuiSetParentFailed;
                }
                track.gui_window = @ptrCast(window);
                track.gui_view = @ptrCast(view);
            }
        },
        .linux => {},
        else => {},
    }

    if (!gui_ext.show(plugin)) {
        if (builtin.os.tag == .macos) {
            if (track.gui_window) |window_raw| {
                const window: *objc.app_kit.Window = @ptrCast(@alignCast(window_raw));
                window.setIsVisible(false);
                window.release();
                track.gui_window = null;
            }
            if (track.gui_view) |view_raw| {
                const view: *objc.app_kit.View = @ptrCast(@alignCast(view_raw));
                view.release();
                track.gui_view = null;
            }
        }
        gui_ext.destroy(plugin);
        return error.GuiShowFailed;
    }

    track.gui_open = true;
}

pub fn closePluginGui(track: *TrackPlugin) void {
    if (track.handle == null) return;
    if (!track.gui_open) return;
    const plugin = track.handle.?.plugin;
    if (track.gui_ext) |gui_ext| {
        _ = gui_ext.hide(plugin);
        gui_ext.destroy(plugin);
    }
    if (builtin.os.tag == .macos) {
        if (track.gui_window) |window_raw| {
            const window: *objc.app_kit.Window = @ptrCast(@alignCast(window_raw));
            // Remove from parent window's child list
            const main_window: ?*objc.app_kit.Window = objc.objc.msgSend(
                objc.app_kit.Application.sharedApplication(),
                "mainWindow",
                ?*objc.app_kit.Window,
                .{},
            );
            if (main_window) |mw| {
                objc.objc.msgSend(mw, "removeChildWindow:", void, .{window});
            }
            window.setIsVisible(false);
            window.release();
            track.gui_window = null;
        }
        if (track.gui_view) |view_raw| {
            const view: *objc.app_kit.View = @ptrCast(@alignCast(view_raw));
            view.release();
            track.gui_view = null;
        }
    } else {
        track.gui_window = null;
        track.gui_view = null;
    }
    track.gui_open = false;
}

pub fn closeAllPluginGuis(
    track_plugins: *[track_count]TrackPlugin,
    track_fx: *[track_count][ui_state.max_fx_slots]TrackPlugin,
) void {
    for (track_plugins) |*track| {
        if (track.gui_open) {
            closePluginGui(track);
        }
    }
    for (track_fx) |*track_slots| {
        for (track_slots) |*slot| {
            if (slot.gui_open) {
                closePluginGui(slot);
            }
        }
    }
}
