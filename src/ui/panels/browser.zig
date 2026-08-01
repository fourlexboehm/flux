//! Browser sidebar chrome.
//! Instruments / Audio Effects list the CLAP catalog from `ui/plugin_host`.
//! Other categories remain placeholders until sample/preset browsers port.

const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const state_mod = @import("../state.zig");
const plugin_host = @import("../plugin_host.zig");

const Category = struct {
    tab: state_mod.BrowserTab,
    label: []const u8,
};

const categories = [_]Category{
    .{ .tab = .sounds, .label = "Sounds" },
    .{ .tab = .drums, .label = "Drums" },
    .{ .tab = .bass, .label = "Bass" },
    .{ .tab = .pad, .label = "Pads" },
    .{ .tab = .lead, .label = "Leads" },
    .{ .tab = .keys, .label = "Keys" },
    .{ .tab = .noise, .label = "Noise" },
    .{ .tab = .instruments, .label = "Instruments" },
    .{ .tab = .audio_effects, .label = "Audio Effects" },
};

pub fn draw(state: *state_mod.State) void {
    if (!state.browser_open) return;

    var side = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = theme.panel,
        .expand = .both,
        .padding = dvui.Rect.all(tokens.pad_panel),
        .corners = .round(tokens.radius_md),
    });
    defer side.deinit();

    dvui.label(@src(), "Browser", .{}, .{
        .font = .theme(.heading),
        .color_text = theme.text,
    });

    // Search
    {
        var search_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = tokens.gap_tight },
        });
        defer search_row.deinit();

        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &state.browser_search },
            .placeholder = "Search…",
        }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = tokens.control_h },
        });
        const text = te.getText();
        state.browser_search_len = text.len;
        te.deinit();
    }

    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
    });
    defer body.deinit();

    // Categories column
    {
        var nav = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background = true,
            .color_fill = theme.cell,
            .min_size_content = .{ .w = tokens.browser_nav_w },
            .expand = .vertical,
            .padding = dvui.Rect.all(tokens.gap_tight),
            .corners = .round(tokens.radius_sm),
            .margin = .{ .x = 0, .y = 0, .w = tokens.gap_tight, .h = 0 },
        });
        defer nav.deinit();

        dvui.label(@src(), "Categories", .{}, .{
            .color_text = theme.text_soft,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = tokens.gap_xs },
        });

        for (categories, 0..) |cat, i| {
            const selected = state.browser_tab == cat.tab;
            const fill = if (selected) theme.accent else theme.panel;
            const text = if (selected) theme.bg else theme.text;
            if (dvui.button(@src(), cat.label, .{}, .{
                .expand = .horizontal,
                .color_fill = fill,
                .color_text = text,
                .min_size_content = .{ .h = tokens.control_h - 2 },
                .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
                .corners = .round(tokens.radius_sm),
                .id_extra = i,
            })) {
                state.setBrowserTab(cat.tab);
            }
        }
    }

    // Content column
    {
        var content = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background = true,
            .color_fill = theme.cell,
            .expand = .both,
            .padding = dvui.Rect.all(tokens.pad_panel),
            .corners = .round(tokens.radius_sm),
        });
        defer content.deinit();

        const tab_name = categoryLabel(state.browser_tab);
        dvui.label(@src(), "{s}", .{tab_name}, .{
            .font = .theme(.heading),
            .color_text = theme.text,
        });

        if (state.browser_search_len > 0) {
            dvui.label(@src(), "Filter: \"{s}\"", .{state.searchSlice()}, .{
                .color_text = theme.text_dim,
                .margin = .{ .x = 0, .y = tokens.gap_xs, .w = 0, .h = 0 },
            });
        }

        switch (state.browser_tab) {
            .instruments => drawPluginList(state, false),
            .audio_effects => drawPluginList(state, true),
            else => {
                dvui.label(@src(), "Sample/preset browser not ported yet — use Instruments / Audio Effects for the CLAP catalog.", .{}, .{
                    .color_text = theme.text_soft,
                    .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = 0 },
                });
            },
        }
    }
}

fn drawPluginList(state: *state_mod.State, fx: bool) void {
    if (!plugin_host.ready() or !plugin_host.g.catalog_ready) {
        dvui.label(@src(), "Plugin catalog not ready.", .{}, .{
            .color_text = theme.text_soft,
            .margin = .{ .x = 0, .y = tokens.gap_group, .w = 0, .h = 0 },
        });
        return;
    }

    const ph = &plugin_host.g;
    const choices: []const i32 = if (fx) ph.fxChoices() else ph.instrumentChoices();
    const filter = state.searchSlice();
    const track = state.selected_track;

    var scroll = dvui.scrollArea(@src(), .{
        .horizontal_bar = .hide,
        .vertical_bar = .auto,
    }, .{
        .expand = .both,
        .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
    });
    defer scroll.deinit();

    var shown: usize = 0;
    for (choices, 0..) |choice, i| {
        if (!ph.matchesSearch(choice, filter)) continue;
        const name = ph.entryName(choice);
        if (name.len == 0) continue;
        shown += 1;
        if (dvui.button(@src(), name, .{}, .{
            .expand = .horizontal,
            .color_fill = theme.panel,
            .color_text = theme.text,
            .min_size_content = .{ .h = tokens.control_h - 2 },
            .corners = .round(tokens.radius_sm),
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            .id_extra = i,
        })) {
            if (fx) {
                if (ph.addFxSlot(track, choice)) {
                    state.bottom_mode = .device;
                    state.selectDeviceFx(ph.fx_counts[track] - 1);
                }
            } else {
                ph.setInstrumentChoice(track, choice);
                state.bottom_mode = .device;
                state.selectDeviceInstrument();
            }
        }
    }

    if (shown == 0) {
        dvui.label(@src(), "No matching plugins. Build clap bundles or install system CLAPs.", .{}, .{
            .color_text = theme.text_soft,
        });
    } else {
        dvui.label(@src(), "{d} plugins — click to load on selected track", .{shown}, .{
            .color_text = theme.text_dim,
            .margin = .{ .x = 0, .y = tokens.gap_tight, .w = 0, .h = 0 },
        });
    }
}

fn categoryLabel(tab: state_mod.BrowserTab) []const u8 {
    for (categories) |cat| {
        if (cat.tab == tab) return cat.label;
    }
    return "Browser";
}
