pub fn Entry(comptime PluginType: type) type {
    return struct {
        const std = @import("std");
        const options = @import("options");
        const builtin = @import("builtin");
        const clap = @import("clap-bindings");

        var gpa: std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }) = undefined;

        pub const clap_entry = createEntry();

        fn createEntry() clap.Entry {
            return clap.Entry{
                .version = clap.version,
                .init = _init,
                .deinit = _deinit,
                .getFactory = _getFactory,
            };
        }

        fn _init(plugin_path: [*:0]const u8) callconv(.c) bool {
            if (builtin.mode == .Debug and options.wait_for_debugger) {
                @breakpoint();
            }

            gpa = .{};
            std.log.debug("Plugin initialized with path {s}", .{plugin_path});
            return true;
        }

        fn _deinit() callconv(.c) void {
            std.log.debug("Plugin deinitialized", .{});
            switch (gpa.deinit()) {
                std.heap.Check.leak => {
                    std.log.debug("Leaks happened!", .{});
                },
                else => {},
            }
        }

        const ClapPluginFactoryId: []const u8 = "clap.plugin-factory";

        fn _getFactory(factory_id: [*:0]const u8) callconv(.c) ?*const anyopaque {
            if (std.mem.eql(u8, std.mem.span(factory_id), ClapPluginFactoryId)) {
                return &plugin_factory;
            }
            std.log.debug("factory_id: {s} ", .{factory_id});
            return null;
        }

        const ClapFactory = struct {
            fn create() clap.PluginFactory {
                return clap.PluginFactory{
                    .getPluginCount = _getPluginCount,
                    .getPluginDescriptor = _getPluginDescriptor,
                    .createPlugin = _createPlugin,
                };
            }

            fn _getPluginCount(_: *const clap.PluginFactory) callconv(.c) u32 {
                return 1;
            }

            fn _getPluginDescriptor(
                _: *const clap.PluginFactory,
                index: u32,
            ) callconv(.c) ?*const clap.Plugin.Descriptor {
                std.log.debug("getPluginDescriptor invoked", .{});
                if (index == 0) {
                    return &PluginType.desc;
                }
                return null;
            }

            fn _createPlugin(
                _: *const clap.PluginFactory,
                host: *const clap.Host,
                plugin_id: [*:0]const u8,
            ) callconv(.c) ?*const clap.Plugin {
                if (!host.clap_version.isCompatible()) {
                    return null;
                }

                if (!std.mem.eql(u8, std.mem.span(plugin_id), std.mem.span(PluginType.desc.id))) {
                    std.log.debug(
                        "Mismatched plugin id: {s}; descriptor id: {s}",
                        .{ plugin_id, PluginType.desc.id },
                    );
                    return null;
                }

                const plugin = PluginType.create(host, gpa.allocator()) catch {
                    std.log.debug("Error allocating plugin!", .{});
                    return null;
                };

                return plugin;
            }
        };

        const plugin_factory = ClapFactory.create();
    };
}
