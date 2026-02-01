const Plugin = @import("plugin.zig");
const SharedEntry = @import("shared").clap_entry.Entry(Plugin);

pub export const clap_entry = SharedEntry.clap_entry;
