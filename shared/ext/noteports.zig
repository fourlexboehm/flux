const clap = @import("clap-bindings");
const std = @import("std");

pub fn create() clap.ext.note_ports.Plugin {
    return .{
        .count = count,
        .get = get,
    };
}

fn count(_: *const clap.Plugin, is_input: bool) callconv(.c) u32 {
    return if (is_input) 1 else 0;
}

fn get(_: *const clap.Plugin, index: u32, is_input: bool, info: *clap.ext.note_ports.Info) callconv(.c) bool {
    if (!is_input or index != 0) {
        return false;
    }

    var name_buf: [clap.name_capacity]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "Note Input {}", .{index}) catch {
        return false;
    };
    std.mem.copyForwards(u8, &info.name, name);

    info.id = @enumFromInt(index);
    info.supported_dialects = .{
        .clap = true,
    };

    info.preferred_dialect = .clap;
    return true;
}
