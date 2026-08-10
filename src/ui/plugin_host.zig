//! CLAP catalog + live device-chain loading for the DVUI host.
//!
//! Discovers plugins at init, owns choice indices and DynLib instances, and
//! publishes loaded CLAP pointers into the audio engine each frame.
//!
//! Builtins: stock Flux FX + instruments load statically (`plugin/builtin_load.zig`).
//! External system CLAPs use DynLib. Plugin GUIs open via `plugin/gui_float.zig`
//! (floating preferred; macOS NSWindow / Linux X11 parent fallbacks).
//! Hardware MIDI (portmidi) merges into live keys with the computer-keyboard piano map.

const std = @import("std");
const clap = @import("clap-bindings");

const chrome = @import("state.zig");
const host_mod = @import("host.zig");
const plugins = @import("../plugin/plugins.zig");
const presets_mod = @import("../plugin/presets.zig");
const plugin_handle = @import("../plugin/handle.zig");
const builtin_load = @import("../plugin/builtin_load.zig");
const gui_float = @import("../plugin/gui_float.zig");
const plugin_call_context = @import("../plugin/call_context.zig");
const clap_ids = @import("../util/clap_ids.zig");
const midi_input = @import("../midi/input.zig");
const audio_engine_mod = @import("../audio/audio_engine.zig");
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
        self.clearPendingProjectStates();
        self.closeAllGuis();
        self.unloadAll(null);
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
        const shared = if (engine) |e| &e.shared else null;
        self.syncInstruments(shared, max_frames);
        self.syncFx(shared, max_frames);
        self.applyPendingProjectStates();
        self.applyPendingPresets();
        if (engine) |e| {
            const snap = plugin_handle.collectLoaded(&self.instruments, &self.fx);
            e.updatePlugins(snap.instruments, snap.fx);
        }
        self.pumpOpenGuis();
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
            if (slot.gui_open) {
                if (slot.getPlugin()) |p| gui_float.pumpOnMainThread(p);
            }
        }
        for (&self.fx) |*row| {
            for (row) |*slot| {
                if (slot.gui_open) {
                    if (slot.getPlugin()) |p| gui_float.pumpOnMainThread(p);
                }
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

// ── Minimal CLAP host callbacks ──────────────────────────────────────────────

const thread_check_ext = clap.ext.thread_check.Host{
    .isMainThread = hostIsMainThread,
    .isAudioThread = hostIsAudioThread,
};

const gui_host_ext = clap.ext.gui.Host{
    .resizeHintsChanged = hostGuiResizeHintsChanged,
    .requestResize = hostGuiRequestResize,
    .requestShow = hostGuiRequestShow,
    .requestHide = hostGuiRequestHide,
    .closed = hostGuiClosed,
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
    if (std.mem.eql(u8, id, clap.ext.gui.id)) return &gui_host_ext;
    if (std.mem.eql(u8, id, clap.ext.preset_load.id) or
        std.mem.eql(u8, id, clap_ids.preset_load_compat_id))
    {
        return &preset_load_host_ext;
    }
    return null;
}

fn hostRequestRestart(_: *const clap.Host) callconv(.c) void {}
fn hostRequestProcess(_: *const clap.Host) callconv(.c) void {}
fn hostRequestCallback(_: *const clap.Host) callconv(.c) void {}

fn hostIsMainThread(host: *const clap.Host) callconv(.c) bool {
    const self = hostFromData(host);
    return std.Thread.getCurrentId() == self.main_thread_id;
}

fn hostIsAudioThread(_: *const clap.Host) callconv(.c) bool {
    return thread_context.is_audio_thread;
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

// ── Process-wide ─────────────────────────────────────────────────────────────

pub var g: PluginHost = undefined;
pub var g_ready: bool = false;

pub fn initGlobal(allocator: std.mem.Allocator) void {
    g = PluginHost.init(allocator);
    g.start();
    g_ready = true;
}

pub fn deinitGlobal() void {
    if (!g_ready) return;
    g.deinit();
    g_ready = false;
}

pub fn ready() bool {
    return g_ready;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "plugin host init without discover still deinit" {
    var ph = PluginHost.init(std.testing.allocator);
    // Don't call start — catalog optional.
    ph.deinit();
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
