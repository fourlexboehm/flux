//! Host shell frame: transport + browser + main + bottom panel.
//! Entry: `src/main.zig`. Port from `src/ui_zgui/` incrementally.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const state_mod = @import("state.zig");
const host_mod = @import("host.zig");
const plugin_host = @import("plugin_host.zig");
const audio_runtime = @import("audio_runtime.zig");
const transport = @import("transport.zig");
const browser = @import("panels/browser.zig");
const bottom = @import("panels/bottom.zig");
const main_pane = @import("views/main_pane.zig");

pub fn init(win: *dvui.Window) !void {
    theme.apply(win);
    // Empty document (session_ops.init + matching arr lanes). No demo seed.
    host_mod.initGlobal(win.gpa);
    host_mod.g.projectChrome(&state_mod.g);
    // CLAP catalog (DynLib load on device pick). Builtins need zig-out/lib bundles.
    plugin_host.initGlobal(win.gpa);
    // Full AudioEngine (graph + metronome + meters + live plugins).
    audio_runtime.initGlobal(win.gpa, state_mod.g.buffer_frames);
    std.log.info("flux-dvui host ready (backend={s})", .{@tagName(dvui.backend.kind)});
    std.log.info("  document: empty session+arrangement", .{});
    std.log.info("  audio: full AudioEngine + CLAP catalog + floating plugin GUIs", .{});
    std.log.info("  MIDI: computer keyboard A–; (Z/X octave) + hardware portmidi", .{});
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
}

pub fn frame() !dvui.App.Result {
    const state = &state_mod.g;
    std.debug.assert(host_mod.ready());
    host_mod.g.drainPlaybackRequests(state);
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
    handleProjectRequests(state);

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

fn handleProjectRequests(state: *state_mod.State) void {
    // Full DAWproject I/O still uses ui_zgui.State; wire adapter later.
    if (state.load_project_request) {
        state.load_project_request = false;
        std.log.info("project load: not yet on DVUI host (needs DAWproject adapter)", .{});
    }
    if (state.save_project_request) {
        state.save_project_request = false;
        if (state.project_path_len == 0) {
            state.save_project_as_request = true;
        } else {
            std.log.info("project save: not yet on DVUI host (path set, adapter pending)", .{});
        }
    }
    if (state.save_project_as_request) {
        state.save_project_as_request = false;
        std.log.info("project save-as: not yet on DVUI host (needs DAWproject adapter)", .{});
    }
}

fn handleGlobalKeys(state: *state_mod.State) void {
    const wd = dvui.currentWindow().data();
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .key) continue;
        const ke = e.evt.key;

        // Computer-keyboard MIDI (edge on down/up; ignore when modifiers held).
        if (plugin_host.ready() and !ke.mod.control() and !ke.mod.command() and !ke.mod.alt()) {
            if (handlePianoKey(state, ke)) {
                e.handle(@src(), wd);
                dvui.refresh(null, @src(), wd.id);
                continue;
            }
        }

        if (ke.action != .down and ke.action != .repeat) continue;

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
            else => {},
        }
    }
}

/// A–; white/black piano map + Z/X octave. Returns true if consumed.
fn handlePianoKey(state: *state_mod.State, ke: dvui.Event.Key) bool {
    const ph = &plugin_host.g;
    const track = state.selected_track;

    // Octave change on edge down only.
    if (ke.action == .down) {
        if (ke.code == .z) {
            ph.keyboard_octave = @max(ph.keyboard_octave - 1, -5);
            ph.clearLiveKeys();
            return true;
        }
        if (ke.code == .x) {
            ph.keyboard_octave = @min(ph.keyboard_octave + 1, 5);
            ph.clearLiveKeys();
            return true;
        }
    }

    const offset: ?u8 = switch (ke.code) {
        .a => 0,
        .w => 1,
        .s => 2,
        .e => 3,
        .d => 4,
        .f => 5,
        .t => 6,
        .g => 7,
        .y => 8,
        .h => 9,
        .u => 10,
        .j => 11,
        .k => 12,
        .o => 13,
        .l => 14,
        .p => 15,
        .semicolon => 16,
        else => null,
    };
    const off = offset orelse return false;

    switch (ke.action) {
        .down => {
            // Ignore key-repeat for note-on.
            ph.applyKeyboardNote(track, off, true);
            return true;
        },
        .up => {
            ph.applyKeyboardNote(track, off, false);
            return true;
        },
        .repeat => return true, // swallow repeat
    }
}
