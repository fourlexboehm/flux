const clap = @import("clap-bindings");

threadlocal var current_plugin: ?*const clap.Plugin = null;

pub fn current() ?*const clap.Plugin {
    return current_plugin;
}

pub fn enter(plugin: *const clap.Plugin) ?*const clap.Plugin {
    const previous = current_plugin;
    current_plugin = plugin;
    return previous;
}

pub fn restore(previous: ?*const clap.Plugin) void {
    current_plugin = previous;
}
