//! Host shell frame: transport + browser + main + bottom panel.
//! Entry: `src/main.zig`. Port from `src/ui_zgui/` incrementally.

const std = @import("std");
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

const sdl = dvui.backend.c;

const PianoKeyBinding = struct {
    scancode: c_int,
    offset: u8,
};

/// Physical positions of the QWERTY A–; piano rows. SDL scancodes are layout
/// independent, so these positions stay put under Dvorak and other layouts.
const piano_key_bindings = [_]PianoKeyBinding{
    .{ .scancode = sdl.SDL_SCANCODE_A, .offset = 0 },
    .{ .scancode = sdl.SDL_SCANCODE_W, .offset = 1 },
    .{ .scancode = sdl.SDL_SCANCODE_S, .offset = 2 },
    .{ .scancode = sdl.SDL_SCANCODE_E, .offset = 3 },
    .{ .scancode = sdl.SDL_SCANCODE_D, .offset = 4 },
    .{ .scancode = sdl.SDL_SCANCODE_F, .offset = 5 },
    .{ .scancode = sdl.SDL_SCANCODE_T, .offset = 6 },
    .{ .scancode = sdl.SDL_SCANCODE_G, .offset = 7 },
    .{ .scancode = sdl.SDL_SCANCODE_Y, .offset = 8 },
    .{ .scancode = sdl.SDL_SCANCODE_H, .offset = 9 },
    .{ .scancode = sdl.SDL_SCANCODE_U, .offset = 10 },
    .{ .scancode = sdl.SDL_SCANCODE_J, .offset = 11 },
    .{ .scancode = sdl.SDL_SCANCODE_K, .offset = 12 },
    .{ .scancode = sdl.SDL_SCANCODE_O, .offset = 13 },
    .{ .scancode = sdl.SDL_SCANCODE_L, .offset = 14 },
    .{ .scancode = sdl.SDL_SCANCODE_P, .offset = 15 },
    .{ .scancode = sdl.SDL_SCANCODE_SEMICOLON, .offset = 16 },
};

var octave_down_was_down = false;
var octave_up_was_down = false;

pub fn init(win: *dvui.Window) !void {
    theme.apply(win);
    // Empty document (session_ops.init + matching arr lanes). No demo seed.
    document_model.initGlobal(win.gpa);
    host_mod.initGlobal(win.gpa);
    host_mod.g.projectChrome(&state_mod.g);
    // CLAP catalog (DynLib load on device pick). Builtins need zig-out/lib bundles.
    plugin_host.initGlobal(win.gpa);
    // Full AudioEngine (graph + metronome + meters + live plugins).
    audio_runtime.initGlobal(win.gpa, state_mod.g.buffer_frames);
    std.log.info("flux-dvui host ready (backend={s})", .{@tagName(dvui.backend.kind)});
    std.log.info("  document: empty session+arrangement", .{});
    std.log.info("  audio: full AudioEngine + CLAP catalog + floating plugin GUIs", .{});
    std.log.info("  MIDI: physical keyboard A–; positions (Z/X octave) + hardware portmidi", .{});
    std.log.info("  Space = play/stop, Tab = session/arrangement, Shift+Tab = device/clip, B = browser", .{});
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
    pollPhysicalPiano(state);
    handleGlobalKeys(state);

    // Full engine: buffer, MIDI, plugin sync, publish host+chrome → RT, pull meters.
    if (audio_runtime.ready()) {
        audio_runtime.g.tick(&host_mod.g, state);
    } else if (plugin_host.ready()) {
        // No audio device: still poll MIDI / keyboard live keys for UI feedback.
        plugin_host.g.tickLiveMidi(state.selected_track);
    }
    // Project after plugin tick so device names match freshly loaded choices.
    host_mod.g.projectChrome(state);
    project_runtime.handleRequests(state);

    // Playhead advances on the UI thread (same as zgui `ui_zgui/recording.tick`).
    // Audio thread renders graph + metronome from the published snapshot.
    if (state.playing) {
        const win = dvui.currentWindow();
        const now = win.frame_time_ns;
        if (state.last_frame_time_ns != 0 and now > state.last_frame_time_ns) {
            const dt_ns = now - state.last_frame_time_ns;
            const dt = @as(f32, @floatFromInt(dt_ns)) / 1e9;
            if (dt > 0 and dt < 0.25) {
                state.playhead_beat += dt * (state.bpm / 60.0);
            }
        }
        state.last_frame_time_ns = now;
        dvui.refresh(null, @src(), win.data().id);
    } else {
        state.last_frame_time_ns = 0;
    }

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
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .key) continue;
        const ke = e.evt.key;

        // The computer piano owns its physical key positions before any
        // layout-dependent editor/global shortcuts see the translated key.
        if (plugin_host.ready() and !ke.mod.control() and !ke.mod.command() and !ke.mod.alt() and isPhysicalPianoKey(ke.code)) {
            e.handle(@src(), wd);
            dvui.refresh(null, @src(), wd.id);
            continue;
        }

        if (state.focused_pane == .bottom and state.bottom_mode == .sequencer and piano_roll.handleKey(state, ke)) {
            e.handle(@src(), wd);
            dvui.refresh(null, @src(), wd.id);
            continue;
        }

        if (ke.action != .down and ke.action != .repeat) continue;

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

/// Poll SDL's physical key state instead of DVUI's layout-translated key names.
fn pollPhysicalPiano(state: *const state_mod.State) void {
    if (!plugin_host.ready()) return;
    const ph = &plugin_host.g;
    var count: c_int = 0;
    const keys = sdl.SDL_GetKeyboardState(&count);
    const octave_down = keyboardDown(keys, count, sdl.SDL_SCANCODE_Z);
    const octave_up = keyboardDown(keys, count, sdl.SDL_SCANCODE_X);

    ph.clearKeyboardNotes();
    if (!keyboardModifierDown(keys, count)) {
        if (octave_down and !octave_down_was_down) {
            ph.keyboard_octave = @max(ph.keyboard_octave - 1, -5);
        }
        if (octave_up and !octave_up_was_down) {
            ph.keyboard_octave = @min(ph.keyboard_octave + 1, 5);
        }

        for (piano_key_bindings) |binding| {
            if (keyboardDown(keys, count, binding.scancode)) {
                ph.applyKeyboardNote(state.selected_track, binding.offset, true);
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
