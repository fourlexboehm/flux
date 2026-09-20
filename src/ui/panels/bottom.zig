//! Bottom detail panel: Device / Clip tabs + content.
//! Bottom Device/Clip panel and horizontal device rack.
//! Plugin pick loads via `ui/plugin_host` (CLAP catalog + DynLib).

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const icons = @import("../icons.zig");
const state_mod = @import("../state.zig");
const plugin_host = @import("../plugin_host.zig");
const audio_runtime = @import("../audio_runtime.zig");
const gui_float = @import("../../plugin/gui_float.zig");
const param_chrome = @import("param_chrome.zig");
const editors = @import("editors/root.zig");
const piano_roll = @import("../views/piano_roll.zig");
const audio_clip_view = @import("../views/audio_clip.zig");
const audio_engine_mod = @import("../../audio/audio_engine.zig");

fn currentEngine() ?*audio_engine_mod.AudioEngine {
    if (!audio_runtime.ready()) return null;
    if (audio_runtime.g.engine == null) return null;
    return &audio_runtime.g.engine.?;
}

/// Card `id_extra` the instrument/FX picker is for (0 = instrument, 900 = "+").
var picker_target_id: usize = 0;
/// Natural-space rect of that card; refreshed each frame while the picker is open.
var picker_anchor: ?dvui.Rect.Natural = null;

fn notePickerAnchor(id_extra: usize, rect_physical: dvui.Rect.Physical) void {
    if (!plugin_host.ready() or !plugin_host.g.picker_open) return;
    if (id_extra != picker_target_id) return;
    picker_anchor = rect_physical.toNatural();
}

pub fn draw(state: *state_mod.State) void {
    // Device names / selected slot projected from host in root.frame.

    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.panel,
        .padding = dvui.Rect.all(tokens.pad_panel),
        .corners = .round(tokens.radius_md),
    });
    defer panel.deinit();

    // Tab row — tight
    {
        var tabs = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_xs },
        });
        defer tabs.deinit();

        const dev_fill = if (state.bottom_mode == .device) theme.accent else theme.cell;
        const dev_text = if (state.bottom_mode == .device) theme.bg else theme.text;
        if (dvui.button(@src(), "Device", .{}, .{
            .color_fill = dev_fill,
            .color_text = dev_text,
            .min_size_content = .{ .h = tokens.control_h },
            .corners = .round(tokens.radius_sm),
            .padding = .{ .x = 6, .y = 1, .w = 6, .h = 1 },
            .gravity_y = 0.5,
        })) {
            state.bottom_mode = .device;
        }

        const clip_fill = if (state.bottom_mode == .sequencer) theme.accent else theme.cell;
        const clip_text = if (state.bottom_mode == .sequencer) theme.bg else theme.text;
        if (dvui.button(@src(), "Clip", .{}, .{
            .color_fill = clip_fill,
            .color_text = clip_text,
            .min_size_content = .{ .h = tokens.control_h },
            .margin = .{ .x = tokens.gap_xs, .y = 0, .w = 0, .h = 0 },
            .corners = .round(tokens.radius_sm),
            .padding = .{ .x = 6, .y = 1, .w = 6, .h = 1 },
            .gravity_y = 0.5,
        })) {
            state.bottom_mode = .sequencer;
        }

        const track_label: []const u8 = if (state.mixer_target == .master)
            "Master"
        else
            state.trackName(state.selected_track);
        dvui.label(@src(), "  {s} · Sc {d}", .{
            track_label,
            state.selected_scene + 1,
        }, .{
            .gravity_y = 0.5,
            .color_text = theme.text_dim,
            .margin = .{ .x = tokens.gap_group, .y = 0, .w = 0, .h = 0 },
        });
    }

    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.cell,
        .padding = dvui.Rect.all(tokens.gap_tight),
        .corners = .round(tokens.radius_sm),
    });
    defer content.deinit();

    switch (state.bottom_mode) {
        .device => drawDeviceChain(state),
        .sequencer => drawClipEditor(state),
    }
}

fn drawDeviceChain(state: *state_mod.State) void {
    const is_master = state.mixer_target == .master;
    const track = state.deviceTrack();
    if (is_master and state.device_target_kind != .fx) {
        state.device_target_kind = .fx;
        state.device_target_fx = 0;
    }

    // Full-height horizontal rack (zgui device panel): each card has its own
    // width by plugin type; chain scrolls when wider than the pane.
    //
    // DVUI: must set `horizontal = .auto` (bar mode alone defaults scroll to
    // none). Content must NOT expand horizontally so min_size_content width
    // becomes virtual_size (same pattern as session grid).
    // Master bus: FX-only chain (no instrument card), matching zgui.
    const fx_count = if (track < state_mod.max_tracks) state.fx_counts[track] else 0;
    const inst_plugin = if (is_master) null else pluginPtrFor(state, 0);
    const inst_empty = if (is_master) true else state.instrument_names[track].len == 0;

    var chain_w: f32 = 0;
    if (!is_master) chain_w += cardWidthFor(inst_plugin, inst_empty);
    var i: usize = 0;
    while (i < fx_count) : (i += 1) {
        if (chain_w > 0) chain_w += tokens.device_chain_gap + 12;
        chain_w += cardWidthFor(pluginPtrFor(state, i + 1), false);
    }
    if (chain_w > 0) chain_w += tokens.device_chain_gap + 12;
    chain_w += tokens.device_add_w;

    var scroll = dvui.scrollArea(@src(), .{
        .horizontal = .auto,
        .horizontal_bar = .auto,
        .vertical = .auto,
        .vertical_bar = .auto,
    }, .{
        .expand = .both,
        .background = false,
    });
    defer scroll.deinit();

    var chain = dvui.box(@src(), .{ .dir = .horizontal }, .{
        // No horizontal expand — that would fill the viewport and hide overflow.
        .expand = .vertical,
        .min_size_content = .{ .w = chain_w, .h = tokens.device_card_min_h },
        .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
    });
    defer chain.deinit();

    var cards_before: usize = 0;
    if (!is_master) {
        const inst_name = state.instrument_names[track];
        drawDeviceCard(state, .{
            .title = if (inst_empty) "Instrument" else inst_name,
            .kind_label = if (inst_empty) "Empty" else "Inst",
            .selected = state.device_target_kind == .instrument,
            .enabled = state.instrument_enabled[track],
            .empty = inst_empty,
            .id_extra = 0,
            .card_w = cardWidthFor(inst_plugin, inst_empty),
            .plugin = inst_plugin,
        });
        cards_before += 1;
    }

    i = 0;
    while (i < fx_count) : (i += 1) {
        if (cards_before > 0) chainChevron(i);
        const p = pluginPtrFor(state, i + 1);
        drawDeviceCard(state, .{
            .title = state.fx_names[track][i],
            .kind_label = "FX",
            .selected = state.device_target_kind == .fx and state.device_target_fx == i,
            .enabled = state.fx_enabled[track][i],
            .empty = false,
            .id_extra = i + 1,
            .card_w = cardWidthFor(p, false),
            .plugin = p,
        });
        cards_before += 1;
    }

    if (cards_before > 0) chainChevron(fx_count + 50);
    drawAddCard(state);

    // Picker is a fixed-width floating panel (not a full-pane replacement).
    if (plugin_host.ready() and plugin_host.g.picker_open) {
        drawPluginPicker(state);
    }
}

/// Per-plugin card width: hug param-chrome columns for embedded UIs; compact
/// for empty/external floating-GUI slots.
fn cardWidthFor(plugin: ?*const @import("clap-bindings").Plugin, empty: bool) f32 {
    if (empty) return tokens.device_w_empty;
    const p = plugin orelse return tokens.device_w_external;
    // Built-ins have bespoke editors with their own natural widths.
    if (editors.cardWidth(p)) |w| return w;
    if (gui_float.hasFloatingGui(p)) return tokens.device_w_external;
    return param_chrome.preferredCardWidth(p);
}

fn pluginPtrFor(state: *const state_mod.State, id_extra: usize) ?*const @import("clap-bindings").Plugin {
    if (!plugin_host.ready()) return null;
    const t = state.deviceTrack();
    if (t >= plugin_host.track_count) return null;
    if (id_extra == 0) {
        if (state.mixer_target == .master) return null;
        return plugin_host.g.instruments[t].getPlugin();
    }
    const fx = id_extra - 1;
    if (fx >= plugin_host.max_fx_slots) return null;
    return plugin_host.g.fx[t][fx].getPlugin();
}

const CardDraw = struct {
    title: []const u8,
    kind_label: []const u8,
    selected: bool,
    enabled: bool,
    empty: bool,
    /// 0 = instrument, 1.. = fx_index + 1
    id_extra: usize,
    card_w: f32,
    plugin: ?*const @import("clap-bindings").Plugin,
};

/// Full-height rack card: header + body with multi-column params or external summary.
fn drawDeviceCard(state: *state_mod.State, opts: CardDraw) void {
    const fill = if (opts.empty)
        theme.empty_slot_fill
    else
        theme.panel;
    const title_col = if (opts.selected) theme.text else if (opts.empty) theme.text_soft else theme.text;
    const border_col = if (opts.selected) theme.selected else theme.grid;

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = fill,
        .min_size_content = .{ .w = opts.card_w, .h = tokens.device_card_min_h },
        .max_size_content = .{ .w = opts.card_w, .h = std.math.floatMax(f32) },
        .expand = if (opts.empty) .none else .vertical,
        .corners = .round(tokens.radius_sm),
        .border = dvui.Rect.all(1),
        .color_border = border_col,
        .padding = .{ .x = tokens.gap_group, .y = tokens.gap_tight, .w = tokens.gap_group, .h = tokens.gap_tight },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .id_extra = opts.id_extra,
    });
    defer card.deinit();

    // Header: LED + name + window/remove
    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = tokens.device_header_h },
            .id_extra = opts.id_extra,
        });
        defer header.deinit();

        if (dvui.button(@src(), " ", .{}, .{
            .min_size_content = .{ .w = tokens.device_led, .h = tokens.device_led },
            .padding = .{},
            .color_fill = if (opts.enabled) theme.accent else theme.cell,
            .corners = .round(tokens.device_led / 2),
            .border = dvui.Rect.all(1),
            .color_border = if (opts.enabled) theme.accent_dim else theme.grid,
            .gravity_y = 0.5,
            .id_extra = opts.id_extra,
        })) toggleDeviceEnabled(state, opts.id_extra);

        if (dvui.button(@src(), opts.title, .{}, .{
            .expand = .horizontal,
            .color_fill = theme.colorFA(0, 0, 0, 0),
            .color_text = title_col,
            .padding = .{ .x = tokens.gap_tight, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
            .id_extra = opts.id_extra,
        })) {
            selectDevice(state, opts.id_extra);
            if (opts.id_extra == 0 and opts.empty) openPicker(state, false, opts.id_extra, card.data().rectScale().r);
        }

        if (!opts.empty) {
            var can_float = false;
            var gui_open = false;
            if (plugin_host.ready()) {
                if (slotForCard(state, opts.id_extra)) |slot| {
                    gui_open = slot.gui_open;
                    if (slot.getPlugin()) |p| can_float = gui_float.hasFloatingGui(p);
                }
            }
            if (can_float) {
                if (icons.button(@src(), if (gui_open) .close else .open_editor, .{
                    .fill = if (gui_open) theme.accent else theme.cell,
                    .color = if (gui_open) theme.bg else theme.text,
                    .id_extra = opts.id_extra,
                })) {
                    selectDevice(state, opts.id_extra);
                    if (plugin_host.ready()) plugin_host.g.toggleSelectedGui(state);
                }
            }
            if (icons.button(@src(), .remove, .{
                .fill = theme.cell,
                .color = theme.text_dim,
                .margin = .{ .x = tokens.gap_xs },
                .id_extra = opts.id_extra,
            })) {
                if (plugin_host.ready()) {
                    const t = state.deviceTrack();
                    if (opts.id_extra == 0) {
                        plugin_host.g.clearInstrument(t);
                    } else {
                        removeFxAt(state, t, opts.id_extra - 1);
                    }
                }
            }
        }
    }

    // Body
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.cell,
        .border = dvui.Rect.all(1),
        .color_border = theme.grid,
        .corners = .round(tokens.radius_sm),
        .padding = dvui.Rect.all(tokens.gap_group),
        .id_extra = opts.id_extra,
    });
    defer body.deinit();

    if (opts.empty) {
        dvui.label(@src(), "No instrument loaded", .{}, .{
            .color_text = theme.text_soft,
            .id_extra = opts.id_extra,
        });
        if (dvui.button(@src(), "Choose instrument…", .{}, .{
            .expand = .none,
            .min_size_content = .{ .h = tokens.control_h + 4 },
            .color_fill = theme.panel,
            .color_text = theme.text,
            .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = 0 },
            .corners = .round(tokens.radius_sm),
            .id_extra = opts.id_extra,
        })) openPicker(state, false, opts.id_extra, card.data().rectScale().r);
    } else if (!opts.enabled) {
        dvui.label(@src(), "Bypassed", .{}, .{
            .color_text = theme.solo_on,
            .id_extra = opts.id_extra,
        });
        if (opts.plugin) |p| {
            drawDeviceBody(state, p, opts.id_extra);
        }
    } else if (opts.plugin) |p| {
        drawDeviceBody(state, p, opts.id_extra);
    } else {
        dvui.label(@src(), "Loading…", .{}, .{
            .color_text = theme.text_soft,
            .id_extra = opts.id_extra,
        });
    }

    notePickerAnchor(opts.id_extra, card.data().rectScale().r);

    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, card.data())) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .press or !me.button.pointer()) continue;
        e.handle(@src(), card.data());
        selectDevice(state, opts.id_extra);
        dvui.refresh(null, @src(), card.data().id);
    }
}

fn selectDevice(state: *state_mod.State, id_extra: usize) void {
    if (id_extra == 0) {
        state.selectDeviceInstrument();
    } else {
        state.selectDeviceFx(id_extra - 1);
    }
}

fn removeFxAt(state: *state_mod.State, track: usize, fx_index: usize) void {
    if (!plugin_host.ready()) return;
    plugin_host.g.removeFx(track, fx_index, currentEngine());
    // Keep selection on a valid slot after compact.
    if (state.device_target_kind == .fx) {
        const n = plugin_host.g.fx_counts[track];
        if (n == 0) {
            if (state.mixer_target == .master) {
                state.device_target_fx = 0;
            } else {
                state.selectDeviceInstrument();
            }
        } else if (state.device_target_fx >= n) {
            state.device_target_fx = n - 1;
        } else if (state.device_target_fx > fx_index) {
            state.device_target_fx -= 1;
        }
    }
}

/// Device-chain keyboard shortcuts (zgui `handleChainShortcuts` parity).
/// Returns true when the key was consumed.
pub fn handleChainKey(state: *state_mod.State, ke: dvui.Event.Key) bool {
    if (state.focused_pane != .bottom or state.bottom_mode != .device) return false;
    if (ke.action != .down and ke.action != .repeat) return false;
    if (!plugin_host.ready()) return false;
    if (plugin_host.g.picker_open) return false;
    // Never steal backspace/delete/arrows from an active text field (preset search).
    if (dvui.currentWindow().textInputRequested() != null) return false;

    const is_master = state.mixer_target == .master;
    const track = state.deviceTrack();
    if (track >= plugin_host.track_count) return false;
    const fx_count = plugin_host.g.fx_counts[track];
    const fx_selected = state.device_target_kind == .fx and fx_count > 0;
    const mod = ke.mod.control() or ke.mod.command();

    switch (ke.code) {
        .delete, .backspace => {
            if (fx_selected) {
                removeFxAt(state, track, state.device_target_fx);
                return true;
            }
            if (!is_master and state.device_target_kind == .instrument) {
                plugin_host.g.clearInstrument(track);
                return true;
            }
            return false;
        },
        .d => {
            if (!mod or !fx_selected) return false;
            if (plugin_host.g.duplicateFx(track, state.device_target_fx, currentEngine())) {
                state.selectDeviceFx(state.device_target_fx + 1);
            }
            return true;
        },
        .left => {
            if (mod) {
                if (fx_selected and state.device_target_fx > 0) {
                    const from = state.device_target_fx;
                    const to = from - 1;
                    plugin_host.g.moveFx(track, from, to, currentEngine());
                    state.device_target_fx = to;
                }
                return fx_selected;
            }
            if (fx_selected) {
                if (state.device_target_fx > 0) {
                    state.selectDeviceFx(state.device_target_fx - 1);
                } else if (!is_master) {
                    state.selectDeviceInstrument();
                }
                return true;
            }
            return false;
        },
        .right => {
            if (mod) {
                if (fx_selected and state.device_target_fx + 1 < fx_count) {
                    const from = state.device_target_fx;
                    const to = from + 1;
                    plugin_host.g.moveFx(track, from, to, currentEngine());
                    state.device_target_fx = to;
                }
                return fx_selected;
            }
            if (state.device_target_kind == .instrument and fx_count > 0) {
                state.selectDeviceFx(0);
                return true;
            }
            if (fx_selected and state.device_target_fx + 1 < fx_count) {
                state.selectDeviceFx(state.device_target_fx + 1);
                return true;
            }
            return false;
        },
        else => return false,
    }
}

fn slotForCard(state: *const state_mod.State, id_extra: usize) ?*plugin_host.LoadedPlugin {
    if (!plugin_host.ready()) return null;
    const t = state.deviceTrack();
    if (t >= plugin_host.track_count) return null;
    if (id_extra == 0) {
        if (state.mixer_target == .master) return null;
        return &plugin_host.g.instruments[t];
    }
    const fx = id_extra - 1;
    if (fx >= plugin_host.max_fx_slots) return null;
    return &plugin_host.g.fx[t][fx];
}

fn toggleDeviceEnabled(state: *state_mod.State, id_extra: usize) void {
    selectDevice(state, id_extra);
    const host_mod = @import("../host.zig");
    if (host_mod.ready()) {
        host_mod.g.toggleDeviceEnabled(state);
    } else {
        state.toggleDeviceEnabled();
    }
}

fn chainChevron(id_extra: usize) void {
    var wrap = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 12, .h = tokens.device_card_min_h },
        .expand = .vertical,
        .margin = .{ .x = tokens.device_chain_gap * 0.5, .y = 0, .w = tokens.device_chain_gap * 0.5, .h = 0 },
        .gravity_y = 0.5,
        .id_extra = id_extra,
    });
    defer wrap.deinit();
    icons.draw(@src(), .chevron_right, .{
        .color = theme.text_soft,
        .size = tokens.icon_sm,
        .id_extra = id_extra,
    });
}

const picker_add_id: usize = 900;

/// Bespoke built-in editor when one exists, else generic CLAP param chrome.
fn drawDeviceBody(state: *state_mod.State, plugin: *const @import("clap-bindings").Plugin, id_extra: usize) void {
    // Instruments get a per-device preset combo (zgui device panel parity).
    if (id_extra == 0) drawInstrumentPresetRow(state, plugin);

    const fx_index: i8 = if (id_extra == 0) -1 else @intCast(id_extra - 1);
    const target = param_chrome.Target{ .track = state.deviceTrack(), .fx_index = fx_index };
    if (editors.draw(plugin, target, id_extra)) return;
    param_chrome.draw(plugin, target, id_extra);
}

// ── Per-device preset combo (instrument cards) ────────────────────────────────

const max_preset_combo: usize = 256;
const preset_placeholder = "(Preset)";
/// Max height of the open preset list (scrolls when content exceeds this).
const preset_list_max_h: f32 = 220;

/// Search buffer + rebuilt label table for the instrument preset list.
var preset_search_buf: [64]u8 = @splat(0);
var preset_search_len: usize = 0;
var preset_filter_choice: i32 = -1;
var preset_filter_plugin_id: [128]u8 = undefined;
var preset_filter_plugin_id_len: usize = 0;
var preset_label_storage: [max_preset_combo][96]u8 = undefined;
var preset_labels: [max_preset_combo][]const u8 = undefined;
var preset_entry_indices: [max_preset_combo]usize = undefined;
var preset_label_count: usize = 0;
var preset_menu_open: bool = false;
var preset_menu_track: usize = 0;

fn presetSearchText() []const u8 {
    return preset_search_buf[0..preset_search_len];
}

fn sanitizePresetName(name: []const u8) []const u8 {
    // Some factory presets embed path junk; show the leaf-ish tail.
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| {
        if (slash + 1 < name.len) return name[slash + 1 ..];
    }
    return name;
}

fn rebuildPresetCombo(plugin_id: []const u8, choice_index: i32) void {
    preset_filter_choice = choice_index;
    const copy_len = @min(plugin_id.len, preset_filter_plugin_id.len);
    @memcpy(preset_filter_plugin_id[0..copy_len], plugin_id[0..copy_len]);
    preset_filter_plugin_id_len = copy_len;

    preset_label_count = 0;
    if (!plugin_host.ready()) return;

    const entries = plugin_host.g.queryPresets(presetSearchText(), "", true);
    for (entries, 0..) |entry, idx| {
        if (preset_label_count >= max_preset_combo) break;
        if (!std.mem.eql(u8, entry.plugin_id, plugin_id)) continue;
        const clean = sanitizePresetName(entry.name);
        const written = std.fmt.bufPrint(&preset_label_storage[preset_label_count], "{s}", .{clean}) catch continue;
        preset_labels[preset_label_count] = written;
        preset_entry_indices[preset_label_count] = idx;
        preset_label_count += 1;
    }
}

fn drawInstrumentPresetRow(state: *state_mod.State, plugin: *const @import("clap-bindings").Plugin) void {
    if (!plugin_host.ready() or plugin_host.g.preset_catalog == null) return;
    const track = state.deviceTrack();
    if (track >= plugin_host.track_count) return;

    const plugin_id = std.mem.span(plugin.descriptor.id);
    if (plugin_id.len == 0) return;

    const choice = plugin_host.g.instrument_choice[track].choice_index;
    const need_rebuild = choice != preset_filter_choice or
        !std.mem.eql(u8, plugin_id, preset_filter_plugin_id[0..preset_filter_plugin_id_len]);
    if (need_rebuild) rebuildPresetCombo(plugin_id, choice);

    // Nothing in the DB for this plugin — omit the row (built-ins often empty).
    if (preset_label_count == 0 and presetSearchText().len == 0) return;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_tight },
        .id_extra = track,
    });
    defer row.deinit();

    dvui.label(@src(), "Preset", .{}, .{
        .color_text = theme.text_dim,
        .gravity_y = 0.5,
        .id_extra = track,
    });

    {
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &preset_search_buf },
            .placeholder = "Search…",
        }, .{
            .min_size_content = .{ .w = 72, .h = tokens.control_h },
            .margin = .{ .x = tokens.gap_tight, .y = 0, .w = 0, .h = 0 },
            .id_extra = track,
        });
        const text = te.getText();
        if (text.len != preset_search_len or !std.mem.eql(u8, text, presetSearchText())) {
            preset_search_len = text.len;
            rebuildPresetCombo(plugin_id, choice);
            // Keep the list open while filtering.
            if (preset_menu_open and preset_menu_track == track) {
                // no-op; open flag stays
            } else if (presetSearchText().len > 0) {
                preset_menu_open = true;
                preset_menu_track = track;
            }
        }
        te.deinit();
    }

    // Current selection label for the trigger button.
    const selected_label: []const u8 = blk: {
        if (plugin_host.g.instrument_preset_list_index[track]) |stored| {
            if (stored < preset_label_count) break :blk preset_labels[stored];
        }
        break :blk preset_placeholder;
    };

    // Dropdown trigger: open a max-height floating list with a scroll area
    // (stock `dvui.dropdown` does not clamp height, so long lists fall off-screen).
    var trigger_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = tokens.gap_tight, .y = 0, .w = 0, .h = 0 },
        .id_extra = track,
    });
    defer trigger_box.deinit();

    if (dvui.button(@src(), selected_label, .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = tokens.control_h },
        .color_fill = theme.cell,
        .color_text = theme.text,
        .border = dvui.Rect.all(1),
        .color_border = theme.grid,
        .corners = .round(tokens.radius_sm),
        .id_extra = track,
    })) {
        if (preset_menu_open and preset_menu_track == track) {
            preset_menu_open = false;
        } else {
            preset_menu_open = true;
            preset_menu_track = track;
            rebuildPresetCombo(plugin_id, choice);
        }
    }

    if (!(preset_menu_open and preset_menu_track == track)) return;

    // Floating window with open_flag so click-X / focus loss can clear the flag.
    // Explicit max height + scrollArea — stock `dropdown` grows unbounded.
    const list_w: f32 = 260;
    var fw = dvui.floatingWindow(@src(), .{
        .open_flag = &preset_menu_open,
        .modal = false,
        .resize = .none,
        .stay_above_parent_window = true,
    }, .{
        .min_size_content = .{ .w = list_w, .h = 100 },
        .max_size_content = .{ .w = list_w, .h = preset_list_max_h },
        .background = true,
        .color_fill = theme.panel,
        .border = dvui.Rect.all(1),
        .color_border = theme.accent,
        .corners = .round(tokens.radius_sm),
        .padding = dvui.Rect.all(tokens.gap_tight),
        .id_extra = track,
    });
    defer fw.deinit();
    fw.dragAreaSet(dvui.windowHeader("Presets", "", &preset_menu_open));

    var scroll = dvui.scrollArea(@src(), .{
        .horizontal = .none,
        .horizontal_bar = .hide,
        .vertical = .auto,
        .vertical_bar = .auto,
    }, .{
        .expand = .both,
        .min_size_content = .{ .w = list_w - 8, .h = 60 },
        .max_size_content = .{ .w = list_w - 8, .h = preset_list_max_h - 36 },
        .id_extra = track,
    });
    defer scroll.deinit();

    if (dvui.button(@src(), preset_placeholder, .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = tokens.control_h - 2 },
        .color_fill = theme.cell,
        .color_text = theme.text_soft,
        .corners = .round(tokens.radius_sm),
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .id_extra = track,
    })) {
        plugin_host.g.instrument_preset_list_index[track] = null;
        preset_menu_open = false;
    }

    if (preset_label_count == 0) {
        dvui.label(@src(), "No matching presets", .{}, .{
            .color_text = theme.text_soft,
            .id_extra = track,
        });
        return;
    }

    for (0..preset_label_count) |row_i| {
        const name = preset_labels[row_i];
        if (dvui.button(@src(), name, .{}, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = tokens.control_h - 2 },
            .color_fill = theme.cell,
            .color_text = theme.text,
            .corners = .round(tokens.radius_sm),
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            .id_extra = row_i + 1 + track * 1000,
        })) {
            const entry_idx = preset_entry_indices[row_i];
            if (plugin_host.g.preset_catalog) |*catalog| {
                if (catalog.resolve(entry_idx) catch null) |entry| {
                    plugin_host.g.loadPresetOnTrackFromList(track, row_i, entry);
                }
            }
            preset_menu_open = false;
        }
    }
}

fn drawAddCard(state: *state_mod.State) void {
    // Box wraps the + so we have a stable rect to center the picker on.
    var wrap = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = tokens.device_add_w, .h = 40 },
        .max_size_content = .{ .w = tokens.device_add_w, .h = 40 },
        .expand = .none,
        .id_extra = picker_add_id,
    });
    defer wrap.deinit();
    notePickerAnchor(picker_add_id, wrap.data().rectScale().r);

    if (dvui.button(@src(), "+", .{}, .{
        .expand = .both,
        .color_fill = theme.panel,
        .color_text = theme.text_dim,
        .border = dvui.Rect.all(1),
        .color_border = theme.grid,
        .corners = .round(tokens.radius_sm),
        .id_extra = picker_add_id,
    })) {
        openPicker(state, true, picker_add_id, wrap.data().rectScale().r);
    }
}

fn openPicker(state: *state_mod.State, for_fx: bool, target_id: usize, anchor_physical: dvui.Rect.Physical) void {
    if (!plugin_host.ready()) return;
    plugin_host.g.picker_open = true;
    plugin_host.g.picker_for_fx = for_fx;
    picker_target_id = target_id;
    // center_on is applied once (auto_pos); capture the card rect at click time.
    picker_anchor = anchor_physical.toNatural();
    if (for_fx) {
        // Target will be the next free FX slot after pick.
        state.bottom_mode = .device;
    } else {
        state.selectDeviceInstrument();
    }
}

fn drawPluginPicker(state: *state_mod.State) void {
    const ph = &plugin_host.g;
    const track = state.deviceTrack();
    const for_fx = ph.picker_for_fx;

    // Fixed-width floating panel centered on the card being chosen (instrument
    // empty slot or "+" add). Does not stretch the device pane.
    var fw = dvui.floatingWindow(@src(), .{
        .open_flag = &ph.picker_open,
        .modal = false,
        .resize = .none,
        .stay_above_parent_window = true,
        .center_on = picker_anchor,
        .window_avoid = .nudge,
    }, .{
        .min_size_content = .{ .w = tokens.plugin_list_w, .h = 280 },
        .max_size_content = .{ .w = tokens.plugin_list_w, .h = 400 },
        .background = true,
        .color_fill = theme.panel,
        .border = dvui.Rect.all(1),
        .color_border = theme.accent,
        .corners = .round(tokens.radius_md),
        .padding = dvui.Rect.all(tokens.pad_panel),
    });
    defer fw.deinit();

    {
        const title: []const u8 = if (for_fx) "Add audio FX" else "Choose instrument";
        fw.dragAreaSet(dvui.windowHeader(title, "", &ph.picker_open));
    }

    // None option for instruments
    if (!for_fx) {
        if (dvui.button(@src(), "None (clear)", .{}, .{
            .expand = .horizontal,
            .color_fill = theme.cell,
            .color_text = theme.text_soft,
            .min_size_content = .{ .h = tokens.control_h },
            .corners = .round(tokens.radius_sm),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        })) {
            ph.setInstrumentChoice(track, 0);
            ph.picker_open = false;
        }
    }

    var scroll = dvui.scrollArea(@src(), .{
        .horizontal = .none,
        .horizontal_bar = .hide,
        .vertical = .auto,
        .vertical_bar = .auto,
    }, .{
        .expand = .both,
        .min_size_content = .{ .h = 160 },
        .max_size_content = .width(tokens.plugin_list_w - 8),
    });
    defer scroll.deinit();

    const choices: []const i32 = if (for_fx) ph.fxChoices() else ph.instrumentChoices();
    if (choices.len == 0) {
        dvui.label(@src(), "Catalog empty — build clap bundles (zig build) or install system CLAPs.", .{}, .{
            .color_text = theme.text_soft,
        });
        return;
    }

    for (choices, 0..) |choice, i| {
        const name = ph.entryName(choice);
        if (name.len == 0) continue;
        if (dvui.button(@src(), name, .{}, .{
            .expand = .horizontal,
            .color_fill = theme.cell,
            .color_text = theme.text,
            .min_size_content = .{ .h = tokens.control_h - 2 },
            .max_size_content = .width(tokens.plugin_list_w - 16),
            .corners = .round(tokens.radius_sm),
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            .id_extra = i,
        })) {
            if (for_fx) {
                if (ph.addFxSlot(track, choice)) {
                    state.selectDeviceFx(ph.fx_counts[track] - 1);
                }
            } else {
                ph.setInstrumentChoice(track, choice);
                state.selectDeviceInstrument();
            }
            ph.picker_open = false;
        }
    }
}

fn drawClipEditor(state: *state_mod.State) void {
    const slot = state.selectedSlot();

    if (slot.kind == .empty) {
        dvui.label(@src(), "No clip selected — use + on an empty session slot to create one.", .{}, .{
            .color_text = theme.text_soft,
            .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        });
        return;
    }

    switch (slot.kind) {
        .empty => {},
        .midi => {
            dvui.label(@src(), "{s} · {d:.0} bars", .{ if (slot.name.len > 0) slot.name else "Untitled MIDI", slot.bars }, .{
                .color_text = theme.text_dim,
            });
            piano_roll.draw(state);
        },
        .audio => audio_clip_view.draw(state),
    }
}
