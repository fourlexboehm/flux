const std = @import("std");
const clap = @import("clap-bindings");
const zgui = @import("zgui");

const Params = @import("../params.zig");
const Plugin = @import("../../plugin.zig");

pub const DrawOptions = struct {
    notify_host: bool = true,
    show_title: bool = true,
};

pub fn drawWindow(plugin: *Plugin) void {
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    const display_size = zgui.io.getDisplaySize();
    zgui.setNextWindowSize(.{ .w = display_size[0], .h = display_size[1], .cond = .always });

    if (zgui.begin(
        "ZPortaFM",
        .{
            .flags = .{
                .no_collapse = true,
                .no_move = true,
                .no_resize = true,
                .no_title_bar = true,
                .always_auto_resize = true,
            },
        },
    )) {
        drawContent(plugin, .{});
    }
    zgui.end();
}

pub fn drawEmbedded(plugin: *Plugin, options: DrawOptions) void {
    drawContent(plugin, options);
}

fn drawContent(plugin: *Plugin, options: DrawOptions) void {
    if (options.show_title) {
        zgui.text("ZPortaFM", .{});
        zgui.sameLine(.{ .spacing = 10.0 });
        zgui.textUnformatted("YM2413 / PortaSound-inspired");
    }

    if (plugin.sample_rate == null) {
        zgui.textUnformatted("Synth engine inactive.");
        return;
    }

    const preset_mode = plugin.params.get(.VoiceMode).Float >= 0.5;
    const avail = zgui.getContentRegionAvail();
    const column_width = avail[0] * 0.5 - 8.0;

    if (zgui.beginChild("PortaLeft", .{ .w = column_width, .h = 0 })) {
        zgui.separatorText("Voice");
        renderCombo(plugin, .VoiceMode, &Params.mode_names, options);
        renderCombo(plugin, .Instrument, &Params.instrument_names, options);

        zgui.separatorText("Performance");
        renderSlider(plugin, .PitchWheelRange, options);
        renderSlider(plugin, .FineTune, options);
        renderSlider(plugin, .OutputLevel, options);

        zgui.separatorText("Patch Global");
        zgui.beginDisabled(.{ .disabled = preset_mode });
        renderSlider(plugin, .Feedback, options);
        renderSlider(plugin, .ModLevel, options);
        zgui.endDisabled();
    }
    zgui.endChild();

    zgui.sameLine(.{});

    if (zgui.beginChild("PortaRight", .{ .w = column_width, .h = 0 })) {
        zgui.separatorText("Modulator");
        zgui.beginDisabled(.{ .disabled = preset_mode });
        renderSlider(plugin, .ModAttack, options);
        renderSlider(plugin, .ModDecay, options);
        renderSlider(plugin, .ModSustain, options);
        renderSlider(plugin, .ModRelease, options);
        renderSlider(plugin, .ModMultiplier, options);
        renderToggle(plugin, .ModWave, options);
        renderToggle(plugin, .ModTremolo, options);
        renderToggle(plugin, .ModVibrato, options);

        zgui.separatorText("Carrier");
        renderSlider(plugin, .CarAttack, options);
        renderSlider(plugin, .CarDecay, options);
        renderSlider(plugin, .CarSustain, options);
        renderSlider(plugin, .CarRelease, options);
        renderSlider(plugin, .CarMultiplier, options);
        renderToggle(plugin, .CarWave, options);
        renderToggle(plugin, .CarTremolo, options);
        renderToggle(plugin, .CarVibrato, options);
        zgui.endDisabled();
    }
    zgui.endChild();
}

fn renderSlider(plugin: *Plugin, param: Params.Parameter, options: DrawOptions) void {
    const index: u32 = @intFromEnum(param);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&plugin.plugin, index, &info)) return;

    var value: f32 = @floatCast(plugin.params.get(param).Float);
    var text_buf: [128]u8 = [_]u8{0} ** 128;
    _ = Params._valueToText(&plugin.plugin, @enumFromInt(index), value, &text_buf, text_buf.len);

    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const name = std.mem.sliceTo(&info.name, 0);
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{name}) catch return;

    if (zgui.sliderFloat(label, .{
        .v = &value,
        .min = @floatCast(info.min_value),
        .max = @floatCast(info.max_value),
        .cfmt = text_buf[0 .. text_buf.len - 1 :0],
    })) {
        plugin.params.set(param, .{ .Float = @floatCast(value) }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}

fn renderToggle(plugin: *Plugin, param: Params.Parameter, options: DrawOptions) void {
    const index: u32 = @intFromEnum(param);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&plugin.plugin, index, &info)) return;

    var enabled = plugin.params.get(param).Float >= 0.5;
    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const name = std.mem.sliceTo(&info.name, 0);
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{name}) catch return;

    if (zgui.checkbox(label, .{ .v = &enabled })) {
        plugin.params.set(param, .{ .Float = if (enabled) 1.0 else 0.0 }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}

fn renderCombo(plugin: *Plugin, param: Params.Parameter, items: []const []const u8, options: DrawOptions) void {
    const index: u32 = @intFromEnum(param);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&plugin.plugin, index, &info)) return;

    var current: i32 = @intFromFloat(@round(plugin.params.get(param).Float));
    if (param == .Instrument) {
        current -= 1;
    }

    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const name = std.mem.sliceTo(&info.name, 0);
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{name}) catch return;

    var items_buf: [512]u8 = [_]u8{0} ** 512;
    var pos: usize = 0;
    for (items) |item| {
        if (pos + item.len + 1 >= items_buf.len) break;
        @memcpy(items_buf[pos..][0..item.len], item);
        pos += item.len;
        items_buf[pos] = 0;
        pos += 1;
    }
    items_buf[pos] = 0;

    if (zgui.combo(label, .{
        .current_item = &current,
        .items_separated_by_zeros = items_buf[0..pos :0],
    })) {
        const stored_value: f64 = if (param == .Instrument) @floatFromInt(current + 1) else @floatFromInt(current);
        plugin.params.set(param, .{ .Float = stored_value }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}
