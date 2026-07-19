const std = @import("std");
const parse = @import("parse.zig");
const xml_writer = @import("xml_writer.zig");
const types = @import("types.zig");
const flatten = @import("flatten.zig");
const media_layout = @import("../media/layout.zig");
const zip_writer = @import("zip_writer.zig");

const XmlWriter = xml_writer.XmlWriter;
const toXml = xml_writer.toXml;
const Project = types.Project;
const Clip = types.Clip;
const WarpPoint = types.WarpPoint;

test "xml escaping" {
    const allocator = std.testing.allocator;
    var writer = XmlWriter.init(allocator);
    defer writer.deinit();

    try writer.writeEscaped("Hello <World> & \"Test\"");
    const result = try writer.toOwnedSlice();
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello &lt;World&gt; &amp; &quot;Test&quot;", result);
}

test "basic project xml" {
    const allocator = std.testing.allocator;

    const proj = Project{
        .application = .{ .name = "Test", .version = "1.0" },
        .transport = .{
            .tempo = .{
                .id = "id0",
                .name = "Tempo",
                .value = 120.0,
                .unit = .bpm,
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<?xml version=\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Project version=\"1.0\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "Tempo") != null);
}

test "CLAP identity and embedded state path round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1.0" },
        .tracks = &.{
            .{
                .id = "track0",
                .name = "Track 1",
                .channel = .{
                    .id = "channel0",
                    .devices = &.{
                        .{
                            .id = "device0",
                            .name = "Portable Synth",
                            .device_id = "org.example.portable-synth",
                            .device_name = "Portable Synth",
                            .device_role = .instrument,
                            .state = .{ .path = "plugins/track0.clap-preset" },
                            .parameters = &.{
                                .{
                                    .id = "device0_p42",
                                    .parameter_id = 42,
                                    .name = "Cutoff",
                                    .value = 0.5,
                                    .min = 0,
                                    .max = 1,
                                    .unit = .linear,
                                },
                            },
                        },
                    },
                },
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    try std.testing.expect(std.mem.indexOf(u8, xml, "parameterID=\"42\"") != null);
    const parsed = try parse.parseProjectXml(allocator, xml);

    const device = parsed.tracks[0].channel.?.devices[0];
    try std.testing.expectEqualStrings("org.example.portable-synth", device.device_id);
    try std.testing.expectEqualStrings("plugins/track0.clap-preset", device.state.?.path);
    try std.testing.expect(!device.state.?.external);
}

test "audio warps parse and write round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const warps_pts = [_]WarpPoint{
        .{ .time = 0.0, .content_time = 0.0 },
        .{ .time = 8.0, .content_time = 2.823541666666667 },
    };
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1.0" },
        .tracks = &.{
            .{
                .id = "tr1",
                .name = "Drumloop",
                .content_type = .audio,
                .channel = .{
                    .id = "ch1",
                    .role = .regular,
                },
            },
        },
        .arrangement = .{
            .id = "arr",
            .lanes = .{
                .id = "root",
                .time_unit = .beats,
                .children = &.{
                    .{
                        .id = "tr1lanes",
                        .track = "tr1",
                        .clips = .{
                            .id = "tr1clips",
                            .clips = &.{
                                .{
                                    .time = 0.0,
                                    .duration = 8.0,
                                    .play_start = 0.0,
                                    .loop_start = 0.0,
                                    .loop_end = 8.0,
                                    .name = "Drumfunk3 170bpm",
                                    .warps = .{
                                        .id = "w1",
                                        .time_unit = .beats,
                                        .content_time_unit = .seconds,
                                        .audio = .{
                                            .id = "a1",
                                            .file = .{ .path = "audio/Drumfunk3 170bpm.wav" },
                                            .duration = 2.823541666666667,
                                            .sample_rate = 48000,
                                            .channels = 2,
                                            .algorithm = "stretch",
                                        },
                                        .warps = &warps_pts,
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Warps") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Audio") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "audio/Drumfunk3 170bpm.wav") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "algorithm=\"stretch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "contentTime") != null);

    const parsed = try parse.parseProjectXml(allocator, xml);
    try std.testing.expect(parsed.arrangement != null);
    const root = parsed.arrangement.?.lanes.?;
    try std.testing.expect(root.children.len >= 1);
    const clips = root.children[0].clips.?;
    try std.testing.expectEqual(@as(usize, 1), clips.clips.len);
    const clip = clips.clips[0];
    try std.testing.expect(clip.warps != null);
    const warps = clip.warps.?;
    try std.testing.expect(warps.audio != null);
    try std.testing.expectEqualStrings("audio/Drumfunk3 170bpm.wav", warps.audio.?.file.path);
    try std.testing.expectEqual(@as(i32, 48000), warps.audio.?.sample_rate);
    try std.testing.expectEqual(@as(i32, 2), warps.audio.?.channels);
    try std.testing.expectEqualStrings("stretch", warps.audio.?.algorithm.?);
    try std.testing.expectEqual(@as(usize, 2), warps.warps.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), warps.warps[0].time, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), warps.warps[1].time, 1e-6);
    // Writer formats floats to 6 decimal places
    try std.testing.expectApproxEqAbs(@as(f64, 2.823541666666667), warps.warps[1].content_time, 1e-6);
}

test "audio clip writes clip-level automation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const points = [_]types.AutomationPoint{.{ .time = 0, .value = 0.5 }};
    const clip_points = [_]types.Points{.{
        .id = "gain-points",
        .target = .{ .parameter = "gain" },
        .points = &points,
    }};
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1.0" },
        .arrangement = .{
            .id = "arr",
            .lanes = .{
                .id = "root",
                .clips = .{
                    .id = "clips",
                    .clips = &.{.{
                        .time = 0,
                        .duration = 4,
                        .points = &clip_points,
                        .audio = .{
                            .file = .{ .path = "audio/test.wav" },
                            .duration = 1,
                            .sample_rate = 48000,
                            .channels = 2,
                        },
                    }},
                },
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Audio") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Points") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "parameter=\"gain\"") != null);
}

test "bitwig nested clips flatten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const xml =
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Project version="1.0">
        \\  <Application name="Bitwig Studio" version="5.0"/>
        \\  <Transport>
        \\    <Tempo unit="bpm" value="149.000000" id="id0" name="Tempo"/>
        \\    <TimeSignature denominator="4" numerator="4" id="id1"/>
        \\  </Transport>
        \\  <Structure>
        \\    <Track contentType="audio" loaded="true" id="id9" name="Drumloop">
        \\      <Channel audioChannels="2" role="regular" solo="false" id="id10"/>
        \\    </Track>
        \\  </Structure>
        \\  <Arrangement id="id19">
        \\    <Lanes timeUnit="beats" id="id20">
        \\      <Lanes track="id9" id="id24">
        \\        <Clips id="id25">
        \\          <Clip time="0.0" duration="8.00003433227539" playStart="0.0" loopStart="0.0" loopEnd="8.00003433227539" fadeTimeUnit="beats" fadeInTime="0.0" fadeOutTime="0.0" name="Drumfunk3 170bpm">
        \\            <Clips id="id26">
        \\              <Clip time="0.0" duration="8.00003433227539" contentTimeUnit="beats" playStart="0.0" fadeTimeUnit="beats" fadeInTime="0.0" fadeOutTime="0.0">
        \\                <Warps contentTimeUnit="seconds" timeUnit="beats" id="id28">
        \\                  <Audio algorithm="stretch" channels="2" duration="2.823541666666667" sampleRate="48000" id="id27">
        \\                    <File path="audio/Drumfunk3 170bpm.wav"/>
        \\                  </Audio>
        \\                  <Warp time="0.0" contentTime="0.0"/>
        \\                  <Warp time="8.00003433227539" contentTime="2.823541666666667"/>
        \\                </Warps>
        \\              </Clip>
        \\            </Clips>
        \\          </Clip>
        \\        </Clips>
        \\      </Lanes>
        \\    </Lanes>
        \\  </Arrangement>
        \\  <Scenes/>
        \\</Project>
    ;

    const parsed = try parse.parseProjectXml(allocator, xml);
    const clip = parsed.arrangement.?.lanes.?.children[0].clips.?.clips[0];
    try std.testing.expect(clip.nested_clips != null);
    try std.testing.expectEqual(@as(usize, 1), clip.nested_clips.?.clips.len);
    try std.testing.expect(clip.nested_clips.?.clips[0].warps != null);

    const flat = try flatten.flattenClipAudio(allocator, &clip);
    try std.testing.expect(flat != null);
    const f = flat.?;
    try std.testing.expectEqualStrings("audio/Drumfunk3 170bpm.wav", f.audio.file.path);
    try std.testing.expectEqual(@as(i32, 48000), f.audio.sample_rate);
    try std.testing.expectEqualStrings("stretch", f.algorithm.?);
    try std.testing.expectEqual(@as(usize, 2), f.warps.len);
    try std.testing.expectApproxEqAbs(@as(f64, 8.00003433227539), f.duration, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.823541666666667), f.audio.duration, 1e-9);
    try std.testing.expectEqualStrings("Drumfunk3 170bpm", f.name.?);
}

test "dawproject portable builtins equalizer compressor parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const xml =
        \\<?xml version="1.0"?>
        \\<Project version="1.0">
        \\  <Application name="Flux" version="0.1"/>
        \\  <Structure>
        \\    <Track contentType="notes" id="t0" name="T1">
        \\      <Channel id="c0" role="regular">
        \\        <Devices>
        \\          <Compressor deviceID="com.flux.builtin.compressor" deviceName="Compressor" deviceRole="audioFX" loaded="true" id="d0" name="Compressor">
        \\            <Parameters>
        \\              <RealParameter id="d0_p10" parameterID="10" name="Compress" min="0" max="1" unit="linear" value="0.3"/>
        \\              <RealParameter id="d0_p11" parameterID="11" name="Output" min="0" max="1" unit="linear" value="0.5"/>
        \\            </Parameters>
        \\            <Threshold id="d0_th" name="Threshold" unit="linear" value="0.3"/>
        \\          </Compressor>
        \\          <Equalizer deviceID="com.flux.builtin.equalizer" deviceName="Equalizer" deviceRole="audioFX" loaded="true" id="d1" name="Equalizer">
        \\            <Parameters>
        \\              <RealParameter id="d1_p100" parameterID="100" name="Input Gain" min="-24" max="24" unit="linear" value="0"/>
        \\            </Parameters>
        \\          </Equalizer>
        \\          <Limiter deviceID="com.flux.builtin.limiter" deviceName="Limiter" deviceRole="audioFX" loaded="true" id="d2" name="Limiter"/>
        \\          <NoiseGate deviceID="com.flux.builtin.noise_gate" deviceName="Noise Gate" deviceRole="audioFX" loaded="true" id="d3" name="Noise Gate">
        \\            <Threshold id="d3_th" name="Threshold" unit="linear" value="0.5"/>
        \\          </NoiseGate>
        \\        </Devices>
        \\      </Channel>
        \\    </Track>
        \\  </Structure>
        \\</Project>
    ;
    const parsed = try parse.parseProjectXml(allocator, xml);
    const ch = parsed.tracks[0].channel.?;
    try std.testing.expectEqual(@as(usize, 4), ch.devices.len);
    try std.testing.expect(ch.devices[0].xml_kind == .compressor);
    try std.testing.expectEqualStrings("com.flux.builtin.compressor", ch.devices[0].device_id);
    try std.testing.expect(ch.devices[0].parameters.len >= 2);
    try std.testing.expect(ch.devices[1].xml_kind == .equalizer);
    try std.testing.expect(ch.devices[2].xml_kind == .limiter);
    try std.testing.expect(ch.devices[3].xml_kind == .noise_gate);
}

test "portable builtin writer follows XSD child order" {
    const allocator = std.testing.allocator;
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1" },
        .tracks = &.{.{
            .id = "t",
            .name = "Track",
            .channel = .{
                .id = "c",
                .devices = &.{.{
                    .id = "gate",
                    .name = "Gate",
                    .device_id = "com.flux.builtin.noise_gate",
                    .device_name = "Gate",
                    .device_role = .audioFX,
                    .xml_kind = .noise_gate,
                    .parameters = &.{.{ .id = "p", .name = "P", .value = 0, .unit = .linear }},
                    .enabled = .{ .id = "en", .name = "On", .value = true },
                    .attack = .{ .id = "a", .name = "Attack", .value = 0.01, .unit = .seconds },
                    .range = .{ .id = "r", .name = "Range", .value = -60, .unit = .decibel },
                    .ratio = .{ .id = "ra", .name = "Ratio", .value = 10, .unit = .linear },
                    .release = .{ .id = "rel", .name = "Release", .value = 0.1, .unit = .seconds },
                    .threshold = .{ .id = "th", .name = "Threshold", .value = -40, .unit = .decibel },
                }},
            },
        }},
    };

    const xml = try toXml(allocator, &proj);
    defer allocator.free(xml);
    const tags = [_][]const u8{ "<Parameters>", "<Enabled", "<Attack", "<Range", "<Ratio", "<Release", "<Threshold" };
    var previous: usize = 0;
    for (tags) |tag| {
        const found = std.mem.indexOf(u8, xml, tag);
        try std.testing.expect(found != null);
        const position = found.?;
        try std.testing.expect(position >= previous);
        previous = position;
    }
}

test "bitwig midi clip playStart loop and clap plugin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Subset of LOAD DIVA.dawproject: instrument + session MIDI punch/loop region.
    const xml =
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Project version="1.0">
        \\  <Application name="Bitwig Studio" version="6.0"/>
        \\  <Transport>
        \\    <Tempo max="666" min="20" unit="bpm" value="110" id="id0" name="Tempo"/>
        \\    <TimeSignature denominator="4" numerator="4" id="id1" name="Time Signature"/>
        \\  </Transport>
        \\  <Structure>
        \\    <Track contentType="notes" loaded="true" id="id2" name="Diva" color="#ff5706">
        \\      <Channel audioChannels="2" destination="id20" role="regular" solo="false" id="id3">
        \\        <Devices>
        \\          <ClapPlugin deviceID="com.u-he.Diva" deviceName="Diva" deviceRole="instrument" loaded="true" id="id7" name="Diva">
        \\            <Parameters/>
        \\            <Enabled value="true" id="id8" name="On/Off"/>
        \\            <State path="plugins/0d8762f7-b4ee-4fb2-98c1-381f17999991.clap-preset"/>
        \\          </ClapPlugin>
        \\        </Devices>
        \\        <Mute value="false" id="id6" name="Mute"/>
        \\        <Pan max="1" min="0" unit="normalized" value="0.5" id="id5" name="Pan"/>
        \\        <Volume max="2" min="0" unit="linear" value="0.316228" id="id4" name="Volume"/>
        \\      </Channel>
        \\    </Track>
        \\  </Structure>
        \\  <Scenes>
        \\    <Scene id="id43" name="Scene 1">
        \\      <Lanes id="id44">
        \\        <ClipSlot hasStop="true" track="id2" id="id45">
        \\          <Clip time="0.0" duration="24.0" playStart="8.0" loopStart="6.0" loopEnd="22.0" enable="true">
        \\            <Notes id="id46">
        \\              <Note time="7.598730" duration="2.745760" channel="0" key="29" vel="0.700000" rel="0.500000"/>
        \\              <Note time="10.557340" duration="2.554195" channel="0" key="33" vel="0.700000" rel="0.500000"/>
        \\            </Notes>
        \\          </Clip>
        \\        </ClipSlot>
        \\      </Lanes>
        \\    </Scene>
        \\  </Scenes>
        \\</Project>
    ;

    const parsed = try parse.parseProjectXml(allocator, xml);
    try std.testing.expectEqual(@as(usize, 1), parsed.tracks.len);
    const track = parsed.tracks[0];
    try std.testing.expectEqualStrings("Diva", track.name);
    try std.testing.expect(track.channel != null);
    const ch = track.channel.?;
    try std.testing.expect(ch.volume != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.316228), ch.volume.?.value, 1e-6);
    try std.testing.expect(ch.pan != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), ch.pan.?.value, 1e-6);
    try std.testing.expect(ch.mute != null);
    try std.testing.expect(!ch.mute.?.value);
    try std.testing.expectEqual(@as(usize, 1), ch.devices.len);
    try std.testing.expectEqualStrings("com.u-he.Diva", ch.devices[0].device_id);
    try std.testing.expectEqualStrings("plugins/0d8762f7-b4ee-4fb2-98c1-381f17999991.clap-preset", ch.devices[0].state.?.path);

    try std.testing.expectEqual(@as(usize, 1), parsed.scenes.len);
    const slot = parsed.scenes[0].clip_slots[0];
    try std.testing.expect(slot.clip != null);
    const clip = slot.clip.?;
    try std.testing.expectApproxEqAbs(@as(f64, 24.0), clip.duration, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), clip.play_start, 1e-9);
    try std.testing.expect(clip.loop_start != null);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), clip.loop_start.?, 1e-9);
    try std.testing.expect(clip.loop_end != null);
    try std.testing.expectApproxEqAbs(@as(f64, 22.0), clip.loop_end.?, 1e-9);
    try std.testing.expect(clip.notes != null);
    try std.testing.expectEqual(@as(usize, 2), clip.notes.?.notes.len);
}

test "session clip slot audio round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const warps_pts = [_]WarpPoint{
        .{ .time = 0.0, .content_time = 0.0 },
        .{ .time = 4.0, .content_time = 2.0 },
    };
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1.0" },
        .tracks = &.{
            .{
                .id = "track0",
                .name = "Audio 1",
                .content_type = .audio,
                .channel = .{ .id = "ch0" },
            },
        },
        .scenes = &.{
            .{
                .id = "scene0",
                .name = "Scene 1",
                .lanes_id = "slanes0",
                .clip_slots = &.{
                    .{
                        .id = "slot0",
                        .track = "track0",
                        .has_stop = true,
                        .clip = .{
                            .time = 0.0,
                            .duration = 4.0,
                            .play_start = 0.0,
                            .loop_start = 0.0,
                            .loop_end = 4.0,
                            .name = "kick",
                            .warps = .{
                                .id = "w0",
                                .time_unit = .beats,
                                .content_time_unit = .seconds,
                                .audio = .{
                                    .id = "a0",
                                    .file = .{ .path = "audio/kick.wav" },
                                    .duration = 2.0,
                                    .sample_rate = 44100,
                                    .channels = 1,
                                    .algorithm = "stretch",
                                },
                                .warps = &warps_pts,
                            },
                        },
                    },
                },
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    const parsed = try parse.parseProjectXml(allocator, xml);
    try std.testing.expectEqual(@as(usize, 1), parsed.scenes.len);
    const slot = parsed.scenes[0].clip_slots[0];
    try std.testing.expect(slot.clip != null);
    const flat = try flatten.flattenClipAudio(allocator, &slot.clip.?);
    try std.testing.expect(flat != null);
    try std.testing.expectEqualStrings("audio/kick.wav", flat.?.audio.file.path);
    try std.testing.expectEqual(@as(i32, 1), flat.?.audio.channels);
    try std.testing.expectEqual(@as(usize, 2), flat.?.warps.len);
}

test "identity warps when audio has no warp points" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const clip: Clip = .{
        .time = 0,
        .duration = 4.0,
        .audio = .{
            .file = .{ .path = "audio/raw.wav" },
            .duration = 1.5,
            .sample_rate = 44100,
            .channels = 2,
        },
    };
    const flat = try flatten.flattenClipAudio(allocator, &clip);
    try std.testing.expect(flat != null);
    try std.testing.expectEqual(@as(usize, 2), flat.?.warps.len);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), flat.?.warps[1].time, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), flat.?.warps[1].content_time, 1e-9);
}

test "collect audio paths from nested clip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const clip: Clip = .{
        .time = 0,
        .duration = 8,
        .nested_clips = .{
            .id = "inner",
            .clips = &.{
                .{
                    .time = 0,
                    .duration = 8,
                    .warps = .{
                        .content_time_unit = .seconds,
                        .audio = .{
                            .file = .{ .path = "audio/nested.wav" },
                            .duration = 3.0,
                            .sample_rate = 48000,
                            .channels = 2,
                        },
                        .warps = &.{
                            .{ .time = 0, .content_time = 0 },
                            .{ .time = 8, .content_time = 3 },
                        },
                    },
                },
            },
        },
    };

    var paths: std.ArrayList([]const u8) = .empty;
    try flatten.collectAudioPaths(allocator, &clip, &paths);
    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
    try std.testing.expectEqualStrings("audio/nested.wav", paths.items[0]);
}

test "external audio file attribute round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const warps_pts = [_]WarpPoint{
        .{ .time = 0.0, .content_time = 0.0 },
        .{ .time = 4.0, .content_time = 1.0 },
    };
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1.0" },
        .tracks = &.{
            .{
                .id = "tr1",
                .name = "Audio",
                .content_type = .audio,
                .channel = .{ .id = "ch1" },
            },
        },
        .scenes = &.{
            .{
                .id = "sc1",
                .name = "Scene 1",
                .lanes_id = "sl1",
                .clip_slots = &.{
                    .{
                        .id = "cs1",
                        .track = "tr1",
                        .clip = .{
                            .time = 0,
                            .duration = 4,
                            .warps = .{
                                .id = "w1",
                                .time_unit = .beats,
                                .content_time_unit = .seconds,
                                .audio = .{
                                    .id = "a1",
                                    .file = .{ .path = "samples/kick.wav", .external = true },
                                    .duration = 1.0,
                                    .sample_rate = 48000,
                                    .channels = 2,
                                },
                                .warps = &warps_pts,
                            },
                        },
                    },
                },
            },
        },
    };

    const xml = try toXml(allocator, &proj);
    try std.testing.expect(std.mem.indexOf(u8, xml, "samples/kick.wav") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "external=\"true\"") != null);

    const parsed = try parse.parseProjectXml(allocator, xml);
    const file = parsed.scenes[0].clip_slots[0].clip.?.warps.?.audio.?.file;
    try std.testing.expectEqualStrings("samples/kick.wav", file.path);
    try std.testing.expect(file.external);
}

test "arrangement tracks clips colors positions and media round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const warp_points = [_]WarpPoint{
        .{ .time = 0.0, .content_time = 0.0 },
        .{ .time = 3.5, .content_time = 1.75 },
    };
    const notes = [_]types.Note{.{
        .time = 0.25,
        .duration = 0.5,
        .key = 64,
        .vel = 0.75,
        .rel = 0.6,
    }};
    const lanes = [_]types.Lanes{
        .{
            .id = "audio-lane",
            .track = "audio-track",
            .clips = .{
                .id = "audio-clips",
                .clips = &.{.{
                    .time = 1.25,
                    .duration = 3.5,
                    .enable = false,
                    .name = "Take 1",
                    .color = "#336699",
                    .warps = .{
                        .id = "audio-warps",
                        .time_unit = .beats,
                        .content_time_unit = .seconds,
                        .audio = .{
                            .id = "audio-source",
                            .file = .{ .path = "samples/take-1.wav", .external = true },
                            .duration = 1.75,
                            .sample_rate = 48000,
                            .channels = 2,
                        },
                        .warps = &warp_points,
                    },
                }},
            },
        },
        .{
            .id = "midi-lane",
            .track = "midi-track",
            .clips = .{
                .id = "midi-clips",
                .clips = &.{.{
                    .time = 8.0,
                    .duration = 4.0,
                    .name = "Lead",
                    .color = "#cc8844",
                    .notes = .{ .id = "lead-notes", .notes = &notes },
                }},
            },
        },
    };
    const proj = Project{
        .application = .{ .name = "Flux", .version = "1.0" },
        .tracks = &.{
            .{ .id = "audio-track", .name = "Audio", .color = "#224466" },
            .{ .id = "midi-track", .name = "MIDI", .color = "#88aa44" },
        },
        .arrangement = .{
            .id = "arrangement",
            .lanes = .{ .id = "root-lanes", .time_unit = .beats, .children = &lanes },
        },
    };

    const xml = try toXml(allocator, &proj);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Arrangement") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "external=\"true\"") != null);

    const parsed = try parse.parseProjectXml(allocator, xml);
    try std.testing.expectEqualStrings("#224466", parsed.tracks[0].color.?);
    try std.testing.expectEqualStrings("#88aa44", parsed.tracks[1].color.?);

    const children = parsed.arrangement.?.lanes.?.children;
    try std.testing.expectEqual(@as(usize, 2), children.len);
    const audio_clip = children[0].clips.?.clips[0];
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), audio_clip.time, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), audio_clip.duration, 1e-6);
    try std.testing.expect(!audio_clip.enable);
    try std.testing.expectEqualStrings("Take 1", audio_clip.name.?);
    try std.testing.expectEqualStrings("#336699", audio_clip.color.?);
    try std.testing.expectEqualStrings("samples/take-1.wav", audio_clip.warps.?.audio.?.file.path);
    try std.testing.expect(audio_clip.warps.?.audio.?.file.external);

    const midi_clip = children[1].clips.?.clips[0];
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), midi_clip.time, 1e-6);
    try std.testing.expectEqualStrings("#cc8844", midi_clip.color.?);
    try std.testing.expectEqual(@as(usize, 1), midi_clip.notes.?.notes.len);
    try std.testing.expectEqual(@as(i32, 64), midi_clip.notes.?.notes[0].key);
}

test "media_layout path safety and sanitize" {
    const allocator = std.testing.allocator;
    try std.testing.expect(media_layout.isSafeRelativePath("samples/kick.wav"));
    try std.testing.expect(media_layout.isSafeRelativePath("recordings/Track1-001.wav"));
    try std.testing.expect(!media_layout.isSafeRelativePath("../etc/passwd"));
    try std.testing.expect(!media_layout.isSafeRelativePath("/abs/path.wav"));
    try std.testing.expect(media_layout.isMediaSubdirPath("samples/a.wav"));
    try std.testing.expect(media_layout.isMediaSubdirPath("recordings/b.wav"));
    try std.testing.expect(!media_layout.isMediaSubdirPath("audio/c.wav"));

    const safe = try media_layout.sanitizeBaseName(allocator, "foo/../../kick drum!.wav");
    defer allocator.free(safe);
    try std.testing.expectEqualStrings("kick drum_.wav", safe);
}

test "thin zip has no wav members" {
    const allocator = std.testing.allocator;
    var zip = zip_writer.ZipWriter.init(allocator);
    defer zip.deinit();
    try zip.addFile("project.xml", "<Project/>");
    try zip.addFile("metadata.xml", "<MetaData/>");
    try zip.addFile("flux_undo.xml", "<Metadata/>");
    try zip.addFile("plugins/track0.clap-preset", "clap....");
    // Intentionally no samples/ or recordings/
    const data = try zip.finish();
    try std.testing.expect(std.mem.indexOf(u8, data, "project.xml") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "samples/") == null);
    try std.testing.expect(std.mem.indexOf(u8, data, ".wav") == null);
}

test "packed zip includes arrangement audio member" {
    const allocator = std.testing.allocator;
    var zip = zip_writer.ZipWriter.init(allocator);
    defer zip.deinit();
    try zip.addFile("project.xml", "<Project><Arrangement/></Project>");
    try zip.addFile("audio/take-1.wav", "RIFF arrangement audio");

    const data = try zip.finish();
    try std.testing.expect(std.mem.indexOf(u8, data, "audio/take-1.wav") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "RIFF arrangement audio") != null);
}
