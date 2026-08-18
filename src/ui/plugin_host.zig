//! CLAP catalog + live device-chain loading for the DVUI host.
//!
//! Discovers plugins at init, owns choice indices and DynLib instances, and
//! publishes loaded CLAP pointers into the audio engine each frame.
//!
//! Builtins: stock Flux FX + instruments load statically (`plugin/builtin_load.zig`).
//! External system CLAPs use DynLib. Plugin GUIs open via `plugin/gui_float.zig`
//! (floating preferred; macOS NSWindow / Linux X11 parent fallbacks).
//! Hardware MIDI (portmidi) merges into live keys with the computer-keyboard piano map.
//!
//! Full CLAP host extensions (thread_pool, params, latency, timer, posix_fd,
//! undo, requestProcess/Callback) live here — restored from pre-DVUI `app/host.zig`.
//! Plugin undo blobs push onto `document.Store.undo_history`.

const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");

const chrome = @import("state.zig");
const host_mod = @import("host.zig");
const document_model = @import("../document/model.zig");
const plugins = @import("../plugin/plugins.zig");
const presets_mod = @import("../plugin/presets.zig");
const plugin_handle = @import("../plugin/handle.zig");
const builtin_load = @import("../plugin/builtin_load.zig");
const gui_float = @import("../plugin/gui_float.zig");
const plugin_call_context = @import("../plugin/call_context.zig");
const clap_ids = @import("../util/clap_ids.zig");
const midi_input = @import("../midi/input.zig");
const audio_engine_mod = @import("../audio/audio_engine.zig");
const audio_graph = @import("../audio/audio_graph.zig");
const audio_constants = @import("../audio/audio_constants.zig");
const audio_events = @import("../audio/audio_events.zig");
const thread_context = @import("../util/thread_context.zig");
const project_plugin_state = @import("../project/runtime/plugin_state.zig");

const PluginCatalog = plugins.PluginCatalog;
const PluginEntry = plugins.PluginEntry;
pub const PresetCatalog = presets_mod.PresetCatalog;
pub const PresetEntry = presets_mod.PresetEntry;
pub const LoadedPlugin = plugin_handle.LoadedPlugin;
const PluginHandle = plugin_handle.PluginHandle;
pub const track_count = plugin_handle.track_count;
pub const max_fx_slots = plugin_handle.max_fx_slots;
const AudioEngine = audio_engine_mod.AudioEngine;

const clock_io: std.Io = std.Io.Threaded.global_single_threaded.io();
const max_gui_timers = 64;
const max_gui_fds = 64;

const GuiTimer = struct {
    plugin: *const clap.Plugin,
    timer_id: clap.Id,
    period_ms: u32,
    next_fire_ns: u64,
    active: bool = false,
};

const GuiFd = struct {
    plugin: *const clap.Plugin,
    fd: c_int,
    flags: clap.ext.posix_fd_support.Flags,
    active: bool = false,
};

/// UI choice for one device slot (instrument or FX).
pub const SlotChoice = struct {
    choice_index: i32 = 0,
    enabled: bool = true,
};

/// Deferred `clap.preset-load` request for a track instrument.
///
/// Strings are host-owned copies: the preset catalog resets its arena on the
/// next browser query, and the request outlives that when the instrument still
/// has to be loaded from disk first.
const PendingPreset = struct {
    plugin_id: []u8,
    location: [:0]u8,
    load_key: ?[:0]u8,
    location_kind: clap.preset_discovery.Location.Kind,
    /// Catalog choice this preset belongs to; the request is dropped if the
    /// user picks a different instrument before the load completes.
    choice_index: i32,
};

pub const PluginHost = struct {
    allocator: std.mem.Allocator,
    catalog: PluginCatalog = undefined,
    catalog_ready: bool = false,
    /// Optional CLAP preset discovery DB (sounds/drums/… browser categories).
    preset_catalog: ?PresetCatalog = null,

    clap_host: clap.Host = undefined,
    main_thread_id: std.Thread.Id = undefined,

    /// Shared with `audio_runtime` JobQueue (CLAP thread_pool + graph parallel).
    jobs: ?*audio_graph.JobQueue = null,
    /// Max worker fan-out for `thread_pool.requestExec` (from FLUX_AUDIO tuning).
    jobs_fanout: u32 = 0,
    /// Engine shared state for `requestProcess` / buffer reconfigure.
    shared_state: ?*audio_engine_mod.SharedState = null,

    callback_requested: std.atomic.Value(bool) = .init(false),
    flush_requested: std.atomic.Value(bool) = .init(false),
    params_rescan_requested: std.atomic.Value(bool) = .init(false),

    instruments: [track_count]LoadedPlugin = @splat(.{}),
    fx: [track_count][max_fx_slots]LoadedPlugin = @splat(@splat(.{})),

    /// Desired chain (user selections). Sync loads/unloads to match.
    instrument_choice: [track_count]SlotChoice = @splat(.{}),
    fx_choice: [track_count][max_fx_slots]SlotChoice = @splat(@splat(.{})),
    /// Leading occupied FX slots per track (packed).
    fx_counts: [track_count]usize = @splat(0),

    /// Project state is queued while the corresponding DynLib is loaded on the
    /// next host tick. Buffers are owned by this host, not the project arena.
    pending_instrument_state: [track_count]?[]u8 = @splat(null),
    pending_fx_state: [track_count][max_fx_slots]?[]u8 = @splat(@splat(null)),

    /// Preset requests waiting for their instrument instance (see `PendingPreset`).
    pending_preset: [track_count]?PendingPreset = @splat(null),

    /// Device-card preset combo selection (list index into the filtered preset
    /// dropdown for that track's current instrument). Null = none / placeholder.
    instrument_preset_list_index: [track_count]?usize = @splat(null),

    /// Computer-keyboard MIDI (physical A–; positions) → merged into live keys.
    keyboard_octave: i8 = 0,
    keyboard_notes: [128]bool = @splat(false),
    keyboard_velocities: [128]f32 = @splat(0),
    /// Per-track live keys published to the engine (keyboard + hardware MIDI).
    live_key_states: [track_count][128]bool = @splat(@splat(false)),
    live_key_velocities: [track_count][128]f32 = @splat(@splat(0)),

    /// Hardware MIDI (portmidi). Optional — disabled if init fails.
    midi: midi_input.MidiInput = .{},
    midi_active: bool = false,

    /// Picker open in device chain ("+" or empty instrument).
    picker_open: bool = false,
    picker_for_fx: bool = false,

    // ── CLAP host extension state ──────────────────────────────────────────
    gui_timers: [max_gui_timers]GuiTimer = @splat(.{
        .plugin = undefined,
        .timer_id = .invalid_id,
        .period_ms = 0,
        .next_fire_ns = 0,
    }),
    next_gui_timer_id: u32 = 1,
    gui_fds: [max_gui_fds]GuiFd = @splat(.{
        .plugin = undefined,
        .fd = -1,
        .flags = .{ ._ = 0 },
    }),

    undo_change_in_progress: bool = false,
    undo_track_index: ?usize = null,
    undo_fx_index: ?usize = null,
    undo_pre_state: ?[]u8 = null,

    /// Last undo-context snapshot pushed to subscribed plugins (dirty compare).
    undo_ctx_last_can_undo: bool = false,
    undo_ctx_last_can_redo: bool = false,
    undo_ctx_last_undo_name: [64]u8 = @splat(0),
    undo_ctx_last_undo_name_len: usize = 0,
    undo_ctx_last_redo_name: [64]u8 = @splat(0),
    undo_ctx_last_redo_name_len: usize = 0,
    /// Force a context push even if can_undo/names match (new subscriber).
    undo_ctx_force: bool = false,
    /// Scratch null-terminated name buffers for PluginContext callbacks.
    undo_ctx_name_buf: [64]u8 = @splat(0),
    redo_ctx_name_buf: [64]u8 = @splat(0),

    pub fn init(allocator: std.mem.Allocator) PluginHost {
        return .{
            .allocator = allocator,
            .main_thread_id = std.Thread.getCurrentId(),
        };
    }

    pub fn start(self: *PluginHost) void {
        self.clap_host = .{
            .clap_version = clap.version,
            .host_data = self,
            .name = "flux",
            .vendor = "gearmulator",
            .url = null,
            .version = "0.1",
            .getExtension = hostGetExtension,
            .requestRestart = hostRequestRestart,
            .requestProcess = hostRequestProcess,
            .requestCallback = hostRequestCallback,
        };

        const catalog = plugins.discover(self.allocator, clock_io) catch |err| {
            std.log.warn("plugin catalog discovery failed: {} (device chain stays empty)", .{err});
            return;
        };
        self.catalog = catalog;
        self.catalog_ready = true;
        std.log.info("plugin catalog: {d} entries ({d} instruments, {d} fx)", .{
            self.catalog.entries.items.len,
            self.catalog.instrument_indices.len,
            self.catalog.fx_indices.len,
        });

        // Best-effort CLAP preset discovery → SQLite; Sounds/Drums/… query it.
        // Samples still come from user Places folders when the index is empty.
        self.preset_catalog = presets_mod.build(self.allocator, clock_io, &self.catalog) catch |err| blk: {
            std.log.warn("preset catalog disabled: {}", .{err});
            break :blk null;
        };
        if (self.preset_catalog != null) {
            std.log.info("preset catalog ready", .{});
        }

        self.midi.init(self.allocator) catch |err| {
            std.log.warn("hardware MIDI disabled: {}", .{err});
            self.midi.disable();
            self.midi_active = false;
            return;
        };
        self.midi_active = true;
        std.log.info("hardware MIDI (portmidi) ready", .{});
    }

    pub fn deinit(self: *PluginHost) void {
        clearUndoChange(self);
        self.clearPendingProjectStates();
        self.closeAllGuis();
        self.unloadAll(null);
        self.jobs = null;
        self.shared_state = null;
        if (self.midi_active) {
            self.midi.deinit();
            self.midi_active = false;
        }
        if (self.preset_catalog) |*pc| {
            pc.deinit();
            self.preset_catalog = null;
        }
        if (self.catalog_ready) {
            self.catalog.deinit();
            self.catalog_ready = false;
        }
        self.* = undefined;
    }

    /// Query preset DB for the active browser category (empty when unavailable).
    pub fn queryPresets(self: *PluginHost, text: []const u8, category: []const u8, ascending: bool) []const PresetEntry {
        const catalog = if (self.preset_catalog) |*pc| pc else return &.{};
        catalog.query(text, category, ascending) catch return &.{};
        return catalog.entries.items;
    }

    /// Load the instrument referenced by a preset entry and queue the CLAP
    /// `preset-load` request; it is applied once the instance exists
    /// (zgui `applyPresetLoadRequests` parity).
    pub fn loadPresetOnTrack(self: *PluginHost, track: usize, entry: PresetEntry) void {
        if (track >= track_count) return;
        if (entry.catalog_index <= 0) {
            std.log.warn("preset '{s}' has no catalog plugin ({s})", .{ entry.name, entry.plugin_id });
            return;
        }
        if (entry.catalog_index != self.instrument_choice[track].choice_index) {
            self.setInstrumentChoice(track, entry.catalog_index);
        }
        self.queuePresetLoad(track, entry) catch |err| {
            std.log.warn("preset load request dropped: {}", .{err});
        };
    }

    /// Apply a preset from the device-card combo and remember the list index
    /// so the dropdown stays on the chosen row after rebuild.
    pub fn loadPresetOnTrackFromList(self: *PluginHost, track: usize, list_index: usize, entry: PresetEntry) void {
        if (track >= track_count) return;
        self.instrument_preset_list_index[track] = list_index;
        self.loadPresetOnTrack(track, entry);
    }

    fn queuePresetLoad(self: *PluginHost, track: usize, entry: PresetEntry) !void {
        self.clearPendingPreset(track);

        const plugin_id = try self.allocator.dupe(u8, entry.plugin_id);
        errdefer self.allocator.free(plugin_id);
        const location = try self.allocator.dupeSentinel(u8, entry.location_z, 0);
        errdefer self.allocator.free(location);
        const load_key: ?[:0]u8 = if (entry.load_key_z) |key|
            try self.allocator.dupeSentinel(u8, key, 0)
        else
            null;

        self.pending_preset[track] = .{
            .plugin_id = plugin_id,
            .location = location,
            .load_key = load_key,
            .location_kind = entry.location_kind,
            .choice_index = entry.catalog_index,
        };
    }

    fn clearPendingPreset(self: *PluginHost, track: usize) void {
        const req = self.pending_preset[track] orelse return;
        self.allocator.free(req.plugin_id);
        self.allocator.free(req.location);
        if (req.load_key) |key| self.allocator.free(key);
        self.pending_preset[track] = null;
    }

    /// Apply queued preset requests whose instrument instance is ready.
    /// Requests are dropped when the choice changed or the load failed.
    fn applyPendingPresets(self: *PluginHost) void {
        for (0..track_count) |track| {
            const req = self.pending_preset[track] orelse continue;

            // Instrument swapped (or load failed and reset the choice to None).
            if (self.instrument_choice[track].choice_index != req.choice_index) {
                self.clearPendingPreset(track);
                continue;
            }
            const entry_id = self.entryOrNone(req.choice_index).id;
            if (entry_id == null or !std.mem.eql(u8, entry_id.?, req.plugin_id)) {
                self.clearPendingPreset(track);
                continue;
            }
            // Still loading from disk — retry next tick.
            const plugin = self.instruments[track].getPlugin() orelse continue;

            applyPresetToPlugin(plugin, req);
            self.clearPendingPreset(track);
        }
    }

    pub fn unloadAll(self: *PluginHost, engine: ?*AudioEngine) void {
        self.closeAllGuis();
        for (0..track_count) |t| self.clearPendingPreset(t);
        const shared = if (engine) |e| &e.shared else null;
        for (&self.instruments, 0..) |*slot, t| {
            if (shared) |s| s.setTrackPlugin(t, null);
            plugin_handle.unloadInstrument(slot, self.allocator, shared, t);
            slot.choice_index = -1;
        }
        for (&self.fx, 0..) |*row, t| {
            for (row, 0..) |*slot, fx_i| {
                if (shared) |s| s.setTrackFxPlugin(t, fx_i, null);
                plugin_handle.unloadFx(slot, self.allocator, shared, t, fx_i);
                slot.choice_index = -1;
            }
        }
        if (shared) |s| s.waitForIdle(clock_io);
    }

    /// Set instrument for track from catalog index. 0 = None.
    pub fn setInstrumentChoice(self: *PluginHost, track: usize, choice: i32) void {
        if (track >= track_count) return;
        self.clearPendingInstrumentState(track);
        // A queued preset belongs to the previous selection.
        self.clearPendingPreset(track);
        // Device-card combo selection is per-instrument; reset on swap.
        if (self.instrument_choice[track].choice_index != choice) {
            self.instrument_preset_list_index[track] = null;
        }
        self.instrument_choice[track].choice_index = choice;
    }

    /// Append or set FX slot. Returns false if chain full / invalid.
    pub fn setFxChoice(self: *PluginHost, track: usize, fx_index: usize, choice: i32) bool {
        if (track >= track_count or fx_index >= max_fx_slots) return false;
        self.clearPendingFxState(track, fx_index);
        self.fx_choice[track][fx_index].choice_index = choice;
        if (choice != 0) {
            self.fx_counts[track] = @max(self.fx_counts[track], fx_index + 1);
            // Keep one empty trailing slot for "+" when space remains.
            if (self.fx_counts[track] < max_fx_slots and
                self.fx_choice[track][self.fx_counts[track]].choice_index == 0)
            {
                // count already covers packed prefix
            }
        } else {
            // Compact trailing empties.
            var n = self.fx_counts[track];
            while (n > 0 and self.fx_choice[track][n - 1].choice_index == 0) : (n -= 1) {}
            self.fx_counts[track] = n;
        }
        return true;
    }

    pub fn addFxSlot(self: *PluginHost, track: usize, choice: i32) bool {
        if (track >= track_count) return false;
        const n = self.fx_counts[track];
        if (n >= max_fx_slots) return false;
        self.fx_choice[track][n].choice_index = choice;
        self.fx_choice[track][n].enabled = true;
        self.fx_counts[track] = n + 1;
        return true;
    }

    pub fn clearInstrument(self: *PluginHost, track: usize) void {
        self.setInstrumentChoice(track, 0);
    }

    /// Remove one FX slot and compact the chain left.
    /// Moves live `LoadedPlugin` instances with their choices so neighbours are
    /// not unloaded/reloaded (zgui `applyChainOpRequest` / `remove_fx` parity).
    pub fn removeFx(self: *PluginHost, track: usize, fx_index: usize, engine: ?*AudioEngine) void {
        if (track >= track_count or fx_index >= self.fx_counts[track]) return;
        const shared = if (engine) |e| &e.shared else null;

        self.quiesceFxRange(shared, track, fx_index, max_fx_slots - 1);

        self.closeGuiBeforeUnload(&self.fx[track][fx_index]);
        plugin_handle.unloadFx(&self.fx[track][fx_index], self.allocator, shared, track, fx_index);
        self.clearPendingFxState(track, fx_index);

        var i = fx_index;
        while (i + 1 < max_fx_slots) : (i += 1) {
            if (shared) |s| writeFxSlotFlags(s, track, i, readFxSlotFlags(s, track, i + 1));
            self.fx[track][i] = self.fx[track][i + 1];
            self.fx_choice[track][i] = self.fx_choice[track][i + 1];
            self.pending_fx_state[track][i] = self.pending_fx_state[track][i + 1];
            self.pending_fx_state[track][i + 1] = null;
        }
        self.fx[track][max_fx_slots - 1] = .{};
        self.fx_choice[track][max_fx_slots - 1] = .{};
        // pending at last is already null after the shift loop
        if (shared) |s| writeFxSlotFlags(s, track, max_fx_slots - 1, .{});

        if (self.fx_counts[track] > 0) self.fx_counts[track] -= 1;
    }

    /// Reorder one FX slot within the packed prefix without reloading plugins.
    pub fn moveFx(self: *PluginHost, track: usize, from: usize, to: usize, engine: ?*AudioEngine) void {
        if (track >= track_count) return;
        const n = self.fx_counts[track];
        if (from == to or from >= n or to >= n) return;
        const shared = if (engine) |e| &e.shared else null;
        const lo = @min(from, to);
        const hi = @max(from, to);
        self.quiesceFxRange(shared, track, lo, hi);

        const runtime = self.fx[track][from];
        const choice = self.fx_choice[track][from];
        const pending = self.pending_fx_state[track][from];
        const flags: FxSlotFlags = if (shared) |s| readFxSlotFlags(s, track, from) else .{};

        if (from < to) {
            var i = from;
            while (i < to) : (i += 1) {
                if (shared) |s| writeFxSlotFlags(s, track, i, readFxSlotFlags(s, track, i + 1));
                self.fx[track][i] = self.fx[track][i + 1];
                self.fx_choice[track][i] = self.fx_choice[track][i + 1];
                self.pending_fx_state[track][i] = self.pending_fx_state[track][i + 1];
            }
        } else {
            var i = from;
            while (i > to) : (i -= 1) {
                if (shared) |s| writeFxSlotFlags(s, track, i, readFxSlotFlags(s, track, i - 1));
                self.fx[track][i] = self.fx[track][i - 1];
                self.fx_choice[track][i] = self.fx_choice[track][i - 1];
                self.pending_fx_state[track][i] = self.pending_fx_state[track][i - 1];
            }
        }
        self.fx[track][to] = runtime;
        self.fx_choice[track][to] = choice;
        self.pending_fx_state[track][to] = pending;
        if (shared) |s| writeFxSlotFlags(s, track, to, flags);
    }

    /// Insert a copy of the FX immediately after `fx_index`, cloning CLAP state
    /// onto the new instance once sync loads it. Returns false if full/invalid.
    pub fn duplicateFx(self: *PluginHost, track: usize, fx_index: usize, engine: ?*AudioEngine) bool {
        if (track >= track_count) return false;
        const n = self.fx_counts[track];
        if (fx_index >= n or n >= max_fx_slots) return false;

        const source_state: ?[]u8 = if (self.fx[track][fx_index].getPlugin()) |plugin|
            project_plugin_state.capturePluginStateForUndo(self.allocator, plugin)
        else
            null;

        const insert_at = fx_index + 1;
        const shared = if (engine) |e| &e.shared else null;
        self.quiesceFxRange(shared, track, insert_at, max_fx_slots - 1);

        // Shift the tail right to open a slot after the source.
        var i: usize = max_fx_slots - 1;
        while (i > insert_at) : (i -= 1) {
            if (shared) |s| writeFxSlotFlags(s, track, i, readFxSlotFlags(s, track, i - 1));
            self.fx[track][i] = self.fx[track][i - 1];
            self.fx_choice[track][i] = self.fx_choice[track][i - 1];
            self.pending_fx_state[track][i] = self.pending_fx_state[track][i - 1];
        }

        // Fresh runtime: choice mismatch makes syncFx load a new instance.
        self.fx[track][insert_at] = .{};
        self.fx_choice[track][insert_at] = self.fx_choice[track][fx_index];
        self.fx_choice[track][insert_at].enabled = self.fx_choice[track][fx_index].enabled;
        self.pending_fx_state[track][insert_at] = null;
        if (shared) |s| writeFxSlotFlags(s, track, insert_at, .{});

        if (source_state) |data| {
            self.clearPendingFxState(track, insert_at);
            self.pending_fx_state[track][insert_at] = data;
        }

        self.fx_counts[track] = n + 1;
        return true;
    }

    const FxSlotFlags = struct {
        started: bool = false,
        need_start: bool = false,
    };

    fn readFxSlotFlags(shared: *audio_engine_mod.SharedState, track: usize, fx_index: usize) FxSlotFlags {
        return .{
            .started = shared.isFxPluginStarted(track, fx_index),
            .need_start = shared.plugins_need_start_fx[track][fx_index].load(.acquire),
        };
    }

    fn writeFxSlotFlags(shared: *audio_engine_mod.SharedState, track: usize, fx_index: usize, flags: FxSlotFlags) void {
        if (flags.started) {
            shared.markFxPluginStarted(track, fx_index);
        } else {
            shared.clearFxPluginStarted(track, fx_index);
        }
        shared.plugins_need_start_fx[track][fx_index].store(flags.need_start, .release);
    }

    /// Detach RT from FX slots [first, last] and wait for the audio callback to finish.
    fn quiesceFxRange(self: *PluginHost, shared: ?*audio_engine_mod.SharedState, track: usize, first: usize, last: usize) void {
        _ = self;
        const s = shared orelse return;
        if (first > last or last >= max_fx_slots) return;
        var i = first;
        while (i <= last) : (i += 1) {
            s.setTrackFxPlugin(track, i, null);
        }
        s.waitForIdle(clock_io);
    }

    pub fn entryName(self: *const PluginHost, choice: i32) []const u8 {
        if (!self.catalog_ready) return "";
        const entry = self.catalog.entryForIndex(choice) orelse return "";
        if (entry.kind == .none or entry.kind == .divider) return "";
        return entry.name;
    }

    /// Project loaded names/enable into document host for chrome.
    pub fn projectToDocumentHost(self: *const PluginHost, host: *host_mod.Host) void {
        for (0..@min(track_count, chrome.max_tracks)) |t| {
            host.instrument_names[t] = self.entryName(self.instrument_choice[t].choice_index);
            host.instrument_enabled[t] = self.instrument_choice[t].enabled;
            const n = @min(self.fx_counts[t], chrome.max_fx_slots);
            host.fx_counts[t] = n;
            for (0..n) |fx| {
                host.fx_names[t][fx] = self.entryName(self.fx_choice[t][fx].choice_index);
                host.fx_enabled[t][fx] = self.fx_choice[t][fx].enabled;
            }
            for (n..chrome.max_fx_slots) |fx| {
                host.fx_names[t][fx] = "";
                host.fx_enabled[t][fx] = true;
            }
        }
    }

    /// Sync DynLib instances to choices and publish pointers to the engine.
    pub fn tick(self: *PluginHost, engine: ?*AudioEngine, max_frames: u32) void {
        if (engine) |e| self.shared_state = &e.shared;
        const shared = if (engine) |e| &e.shared else null;
        self.syncInstruments(shared, max_frames);
        self.syncFx(shared, max_frames);
        self.applyPendingProjectStates();
        self.applyPendingPresets();
        if (engine) |e| {
            const snap = plugin_handle.collectLoaded(&self.instruments, &self.fx);
            e.updatePlugins(snap.instruments, snap.fx);
        }
        // Host services: all loaded plugins (not only open GUIs), then GUI windows.
        pumpMainThreadCallbacks(self);
        pumpParamRescans(self);
        pumpParamFlushes(self);
        pumpPluginGuiEvents(self, clock_io);
        pumpUndoContextUpdates(self);
        self.pumpOpenGuis();
    }

    /// Stop/deactivate/reactivate every loaded plugin at a new max block size.
    /// Caller must stop the device and wait for the audio callback to go idle.
    pub fn reconfigureMaxFrames(self: *PluginHost, shared: *audio_engine_mod.SharedState, new_frames: u32) void {
        const was_audio = thread_context.is_audio_thread;
        thread_context.is_audio_thread = true;
        defer thread_context.is_audio_thread = was_audio;

        for (0..track_count) |t| {
            if (shared.isPluginStarted(t)) {
                if (self.instruments[t].getPlugin()) |plugin| {
                    plugin.stopProcessing(plugin);
                }
                shared.clearPluginStarted(t);
            }
            for (0..max_fx_slots) |fx_index| {
                if (shared.isFxPluginStarted(t, fx_index)) {
                    if (self.fx[t][fx_index].getPlugin()) |plugin| {
                        plugin.stopProcessing(plugin);
                    }
                    shared.clearFxPluginStarted(t, fx_index);
                }
            }
        }

        for (0..track_count) |t| {
            if (self.instruments[t].getPlugin()) |plugin| {
                plugin.deactivate(plugin);
                if (!plugin.activate(plugin, audio_constants.sample_rate, 1, new_frames)) {
                    std.log.warn("Failed to re-activate instrument track {d} at {d} frames", .{ t, new_frames });
                } else {
                    shared.requestStartProcessing(t);
                }
            }
            for (0..max_fx_slots) |fx_index| {
                if (self.fx[t][fx_index].getPlugin()) |plugin| {
                    plugin.deactivate(plugin);
                    if (!plugin.activate(plugin, audio_constants.sample_rate, 1, new_frames)) {
                        std.log.warn("Failed to re-activate fx track {d} slot {d} at {d} frames", .{ t, fx_index, new_frames });
                    } else {
                        shared.requestStartProcessingFx(t, fx_index);
                    }
                }
            }
        }
    }

    /// Apply a serialized CLAP state blob to a slot (document undo/redo).
    pub fn applyPluginStateBlob(self: *PluginHost, track: usize, fx_index: ?usize, data: []const u8) bool {
        if (track >= track_count) return false;
        const plugin = if (fx_index) |fx| blk: {
            if (fx >= max_fx_slots) return false;
            break :blk self.fx[track][fx].getPlugin();
        } else self.instruments[track].getPlugin();
        const p = plugin orelse return false;
        project_plugin_state.loadPluginStateFromData(p, data);
        return true;
    }

    /// CLAP plugin for the device-chain chrome target (instrument or FX slot).
    pub fn deviceTargetPlugin(self: *PluginHost, state: *const chrome.State) ?*const clap.Plugin {
        const slot = self.selectedSlot(state) orelse return null;
        return slot.getPlugin();
    }

    /// Retain serialized CLAP state until the selected plugin has been loaded.
    pub fn queueProjectState(self: *PluginHost, track: usize, fx_index: ?usize, data: []const u8) !void {
        if (track >= track_count) return error.InvalidTrack;
        const owned = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(owned);
        if (fx_index) |fx| {
            if (fx >= max_fx_slots) return error.InvalidFxSlot;
            self.clearPendingFxState(track, fx);
            self.pending_fx_state[track][fx] = owned;
        } else {
            self.clearPendingInstrumentState(track);
            self.pending_instrument_state[track] = owned;
        }
    }

    pub fn clearPendingProjectStates(self: *PluginHost) void {
        for (0..track_count) |track| {
            self.clearPendingInstrumentState(track);
            for (0..max_fx_slots) |fx| self.clearPendingFxState(track, fx);
        }
    }

    fn clearPendingInstrumentState(self: *PluginHost, track: usize) void {
        if (self.pending_instrument_state[track]) |data| self.allocator.free(data);
        self.pending_instrument_state[track] = null;
    }

    fn clearPendingFxState(self: *PluginHost, track: usize, fx: usize) void {
        if (self.pending_fx_state[track][fx]) |data| self.allocator.free(data);
        self.pending_fx_state[track][fx] = null;
    }

    fn applyPendingProjectStates(self: *PluginHost) void {
        for (0..track_count) |track| {
            if (self.pending_instrument_state[track]) |data| {
                if (self.instruments[track].getPlugin()) |plugin| {
                    project_plugin_state.loadPluginStateFromData(plugin, data);
                    self.clearPendingInstrumentState(track);
                } else if (self.instrument_choice[track].choice_index == 0) {
                    self.clearPendingInstrumentState(track);
                }
            }
            for (0..max_fx_slots) |fx| {
                if (self.pending_fx_state[track][fx]) |data| {
                    if (self.fx[track][fx].getPlugin()) |plugin| {
                        project_plugin_state.loadPluginStateFromData(plugin, data);
                        self.clearPendingFxState(track, fx);
                    } else if (self.fx_choice[track][fx].choice_index == 0) {
                        self.clearPendingFxState(track, fx);
                    }
                }
            }
        }
    }

    /// Poll hardware MIDI + merge keyboard/hardware into live keys for `target_track`.
    /// `preview_pitch` is the piano-roll audition note (drag / keyboard strip).
    pub fn tickLiveMidi(self: *PluginHost, target_track: usize, preview_pitch: ?u8) void {
        if (self.midi_active) self.midi.poll();

        self.live_key_states = @splat(@splat(false));
        self.live_key_velocities = @splat(@splat(0));

        var pressed: [128]bool = self.keyboard_notes;
        var vels: [128]f32 = self.keyboard_velocities;
        if (self.midi_active) {
            for (0..128) |n| {
                if (self.midi.note_states[n]) {
                    pressed[n] = true;
                    vels[n] = @max(vels[n], self.midi.note_velocities[n]);
                }
            }
        }
        if (preview_pitch) |pitch| {
            pressed[pitch] = true;
            vels[pitch] = @max(vels[pitch], 0.8);
        }
        if (target_track < track_count) {
            self.live_key_states[target_track] = pressed;
            self.live_key_velocities[target_track] = vels;
        }
    }

    // ── Floating plugin GUI ────────────────────────────────────────────────

    pub fn selectedSlot(self: *PluginHost, state: *const chrome.State) ?*LoadedPlugin {
        const t = state.deviceTrack();
        if (t >= track_count) return null;
        return switch (state.device_target_kind) {
            .instrument => if (state.mixer_target == .master) null else &self.instruments[t],
            .fx => blk: {
                if (state.device_target_fx >= max_fx_slots) break :blk null;
                break :blk &self.fx[t][state.device_target_fx];
            },
        };
    }

    pub fn openSelectedGui(self: *PluginHost, state: *const chrome.State) void {
        const slot = self.selectedSlot(state) orelse return;
        self.openSlotGui(slot);
    }

    pub fn closeSelectedGui(self: *PluginHost, state: *const chrome.State) void {
        const slot = self.selectedSlot(state) orelse return;
        self.closeSlotGui(slot);
    }

    pub fn toggleSelectedGui(self: *PluginHost, state: *const chrome.State) void {
        const slot = self.selectedSlot(state) orelse return;
        if (slot.gui_open) {
            self.closeSlotGui(slot);
        } else {
            self.openSlotGui(slot);
        }
    }

    fn openSlotGui(self: *PluginHost, slot: *LoadedPlugin) void {
        _ = self;
        if (slot.gui_open) return;
        gui_float.open(slot) catch |err| {
            std.log.warn("plugin GUI open failed: {}", .{err});
        };
    }

    fn closeSlotGui(self: *PluginHost, slot: *LoadedPlugin) void {
        _ = self;
        gui_float.close(slot);
    }

    pub fn closeAllGuis(self: *PluginHost) void {
        for (&self.instruments) |*slot| self.closeSlotGui(slot);
        for (&self.fx) |*row| {
            for (row) |*slot| self.closeSlotGui(slot);
        }
    }

    fn pumpOpenGuis(self: *PluginHost) void {
        for (&self.instruments) |*slot| {
            if (!slot.gui_open) continue;
            if (gui_float.pumpHostWindow(slot)) {
                self.closeSlotGui(slot);
                continue;
            }
            if (slot.getPlugin()) |p| gui_float.pumpOnMainThread(p);
        }
        for (&self.fx) |*row| {
            for (row) |*slot| {
                if (!slot.gui_open) continue;
                if (gui_float.pumpHostWindow(slot)) {
                    self.closeSlotGui(slot);
                    continue;
                }
                if (slot.getPlugin()) |p| gui_float.pumpOnMainThread(p);
            }
        }
    }

    /// Close GUI before unloading when choice changes.
    fn closeGuiBeforeUnload(self: *PluginHost, slot: *LoadedPlugin) void {
        self.closeSlotGui(slot);
    }

    fn syncInstruments(self: *PluginHost, shared: ?*audio_engine_mod.SharedState, max_frames: u32) void {
        for (&self.instruments, 0..) |*slot, t| {
            const choice = self.instrument_choice[t].choice_index;
            const entry = self.entryOrNone(choice);
            const kind = entry.kind;

            if (kind == .none or kind == .divider) {
                if (slot.isLoaded()) {
                    self.closeGuiBeforeUnload(slot);
                    if (shared) |s| {
                        s.setTrackPlugin(t, null);
                        s.waitForIdle(clock_io);
                    }
                    plugin_handle.unloadInstrument(slot, self.allocator, shared, t);
                }
                slot.choice_index = choice;
                continue;
            }

            if (slot.choice_index != choice) {
                if (slot.isLoaded()) {
                    self.closeGuiBeforeUnload(slot);
                    if (shared) |s| {
                        s.setTrackPlugin(t, null);
                        s.waitForIdle(clock_io);
                    }
                    plugin_handle.unloadInstrument(slot, self.allocator, shared, t);
                }
                slot.choice_index = choice;
            }

            if (!slot.isLoaded()) {
                self.loadSlot(slot, entry, max_frames) catch |err| {
                    std.log.warn("instrument load failed track={d} {s}: {}", .{ t, entry.name, err });
                    self.instrument_choice[t].choice_index = 0;
                    slot.choice_index = 0;
                    continue;
                };
                if (shared) |s| s.requestStartProcessing(t);
            }
        }
    }

    fn syncFx(self: *PluginHost, shared: ?*audio_engine_mod.SharedState, max_frames: u32) void {
        for (&self.fx, 0..) |*row, t| {
            for (row, 0..) |*slot, fx_i| {
                const choice = self.fx_choice[t][fx_i].choice_index;
                const entry = self.entryOrNone(choice);
                const kind = entry.kind;

                if (kind == .none or kind == .divider) {
                    if (slot.isLoaded()) {
                        self.closeGuiBeforeUnload(slot);
                        if (shared) |s| {
                            s.setTrackFxPlugin(t, fx_i, null);
                            s.waitForIdle(clock_io);
                        }
                        plugin_handle.unloadFx(slot, self.allocator, shared, t, fx_i);
                    }
                    slot.choice_index = choice;
                    continue;
                }

                if (slot.choice_index != choice) {
                    if (slot.isLoaded()) {
                        self.closeGuiBeforeUnload(slot);
                        if (shared) |s| {
                            s.setTrackFxPlugin(t, fx_i, null);
                            s.waitForIdle(clock_io);
                        }
                        plugin_handle.unloadFx(slot, self.allocator, shared, t, fx_i);
                    }
                    slot.choice_index = choice;
                }

                if (!slot.isLoaded()) {
                    self.loadSlot(slot, entry, max_frames) catch |err| {
                        std.log.warn("fx load failed track={d} slot={d} {s}: {}", .{ t, fx_i, entry.name, err });
                        self.fx_choice[t][fx_i].choice_index = 0;
                        slot.choice_index = 0;
                        continue;
                    };
                    if (slot.getPlugin()) |plugin| {
                        if (!plugin_handle.pluginHasAudioInput(plugin)) {
                            std.log.warn("FX has no audio input, unloading: {s}", .{entry.name});
                            if (shared) |s| {
                                s.setTrackFxPlugin(t, fx_i, null);
                                s.waitForIdle(clock_io);
                            }
                            plugin_handle.unloadFx(slot, self.allocator, shared, t, fx_i);
                            self.fx_choice[t][fx_i].choice_index = 0;
                            slot.choice_index = 0;
                            continue;
                        }
                    }
                    if (shared) |s| s.requestStartProcessingFx(t, fx_i);
                }
            }
        }
    }

    fn entryOrNone(self: *const PluginHost, choice: i32) PluginEntry {
        if (!self.catalog_ready or choice <= 0) {
            return .{ .kind = .none, .name = "None" };
        }
        return self.catalog.entryForIndex(choice) orelse .{ .kind = .none, .name = "None" };
    }

    /// Load a catalog entry: Flux built-ins (instruments + stock FX) are linked
    /// in-process; external CLAPs come from DynLib bundles.
    fn loadSlot(self: *PluginHost, slot: *LoadedPlugin, entry: PluginEntry, max_frames: u32) !void {
        switch (entry.kind) {
            .builtin => {
                const id = entry.id orelse return error.PluginMissingId;
                if (builtin_load.isStaticFxId(id)) {
                    try builtin_load.loadStaticFx(slot, self.allocator, &self.clap_host, id, max_frames);
                    return;
                }
                if (builtin_load.isStaticInstrumentId(id)) {
                    try builtin_load.loadStaticInstrument(slot, self.allocator, &self.clap_host, id, max_frames);
                    return;
                }
                return error.UnknownBuiltin;
            },
            .clap => {
                const path = entry.path orelse return error.PluginMissingPath;
                _ = std.Io.Dir.cwd().statFile(clock_io, path, .{}) catch return error.PluginFileMissing;
                slot.handle = try PluginHandle.init(
                    self.allocator,
                    &self.clap_host,
                    path,
                    entry.id,
                    max_frames,
                );
            },
            .none, .divider => return error.InvalidPluginKind,
        }
    }

    // ── Keyboard MIDI ──────────────────────────────────────────────────────

    pub fn clearKeyboardNotes(self: *PluginHost) void {
        self.keyboard_notes = @splat(false);
        self.keyboard_velocities = @splat(0);
    }

    pub fn clearLiveKeys(self: *PluginHost) void {
        self.clearKeyboardNotes();
        self.live_key_states = @splat(@splat(false));
        self.live_key_velocities = @splat(@splat(0));
    }

    /// Piano-map note: `offset` semitones above C of the current keyboard octave.
    /// Updates keyboard note state; call `tickLiveMidi` to publish to engine.
    pub fn applyKeyboardNote(
        self: *PluginHost,
        track: usize,
        offset: u8,
        down: bool,
    ) void {
        _ = track;
        const base: i16 = 60 + @as(i16, self.keyboard_octave) * 12;
        const pitch_i = base + @as(i16, @intCast(offset));
        if (pitch_i < 0 or pitch_i > 127) return;
        const note: u8 = @intCast(pitch_i);
        self.keyboard_notes[note] = down;
        self.keyboard_velocities[note] = if (down) 0.8 else 0;
    }

    // ── Catalog helpers for UI ─────────────────────────────────────────────

    pub fn instrumentChoices(self: *const PluginHost) []const i32 {
        if (!self.catalog_ready) return &.{};
        return self.catalog.instrument_indices;
    }

    pub fn fxChoices(self: *const PluginHost) []const i32 {
        if (!self.catalog_ready) return &.{};
        return self.catalog.fx_indices;
    }

    pub fn matchesSearch(self: *const PluginHost, choice: i32, filter: []const u8) bool {
        if (filter.len == 0) return true;
        const name = self.entryName(choice);
        if (name.len == 0) return false;
        // Case-insensitive substring.
        if (filter.len > name.len) return false;
        var i: usize = 0;
        while (i + filter.len <= name.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(name[i..][0..filter.len], filter)) return true;
        }
        return false;
    }
};

// ── CLAP host callbacks (full extension surface) ─────────────────────────────

const thread_check_ext = clap.ext.thread_check.Host{
    .isMainThread = hostIsMainThread,
    .isAudioThread = hostIsAudioThread,
};

const thread_pool_ext = clap.ext.thread_pool.Host{
    .requestExec = hostRequestExec,
};

const gui_host_ext = clap.ext.gui.Host{
    .resizeHintsChanged = hostGuiResizeHintsChanged,
    .requestResize = hostGuiRequestResize,
    .requestShow = hostGuiRequestShow,
    .requestHide = hostGuiRequestHide,
    .closed = hostGuiClosed,
};

const undo_host_ext = clap.ext.undo.Host{
    .begin_change = hostUndoBeginChange,
    .cancel_change = hostUndoCancelChange,
    .change_made = hostUndoChangeMade,
    .request_undo = hostUndoRequestUndo,
    .request_redo = hostUndoRequestRedo,
    .set_wants_context_updates = hostUndoSetWantsContextUpdates,
};

const params_host_ext = clap.ext.params.Host{
    .rescan = hostParamsRescan,
    .clear = hostParamsClear,
    .requestFlush = hostParamsRequestFlush,
};

const latency_host_ext = clap.ext.latency.Host{
    .changed = hostLatencyChanged,
};

const timer_support_ext = clap.ext.timer_support.Host{
    .registerTimer = hostTimerRegister,
    .unregisterTimer = hostTimerUnregister,
};

const posix_fd_support_ext = clap.ext.posix_fd_support.Host{
    .registerFd = hostPosixFdRegister,
    .modifyFd = hostPosixFdModify,
    .unregiserFd = hostPosixFdUnregister,
};

const preset_load_host_ext = clap.ext.preset_load.Host{
    .onError = hostPresetLoadError,
    .loaded = hostPresetLoadLoaded,
};

/// Call `preset-load.from_location` on a loaded instrument.
fn applyPresetToPlugin(plugin: *const clap.Plugin, req: PendingPreset) void {
    const ext_raw = plugin.getExtension(plugin, clap.ext.preset_load.id) orelse
        plugin.getExtension(plugin, clap_ids.preset_load_compat_id) orelse
        {
            std.log.warn("plugin does not support preset-load extension", .{});
            return;
        };
    const ext: *const clap.ext.preset_load.Plugin = @ptrCast(@alignCast(ext_raw));
    const load_key: ?[*:0]const u8 = if (req.load_key) |key| key.ptr else null;
    const location: ?[*:0]const u8 = if (req.location_kind == .plugin) null else req.location.ptr;
    if (!ext.fromLocation(plugin, req.location_kind, location, load_key)) {
        std.log.warn("preset load failed (plugin returned false)", .{});
    }
}

fn hostPresetLoadError(
    _: *const clap.Host,
    _: clap.preset_discovery.Location.Kind,
    _: ?[*:0]const u8,
    _: ?[*:0]const u8,
    os_error: i32,
    msg: [*:0]const u8,
) callconv(.c) void {
    std.log.warn("preset load error (os_error={d}): {s}", .{ os_error, std.mem.span(msg) });
}

fn hostPresetLoadLoaded(
    _: *const clap.Host,
    _: clap.preset_discovery.Location.Kind,
    _: ?[*:0]const u8,
    _: ?[*:0]const u8,
) callconv(.c) void {
    // Selection already lives in host state; nothing to reconcile yet.
}

fn hostFromData(host: *const clap.Host) *PluginHost {
    return @ptrCast(@alignCast(host.host_data));
}

fn hostGetExtension(host: *const clap.Host, extension_id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    _ = host;
    const id = std.mem.span(extension_id);
    if (std.mem.eql(u8, id, clap.ext.thread_check.id)) return &thread_check_ext;
    if (std.mem.eql(u8, id, clap.ext.thread_pool.id)) return &thread_pool_ext;
    if (std.mem.eql(u8, id, clap.ext.gui.id)) return &gui_host_ext;
    if (std.mem.eql(u8, id, clap.ext.undo.id)) return &undo_host_ext;
    if (std.mem.eql(u8, id, clap.ext.params.id)) return &params_host_ext;
    if (std.mem.eql(u8, id, clap.ext.latency.id)) return &latency_host_ext;
    if (std.mem.eql(u8, id, clap.ext.timer_support.id)) return &timer_support_ext;
    if (std.mem.eql(u8, id, clap.ext.posix_fd_support.id)) return &posix_fd_support_ext;
    if (std.mem.eql(u8, id, clap.ext.preset_load.id) or
        std.mem.eql(u8, id, clap_ids.preset_load_compat_id))
    {
        return &preset_load_host_ext;
    }
    return null;
}

fn hostRequestRestart(_: *const clap.Host) callconv(.c) void {}

fn hostRequestProcess(host: *const clap.Host) callconv(.c) void {
    const self = hostFromData(host);
    if (self.shared_state) |shared| {
        shared.process_requested.store(true, .release);
    }
}

fn hostRequestCallback(host: *const clap.Host) callconv(.c) void {
    const self = hostFromData(host);
    self.callback_requested.store(true, .release);
}

fn hostIsMainThread(host: *const clap.Host) callconv(.c) bool {
    const self = hostFromData(host);
    return std.Thread.getCurrentId() == self.main_thread_id;
}

fn hostIsAudioThread(_: *const clap.Host) callconv(.c) bool {
    return thread_context.is_audio_thread;
}

fn hostRequestExec(host: *const clap.Host, task_count: u32) callconv(.c) bool {
    if (task_count == 0) return true;

    const self = hostFromData(host);
    const plugin = audio_graph.current_processing_plugin orelse return false;

    const ext_raw = plugin.getExtension(plugin, clap.ext.thread_pool.id) orelse return false;
    const ext: *const clap.ext.thread_pool.Plugin = @ptrCast(@alignCast(ext_raw));

    // Cap nesting to avoid pathological recursion; fall back to sync exec.
    const max_depth: u32 = 4;
    if (thread_context.clap_threadpool_depth >= max_depth) {
        for (0..task_count) |i| ext.exec(plugin, @intCast(i));
        return true;
    }

    if (self.jobs) |job_queue| {
        thread_context.clap_threadpool_depth += 1;
        defer thread_context.clap_threadpool_depth -= 1;

        const base_fanout: u32 = if (self.jobs_fanout > 0) self.jobs_fanout else 1;
        const desired_fanout: u32 = if (thread_context.in_jobs_worker) @max(1, base_fanout / 2) else base_fanout;
        const job_count: u32 = @min(task_count, desired_fanout);

        const Shared = struct {
            plugin: *const clap.Plugin,
            exec_fn: *const fn (*const clap.Plugin, u32) callconv(.c) void,
            task_count: u32,
            next_task: std.atomic.Value(u32) = .init(0),
        };

        var shared = Shared{
            .plugin = plugin,
            .exec_fn = ext.exec,
            .task_count = task_count,
            .next_task = .init(0),
        };

        const RootJob = struct {
            pub fn exec(_: *@This()) void {}
        };
        const root = job_queue.allocate(RootJob{});

        const WorkerJob = struct {
            shared: *Shared,
            pub fn exec(job: *@This()) void {
                thread_context.is_audio_thread = true;
                thread_context.in_jobs_worker = true;
                defer thread_context.in_jobs_worker = false;

                while (true) {
                    const idx = job.shared.next_task.fetchAdd(1, .acq_rel);
                    if (idx >= job.shared.task_count) break;
                    job.shared.exec_fn(job.shared.plugin, idx);
                }
            }
        };

        for (0..job_count) |_| {
            const worker = job_queue.allocate(WorkerJob{ .shared = &shared });
            job_queue.finishWith(worker, root);
            job_queue.schedule(worker);
        }

        job_queue.schedule(root);
        job_queue.waitRealtime(root);
        return true;
    }
    return false;
}

fn hostGuiResizeHintsChanged(_: *const clap.Host) callconv(.c) void {}
fn hostGuiRequestResize(_: *const clap.Host, _: u32, _: u32) callconv(.c) bool {
    return true;
}
fn hostGuiRequestShow(_: *const clap.Host) callconv(.c) bool {
    return true;
}
fn hostGuiRequestHide(_: *const clap.Host) callconv(.c) bool {
    return true;
}
fn hostGuiClosed(host: *const clap.Host, _: bool) callconv(.c) void {
    // Plugin closed its floating window — clear matching slot flags.
    const self = hostFromData(host);
    const closed_plugin = plugin_call_context.current();
    for (&self.instruments) |*slot| {
        if (!slot.gui_open) continue;
        if (closed_plugin) |p| {
            if (slot.getPlugin() == p) slot.clearGuiFlags();
        } else {
            slot.clearGuiFlags();
        }
    }
    for (&self.fx) |*row| {
        for (row) |*slot| {
            if (!slot.gui_open) continue;
            if (closed_plugin) |p| {
                if (slot.getPlugin() == p) slot.clearGuiFlags();
            } else {
                slot.clearGuiFlags();
            }
        }
    }
}

fn hostLatencyChanged(_: *const clap.Host) callconv(.c) void {
    // Soft: graph latency compensation recomputes from plugin latency queries
    // on the next process; no hard restart required.
}

fn hostParamsRescan(host: *const clap.Host, _: clap.ext.params.Host.RescanFlags) callconv(.c) void {
    const self = hostFromData(host);
    self.params_rescan_requested.store(true, .release);
}

fn hostParamsClear(host: *const clap.Host, param_id: clap.Id, _: clap.ext.params.Host.ClearFlags) callconv(.c) void {
    const self = hostFromData(host);
    const plugin = resolveCallingPlugin(self) orelse return;
    const slot = findPluginSlot(self, plugin) orelse return;
    if (!document_model.ready()) return;

    const document_commands = @import("../document/commands.zig");
    _ = document_commands.clearParameterAutomation(
        &document_model.g,
        slot.track_index,
        slot.fx_index,
        @backingInt(param_id),
    );
}

fn hostParamsRequestFlush(host: *const clap.Host) callconv(.c) void {
    const self = hostFromData(host);
    self.flush_requested.store(true, .release);
}

// ── Main-thread pumps ────────────────────────────────────────────────────────

fn callPluginOnMainThread(plugin: *const clap.Plugin) void {
    const previous = plugin_call_context.enter(plugin);
    defer plugin_call_context.restore(previous);
    plugin.onMainThread(plugin);
}

fn pumpMainThreadCallbacks(self: *PluginHost) void {
    if (!self.callback_requested.swap(false, .acq_rel)) return;
    for (&self.instruments) |*slot| {
        if (slot.getPlugin()) |p| callPluginOnMainThread(p);
    }
    for (&self.fx) |*row| {
        for (row) |*slot| {
            if (slot.getPlugin()) |p| callPluginOnMainThread(p);
        }
    }
}

fn pumpParamRescans(self: *PluginHost) void {
    if (!self.params_rescan_requested.swap(false, .acq_rel)) return;
    if (!document_model.ready()) return;
    // Smart-param tables cache params by plugin pointer; force a rebuild.
    chrome.g.controller.smart_target_token = 0;
    chrome.g.controller.smart_param_count = 0;
    chrome.g.controller.smart_page = 0;
}

fn pumpParamFlushes(self: *PluginHost) void {
    if (!self.flush_requested.swap(false, .acq_rel)) return;
    // Flush all loaded plugins with empty event lists (host-side param flush path).
    for (&self.instruments) |*slot| {
        if (slot.getPlugin()) |p| flushPluginParams(p);
    }
    for (&self.fx) |*row| {
        for (row) |*slot| {
            if (slot.getPlugin()) |p| flushPluginParams(p);
        }
    }
}

fn flushPluginParams(plugin: *const clap.Plugin) void {
    const ext_raw = plugin.getExtension(plugin, clap.ext.params.id) orelse return;
    const params: *const clap.ext.params.Plugin = @ptrCast(@alignCast(ext_raw));
    var in_list: audio_events.EventList = .{};
    var in_events = audio_events.emptyInputEvents(&in_list);
    var out_list: audio_events.OutputEventList = .{};
    var out_events = clap.events.OutputEvents{
        .context = &out_list,
        .tryPush = audio_events.outputEventsTryPush,
    };
    const previous = plugin_call_context.enter(plugin);
    defer plugin_call_context.restore(previous);
    params.flush(plugin, &in_events, &out_events);
}

fn pumpPluginGuiEvents(self: *PluginHost, io: std.Io) void {
    pumpPluginTimers(self, io);
    pumpPluginFds(self);
}

fn hostTimerRegister(host: *const clap.Host, period_ms: u32, timer_id: *clap.Id) callconv(.c) bool {
    if (thread_context.is_audio_thread) return false;
    const plugin = plugin_call_context.current() orelse return false;
    const self = hostFromData(host);
    const now_ns = nowNs(clock_io);

    for (&self.gui_timers) |*timer| {
        if (!timer.active) {
            const id: clap.Id = @fromBackingInt(@intCast(self.next_gui_timer_id));
            self.next_gui_timer_id +%= 1;
            if (self.next_gui_timer_id == @backingInt(clap.Id.invalid_id)) {
                self.next_gui_timer_id = 1;
            }
            timer.* = .{
                .plugin = plugin,
                .timer_id = id,
                .period_ms = @max(period_ms, 1),
                .next_fire_ns = now_ns + msToNs(@max(period_ms, 1)),
                .active = true,
            };
            timer_id.* = id;
            return true;
        }
    }
    return false;
}

fn hostTimerUnregister(host: *const clap.Host, timer_id: clap.Id) callconv(.c) bool {
    if (thread_context.is_audio_thread) return false;
    const self = hostFromData(host);
    for (&self.gui_timers) |*timer| {
        if (timer.active and timer.timer_id == timer_id) {
            timer.active = false;
            return true;
        }
    }
    return false;
}

fn hostPosixFdRegister(host: *const clap.Host, fd: c_int, flags: clap.ext.posix_fd_support.Flags) callconv(.c) bool {
    if (thread_context.is_audio_thread) return false;
    const plugin = plugin_call_context.current() orelse return false;
    const self = hostFromData(host);

    for (&self.gui_fds) |*entry| {
        if (entry.active and entry.fd == fd) return false;
    }
    for (&self.gui_fds) |*entry| {
        if (!entry.active) {
            entry.* = .{
                .plugin = plugin,
                .fd = fd,
                .flags = flags,
                .active = true,
            };
            return true;
        }
    }
    return false;
}

fn hostPosixFdModify(host: *const clap.Host, fd: c_int, flags: clap.ext.posix_fd_support.Flags) callconv(.c) bool {
    if (thread_context.is_audio_thread) return false;
    const self = hostFromData(host);
    for (&self.gui_fds) |*entry| {
        if (entry.active and entry.fd == fd) {
            entry.flags = flags;
            return true;
        }
    }
    return false;
}

fn hostPosixFdUnregister(host: *const clap.Host, fd: c_int) callconv(.c) bool {
    if (thread_context.is_audio_thread) return false;
    const self = hostFromData(host);
    for (&self.gui_fds) |*entry| {
        if (entry.active and entry.fd == fd) {
            entry.active = false;
            return true;
        }
    }
    return false;
}

fn pumpPluginTimers(self: *PluginHost, io: std.Io) void {
    const now_ns = nowNs(io);
    for (&self.gui_timers) |*timer| {
        if (!timer.active) continue;
        if (!pluginIsLoaded(self, timer.plugin)) {
            timer.active = false;
            continue;
        }
        if (now_ns < timer.next_fire_ns) continue;

        const ext_raw = timer.plugin.getExtension(timer.plugin, clap.ext.timer_support.id) orelse {
            timer.active = false;
            continue;
        };
        const ext: *const clap.ext.timer_support.Plugin = @ptrCast(@alignCast(ext_raw));
        {
            const previous = plugin_call_context.enter(timer.plugin);
            defer plugin_call_context.restore(previous);
            ext.onTimer(timer.plugin, timer.timer_id);
        }
        timer.next_fire_ns = now_ns + msToNs(timer.period_ms);
    }
}

fn pumpPluginFds(self: *PluginHost) void {
    if (comptime builtin.os.tag != .linux) return;

    var poll_fds: [max_gui_fds]std.posix.pollfd = undefined;
    var sources: [max_gui_fds]*GuiFd = undefined;
    var count: usize = 0;
    for (&self.gui_fds) |*entry| {
        if (!entry.active) continue;
        if (!pluginIsLoaded(self, entry.plugin)) {
            entry.active = false;
            continue;
        }
        poll_fds[count] = .{
            .fd = entry.fd,
            .events = posixEventsFromFlags(entry.flags),
            .revents = 0,
        };
        sources[count] = entry;
        count += 1;
    }
    if (count == 0) return;

    const ready_count = std.posix.poll(poll_fds[0..count], 0) catch return;
    if (ready_count == 0) return;

    for (poll_fds[0..count], sources[0..count]) |poll_fd, entry| {
        if (poll_fd.revents == 0) continue;
        const flags = flagsFromPosixEvents(poll_fd.revents);
        const ext_raw = entry.plugin.getExtension(entry.plugin, clap.ext.posix_fd_support.id) orelse {
            entry.active = false;
            continue;
        };
        const ext: *const clap.ext.posix_fd_support.Plugin = @ptrCast(@alignCast(ext_raw));
        {
            const previous = plugin_call_context.enter(entry.plugin);
            defer plugin_call_context.restore(previous);
            ext.onFd(entry.plugin, entry.fd, flags);
        }
    }
}

fn pluginIsLoaded(self: *PluginHost, plugin: *const clap.Plugin) bool {
    for (&self.instruments) |*slot| {
        if (slot.getPlugin() == plugin) return true;
    }
    for (&self.fx) |*row| {
        for (row) |*slot| {
            if (slot.getPlugin() == plugin) return true;
        }
    }
    return false;
}

fn nowNs(io: std.Io) u64 {
    const now = std.Io.Clock.awake.now(io);
    const ns = now.toNanoseconds();
    return if (ns > 0) @intCast(ns) else 0;
}

fn msToNs(ms: u32) u64 {
    return @as(u64, ms) * std.time.ns_per_ms;
}

fn posixEventsFromFlags(flags: clap.ext.posix_fd_support.Flags) @FieldType(std.posix.pollfd, "events") {
    var events: @FieldType(std.posix.pollfd, "events") = 0;
    if (flags.read) events |= std.posix.POLL.IN;
    if (flags.write) events |= std.posix.POLL.OUT;
    if (flags.@"error") events |= std.posix.POLL.ERR;
    return events;
}

fn flagsFromPosixEvents(events: @FieldType(std.posix.pollfd, "revents")) clap.ext.posix_fd_support.Flags {
    return .{
        .read = (events & std.posix.POLL.IN) != 0,
        .write = (events & std.posix.POLL.OUT) != 0,
        .@"error" = (events & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0,
        ._ = 0,
    };
}

// ── Undo host extension → document undo history ──────────────────────────────

const UndoTarget = struct {
    track_index: usize,
    fx_index: ?usize,
    plugin: *const clap.Plugin,
};

fn getActivePluginForUndo(self: *PluginHost, state: *const chrome.State) ?UndoTarget {
    const track_idx = state.deviceTrack();
    if (track_idx >= track_count) return null;

    switch (state.device_target_kind) {
        .instrument => {
            const plugin = self.instruments[track_idx].getPlugin() orelse return null;
            return .{ .track_index = track_idx, .fx_index = null, .plugin = plugin };
        },
        .fx => {
            const fx_idx = state.device_target_fx;
            if (fx_idx >= max_fx_slots) return null;
            const plugin = self.fx[track_idx][fx_idx].getPlugin() orelse return null;
            return .{ .track_index = track_idx, .fx_index = fx_idx, .plugin = plugin };
        },
    }
}

fn getPluginForUndoSlot(self: *PluginHost, track_idx: usize, fx_index: ?usize) ?*const clap.Plugin {
    if (track_idx >= track_count) return null;
    if (fx_index) |fx| {
        if (fx >= max_fx_slots) return null;
        return self.fx[track_idx][fx].getPlugin();
    }
    return self.instruments[track_idx].getPlugin();
}

fn clearUndoChange(self: *PluginHost) void {
    if (self.undo_pre_state) |pre| {
        self.allocator.free(pre);
    }
    self.undo_pre_state = null;
    self.undo_track_index = null;
    self.undo_fx_index = null;
    self.undo_change_in_progress = false;
}

fn hostUndoBeginChange(host: *const clap.Host) callconv(.c) void {
    const self = hostFromData(host);
    if (self.undo_change_in_progress) {
        std.log.warn("Plugin called begin_change while change already in progress", .{});
        return;
    }
    // Chrome global is always present in the product path.
    const state = &chrome.g;
    const target = getActivePluginForUndo(self, state) orelse return;

    if (project_plugin_state.capturePluginStateForUndo(self.allocator, target.plugin)) |pre_state| {
        self.undo_pre_state = pre_state;
        self.undo_track_index = target.track_index;
        self.undo_fx_index = target.fx_index;
        self.undo_change_in_progress = true;
    }
}

fn hostUndoCancelChange(host: *const clap.Host) callconv(.c) void {
    const self = hostFromData(host);
    clearUndoChange(self);
}

fn hostUndoChangeMade(
    host: *const clap.Host,
    name: [*:0]const u8,
    delta: ?*const anyopaque,
    delta_size: usize,
    delta_can_undo: bool,
) callconv(.c) void {
    _ = delta;
    _ = delta_size;
    _ = delta_can_undo;

    const self = hostFromData(host);
    const state = &chrome.g;

    const has_begin_change = self.undo_track_index != null;
    const track_idx = if (has_begin_change)
        self.undo_track_index.?
    else
        state.deviceTrack();
    const fx_index = if (has_begin_change)
        self.undo_fx_index
    else switch (state.device_target_kind) {
        .instrument => null,
        .fx => state.device_target_fx,
    };

    const old_state = self.undo_pre_state orelse {
        std.log.debug("Plugin change_made without begin_change: {s}", .{name});
        clearUndoChange(self);
        return;
    };
    // Ownership of old_state transfers to history; clear pre pointer first.
    self.undo_pre_state = null;
    self.undo_change_in_progress = false;
    self.undo_track_index = null;
    self.undo_fx_index = null;

    const plugin = getPluginForUndoSlot(self, track_idx, fx_index) orelse {
        self.allocator.free(old_state);
        return;
    };

    const new_state = project_plugin_state.capturePluginStateForUndo(self.allocator, plugin) orelse {
        self.allocator.free(old_state);
        return;
    };

    if (!document_model.ready()) {
        self.allocator.free(old_state);
        self.allocator.free(new_state);
        return;
    }
    document_model.g.undo_history.push(.{
        .plugin_state = .{
            .track_index = track_idx,
            .fx_index = fx_index,
            .old_state = old_state,
            .new_state = new_state,
        },
    });
    std.log.debug("Plugin undo entry: {s} track={d} fx={?}", .{ name, track_idx, fx_index });
    // History changed — push context to subscribed plugins immediately.
    pumpUndoContextUpdates(self);
}

fn hostUndoRequestUndo(host: *const clap.Host) callconv(.c) void {
    if (!document_model.ready()) return;
    const document_commands = @import("../document/commands.zig");
    _ = document_commands.undo(&document_model.g);
    pumpUndoContextUpdates(hostFromData(host));
}

fn hostUndoRequestRedo(host: *const clap.Host) callconv(.c) void {
    if (!document_model.ready()) return;
    const document_commands = @import("../document/commands.zig");
    _ = document_commands.redo(&document_model.g);
    pumpUndoContextUpdates(hostFromData(host));
}

fn hostUndoSetWantsContextUpdates(host: *const clap.Host, is_subscribed: bool) callconv(.c) void {
    if (thread_context.is_audio_thread) return;
    const self = hostFromData(host);
    const plugin = resolveCallingPlugin(self) orelse {
        std.log.debug("set_wants_context_updates({any}): no calling plugin context", .{is_subscribed});
        return;
    };
    const slot = findSlotForPlugin(self, plugin) orelse {
        std.log.debug("set_wants_context_updates({any}): plugin not in host slots", .{is_subscribed});
        return;
    };
    slot.wants_undo_context = is_subscribed;
    if (is_subscribed) {
        // Immediate push so the plugin GUI can enable undo/redo chrome right away.
        self.undo_ctx_force = true;
        pumpUndoContextUpdates(self);
    }
}

fn resolveCallingPlugin(self: *PluginHost) ?*const clap.Plugin {
    if (plugin_call_context.current()) |p| return p;
    // Same fallback as undo capture: device-panel target when context is unset
    // (plugin GUI thread calling host without an enter/restore nest).
    const state = &chrome.g;
    if (getActivePluginForUndo(self, state)) |t| return t.plugin;
    return null;
}

fn findSlotForPlugin(self: *PluginHost, plugin: *const clap.Plugin) ?*LoadedPlugin {
    for (&self.instruments) |*slot| {
        if (slot.getPlugin() == plugin) return slot;
    }
    for (&self.fx) |*row| {
        for (row) |*slot| {
            if (slot.getPlugin() == plugin) return slot;
        }
    }
    return null;
}

const PluginSlot = struct {
    track_index: usize,
    fx_index: ?usize,
};

fn findPluginSlot(self: *PluginHost, plugin: *const clap.Plugin) ?PluginSlot {
    for (&self.instruments, 0..) |*slot, track_index| {
        if (slot.getPlugin() == plugin) return .{ .track_index = track_index, .fx_index = null };
    }
    for (&self.fx, 0..) |*row, track_index| {
        for (row, 0..) |*slot, fx_index| {
            if (slot.getPlugin() == plugin) return .{ .track_index = track_index, .fx_index = fx_index };
        }
    }
    return null;
}

fn hasUndoContextSubscriber(self: *const PluginHost) bool {
    for (&self.instruments) |*slot| {
        if (slot.wants_undo_context and slot.isLoaded()) return true;
    }
    for (&self.fx) |*row| {
        for (row) |*slot| {
            if (slot.wants_undo_context and slot.isLoaded()) return true;
        }
    }
    return false;
}

fn copyNameZ(buf: *[64]u8, name: ?[]const u8) ?[*:0]const u8 {
    const s = name orelse return null;
    if (s.len == 0) return null;
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0].ptr;
}

fn namesEqual(stored: []const u8, current: ?[]const u8) bool {
    const cur = current orelse return stored.len == 0;
    return std.mem.eql(u8, stored, cur);
}

/// Push can_undo / can_redo / step names to plugins that subscribed via
/// `set_wants_context_updates`. Dirty-compared so UI-side undo (Ctrl+Z) is
/// reflected on the next host tick without redundant extension calls.
fn pumpUndoContextUpdates(self: *PluginHost) void {
    if (!hasUndoContextSubscriber(self)) {
        self.undo_ctx_force = false;
        return;
    }
    if (!document_model.ready()) return;

    const can_undo = document_model.g.undo_history.canUndo();
    const can_redo = document_model.g.undo_history.canRedo();
    const undo_desc = document_model.g.undo_history.getUndoDescription();
    const redo_desc = document_model.g.undo_history.getRedoDescription();

    const last_undo = self.undo_ctx_last_undo_name[0..self.undo_ctx_last_undo_name_len];
    const last_redo = self.undo_ctx_last_redo_name[0..self.undo_ctx_last_redo_name_len];
    if (!self.undo_ctx_force and
        self.undo_ctx_last_can_undo == can_undo and
        self.undo_ctx_last_can_redo == can_redo and
        namesEqual(last_undo, undo_desc) and
        namesEqual(last_redo, redo_desc))
    {
        return;
    }

    const undo_z = copyNameZ(&self.undo_ctx_name_buf, undo_desc);
    const redo_z = copyNameZ(&self.redo_ctx_name_buf, redo_desc);

    for (&self.instruments) |*slot| {
        notifyUndoContextSlot(slot, can_undo, can_redo, undo_z, redo_z);
    }
    for (&self.fx) |*row| {
        for (row) |*slot| {
            notifyUndoContextSlot(slot, can_undo, can_redo, undo_z, redo_z);
        }
    }

    self.undo_ctx_last_can_undo = can_undo;
    self.undo_ctx_last_can_redo = can_redo;
    if (undo_desc) |d| {
        const n = @min(d.len, self.undo_ctx_last_undo_name.len);
        @memcpy(self.undo_ctx_last_undo_name[0..n], d[0..n]);
        self.undo_ctx_last_undo_name_len = n;
    } else {
        self.undo_ctx_last_undo_name_len = 0;
    }
    if (redo_desc) |d| {
        const n = @min(d.len, self.undo_ctx_last_redo_name.len);
        @memcpy(self.undo_ctx_last_redo_name[0..n], d[0..n]);
        self.undo_ctx_last_redo_name_len = n;
    } else {
        self.undo_ctx_last_redo_name_len = 0;
    }
    self.undo_ctx_force = false;
}

fn notifyUndoContextSlot(
    slot: *LoadedPlugin,
    can_undo: bool,
    can_redo: bool,
    undo_name: ?[*:0]const u8,
    redo_name: ?[*:0]const u8,
) void {
    if (!slot.wants_undo_context) return;
    const plugin = slot.getPlugin() orelse {
        slot.wants_undo_context = false;
        return;
    };
    const ext_raw = plugin.getExtension(plugin, clap.ext.undo.context_id) orelse {
        // Plugin asked for updates but does not implement clap.undo_context — drop.
        slot.wants_undo_context = false;
        std.log.debug("plugin subscribed to undo context without clap.undo_context extension", .{});
        return;
    };
    const ctx: *const clap.ext.undo.PluginContext = @ptrCast(@alignCast(ext_raw));
    const previous = plugin_call_context.enter(plugin);
    defer plugin_call_context.restore(previous);
    ctx.set_can_undo(plugin, can_undo);
    ctx.set_can_redo(plugin, can_redo);
    ctx.set_undo_name(plugin, undo_name);
    ctx.set_redo_name(plugin, redo_name);
}

// ── Process-wide ─────────────────────────────────────────────────────────────

pub var g: PluginHost = undefined;
pub var g_ready: bool = false;

pub fn initGlobal(allocator: std.mem.Allocator) void {
    g = PluginHost.init(allocator);
    g.start();
    if (document_model.ready()) {
        document_model.g.plugin_state_applier = applyPluginStateBlobFromDocument;
    }
    g_ready = true;
}

pub fn deinitGlobal() void {
    if (!g_ready) return;
    if (document_model.ready()) {
        document_model.g.plugin_state_applier = null;
    }
    g.deinit();
    g_ready = false;
}

pub fn ready() bool {
    return g_ready;
}

fn applyPluginStateBlobFromDocument(track_index: usize, fx_index: ?usize, data: []const u8) bool {
    if (!g_ready) return false;
    return g.applyPluginStateBlob(track_index, fx_index, data);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "plugin host init without discover still deinit" {
    var ph = PluginHost.init(std.testing.allocator);
    // Don't call start — catalog optional.
    ph.deinit();
}

test "undo context name helpers and dirty compare" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(copyNameZ(&buf, null) == null);
    try std.testing.expect(copyNameZ(&buf, "") == null);
    const z = copyNameZ(&buf, "Change Plugin") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Change Plugin", std.mem.span(z));

    try std.testing.expect(namesEqual("", null));
    try std.testing.expect(namesEqual("Edit Notes", "Edit Notes"));
    try std.testing.expect(!namesEqual("Edit Notes", "Create Clip"));
    try std.testing.expect(!namesEqual("x", null));
}

test "LoadedPlugin clearHostFlags clears undo context subscription" {
    var slot: LoadedPlugin = .{};
    slot.wants_undo_context = true;
    slot.gui_open = true;
    slot.clearHostFlags();
    try std.testing.expect(!slot.wants_undo_context);
    try std.testing.expect(!slot.gui_open);
}

test "pumpUndoContextUpdates no-ops without subscribers" {
    var ph = PluginHost.init(std.testing.allocator);
    defer ph.deinit();
    ph.undo_ctx_force = true;
    pumpUndoContextUpdates(&ph);
    try std.testing.expect(!ph.undo_ctx_force);
}

test "set instrument choice updates name projection" {
    var ph = PluginHost.init(std.testing.allocator);
    defer ph.deinit();
    // Manual catalog-free name is empty for choice 0.
    try std.testing.expectEqualStrings("", ph.entryName(0));
    ph.setInstrumentChoice(0, 0);
    try std.testing.expectEqual(@as(i32, 0), ph.instrument_choice[0].choice_index);
}

test "queued project state owns and replaces its data" {
    var ph = PluginHost.init(std.testing.allocator);
    defer ph.deinit();

    var source = [_]u8{ 1, 2, 3 };
    try ph.queueProjectState(0, null, &source);
    source[0] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, ph.pending_instrument_state[0].?);

    try ph.queueProjectState(0, null, &.{4});
    try std.testing.expectEqualSlices(u8, &.{4}, ph.pending_instrument_state[0].?);
    try ph.queueProjectState(0, 1, &.{ 5, 6 });
    try std.testing.expectEqualSlices(u8, &.{ 5, 6 }, ph.pending_fx_state[0][1].?);

    ph.clearPendingProjectStates();
    try std.testing.expect(ph.pending_instrument_state[0] == null);
    try std.testing.expect(ph.pending_fx_state[0][1] == null);
}

fn testPresetEntry(catalog_index: i32) PresetEntry {
    return .{
        .name = "Bright Pad",
        .plugin_id = "com.example.synth",
        .plugin_name = "Example Synth",
        .provider_id = "example",
        .location_kind = .file,
        .location_z = "/presets/bright.xml",
        .load_key_z = "42",
        .catalog_index = catalog_index,
    };
}

test "preset request is queued with host-owned strings" {
    var ph = PluginHost.init(std.testing.allocator);
    defer ph.deinit();

    ph.loadPresetOnTrack(0, testPresetEntry(5));
    try std.testing.expectEqual(@as(i32, 5), ph.instrument_choice[0].choice_index);
    const req = ph.pending_preset[0].?;
    try std.testing.expectEqualStrings("com.example.synth", req.plugin_id);
    try std.testing.expectEqualStrings("/presets/bright.xml", req.location);
    try std.testing.expectEqualStrings("42", req.load_key.?);

    // Choosing another instrument drops the request.
    ph.setInstrumentChoice(0, 6);
    try std.testing.expect(ph.pending_preset[0] == null);
}

test "preset request without catalog plugin is not queued" {
    var ph = PluginHost.init(std.testing.allocator);
    defer ph.deinit();

    ph.loadPresetOnTrack(0, testPresetEntry(-1));
    try std.testing.expect(ph.pending_preset[0] == null);
    try std.testing.expectEqual(@as(i32, 0), ph.instrument_choice[0].choice_index);
}

test "preset request is dropped when the choice has no catalog entry" {
    var ph = PluginHost.init(std.testing.allocator);
    defer ph.deinit();

    ph.loadPresetOnTrack(0, testPresetEntry(5));
    try std.testing.expect(ph.pending_preset[0] != null);
    // No catalog (and so no instance) — the request cannot be honoured.
    ph.applyPendingPresets();
    try std.testing.expect(ph.pending_preset[0] == null);
}

test "removeFx compacts choices without engine" {
    var ph = PluginHost.init(std.testing.allocator);
    defer ph.deinit();

    try std.testing.expect(ph.addFxSlot(0, 3));
    try std.testing.expect(ph.addFxSlot(0, 7));
    try std.testing.expect(ph.addFxSlot(0, 11));
    try std.testing.expectEqual(@as(usize, 3), ph.fx_counts[0]);

    // Mark live choice_index so move/remove keep slots aligned for sync.
    ph.fx[0][0].choice_index = 3;
    ph.fx[0][1].choice_index = 7;
    ph.fx[0][2].choice_index = 11;

    ph.removeFx(0, 1, null);
    try std.testing.expectEqual(@as(usize, 2), ph.fx_counts[0]);
    try std.testing.expectEqual(@as(i32, 3), ph.fx_choice[0][0].choice_index);
    try std.testing.expectEqual(@as(i32, 11), ph.fx_choice[0][1].choice_index);
    try std.testing.expectEqual(@as(i32, 0), ph.fx_choice[0][2].choice_index);
    try std.testing.expectEqual(@as(i32, 3), ph.fx[0][0].choice_index);
    try std.testing.expectEqual(@as(i32, 11), ph.fx[0][1].choice_index);
}

test "moveFx reorders packed chain" {
    var ph = PluginHost.init(std.testing.allocator);
    defer ph.deinit();

    _ = ph.addFxSlot(0, 3);
    _ = ph.addFxSlot(0, 7);
    _ = ph.addFxSlot(0, 11);
    ph.fx[0][0].choice_index = 3;
    ph.fx[0][1].choice_index = 7;
    ph.fx[0][2].choice_index = 11;

    ph.moveFx(0, 0, 2, null);
    try std.testing.expectEqual(@as(i32, 7), ph.fx_choice[0][0].choice_index);
    try std.testing.expectEqual(@as(i32, 11), ph.fx_choice[0][1].choice_index);
    try std.testing.expectEqual(@as(i32, 3), ph.fx_choice[0][2].choice_index);
    try std.testing.expectEqual(@as(i32, 7), ph.fx[0][0].choice_index);
    try std.testing.expectEqual(@as(i32, 11), ph.fx[0][1].choice_index);
    try std.testing.expectEqual(@as(i32, 3), ph.fx[0][2].choice_index);
}

test "duplicateFx inserts choice after source" {
    var ph = PluginHost.init(std.testing.allocator);
    defer ph.deinit();

    _ = ph.addFxSlot(0, 3);
    _ = ph.addFxSlot(0, 7);
    ph.fx[0][0].choice_index = 3;
    ph.fx[0][1].choice_index = 7;

    try std.testing.expect(ph.duplicateFx(0, 0, null));
    try std.testing.expectEqual(@as(usize, 3), ph.fx_counts[0]);
    try std.testing.expectEqual(@as(i32, 3), ph.fx_choice[0][0].choice_index);
    try std.testing.expectEqual(@as(i32, 3), ph.fx_choice[0][1].choice_index);
    try std.testing.expectEqual(@as(i32, 7), ph.fx_choice[0][2].choice_index);
    // New slot is empty so sync will load; source stays loaded.
    try std.testing.expect(!ph.fx[0][1].isLoaded());
    try std.testing.expectEqual(@as(i32, -1), ph.fx[0][1].choice_index);
    try std.testing.expectEqual(@as(i32, 7), ph.fx[0][2].choice_index);
}
