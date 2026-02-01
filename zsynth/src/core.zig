const shared = @import("shared");
const PluginType = @import("plugin.zig").Plugin;
const ViewType = @import("ext/gui/view.zig");

const Core = shared.core.Core(PluginType, ViewType);

pub const Plugin = Core.Plugin;
pub const View = Core.View;
pub const font = Core.font;
