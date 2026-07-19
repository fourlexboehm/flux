const clap = @import("clap-bindings");
const std = @import("std");

/// Instrument: no audio inputs, one stereo output.
pub fn create() clap.ext.audio_ports.Plugin {
    return createInstrument();
}

pub fn createInstrument() clap.ext.audio_ports.Plugin {
    return .{
        .count = instrumentCount,
        .get = instrumentGet,
    };
}

/// Audio FX: one stereo input + one stereo output.
pub fn createEffect() clap.ext.audio_ports.Plugin {
    return .{
        .count = effectCount,
        .get = effectGet,
    };
}

fn instrumentCount(_: *const clap.Plugin, is_input: bool) callconv(.c) u32 {
    return if (is_input) 0 else 1;
}

fn instrumentGet(_: *const clap.Plugin, index: u32, is_input: bool, info: *clap.ext.audio_ports.Info) callconv(.c) bool {
    if (is_input or index != 0) return false;
    fillStereo(info, "Output", 0);
    return true;
}

fn effectCount(_: *const clap.Plugin, _: bool) callconv(.c) u32 {
    return 1;
}

fn effectGet(_: *const clap.Plugin, index: u32, is_input: bool, info: *clap.ext.audio_ports.Info) callconv(.c) bool {
    if (index != 0) return false;
    fillStereo(info, if (is_input) "Input" else "Output", if (is_input) 0 else 1);
    return true;
}

fn fillStereo(info: *clap.ext.audio_ports.Info, name: []const u8, id: u32) void {
    @memset(&info.name, 0);
    const n = @min(name.len, info.name.len - 1);
    @memcpy(info.name[0..n], name[0..n]);
    info.id = @enumFromInt(id);
    info.channel_count = 2;
    info.flags = .{
        .is_main = true,
        .supports_64bits = false,
    };
    info.port_type = "stereo";
    info.in_place_pair = .invalid_id;
}
