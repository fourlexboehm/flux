//! Shared CLAP state extension: id-keyed little-endian f64 binary.
//!
//! Layout:
//!   count: u32
//!   count × { id: u32, value_bits: u64 }  // value is f64 via @bitCast
//!
//! Works for enum-backed instrument params and table-backed builtin FX.
//! No JSON; old instrument states are not loadable.

const clap = @import("clap-bindings");
const std = @import("std");
const tracy = @import("tracy");

const mutex_io: std.Io = std.Io.Threaded.global_single_threaded.io();

const entry_size = 4 + 8;

fn writeAll(stream: *const clap.OStream, data: []const u8) bool {
    var total: usize = 0;
    while (total < data.len) {
        const res = stream.write(stream, data.ptr + total, data.len - total);
        if (res == .write_error) return false;
        const n: usize = @intCast(@intFromEnum(res));
        if (n == 0) return false;
        total += n;
    }
    return true;
}

fn readAll(allocator: std.mem.Allocator, stream: *const clap.IStream) ?[]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    var chunk: [1024]u8 = undefined;
    while (true) {
        const res = stream.read(stream, &chunk, chunk.len);
        if (res == .read_error) {
            list.deinit(allocator);
            return null;
        }
        if (res == .end_of_file) break;
        const n: usize = @intCast(@intFromEnum(res));
        if (n == 0) break;
        list.appendSlice(allocator, chunk[0..n]) catch {
            list.deinit(allocator);
            return null;
        };
    }
    return list.toOwnedSlice(allocator) catch {
        list.deinit(allocator);
        return null;
    };
}

fn afterLoad(comptime PluginType: type, plugin: *PluginType) void {
    if (@hasDecl(PluginType, "applyParamChanges")) {
        plugin.applyParamChanges(true);
    } else if (@hasDecl(PluginType, "applyParamsToDsp")) {
        plugin.applyParamsToDsp();
    }
}

fn valueFromFloat(comptime Params: type, param: Params.Parameter, v: f64) Params.ParameterValue {
    if (@hasDecl(Params, "fromFloat")) {
        return Params.fromFloat(param, v);
    }
    return .{ .Float = v };
}

/// Enum-backed instruments (EnumStore): param id = @intFromEnum.
pub fn create(comptime Params: type, comptime PluginType: type) clap.ext.state.Plugin {
    const param_count: u32 = @intCast(if (@hasDecl(Params, "param_count"))
        Params.param_count
    else
        std.meta.fieldNames(Params.Parameter).len);

    return .{
        .save = struct {
            fn save(clap_plugin: *const clap.Plugin, stream: *const clap.OStream) callconv(.c) bool {
                const zone = tracy.ZoneN(@src(), "State saving");
                defer zone.End();

                const plugin = PluginType.fromClapPlugin(clap_plugin);
                if (!plugin.params.mutex.tryLock()) return false;
                defer plugin.params.mutex.unlock(mutex_io);

                const nbytes = 4 + @as(usize, param_count) * entry_size;
                const buf = plugin.allocator.alloc(u8, nbytes) catch return false;
                defer plugin.allocator.free(buf);

                std.mem.writeInt(u32, buf[0..4], param_count, .little);
                var off: usize = 4;
                var i: u32 = 0;
                while (i < param_count) : (i += 1) {
                    const param: Params.Parameter = @enumFromInt(i);
                    const value = plugin.params.values.get(param).asFloat();
                    std.mem.writeInt(u32, buf[off..][0..4], i, .little);
                    off += 4;
                    std.mem.writeInt(u64, buf[off..][0..8], @bitCast(value), .little);
                    off += 8;
                }
                return writeAll(stream, buf[0..off]);
            }
        }.save,
        .load = struct {
            fn load(clap_plugin: *const clap.Plugin, stream: *const clap.IStream) callconv(.c) bool {
                const zone = tracy.ZoneN(@src(), "State loading");
                defer zone.End();

                const plugin = PluginType.fromClapPlugin(clap_plugin);
                const data = readAll(plugin.allocator, stream) orelse return false;
                defer plugin.allocator.free(data);
                if (data.len < 4) return false;

                const count = std.mem.readInt(u32, data[0..4], .little);
                {
                    if (!plugin.params.mutex.tryLock()) return false;
                    defer plugin.params.mutex.unlock(mutex_io);

                    var off: usize = 4;
                    var i: u32 = 0;
                    while (i < count and off + entry_size <= data.len) : (i += 1) {
                        const id = std.mem.readInt(u32, data[off..][0..4], .little);
                        off += 4;
                        const bits = std.mem.readInt(u64, data[off..][0..8], .little);
                        off += 8;
                        const param = std.enums.fromInt(Params.Parameter, id) orelse continue;
                        plugin.params.values.set(param, valueFromFloat(Params, param, @bitCast(bits)));
                    }
                }

                afterLoad(PluginType, plugin);
                return true;
            }
        }.load,
    };
}

/// Table-backed builtins: param id from `defs[i].id`.
pub fn createTable(comptime PluginType: type) clap.ext.state.Plugin {
    return .{
        .save = struct {
            fn save(clap_plugin: *const clap.Plugin, stream: *const clap.OStream) callconv(.c) bool {
                const zone = tracy.ZoneN(@src(), "State saving");
                defer zone.End();

                const self = PluginType.fromClapPlugin(clap_plugin);
                const count = self.params.count;
                const nbytes = 4 + @as(usize, count) * entry_size;

                var stack: [4 + 64 * entry_size]u8 = undefined;
                const use_stack = nbytes <= stack.len;
                const buf: []u8 = if (use_stack)
                    stack[0..nbytes]
                else
                    self.allocator.alloc(u8, nbytes) catch return false;
                defer if (!use_stack) self.allocator.free(buf);

                std.mem.writeInt(u32, buf[0..4], count, .little);
                var off: usize = 4;
                for (0..count) |ci| {
                    std.mem.writeInt(u32, buf[off..][0..4], self.params.defs[ci].id, .little);
                    off += 4;
                    std.mem.writeInt(u64, buf[off..][0..8], @bitCast(self.params.values[ci]), .little);
                    off += 8;
                }
                return writeAll(stream, buf[0..off]);
            }
        }.save,
        .load = struct {
            fn load(clap_plugin: *const clap.Plugin, stream: *const clap.IStream) callconv(.c) bool {
                const zone = tracy.ZoneN(@src(), "State loading");
                defer zone.End();

                const self = PluginType.fromClapPlugin(clap_plugin);
                const data = readAll(self.allocator, stream) orelse return false;
                defer self.allocator.free(data);
                if (data.len < 4) return false;

                const count = std.mem.readInt(u32, data[0..4], .little);
                var off: usize = 4;
                var i: u32 = 0;
                while (i < count and off + entry_size <= data.len) : (i += 1) {
                    const id = std.mem.readInt(u32, data[off..][0..4], .little);
                    off += 4;
                    const bits = std.mem.readInt(u64, data[off..][0..8], .little);
                    off += 8;
                    self.params.set(id, @bitCast(bits));
                }
                afterLoad(PluginType, self);
                return true;
            }
        }.load,
    };
}
