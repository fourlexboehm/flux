//! Host shell frame: transport + browser + main + bottom panel.
//! Entry: `src/main.zig`.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const state_mod = @import("state.zig");
const host_mod = @import("host.zig");
const plugin_host = @import("plugin_host.zig");
const audio_runtime = @import("audio_runtime.zig");
const project_runtime = @import("project_runtime.zig");
const document_model = @import("../document/model.zig");
const document_commands = @import("../document/commands.zig");
const transport = @import("transport.zig");
const browser = @import("panels/browser.zig");
const bottom = @import("panels/bottom.zig");
const main_pane = @import("views/main_pane.zig");
const piano_roll = @import("views/piano_roll.zig");
const session_view = @import("views/session.zig");
const arrangement_view = @import("views/arrangement.zig");
const edit_actions = @import("edit_actions.zig");
const media_drop = @import("media_drop.zig");
const recording = @import("recording.zig");
const midi_input = @import("../midi/input.zig");
const controller_mapping = @import("../midi/controller_mapping.zig");

const sdl = dvui.backend.c;
const clock_io: std.Io = std.Io.Threaded.global_single_threaded.io();

const PianoKeyBinding = struct {
    scancode: c_int,
    /// macOS ANSI virtual keycode (kVK_ANSI_*), used when a plugin window
    /// steals OS focus and SDL keyboard state stops updating.
    mac_keycode: u16,
    offset: u8,
};

/// Physical positions of the QWERTY A–; piano rows. SDL scancodes are layout
/// independent, so these positions stay put under Dvorak and other layouts.
/// mac_keycode values match Carbon/HIToolbox ANSI layout (same as zgui's
/// `forwardMacosPluginKey` table).
const piano_key_bindings = [_]PianoKeyBinding{
    .{ .scancode = sdl.SDL_SCANCODE_A, .mac_keycode = 0, .offset = 0 },
    .{ .scancode = sdl.SDL_SCANCODE_W, .mac_keycode = 13, .offset = 1 },
    .{ .scancode = sdl.SDL_SCANCODE_S, .mac_keycode = 1, .offset = 2 },
    .{ .scancode = sdl.SDL_SCANCODE_E, .mac_keycode = 14, .offset = 3 },
    .{ .scancode = sdl.SDL_SCANCODE_D, .mac_keycode = 2, .offset = 4 },
    .{ .scancode = sdl.SDL_SCANCODE_F, .mac_keycode = 3, .offset = 5 },
    .{ .scancode = sdl.SDL_SCANCODE_T, .mac_keycode = 17, .offset = 6 },
    .{ .scancode = sdl.SDL_SCANCODE_G, .mac_keycode = 5, .offset = 7 },
    .{ .scancode = sdl.SDL_SCANCODE_Y, .mac_keycode = 16, .offset = 8 },
    .{ .scancode = sdl.SDL_SCANCODE_H, .mac_keycode = 4, .offset = 9 },
    .{ .scancode = sdl.SDL_SCANCODE_U, .mac_keycode = 32, .offset = 10 },
    .{ .scancode = sdl.SDL_SCANCODE_J, .mac_keycode = 38, .offset = 11 },
    .{ .scancode = sdl.SDL_SCANCODE_K, .mac_keycode = 40, .offset = 12 },
    .{ .scancode = sdl.SDL_SCANCODE_O, .mac_keycode = 31, .offset = 13 },
    .{ .scancode = sdl.SDL_SCANCODE_L, .mac_keycode = 37, .offset = 14 },
    .{ .scancode = sdl.SDL_SCANCODE_P, .mac_keycode = 35, .offset = 15 },
    .{ .scancode = sdl.SDL_SCANCODE_SEMICOLON, .mac_keycode = 41, .offset = 16 },
};

/// Octave shift keys (Z/X). Separate from note bindings so edge detection stays
/// independent of the note-offset table.
const mac_keycode_z: u16 = 6;
const mac_keycode_x: u16 = 7;
const mac_keycode_lctrl: u16 = 59;
const mac_keycode_rctrl: u16 = 62;
const mac_keycode_lalt: u16 = 58;
const mac_keycode_ralt: u16 = 61;
const mac_keycode_lcmd: u16 = 55;
const mac_keycode_rcmd: u16 = 54;

const flux_keyboard_physical_down = if (builtin.os.tag == .macos)
    struct {
        extern fn flux_keyboard_physical_down(mac_keycode: u16) bool;
    }.flux_keyboard_physical_down
else
    struct {
        fn f(_: u16) bool {
            return false;
        }
    }.f;

var octave_down_was_down = false;
var octave_up_was_down = false;
/// Previous-frame `wantTextInput` — `textInputRect` is cleared at Window.begin,
/// so we only learn about typing after widgets draw; suppress piano next frame.
var text_input_was_active = false;

pub fn init(win: *dvui.Window) !void {
    theme.apply(win);
    // XInitThreads before any CLAP opens an X11 parent (Linux only).
    const gui_float = @import("../plugin/gui_float.zig");
    gui_float.initPlatform();
    logDisplayScale(win);
    // Empty document (session_ops.init + matching arr lanes). No demo seed.
    document_model.initGlobal(win.gpa);
    host_mod.initGlobal(win.gpa);
    host_mod.g.projectChrome(&state_mod.g);
    // CLAP catalog (DynLib load on device pick). Builtins need zig-out/lib bundles.
    plugin_host.initGlobal(win.gpa);
    // Full AudioEngine (graph + metronome + meters + live plugins).
    audio_runtime.initGlobal(win.gpa, state_mod.g.buffer_frames);
    preloadDevDevice();
    std.log.info("flux-dvui host ready (backend={s})", .{@tagName(dvui.backend.kind)});
    std.log.info("  document: empty session+arrangement", .{});
    std.log.info("  audio: full AudioEngine + CLAP catalog + floating/parented plugin GUIs", .{});
    std.log.info("  MIDI: physical keyboard A–; positions (Z/X octave) + hardware portmidi", .{});
    std.log.info("  Space = play/stop, Tab = session/arrangement, Shift+Tab = device/clip, B = browser", .{});
}

/// One-shot HiDPI / Wayland scale dump so blurry UI is diagnosable without a debugger.
fn logDisplayScale(win: *dvui.Window) void {
    const be = win.backend;
    const win_sz = be.windowSize();
    const px_sz = be.pixelSize();
    const content = be.contentScale();
    const px_ratio = if (win_sz.w > 0) px_sz.w / win_sz.w else 0;
    std.log.info("display scale: window {d:.0}x{d:.0}  pixels {d:.0}x{d:.0}  pixel_ratio={d:.2}  content_scale={d:.2}  natural_scale={d:.2}", .{
        win_sz.w,
        win_sz.h,
        px_sz.w,
        px_sz.h,
        px_ratio,
        content,
        win.natural_scale,
    });
    if (px_ratio < 1.5 and content >= 1.5) {
        std.log.warn("HiDPI: content_scale={d:.2} but pixel buffer ~1x — compositor may blur the UI", .{content});
    } else if (px_ratio >= 1.5) {
        std.log.info("HiDPI: sharp pixel buffer (ratio {d:.2}); system content_scale={d:.2}", .{ px_ratio, content });
    } else if (comptime builtin.os.tag == .linux) {
        std.log.warn("HiDPI: pixel_ratio≈1 — use native Wayland SDL (unset SDL_VIDEODRIVER=x11). Expect ~2 on this panel.", .{});
    }
}

/// Dev hook: `FLUX_DEV_DEVICE=<clap plugin id>` loads that plugin on track 1
/// and opens the Device panel, so built-in editors can be eyeballed without
/// clicking through the browser. No effect when unset.
fn preloadDevDevice() void {
    const wanted_z = std.c.getenv("FLUX_DEV_DEVICE") orelse return;
    const wanted = std.mem.span(wanted_z);
    if (!plugin_host.ready() or !plugin_host.g.catalog_ready) return;

    for (plugin_host.g.catalog.entries.items, 0..) |entry, i| {
        const id = entry.id orelse continue;
        if (!std.mem.eql(u8, id, wanted)) continue;
        if (entry.is_audio_effect) {
            _ = plugin_host.g.addFxSlot(0, @intCast(i));
            state_mod.g.selectDeviceFx(0);
        } else {
            plugin_host.g.setInstrumentChoice(0, @intCast(i));
            state_mod.g.selectDeviceInstrument();
        }
        state_mod.g.bottom_mode = .device;
        std.log.info("FLUX_DEV_DEVICE: preloaded {s} on track 1", .{id});
        return;
    }
    std.log.warn("FLUX_DEV_DEVICE: no catalog entry for {s}", .{wanted});
}

pub fn deinit(win: *dvui.Window) void {
    _ = win;
    // Unload plugins while engine still exists (quiesce RT pointers).
    if (plugin_host.ready() and audio_runtime.ready()) {
        const eng = if (audio_runtime.g.engine != null) &audio_runtime.g.engine.? else null;
        plugin_host.g.unloadAll(eng);
    }
    audio_runtime.deinitGlobal();
    plugin_host.deinitGlobal();
    host_mod.deinitGlobal();
    document_model.deinitGlobal();
}

pub fn frame() !dvui.App.Result {
    const state = &state_mod.g;
    std.debug.assert(host_mod.ready());
    host_mod.g.drainPlaybackRequests(state);
    recording.drainUiRequests(state);

    // Playhead + recording quantize/finalize.
    // Runs before live-key refresh so keyboard edge capture sees last frame's baseline.
    const win = dvui.currentWindow();
    const frame_ns = win.frame_time_ns;
    var dt: f64 = 0;
    if (state.playing) {
        if (state.last_frame_time_ns != 0 and frame_ns > state.last_frame_time_ns) {
            const dt_ns = frame_ns - state.last_frame_time_ns;
            dt = @as(f64, @floatFromInt(dt_ns)) / 1e9;
            if (dt < 0 or dt >= 0.25) dt = 0;
        }
        state.last_frame_time_ns = frame_ns;
        dvui.refresh(null, @src(), win.data().id);
    } else {
        state.last_frame_time_ns = 0;
    }
    recording.tick(state, dt);

    pollPhysicalPiano(state);
    handleGlobalKeys(state);

    const midi_track = recording.midiTargetTrack(state);

    // Full engine: buffer, MIDI, plugin sync, publish host+chrome → RT, pull meters.
    if (audio_runtime.ready()) {
        audio_runtime.g.tick(&host_mod.g, state);
    } else if (plugin_host.ready()) {
        // No audio device: still poll MIDI / keyboard live keys for UI feedback.
        plugin_host.g.tickLiveMidi(midi_track, state.piano_preview_pitch);
    }

    // Drain hardware MIDI every frame (queue capacity is finite).
    // Control-surface CCs → document/session + RT param writes; notes → recording.
    if (plugin_host.ready() and plugin_host.g.midi_active) {
        var midi_events: [256]midi_input.MidiEvent = undefined;
        while (true) {
            const n = plugin_host.g.midi.drainEvents(midi_events[0..]);
            if (n == 0) break;
            const device_plugin = plugin_host.g.deviceTargetPlugin(state);
            controller_mapping.applyMidiEvents(state, midi_events[0..n], device_plugin);
            const now = std.Io.Clock.awake.now(clock_io);
            recording.processMidiEvents(state, midi_events[0..n], now);
            if (n < midi_events.len) break;
        }
    }
    recording.processKeyboardEvents(state);

    // Project after plugin tick so device names match freshly loaded choices.
    host_mod.g.projectChrome(state);
    project_runtime.handleRequests(state);
    media_drop.pollNativeDrops(state);

    {
        var root = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = theme.bg,
            .padding = dvui.Rect.all(0),
        });
        defer root.deinit();

        transport.draw(state);

        // Vertical split: top (browser + main) / bottom (device + clip)
        var vpaned = dvui.paned(@src(), .{
            .direction = .vertical,
            .collapsed_size = 0,
            .split_ratio = &state.top_split_ratio,
            .handle_size = 5,
            .handle_margin = 2,
        }, .{
            .expand = .both,
            .background = false,
            .margin = dvui.Rect.all(2),
        });
        defer vpaned.deinit();

        if (vpaned.showFirst()) {
            drawTop(state);
        }
        if (vpaned.showSecond()) {
            bottom.draw(state);
        }
    }

    // Capture for next frame's piano poll (cleared again in Window.begin).
    text_input_was_active = dvui.currentWindow().textInputRequested() != null;

    return .ok;
}

fn drawTop(state: *state_mod.State) void {
    if (!state.browser_open) {
        main_pane.draw(state);
        return;
    }

    var hpaned = dvui.paned(@src(), .{
        .direction = .horizontal,
        .collapsed_size = 0,
        .split_ratio = &state.browser_split_ratio,
        .handle_size = 5,
        .handle_margin = 2,
    }, .{
        .expand = .both,
        .background = false,
    });
    defer hpaned.deinit();

    if (hpaned.showFirst()) {
        browser.draw(state);
    }
    if (hpaned.showSecond()) {
        main_pane.draw(state);
    }
}

fn handleGlobalKeys(state: *state_mod.State) void {
    const wd = dvui.currentWindow().data();
    // Text fields own the keyboard (last frame flag — rect is wiped in Window.begin).
    // Without this, piano capture + device-chain backspace/delete steal keys from
    // the preset search box and similar entries.
    const typing = text_input_was_active;

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .key) continue;
        const ke = e.evt.key;

        // The computer piano owns its physical key positions before any
        // layout-dependent editor/global shortcuts see the translated key.
        if (!typing and plugin_host.ready() and !ke.mod.control() and !ke.mod.command() and !ke.mod.alt() and isPhysicalPianoKey(ke.code)) {
            e.handle(@src(), wd);
            dvui.refresh(null, @src(), wd.id);
            continue;
        }

        if (!typing and state.focused_pane == .bottom and state.bottom_mode == .sequencer and piano_roll.handleKey(state, ke)) {
            e.handle(@src(), wd);
            dvui.refresh(null, @src(), wd.id);
            continue;
        }

        if (!typing and state.focused_pane == .bottom and state.bottom_mode == .device and bottom.handleChainKey(state, ke)) {
            e.handle(@src(), wd);
            dvui.refresh(null, @src(), wd.id);
            continue;
        }

        if (ke.action != .down and ke.action != .repeat) continue;

        // Global document undo/redo (any focused pane).
        if (edit_actions.fromKey(ke)) |action| {
            if (action == .undo or action == .redo) {
                if (document_model.ready()) {
                    const store = &document_model.g;
                    const did = if (action == .undo) document_commands.undo(store) else document_commands.redo(store);
                    if (did) {
                        e.handle(@src(), wd);
                        if (host_mod.ready()) host_mod.g.projectChrome(state);
                        dvui.refresh(null, @src(), wd.id);
                        continue;
                    }
                }
            }
        }

        if (state.focused_pane == .session) {
            if (edit_actions.fromKey(ke)) |action| {
                const edited = switch (state.view_mode) {
                    .session => session_view.applyEditAction(state, action),
                    .arrangement => arrangement_view.applyEditAction(state, action),
                };
                if (edited) {
                    e.handle(@src(), wd);
                    dvui.refresh(null, @src(), wd.id);
                    continue;
                }
            }
        }

        switch (ke.code) {
            .space => {
                e.handle(@src(), wd);
                state.togglePlay();
                dvui.refresh(null, @src(), wd.id);
            },
            .tab => {
                e.handle(@src(), wd);
                if (ke.mod.shift()) {
                    state.toggleBottomMode();
                } else {
                    state.toggleViewMode();
                }
                dvui.refresh(null, @src(), wd.id);
            },
            .b => {
                // B toggles browser when not using cmd/ctrl/alt
                if (!ke.mod.control() and !ke.mod.command() and !ke.mod.alt()) {
                    e.handle(@src(), wd);
                    state.toggleBrowser();
                    dvui.refresh(null, @src(), wd.id);
                }
            },
            .left, .right, .up, .down => {
                if (state.focused_pane != .session or state.view_mode != .session) continue;
                e.handle(@src(), wd);
                switch (ke.code) {
                    .left => {
                        if (state.selected_track > 0) state.selected_track -= 1;
                    },
                    .right => {
                        if (state.selected_track + 1 < state.track_count) state.selected_track += 1;
                    },
                    .up => {
                        if (state.selected_scene > 0) state.selected_scene -= 1;
                    },
                    .down => {
                        if (state.selected_scene + 1 < state.scene_count) state.selected_scene += 1;
                    },
                    else => unreachable,
                }
                if (document_model.ready()) {
                    if (state.selectedSlot().kind == .empty) {
                        document_commands.setSessionAnchor(&document_model.g, state.selected_track, state.selected_scene, !ke.mod.shift());
                    } else {
                        document_commands.selectSessionSlot(&document_model.g, state.selected_track, state.selected_scene, ke.mod.shift());
                    }
                }
                dvui.refresh(null, @src(), wd.id);
            },
            .enter => {
                if (state.focused_pane != .session or state.view_mode != .session) continue;
                e.handle(@src(), wd);
                if (state.selectedSlot().kind == .empty and document_model.ready()) {
                    document_commands.createClip(&document_model.g, state.selected_track, state.selected_scene, state.beatsPerBar());
                    if (host_mod.ready()) host_mod.g.projectChrome(state);
                }
                state.bottom_mode = .sequencer;
                state.focused_pane = .bottom;
                dvui.refresh(null, @src(), wd.id);
            },
            .delete, .backspace => {
                if (state.focused_pane != .session or state.view_mode != .session or state.selectedSlot().kind == .empty) continue;
                e.handle(@src(), wd);
                if (document_model.ready()) {
                    document_commands.deleteClip(&document_model.g, state.selected_track, state.selected_scene);
                    if (host_mod.ready()) host_mod.g.projectChrome(state);
                }
                dvui.refresh(null, @src(), wd.id);
            },
            else => {},
        }
    }
}

fn keyboardDown(keys: [*c]const bool, count: c_int, scancode: c_int) bool {
    return scancode >= 0 and scancode < count and keys[@intCast(scancode)];
}

fn keyboardModifierDown(keys: [*c]const bool, count: c_int) bool {
    const modifiers = [_]c_int{
        sdl.SDL_SCANCODE_LCTRL,
        sdl.SDL_SCANCODE_RCTRL,
        sdl.SDL_SCANCODE_LALT,
        sdl.SDL_SCANCODE_RALT,
        sdl.SDL_SCANCODE_LGUI,
        sdl.SDL_SCANCODE_RGUI,
    };
    for (modifiers) |scancode| if (keyboardDown(keys, count, scancode)) return true;
    return false;
}

fn macModifierDown() bool {
    return flux_keyboard_physical_down(mac_keycode_lctrl) or
        flux_keyboard_physical_down(mac_keycode_rctrl) or
        flux_keyboard_physical_down(mac_keycode_lalt) or
        flux_keyboard_physical_down(mac_keycode_ralt) or
        flux_keyboard_physical_down(mac_keycode_lcmd) or
        flux_keyboard_physical_down(mac_keycode_rcmd);
}

/// Poll physical piano keys. On macOS, HID system key state is used so notes
/// keep routing when a floating/parented CLAP window holds OS focus (SDL only
/// updates keyboard state for its own key window). Elsewhere: SDL scancodes.
fn pollPhysicalPiano(state: *const state_mod.State) void {
    if (!plugin_host.ready()) return;
    const ph = &plugin_host.g;
    ph.clearKeyboardNotes();

    // Typing in a text field owns the keyboard — release any held piano notes.
    // (Uses last frame's wantTextInput; rect is wiped in Window.begin.)
    if (text_input_was_active) {
        octave_down_was_down = false;
        octave_up_was_down = false;
        return;
    }

    if (builtin.os.tag == .macos) {
        pollMacosPhysicalPiano(state, ph);
        return;
    }

    var count: c_int = 0;
    const keys = sdl.SDL_GetKeyboardState(&count);
    const octave_down = keyboardDown(keys, count, sdl.SDL_SCANCODE_Z);
    const octave_up = keyboardDown(keys, count, sdl.SDL_SCANCODE_X);

    if (!keyboardModifierDown(keys, count)) {
        if (octave_down and !octave_down_was_down) {
            ph.keyboard_octave = @max(ph.keyboard_octave - 1, -5);
        }
        if (octave_up and !octave_up_was_down) {
            ph.keyboard_octave = @min(ph.keyboard_octave + 1, 5);
        }

        const midi_track = recording.midiTargetTrack(state);
        for (piano_key_bindings) |binding| {
            if (keyboardDown(keys, count, binding.scancode)) {
                ph.applyKeyboardNote(midi_track, binding.offset, true);
            }
        }
    }
    octave_down_was_down = octave_down;
    octave_up_was_down = octave_up;
}

/// macOS path: CGEventSourceKeyState / HID, works with plugin child focus.
fn pollMacosPhysicalPiano(state: *const state_mod.State, ph: *plugin_host.PluginHost) void {
    const octave_down = flux_keyboard_physical_down(mac_keycode_z);
    const octave_up = flux_keyboard_physical_down(mac_keycode_x);

    if (!macModifierDown()) {
        if (octave_down and !octave_down_was_down) {
            ph.keyboard_octave = @max(ph.keyboard_octave - 1, -5);
        }
        if (octave_up and !octave_up_was_down) {
            ph.keyboard_octave = @min(ph.keyboard_octave + 1, 5);
        }

        const midi_track = recording.midiTargetTrack(state);
        for (piano_key_bindings) |binding| {
            if (flux_keyboard_physical_down(binding.mac_keycode)) {
                ph.applyKeyboardNote(midi_track, binding.offset, true);
            }
        }
    }
    octave_down_was_down = octave_down;
    octave_up_was_down = octave_up;
}

fn dvuiKeyToSdl(code: dvui.enums.Key) ?sdl.SDL_Keycode {
    return switch (code) {
        .a,
        .b,
        .c,
        .d,
        .e,
        .f,
        .g,
        .h,
        .i,
        .j,
        .k,
        .l,
        .m,
        .n,
        .o,
        .p,
        .q,
        .r,
        .s,
        .t,
        .u,
        .v,
        .w,
        .x,
        .y,
        .z,
        => @intCast(sdl.SDLK_A + @backingInt(code) - @backingInt(dvui.enums.Key.a)),
        .semicolon => sdl.SDLK_SEMICOLON,
        .comma => sdl.SDLK_COMMA,
        .period => sdl.SDLK_PERIOD,
        else => null,
    };
}

fn isPhysicalPianoKey(code: dvui.enums.Key) bool {
    const keycode = dvuiKeyToSdl(code) orelse return false;
    const scancode: c_int = @intCast(sdl.SDL_GetScancodeFromKey(keycode, null));
    if (scancode == sdl.SDL_SCANCODE_Z or scancode == sdl.SDL_SCANCODE_X) return true;
    for (piano_key_bindings) |binding| if (scancode == binding.scancode) return true;
    return false;
}
