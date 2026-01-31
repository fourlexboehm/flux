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
        "ZMinimoog",
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
        zgui.text("ZMinimoog (WDF)", .{});
    }

    if (plugin.sample_rate == null) {
        zgui.textUnformatted("Synth engine inactive.");
        return;
    }

    const avail = zgui.getContentRegionAvail();
    const col_width = avail[0] * 0.5 - 8;

    // Two column layout
    if (zgui.beginChild("LeftColumn", .{ .w = col_width, .h = 0 })) {
        // Oscillator 1
        zgui.separatorText("Oscillator 1");
        renderParam(plugin, .Osc1Level, options);
        renderCombo(plugin, .Osc1Waveform, &.{ "Triangle", "Shark", "Sawtooth", "Square", "Wide Pulse", "Narrow Pulse" }, options);
        renderCombo(plugin, .Osc1Range, &.{ "LO", "32'", "16'", "8'", "4'", "2'" }, options);

        // Oscillator 2
        zgui.separatorText("Oscillator 2");
        renderParam(plugin, .Osc2Level, options);
        renderCombo(plugin, .Osc2Waveform, &.{ "Triangle", "Shark", "Sawtooth", "Square", "Wide Pulse", "Narrow Pulse" }, options);
        renderCombo(plugin, .Osc2Range, &.{ "LO", "32'", "16'", "8'", "4'", "2'" }, options);
        renderParam(plugin, .Osc2Detune, options);

        // Oscillator 3
        zgui.separatorText("Oscillator 3");
        renderParam(plugin, .Osc3Level, options);
        renderCombo(plugin, .Osc3Waveform, &.{ "Triangle", "Shark", "Sawtooth", "Square", "Wide Pulse", "Narrow Pulse" }, options);
        renderCombo(plugin, .Osc3Range, &.{ "LO", "32'", "16'", "8'", "4'", "2'" }, options);
        renderParam(plugin, .Osc3Detune, options);
        renderToggle(plugin, .Osc3KeyboardCtrl, "Keyboard Ctrl", options);

        // Noise
        zgui.separatorText("Noise");
        renderParam(plugin, .NoiseLevel, options);
        renderCombo(plugin, .NoiseType, &.{ "White", "Pink" }, options);
    }
    zgui.endChild();

    zgui.sameLine(.{});

    if (zgui.beginChild("RightColumn", .{ .w = col_width, .h = 0 })) {
        // Filter
        zgui.separatorText("Filter");
        renderParam(plugin, .FilterCutoff, options);
        renderParam(plugin, .FilterEmphasis, options);
        renderParam(plugin, .FilterContour, options);
        renderCombo(plugin, .FilterKeyTracking, &.{ "Off", "Half", "Full" }, options);

        // Modulation
        zgui.separatorText("Modulation");
        renderToggle(plugin, .Osc3ToFilter, "Osc3 > Filter", options);
        renderToggle(plugin, .Osc3ToOsc, "Osc3 > Osc", options);

        // Envelope
        zgui.separatorText("Envelope");
        renderParam(plugin, .Attack, options);
        renderParam(plugin, .Decay, options);
        renderParam(plugin, .Sustain, options);
        renderParam(plugin, .Release, options);

        // Controllers
        zgui.separatorText("Controllers");
        renderParam(plugin, .Glide, options);
        renderParam(plugin, .PitchBendRange, options);
        renderParam(plugin, .MasterVolume, options);
    }
    zgui.endChild();
}

fn renderParam(plugin: *Plugin, param: Params.Parameter, options: DrawOptions) void {
    const index: u32 = @intFromEnum(param);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&plugin.plugin, index, &info)) {
        return;
    }

    var val: f32 = @floatCast(plugin.params.get(param).Float);
    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const name = std.mem.sliceTo(&info.name, 0);
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{name}) catch return;

    var text_buf: [256]u8 = [_]u8{0} ** 256;
    _ = Params._valueToText(&plugin.plugin, @enumFromInt(index), val, &text_buf, 256);

    if (zgui.sliderFloat(label, .{
        .v = &val,
        .min = @floatCast(info.min_value),
        .max = @floatCast(info.max_value),
        .cfmt = text_buf[0..255 :0],
    })) {
        plugin.params.set(param, .{ .Float = @floatCast(val) }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}

fn renderCombo(plugin: *Plugin, param: Params.Parameter, items: []const []const u8, options: DrawOptions) void {
    const index: u32 = @intFromEnum(param);
    var info: clap.ext.params.Info = undefined;
    if (!Params._getInfo(&plugin.plugin, index, &info)) {
        return;
    }

    const val: f32 = @floatCast(plugin.params.get(param).Float);
    var current: i32 = @intFromFloat(@round(@max(0.0, @min(@as(f32, @floatFromInt(items.len - 1)), val))));

    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const name = std.mem.sliceTo(&info.name, 0);
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{name}) catch return;

    // Build items array for combo
    var item_ptrs: [16][*:0]const u8 = undefined;
    for (items, 0..) |item, i| {
        if (i >= 16) break;
        item_ptrs[i] = @ptrCast(item.ptr);
    }

    if (zgui.combo(label, .{
        .current_item = &current,
        .items_separated_by_zeros = blk: {
            // Build null-separated string
            var buf: [512]u8 = [_]u8{0} ** 512;
            var pos: usize = 0;
            for (items) |item| {
                if (pos + item.len + 1 >= buf.len) break;
                @memcpy(buf[pos..][0..item.len], item);
                pos += item.len + 1; // include null separator
            }
            break :blk buf[0..pos :0];
        },
    })) {
        plugin.params.set(param, .{ .Float = @floatFromInt(current) }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}

fn renderToggle(plugin: *Plugin, param: Params.Parameter, label_text: []const u8, options: DrawOptions) void {
    const val: f32 = @floatCast(plugin.params.get(param).Float);
    var enabled: bool = val >= 0.5;

    var label_buf: [256]u8 = [_]u8{0} ** 256;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{label_text}) catch return;

    if (zgui.checkbox(label, .{ .v = &enabled })) {
        plugin.params.set(param, .{ .Float = if (enabled) 1.0 else 0.0 }, .{ .should_notify_host = options.notify_host }) catch return;
        if (!options.notify_host) {
            plugin.applyParamChanges(false);
        }
    }
}
