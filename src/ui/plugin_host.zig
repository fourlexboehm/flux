//! CLAP catalog + live device-chain loading for the DVUI host.
//!
//! Discovers plugins at init, owns choice indices and DynLib instances, and
//! publishes loaded CLAP pointers into the audio engine each frame.
//!
//! Builtins (ZSynth, ZMinimoog, …) load from their on-disk `.clap` bundles via
//! DynLib when present under `zig-out/lib/` — no static builtin / zgui link.
//! External system CLAPs load the same way. Floating plugin GUIs open via
//! `plugin/gui_float.zig` (plugin-owned windows; no AppKit parent). Hardware
//! MIDI (portmidi) merges into live keys with the computer-keyboard piano map.

const std = @import("std");
const clap = @import("clap-bindings");

const chrome = @import("state.zig");
const host_mod = @import("host.zig");
const plugins = @import("../plugin/plugins.zig");
const plugin_handle = @import("../plugin/handle.zig");
const gui_float = @import("../plugin/gui_float.zig");
const plugin_call_context = @import("../plugin/call_context.zig");
const midi_input = @import("../midi/input.zig");
const audio_engine_mod = @import("../audio/audio_engine.zig");
const thread_context = @import("../util/thread_context.zig");

const PluginCatalog = plugins.PluginCatalog;
const PluginEntry = plugins.PluginEntry;
const LoadedPlugin = plugin_handle.LoadedPlugin;
const PluginHandle = plugin_handle.PluginHandle;
const track_count = plugin_handle.track_count;
const max_fx_slots = plugin_handle.max_fx_slots;
const AudioEngine = audio_engine_mod.AudioEngine;

const clock_io: std.Io = std.Io.Threaded.global_single_threaded.io();

/// UI choice for one device slot (instrument or FX).
pub const SlotChoice = struct {
    choice_index: i32 = 0,
    enabled: bool = true,
};

pub const PluginHost = struct {
    allocator: std.mem.Allocator,
    catalog: PluginCatalog = undefined,
    catalog_ready: bool = false,

    clap_host: clap.Host = undefined,
    main_thread_id: std.Thread.Id = undefined,

    instruments: [track_count]LoadedPlugin = @splat(.{}),
    fx: [track_count][max_fx_slots]LoadedPlugin = @splat(@splat(.{})),

    /// Desired chain (user selections). Sync loads/unloads to match.
    instrument_choice: [track_count]SlotChoice = @splat(.{}),
    fx_choice: [track_count][max_fx_slots]SlotChoice = @splat(@splat(.{})),
    /// Leading occupied FX slots per track (packed).
    fx_counts: [track_count]usize = @splat(0),

    /// Computer-keyboard MIDI (A–; piano map) → merged into live keys.
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
        self.closeAllGuis();
        self.unloadAll(null);
        if (self.midi_active) {
            self.midi.deinit();
            self.midi_active = false;
        }
        if (self.catalog_ready) {
            self.catalog.deinit();
            self.catalog_ready = false;
        }
        self.* = undefined;
    }

    pub fn unloadAll(self: *PluginHost, engine: ?*AudioEngine) void {
        self.closeAllGuis();
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
        self.instrument_choice[track].choice_index = choice;
    }

    /// Append or set FX slot. Returns false if chain full / invalid.
    pub fn setFxChoice(self: *PluginHost, track: usize, fx_index: usize, choice: i32) bool {
        if (track >= track_count or fx_index >= max_fx_slots) return false;
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

    pub fn removeFx(self: *PluginHost, track: usize, fx_index: usize) void {
        if (track >= track_count or fx_index >= self.fx_counts[track]) return;
        // Compact left.
        var i = fx_index;
        while (i + 1 < max_fx_slots) : (i += 1) {
            self.fx_choice[track][i] = self.fx_choice[track][i + 1];
        }
        self.fx_choice[track][max_fx_slots - 1] = .{};
        if (self.fx_counts[track] > 0) self.fx_counts[track] -= 1;
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
        if (engine) |e| {
            const snap = plugin_handle.collectLoaded(&self.instruments, &self.fx);
            e.updatePlugins(snap.instruments, snap.fx);
        }
        self.pumpOpenGuis();
    }

    /// Poll hardware MIDI + merge keyboard/hardware into live keys for `target_track`.
    pub fn tickLiveMidi(self: *PluginHost, target_track: usize) void {
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
        if (target_track < track_count) {
            self.live_key_states[target_track] = pressed;
            self.live_key_velocities[target_track] = vels;
        }
    }

    // ── Floating plugin GUI ────────────────────────────────────────────────

    pub fn selectedSlot(self: *PluginHost, state: *const chrome.State) ?*LoadedPlugin {
        const t = state.selected_track;
        if (t >= track_count) return null;
        return switch (state.device_target_kind) {
            .instrument => &self.instruments[t],
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

    /// Load via DynLib. Builtin catalog entries use the same path when the
    /// `.clap` bundle exists under zig-out (or system paths for externals).
    fn loadSlot(self: *PluginHost, slot: *LoadedPlugin, entry: PluginEntry, max_frames: u32) !void {
        const path = entry.path orelse return error.PluginMissingPath;
        switch (entry.kind) {
            .builtin, .clap => {
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

fn hostFromData(host: *const clap.Host) *PluginHost {
    return @ptrCast(@alignCast(host.host_data));
}

fn hostGetExtension(host: *const clap.Host, extension_id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    _ = host;
    const id = std.mem.span(extension_id);
    if (std.mem.eql(u8, id, clap.ext.thread_check.id)) return &thread_check_ext;
    if (std.mem.eql(u8, id, clap.ext.gui.id)) return &gui_host_ext;
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
