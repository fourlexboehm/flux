const clap = @import("clap-bindings");
const std = @import("std");
const tracy = @import("tracy");
const mutex_io: std.Io = std.Io.Threaded.global_single_threaded.ioBasic();

pub fn create(comptime Params: type, comptime PluginType: type) clap.ext.state.Plugin {
    return .{
        .save = SaveLoad(Params, PluginType).save,
        .load = SaveLoad(Params, PluginType).load,
    };
}

fn SaveLoad(comptime Params: type, comptime PluginType: type) type {
    return struct {
        fn save(clap_plugin: *const clap.Plugin, stream: *const clap.OStream) callconv(.c) bool {
            const zone = tracy.ZoneN(@src(), "State saving");
            defer zone.End();

            std.log.debug("Saving plugin state...", .{});
            const plugin = PluginType.fromClapPlugin(clap_plugin);

            const locked = plugin.params.mutex.tryLock();
            if (!locked) {
                std.log.debug("_save: couldn't get lock!", .{});
                return false;
            }
            defer plugin.params.mutex.unlock(mutex_io);

            const str = std.json.Stringify.valueAlloc(plugin.allocator, plugin.params.values.values, .{}) catch return false;
            std.log.debug("Plugin data saved: {s}", .{str});
            defer plugin.allocator.free(str);

            const res = stream.write(stream, str.ptr, str.len);
            if (res == .write_error) {
                std.log.err("Unable to write to plugin host output stream!", .{});
                return false;
            }

            var total_bytes_written = @intFromEnum(res);
            while (total_bytes_written < str.len) {
                const bytes: usize = @intCast(total_bytes_written);
                total_bytes_written += @intFromEnum(stream.write(stream, str.ptr + bytes, str.len - bytes));
            }

            return total_bytes_written == str.len;
        }

        fn load(clap_plugin: *const clap.Plugin, stream: *const clap.IStream) callconv(.c) bool {
            const zone = tracy.ZoneN(@src(), "State loading");
            defer zone.End();

            std.log.debug("Loading plugin state...", .{});
            const plugin = PluginType.fromClapPlugin(clap_plugin);

            var param_data_buf = std.ArrayList(u8).empty;
            defer param_data_buf.deinit(plugin.allocator);

            const max_buf_size = 1024;
            var buf: [max_buf_size]u8 = undefined;
            const res = stream.read(stream, &buf, max_buf_size);
            if (res == .read_error or res == .end_of_file) {
                std.log.err("Clap IStream Read Error or EOF on first read!", .{});
                return false;
            }

            var bytes_read = @intFromEnum(res);
            while (bytes_read > 0) {
                const bytes: usize = @intCast(bytes_read);
                param_data_buf.appendSlice(plugin.allocator, buf[0..bytes]) catch {
                    std.log.err("Unable to append state data from plugin host to param data buffer.", .{});
                    return false;
                };

                bytes_read = @intFromEnum(stream.read(stream, &buf, max_buf_size));
            }
            std.log.debug("Plugin data loaded: {s}", .{param_data_buf.items});

            const params = createParamsFromBuffer(plugin.allocator, param_data_buf.items);
            if (params == null) {
                std.log.err(
                    "Unable to create params from the active state buffer! {s}",
                    .{param_data_buf.items},
                );
                return true;
            }

            if (plugin.params.mutex.tryLock()) {
                plugin.params.values = params.?;
                plugin.params.mutex.unlock(mutex_io);

                plugin.applyParamChanges(true);
                std.log.debug("Plugin state restored successfully", .{});
                return true;
            }

            std.log.warn("_load: couldn't get params lock!", .{});
            return false;
        }

        fn createParamsFromBuffer(allocator: std.mem.Allocator, buffer: []u8) ?Params.ParameterArray {
            const params_data = std.json.parseFromSlice([]Params.ParameterValue, allocator, buffer, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.log.err("Error loading parameters: {}", .{err});
                return null;
            };
            defer params_data.deinit();

            var params = Params.ParameterArray.init(Params.param_defaults);
            if (Params.param_count != params_data.value.len) {
                std.log.warn(
                    "Parameter count {d} does not match length of previously saved parameter data {d}",
                    .{ Params.param_count, params_data.value.len },
                );
                return params;
            }
            for (params_data.value, 0..) |param, i| {
                if (i >= Params.param_count) break;
                const param_type = std.enums.fromInt(Params.Parameter, i) orelse {
                    std.log.err("Error creating parameter: invalid index {d}", .{i});
                    return null;
                };
                params.set(param_type, param);
            }

            return params;
        }
    };
}
