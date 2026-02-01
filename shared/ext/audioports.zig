const clap = @import("clap-bindings");
const std = @import("std");

pub fn create() clap.ext.audio_ports.Plugin {
    return .{
        .count = count,
        .get = get,
    };
}

fn count(_: *const clap.Plugin, is_input: bool) callconv(.c) u32 {
    return if (is_input) 0 else 1;
}

fn get(_: *const clap.Plugin, index: u32, is_input: bool, info: *clap.ext.audio_ports.Info) callconv(.c) bool {
    var name_buf: [clap.name_capacity]u8 = undefined;
    if (is_input) {
        return false;
    }

    const name = std.fmt.bufPrint(&name_buf, "Audio Output {}", .{index}) catch {
        return false;
    };
    std.mem.copyForwards(u8, &info.name, name);

    info.id = @enumFromInt(index);
    info.channel_count = 2;
    info.flags = .{
        .is_main = true,
        .supports_64bits = false,
    };
    info.port_type = "stereo";
    info.in_place_pair = .invalid_id;

    return true;
}
