pub fn Core(comptime PluginType: type, comptime ViewType: type) type {
    return struct {
        pub const Plugin = PluginType;
        pub const View = ViewType;
        pub const font = @import("static_data").font;
    };
}
