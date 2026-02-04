const builtin = @import("builtin");
const std = @import("std");
const colors = @import("ui/colors.zig");
const objc = if (builtin.os.tag == .macos) @import("objc") else struct {};

const Theme = colors.Colors.Theme;

fn containsInsensitive(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

pub fn resolveTheme() Theme {
    if (std.c.getenv("FLUX_THEME")) |env| {
        const value = std.mem.span(env);
        if (std.ascii.eqlIgnoreCase(value, "light")) return .light;
        if (std.ascii.eqlIgnoreCase(value, "dark")) return .dark;
        if (std.ascii.eqlIgnoreCase(value, "system")) return detectSystemTheme();
    }
    return detectSystemTheme();
}

fn detectSystemTheme() Theme {
    return switch (builtin.os.tag) {
        .macos => detectMacTheme(),
        .linux => detectLinuxTheme(),
        else => .light,
    };
}

fn detectMacTheme() Theme {
    if (builtin.os.tag == .macos) {
        const app = objc.app_kit.Application.sharedApplication();
        const appearance = objc.objc.msgSend(app, "effectiveAppearance", ?*objc.app_kit.Appearance, .{});
        if (appearance) |ap| {
            const name = objc.objc.msgSend(ap, "name", *objc.foundation.String, .{});
            const dark_name = objc.foundation.String.stringWithUTF8String("NSAppearanceNameDarkAqua");
            if (name.isEqualToString(dark_name)) {
                return .dark;
            }
        }
    }
    return .light;
}

fn detectLinuxTheme() Theme {
    if (builtin.os.tag == .linux) {
        if (std.c.getenv("GTK_THEME")) |env| {
            if (containsInsensitive(std.mem.span(env), "dark")) return .dark;
        }
    }
    return .light;
}
