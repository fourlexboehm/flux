//! Bottom detail panel: Device / Clip tabs + content.
//! Device chain chrome ports layout from `ui_zgui/panels/device.zig`.
//! Plugin pick loads via `ui/plugin_host` (CLAP catalog + DynLib).

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const icons = @import("../icons.zig");
const state_mod = @import("../state.zig");
const plugin_host = @import("../plugin_host.zig");
const gui_float = @import("../../plugin/gui_float.zig");
const piano_roll = @import("../views/piano_roll.zig");

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

        dvui.label(@src(), "  {s} · Sc {d}", .{
            state.trackName(state.selected_track),
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
    const track = state.selected_track;
    if (plugin_host.ready() and plugin_host.g.picker_open) {
        drawPluginPicker(state);
        return;
    }

    const fx_count = state.fx_counts[track];
    const chain_w = tokens.device_card_w * @as(f32, @floatFromInt(fx_count + 1)) +
        22 * @as(f32, @floatFromInt(fx_count + 1)) + tokens.device_add_w + 8;

    {
        var scroll = dvui.scrollArea(@src(), .{
            .horizontal_bar = .auto,
            .vertical_bar = .auto,
        }, .{
            .expand = .both,
            .min_size_content = .{ .h = tokens.device_chain_h },
            .background = false,
        });
        defer scroll.deinit();

        var chain = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = chain_w, .h = tokens.device_chain_h },
            .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
        });
        defer chain.deinit();

        const inst_name = state.instrument_names[track];
        const has_inst = inst_name.len > 0;
        drawDeviceChip(state, .{
            .title = if (has_inst) inst_name else "Instrument",
            .kind_label = if (has_inst) "Inst" else "Empty",
            .selected = state.device_target_kind == .instrument,
            .enabled = state.instrument_enabled[track],
            .empty = !has_inst,
            .id_extra = 0,
        });

        var i: usize = 0;
        while (i < fx_count) : (i += 1) {
            chainChevron(i);
            drawDeviceChip(state, .{
                .title = state.fx_names[track][i],
                .kind_label = "FX",
                .selected = state.device_target_kind == .fx and state.device_target_fx == i,
                .enabled = state.fx_enabled[track][i],
                .empty = false,
                .id_extra = i + 1,
            });
        }

        chainChevron(fx_count + 50);
        drawAddCard(state, track, fx_count);
    }
}

/// Fills remaining bottom-pane height under the chip strip: name, enable, GUI.
fn drawSelectedDeviceDetail(state: *state_mod.State) void {
    const track = state.selected_track;

    var detail = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.panel,
        .padding = dvui.Rect.all(tokens.pad_panel),
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        .corners = .round(tokens.radius_sm),
        .border = dvui.Rect.all(1),
        .color_border = theme.grid,
    });
    defer detail.deinit();

    const kind_label: []const u8 = switch (state.device_target_kind) {
        .instrument => "Instrument",
        .fx => "FX",
    };
    const name: []const u8 = switch (state.device_target_kind) {
        .instrument => if (state.instrument_names[track].len > 0)
            state.instrument_names[track]
        else
            "(empty)",
        .fx => blk: {
            const fx = state.device_target_fx;
            if (fx < state.fx_counts[track] and state.fx_names[track][fx].len > 0)
                break :blk state.fx_names[track][fx];
            break :blk "(empty)";
        },
    };
    const enabled = switch (state.device_target_kind) {
        .instrument => state.instrument_enabled[track],
        .fx => if (state.device_target_fx < state_mod.max_fx_slots)
            state.fx_enabled[track][state.device_target_fx]
        else
            true,
    };

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_tight },
        });
        defer row.deinit();

        dvui.label(@src(), "{s} · {s}", .{ kind_label, name }, .{
            .color_text = theme.text,
            .gravity_y = 0.5,
        });

        if (dvui.button(@src(), if (enabled) "Enabled" else "Bypassed", .{}, .{
            .color_fill = if (enabled) theme.accent_dim else theme.cell,
            .color_text = theme.text,
            .min_size_content = .{ .h = tokens.control_h },
            .corners = .round(tokens.radius_sm),
            .padding = .{ .x = 6, .y = 1, .w = 6, .h = 1 },
            .margin = .{ .x = tokens.gap_group, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
        })) {
            const id_extra: usize = switch (state.device_target_kind) {
                .instrument => 0,
                .fx => state.device_target_fx + 1,
            };
            toggleDeviceEnabled(state, id_extra);
        }
    }

    const has_plugin = name.len > 0 and !std.mem.eql(u8, name, "(empty)");
    if (!has_plugin) {
        dvui.label(@src(), "Select a device or use + to load a CLAP from the catalog.", .{}, .{
            .color_text = theme.text_soft,
        });
        return;
    }

    var gui_open = false;
    var can_float = false;
    if (plugin_host.ready()) {
        if (plugin_host.g.selectedSlot(state)) |slot| {
            gui_open = slot.gui_open;
            if (slot.getPlugin()) |p| {
                can_float = gui_float.hasFloatingGui(p);
            }
        }
    }

    {
        var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer actions.deinit();

        const gui_label: []const u8 = if (gui_open) "Close GUI" else "Open GUI";
        const gui_fill = if (gui_open) theme.accent else theme.cell;
        const gui_text = if (gui_open) theme.bg else theme.text;
        if (dvui.button(@src(), gui_label, .{}, .{
            .color_fill = gui_fill,
            .color_text = gui_text,
            .min_size_content = .{ .h = tokens.control_h },
            .corners = .round(tokens.radius_sm),
            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
            .gravity_y = 0.5,
        })) {
            if (plugin_host.ready()) {
                plugin_host.g.toggleSelectedGui(state);
            }
        }

        if (!can_float and !gui_open) {
            dvui.label(@src(), "  (no GUI extension)", .{}, .{
                .color_text = theme.text_soft,
                .gravity_y = 0.5,
            });
        } else if (gui_open) {
            dvui.label(@src(), "  plugin window open", .{}, .{
                .color_text = theme.text_dim,
                .gravity_y = 0.5,
            });
        }
    }

    dvui.label(@src(), "Plugin params / embedded UI — free height under the chip strip.", .{}, .{
        .color_text = theme.text_soft,
        .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = 0 },
    });
}

const ChipDraw = struct {
    title: []const u8,
    kind_label: []const u8,
    selected: bool,
    enabled: bool,
    empty: bool,
    /// 0 = instrument, 1.. = fx_index + 1
    id_extra: usize,
};

/// Full-height rack card, preserving the original device pane's horizontal
/// signal-flow layout. External plugin editors still open in native windows.
fn drawDeviceChip(state: *state_mod.State, opts: ChipDraw) void {
    const fill = if (opts.selected)
        theme.accent_dim
    else if (opts.empty)
        theme.empty_slot_fill
    else
        theme.panel;
    const title_col = if (opts.selected) theme.text else if (opts.empty) theme.text_soft else theme.text;
    const border_col = if (opts.selected) theme.selected else theme.grid;

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = fill,
        .min_size_content = .{ .w = tokens.device_card_w, .h = tokens.device_card_h },
        .corners = .round(tokens.radius_sm),
        .border = dvui.Rect.all(if (opts.selected) 1.5 else 1),
        .color_border = border_col,
        .padding = .{ .x = tokens.gap_group, .y = tokens.gap_tight, .w = tokens.gap_group, .h = tokens.gap_tight },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
        .id_extra = opts.id_extra,
    });
    defer card.deinit();

    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = tokens.device_header_h },
            .gravity_y = 0.5,
            .id_extra = opts.id_extra,
        });
        defer header.deinit();

        if (dvui.button(@src(), " ", .{}, .{
            .min_size_content = .{ .w = tokens.device_led, .h = tokens.device_led },
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
            .id_extra = opts.id_extra,
        })) {
            selectDevice(state, opts.id_extra);
            if (opts.id_extra == 0 and opts.empty) openPicker(state, false);
        }
    }

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

    const sub: []const u8 = if (!opts.empty and !opts.enabled) "Bypassed" else opts.kind_label;
    dvui.label(@src(), "{s}", .{sub}, .{
        .color_text = if (!opts.enabled and !opts.empty) theme.solo_on else theme.text_soft,
        .id_extra = opts.id_extra,
    });

    if (opts.empty) {
        dvui.label(@src(), "Drop a device here or click Choose.", .{}, .{
            .color_text = theme.text_soft,
            .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = 0 },
        });
        if (dvui.button(@src(), "Choose instrument", .{}, .{
            .expand = .none,
            .min_size_content = .{ .w = 132, .h = tokens.control_h + 4 },
            .color_fill = theme.panel,
            .color_text = theme.text,
            .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = 0 },
            .corners = .round(tokens.radius_sm),
        })) openPicker(state, false);
    } else {
        var gui_open = false;
        if (plugin_host.ready() and opts.selected) {
            if (plugin_host.g.selectedSlot(state)) |slot| gui_open = slot.gui_open;
        }
        if (dvui.button(@src(), if (gui_open) "Close plugin window" else "Open plugin window", .{}, .{
            .color_fill = if (gui_open) theme.accent else theme.panel,
            .color_text = if (gui_open) theme.bg else theme.text,
            .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = 0 },
            .corners = .round(tokens.radius_sm),
        })) {
            selectDevice(state, opts.id_extra);
            if (plugin_host.ready()) plugin_host.g.toggleSelectedGui(state);
        }

        if (dvui.button(@src(), if (opts.id_extra == 0) "Remove instrument" else "Remove effect", .{}, .{
            .color_fill = theme.cell,
            .color_text = theme.text_dim,
            .gravity_y = 1.0,
            .corners = .round(tokens.radius_sm),
        })) {
            if (plugin_host.ready()) {
                if (opts.id_extra == 0) {
                    plugin_host.g.clearInstrument(state.selected_track);
                } else {
                    plugin_host.g.removeFx(state.selected_track, opts.id_extra - 1);
                    state.selectDeviceInstrument();
                }
            }
        }
    }

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
        .min_size_content = .{ .w = 20, .h = tokens.device_card_h },
        .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
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

fn drawAddCard(state: *state_mod.State, track: usize, fx_count: usize) void {
    _ = track;
    _ = fx_count;
    if (dvui.button(@src(), "+  Add effect", .{}, .{
        .min_size_content = .{ .w = tokens.device_add_w, .h = tokens.device_card_h },
        .color_fill = theme.panel,
        .color_text = theme.text_dim,
        .border = dvui.Rect.all(1),
        .color_border = theme.grid,
        .corners = .round(tokens.radius_sm),
        .id_extra = 900,
    })) {
        openPicker(state, true);
    }
}

fn openPicker(state: *state_mod.State, for_fx: bool) void {
    if (!plugin_host.ready()) return;
    plugin_host.g.picker_open = true;
    plugin_host.g.picker_for_fx = for_fx;
    if (for_fx) {
        // Target will be the next free FX slot after pick.
        state.bottom_mode = .device;
    } else {
        state.selectDeviceInstrument();
    }
}

fn drawPluginPicker(state: *state_mod.State) void {
    const ph = &plugin_host.g;
    const track = state.selected_track;
    const for_fx = ph.picker_for_fx;

    var overlay = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = tokens.plugin_list_w, .h = 160 },
        .max_size_content = .width(tokens.plugin_list_w),
        .background = true,
        .color_fill = theme.panel,
        .padding = dvui.Rect.all(tokens.pad_panel),
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        .corners = .round(tokens.radius_md),
        .border = dvui.Rect.all(1),
        .color_border = theme.accent,
    });
    defer overlay.deinit();

    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_tight },
        });
        defer header.deinit();

        const title: []const u8 = if (for_fx) "Add audio FX" else "Choose instrument";
        dvui.label(@src(), "{s}", .{title}, .{
            .font = .theme(.heading),
            .color_text = theme.text,
            .gravity_y = 0.5,
        });

        if (dvui.button(@src(), "Close", .{}, .{
            .color_fill = theme.cell,
            .color_text = theme.text,
            .min_size_content = .{ .h = tokens.control_h },
            .corners = .round(tokens.radius_sm),
            .gravity_x = 1.0,
            .gravity_y = 0.5,
        })) {
            ph.picker_open = false;
        }
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
        .horizontal_bar = .hide,
        .vertical_bar = .auto,
    }, .{
        .expand = .both,
        .min_size_content = .{ .h = 120 },
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

    if (slot.kind == .midi) {
        dvui.label(@src(), "{s} · {d:.0} bars", .{ if (slot.name.len > 0) slot.name else "Untitled MIDI", slot.bars }, .{
            .color_text = theme.text_dim,
        });
        piano_roll.draw(state);
        return;
    }

    dvui.label(@src(), "Clip editor", .{}, .{
        .font = .theme(.heading),
        .color_text = theme.text,
    });

    const kind_label: []const u8 = switch (slot.kind) {
        .empty => "Empty",
        .midi => "MIDI",
        .audio => "Audio",
    };
    const play_label: []const u8 = switch (slot.play) {
        .empty => "-",
        .stopped => "Stopped",
        .queued => "Queued",
        .playing => "Playing",
    };

    dvui.label(@src(), "{s}  ·  {s}  ·  {d:.0} bars", .{
        if (slot.name.len > 0) slot.name else "Untitled",
        kind_label,
        slot.bars,
    }, .{
        .color_text = theme.text_dim,
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
    });
    dvui.label(@src(), "State: {s}", .{play_label}, .{
        .color_text = theme.text_soft,
        .margin = .{ .x = 0, .y = tokens.gap_xs, .w = 0, .h = 0 },
    });
    switch (slot.kind) {
        .midi => unreachable,
        .audio => dvui.label(@src(), "Audio viewer — port from ui_zgui/views/", .{}, .{
            .color_text = theme.text_soft,
            .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = 0 },
        }),
        .empty => {},
    }
}
