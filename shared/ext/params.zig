//! Shared CLAP params extension glue for Flux stock devices and instrument plugins.
//!
//! Two backends:
//! - **Table** (`tableCreate`): id-keyed `ParamDef` list + `f64` values (builtins FX).
//! - **Enum** (`EnumStore` + `enumCreate`): enum-indexed values + meta (instruments).

const clap = @import("clap-bindings");
const std = @import("std");
const tracy = @import("tracy");

const mutex_io: std.Io = std.Io.Threaded.global_single_threaded.io();

pub const max_queued_param_events = 128;

pub const UnitTag = enum {
    linear,
    decibel,
    seconds,
    hertz,

    pub fn toDawproject(self: UnitTag) []const u8 {
        return switch (self) {
            .linear => "linear",
            .decibel => "decibel",
            .seconds => "seconds",
            .hertz => "hertz",
        };
    }

    pub fn toDisplay(self: UnitTag) Display {
        return switch (self) {
            .linear => .number,
            .decibel => .number,
            .seconds => .seconds,
            .hertz => .hz,
        };
    }
};

pub const ParamDef = struct {
    id: u32,
    name: [:0]const u8,
    /// Optional hierarchical module path (CLAP `module`).
    module: []const u8 = "",
    /// Schema / UI name for DAWproject (builtins); defaults to `name` when empty.
    schema_name: []const u8 = "",
    min: f64 = 0,
    max: f64 = 1,
    default: f64 = 0,
    stepped: bool = false,
    is_enum: bool = false,
    is_bool: bool = false,
    requires_process: bool = false,
    display: Display = .number,
    unit: UnitTag = .linear,
    /// When `display == .labels`, value is rounded to index into this slice.
    labels: ?[]const []const u8 = null,
};

pub const Display = enum {
    number,
    hz,
    seconds,
    cents,
    semitones,
    percent,
    labels,
    bool_on_off,
};

pub fn copyName(dest: []u8, src: []const u8) void {
    @memset(dest, 0);
    const n = @min(src.len, dest.len -| 1);
    if (n > 0) @memcpy(dest[0..n], src[0..n]);
}

pub fn fillInfo(info: *clap.ext.params.Info, def: ParamDef) void {
    info.* = .{
        .id = @enumFromInt(def.id),
        .flags = .{
            .is_automatable = true,
            .is_stepped = def.stepped or def.is_bool or def.is_enum,
            .is_enum = def.is_enum,
            .requires_process = def.requires_process,
        },
        .cookie = null,
        .name = undefined,
        .module = undefined,
        .min_value = def.min,
        .max_value = def.max,
        .default_value = def.default,
    };
    copyName(&info.name, def.name);
    copyName(&info.module, def.module);
}

pub fn formatValue(def: ParamDef, value: f64, buf: []u8) ?usize {
    const text: []const u8 = switch (def.display) {
        .hz => std.fmt.bufPrint(buf, "{d:.0} Hz", .{value}) catch return null,
        .seconds => std.fmt.bufPrint(buf, "{d:.3} s", .{value}) catch return null,
        .cents => std.fmt.bufPrint(buf, "{d:.1} ct", .{value}) catch return null,
        .semitones => std.fmt.bufPrint(buf, "{d:.0} st", .{value}) catch return null,
        .percent => std.fmt.bufPrint(buf, "{d:.0}%", .{value * 100.0}) catch return null,
        .bool_on_off => std.fmt.bufPrint(buf, "{s}", .{if (value >= 0.5) "On" else "Off"}) catch return null,
        .labels => blk: {
            const labels = def.labels orelse break :blk std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch return null;
            if (labels.len == 0) break :blk std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch return null;
            const idx: usize = @intFromFloat(std.math.clamp(@round(value), 0, @as(f64, @floatFromInt(labels.len - 1))));
            break :blk std.fmt.bufPrint(buf, "{s}", .{labels[idx]}) catch return null;
        },
        .number => std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch return null,
    };
    return text.len;
}

pub fn formatValueToClap(def: ParamDef, value: f64, display: [*]u8, size: u32) bool {
    if (size == 0) return false;
    var tmp: [128]u8 = undefined;
    const n = formatValue(def, value, &tmp) orelse return false;
    const out_n = @min(n, size - 1);
    @memcpy(display[0..out_n], tmp[0..out_n]);
    display[out_n] = 0;
    return true;
}

pub fn parseFloatLoose(text: []const u8) ?f64 {
    var slice = std.mem.trim(u8, text, " \t");
    const suffixes = [_][]const u8{ " Hz", "Hz", " s", "s", " ct", "ct", " st", "st", "%" };
    for (suffixes) |suf| {
        if (std.mem.endsWith(u8, slice, suf)) {
            slice = std.mem.trim(u8, slice[0 .. slice.len - suf.len], " \t");
            break;
        }
    }
    return std.fmt.parseFloat(f64, slice) catch null;
}

// ---------------------------------------------------------------------------
// Table-backed params (builtins FX)
// ---------------------------------------------------------------------------

/// CLAP extension for plugins whose `params` field is table-backed:
/// `count`, `defs`, `values`, `indexOf(id)`, `set(id, value)`.
/// Optional: `applyParamsToDsp()` after flush when dirty / events applied.
pub fn tableCreate(comptime PluginType: type) clap.ext.params.Plugin {
    return .{
        .count = tableCount(PluginType),
        .getInfo = tableGetInfo(PluginType),
        .getValue = tableGetValue(PluginType),
        .valueToText = tableValueToText(PluginType),
        .textToValue = tableTextToValue(PluginType),
        .flush = tableFlush(PluginType),
    };
}

fn tableCount(comptime PluginType: type) *const fn (*const clap.Plugin) callconv(.c) u32 {
    return struct {
        fn f(plugin: *const clap.Plugin) callconv(.c) u32 {
            return PluginType.fromClapPlugin(plugin).params.count;
        }
    }.f;
}

fn tableGetInfo(comptime PluginType: type) *const fn (*const clap.Plugin, u32, *clap.ext.params.Info) callconv(.c) bool {
    return struct {
        fn f(plugin: *const clap.Plugin, index: u32, info: *clap.ext.params.Info) callconv(.c) bool {
            const p = PluginType.fromClapPlugin(plugin);
            if (index >= p.params.count) return false;
            const d = p.params.defs[index];
            fillInfo(info, .{
                .id = d.id,
                .name = d.name,
                .module = d.module,
                .min = d.min,
                .max = d.max,
                .default = d.default,
                .stepped = d.stepped or d.is_bool,
                .is_enum = d.is_enum,
                .is_bool = d.is_bool,
                .display = d.display,
                .labels = d.labels,
            });
            return true;
        }
    }.f;
}

fn tableGetValue(comptime PluginType: type) *const fn (*const clap.Plugin, clap.Id, *f64) callconv(.c) bool {
    return struct {
        fn f(plugin: *const clap.Plugin, param_id: clap.Id, value: *f64) callconv(.c) bool {
            const p = PluginType.fromClapPlugin(plugin);
            const id: u32 = @intFromEnum(param_id);
            if (p.params.indexOf(id)) |i| {
                value.* = p.params.values[i];
                return true;
            }
            return false;
        }
    }.f;
}

fn tableValueToText(comptime PluginType: type) *const fn (*const clap.Plugin, clap.Id, f64, [*]u8, u32) callconv(.c) bool {
    return struct {
        fn f(plugin: *const clap.Plugin, param_id: clap.Id, value: f64, display: [*]u8, size: u32) callconv(.c) bool {
            const p = PluginType.fromClapPlugin(plugin);
            const id: u32 = @intFromEnum(param_id);
            const i = p.params.indexOf(id) orelse return false;
            return formatValueToClap(p.params.defs[i], value, display, size);
        }
    }.f;
}

fn tableTextToValue(comptime PluginType: type) *const fn (*const clap.Plugin, clap.Id, [*:0]const u8, *f64) callconv(.c) bool {
    _ = PluginType;
    return struct {
        fn f(_: *const clap.Plugin, _: clap.Id, display: [*:0]const u8, value: *f64) callconv(.c) bool {
            value.* = parseFloatLoose(std.mem.span(display)) orelse return false;
            return true;
        }
    }.f;
}

fn tableFlush(comptime PluginType: type) *const fn (*const clap.Plugin, *const clap.events.InputEvents, *const clap.events.OutputEvents) callconv(.c) void {
    return struct {
        fn f(plugin: *const clap.Plugin, in: *const clap.events.InputEvents, _: *const clap.events.OutputEvents) callconv(.c) void {
            const p = PluginType.fromClapPlugin(plugin);
            const count = in.size(in);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const hdr = in.get(in, i);
                if (hdr.type != .param_value) continue;
                const ev: *const clap.events.ParamValue = @ptrCast(@alignCast(hdr));
                p.params.set(@intFromEnum(ev.param_id), ev.value);
            }
        }
    }.f;
}

// ---------------------------------------------------------------------------
// Enum-backed params (instruments)
// ---------------------------------------------------------------------------

pub fn EnumStore(
    comptime Parameter: type,
    comptime ParameterValue: type,
    comptime param_defaults: anytype,
) type {
    return struct {
        pub const Self = @This();
        pub const ParameterArray = std.EnumArray(Parameter, ParameterValue);
        pub const param_count = std.meta.fieldNames(Parameter).len;
        pub const defaults = param_defaults;

        values: ParameterArray = .init(param_defaults),
        mutex: std.Io.Mutex = .init,
        events: std.ArrayList(clap.events.ParamValue) = .empty,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.events.deinit(self.allocator);
        }

        pub fn prepare(self: *Self) !void {
            try self.events.ensureTotalCapacity(self.allocator, max_queued_param_events);
        }

        pub fn get(self: *Self, param: Parameter) ParameterValue {
            self.mutex.lockUncancelable(mutex_io);
            defer self.mutex.unlock(mutex_io);
            return self.values.get(param);
        }

        pub const SetFlags = struct {
            should_notify_host: bool = false,
        };

        pub fn set(self: *Self, param: Parameter, val: ParameterValue, flags: SetFlags) !void {
            self.mutex.lockUncancelable(mutex_io);
            defer self.mutex.unlock(mutex_io);
            self.values.set(param, val);

            if (flags.should_notify_host) {
                const event = clap.events.ParamValue{
                    .header = .{
                        .type = .param_value,
                        .size = @sizeOf(clap.events.ParamValue),
                        .space_id = clap.events.core_space_id,
                        .sample_offset = 0,
                        .flags = .{},
                    },
                    .note_id = .unspecified,
                    .channel = .unspecified,
                    .key = .unspecified,
                    .port_index = .unspecified,
                    .param_id = @enumFromInt(@intFromEnum(param)),
                    .value = val.asFloat(),
                    .cookie = null,
                };
                if (self.events.items.len < self.events.capacity) {
                    self.events.appendAssumeCapacity(event);
                } else {
                    try self.events.append(self.allocator, event);
                }
            }
        }
    };
}

/// Enum-backed CLAP params extension.
///
/// - `metaFn(Parameter) ParamDef` — getInfo + default text formatting
/// - `fromFloatFn(Parameter, f64) ParameterValue` — automation → storage
/// - optional `valueToTextFn` / `textToValueFn` — return true if handled
///
/// `ParameterValue` must provide `asFloat()`. `PluginType` must provide
/// `fromClapPlugin`, `params` (EnumStore), and `applyParamChanges(bool)`.
pub fn enumCreate(
    comptime PluginType: type,
    comptime Parameter: type,
    comptime ParameterValue: type,
    comptime metaFn: fn (Parameter) ParamDef,
    comptime fromFloatFn: fn (Parameter, f64) ParameterValue,
    comptime valueToTextFn: ?fn (*const clap.Plugin, Parameter, f64, [*]u8, u32) bool,
    comptime textToValueFn: ?fn (*const clap.Plugin, Parameter, []const u8, *f64) bool,
) clap.ext.params.Plugin {
    const param_count = std.meta.fieldNames(Parameter).len;
    return .{
        .count = struct {
            fn f(_: *const clap.Plugin) callconv(.c) u32 {
                return @intCast(param_count);
            }
        }.f,
        .getInfo = struct {
            fn f(_: *const clap.Plugin, index: u32, info: *clap.ext.params.Info) callconv(.c) bool {
                if (index >= param_count) return false;
                const param: Parameter = @enumFromInt(index);
                fillInfo(info, metaFn(param));
                return true;
            }
        }.f,
        .getValue = struct {
            fn f(clap_plugin: *const clap.Plugin, param_id: clap.Id, value: *f64) callconv(.c) bool {
                const index = @intFromEnum(param_id);
                if (index >= param_count) return false;
                const plugin = PluginType.fromClapPlugin(clap_plugin);
                const param: Parameter = @enumFromInt(index);
                value.* = plugin.params.get(param).asFloat();
                return true;
            }
        }.f,
        .valueToText = struct {
            fn f(clap_plugin: *const clap.Plugin, param_id: clap.Id, value: f64, buffer: [*]u8, size: u32) callconv(.c) bool {
                const index = @intFromEnum(param_id);
                if (index >= param_count) return false;
                const param: Parameter = @enumFromInt(index);
                if (valueToTextFn) |custom| {
                    if (custom(clap_plugin, param, value, buffer, size)) return true;
                }
                return formatValueToClap(metaFn(param), value, buffer, size);
            }
        }.f,
        .textToValue = struct {
            fn f(clap_plugin: *const clap.Plugin, param_id: clap.Id, text: [*:0]const u8, value: *f64) callconv(.c) bool {
                const index = @intFromEnum(param_id);
                if (index >= param_count) return false;
                const param: Parameter = @enumFromInt(index);
                const slice = std.mem.span(text);
                if (textToValueFn) |custom| {
                    if (custom(clap_plugin, param, slice, value)) return true;
                }
                const def = metaFn(param);
                if (def.labels) |labels| {
                    for (labels, 0..) |name, i| {
                        if (std.ascii.eqlIgnoreCase(slice, name)) {
                            value.* = @floatFromInt(i);
                            return true;
                        }
                    }
                }
                value.* = parseFloatLoose(slice) orelse return false;
                return true;
            }
        }.f,
        .flush = struct {
            fn processEvent(plugin: *PluginType, event: *const clap.events.Header) bool {
                if (event.space_id != clap.events.core_space_id) return false;
                if (event.type != .param_value) return false;
                const param_event: *align(1) const clap.events.ParamValue = @ptrCast(event);
                const index = @intFromEnum(param_event.param_id);
                if (index >= param_count) return false;
                const param: Parameter = @enumFromInt(index);
                plugin.params.set(param, fromFloatFn(param, param_event.value), .{}) catch unreachable;
                return true;
            }

            fn f(
                clap_plugin: *const clap.Plugin,
                input_events: *const clap.events.InputEvents,
                output_events: *const clap.events.OutputEvents,
            ) callconv(.c) void {
                const zone = tracy.ZoneN(@src(), "Flush parameters");
                defer zone.End();

                const plugin = PluginType.fromClapPlugin(clap_plugin);
                var params_did_change = false;
                for (0..input_events.size(input_events)) |i| {
                    const event = input_events.get(input_events, @intCast(i));
                    if (processEvent(plugin, event)) params_did_change = true;
                }

                if (plugin.params.mutex.tryLock()) {
                    defer plugin.params.mutex.unlock(mutex_io);
                    if (plugin.params.events.items.len > 0) params_did_change = true;
                    while (plugin.params.events.pop()) |event_value| {
                        var event = event_value;
                        _ = output_events.tryPush(output_events, &event.header);
                    }
                }

                if (params_did_change) {
                    plugin.applyParamChanges(true);
                }
            }
        }.f,
    };
}

/// Float-only ParameterValue mapper: `{ .Float = v }`.
pub fn fromFloatOnly(comptime Parameter: type, comptime ParameterValue: type) fn (Parameter, f64) ParameterValue {
    return struct {
        fn f(_: Parameter, v: f64) ParameterValue {
            return .{ .Float = v };
        }
    }.f;
}
