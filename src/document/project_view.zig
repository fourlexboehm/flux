//! UI-neutral DAWproject serialization and loading views.

const document_model = @import("../document/model.zig");
const clip_mod = @import("../session/clip_pool.zig");
const notes = @import("../session/notes.zig");
const audio_clip = @import("../session/audio_clip.zig");
const std = @import("std");

const max_tracks = @import("../session/constants.zig").max_tracks;
const max_fx_slots = @import("../audio/engine_ui.zig").max_fx_slots;

const MissingRole = enum { instrument, note_fx, audio_fx, analyzer };
const MissingPlugin = struct {
    device_id: []const u8 = "",
    device_name: []const u8 = "",
    role: MissingRole = .instrument,
    loaded: bool = false,
};

pub const DeviceChoice = struct {
    choice_index: i32 = 0,
    enabled: bool = true,
};

pub const View = struct {
    session: *@import("../session/types.zig").SessionView,
    arrangement: *@import("../arrangement/types.zig").ArrangementView,
    clip_pool: *@import("../session/clip_pool.zig").ClipPool,
    sample_store: *@import("../audio/sample_store.zig").SampleStore,
    bpm: f32,
    time_signature_numerator: u8,
    time_signature_denominator: u8,
    project_path: ?[]const u8,
    track_plugins: [max_tracks]DeviceChoice,
    track_fx: [max_tracks][max_fx_slots]DeviceChoice,
    missing_track_plugins: [max_tracks]?MissingPlugin = @splat(null),
    missing_track_fx: [max_tracks][max_fx_slots]?MissingPlugin = @splat(@splat(null)),

    pub fn init(
        document: document_model.Model,
        bpm: f32,
        time_signature_numerator: u8,
        time_signature_denominator: u8,
        project_path: ?[]const u8,
        track_plugins: [max_tracks]DeviceChoice,
        track_fx: [max_tracks][max_fx_slots]DeviceChoice,
    ) View {
        return .{
            .session = document.session,
            .arrangement = document.arrangement,
            .clip_pool = document.clip_pool,
            .sample_store = document.sample_store,
            .bpm = bpm,
            .time_signature_numerator = time_signature_numerator,
            .time_signature_denominator = time_signature_denominator,
            .project_path = project_path,
            .track_plugins = track_plugins,
            .track_fx = track_fx,
        };
    }

    pub fn slotClipConst(self: *const View, track: usize, scene: usize) ?*const clip_mod.Clip {
        return self.clip_pool.getConst(self.session.clips[track][scene].clip);
    }

    pub fn slotPianoConst(self: *const View, track: usize, scene: usize) ?*const notes.PianoRollClip {
        const clip = self.slotClipConst(track, scene) orelse return null;
        return if (clip.content == .midi) &clip.content.midi else null;
    }

    pub fn slotAudioConst(self: *const View, track: usize, scene: usize) ?*const audio_clip.AudioClip {
        const clip = self.slotClipConst(track, scene) orelse return null;
        return if (clip.content == .audio) &clip.content.audio else null;
    }

    pub fn trackHasAudio(self: *const View, track: usize) bool {
        for (0..self.session.scene_count) |scene| if (self.slotAudioConst(track, scene) != null) return true;
        const arrangement = self.arrangement;
        for (self.arrangement.tracks.items) |*arr_track| {
            if (arr_track.session_track_index != track) continue;
            for (arr_track.clips.items) |*placement| {
                if (arrangement.placementAudio(placement) != null) return true;
            }
        }
        return false;
    }

    pub fn trackHasNotes(self: *const View, track: usize) bool {
        for (0..self.session.scene_count) |scene| if (self.slotPianoConst(track, scene) != null) return true;
        const arrangement = self.arrangement;
        for (self.arrangement.tracks.items) |*arr_track| {
            if (arr_track.session_track_index != track) continue;
            for (arr_track.clips.items) |*placement| {
                const clip = arrangement.placementClip(placement) orelse continue;
                if (clip.content == .midi) return true;
            }
        }
        return false;
    }
};

/// Mutable document view used by the UI-neutral DAWproject appliers.
pub const LoadView = struct {
    allocator: std.mem.Allocator,
    session: *@import("../session/types.zig").SessionView,
    arrangement: *@import("../arrangement/types.zig").ArrangementView,
    clip_pool: *@import("../session/clip_pool.zig").ClipPool,
    sample_store: *@import("../audio/sample_store.zig").SampleStore,
    scratch_clip: notes.PianoRollClip,
    bpm: f32,
    time_signature_numerator: u8,

    pub fn init(document: document_model.Model, allocator: std.mem.Allocator, bpm: f32, time_signature_numerator: u8) LoadView {
        return .{
            .allocator = allocator,
            .session = document.session,
            .arrangement = document.arrangement,
            .clip_pool = document.clip_pool,
            .sample_store = document.sample_store,
            .scratch_clip = notes.PianoRollClip.init(allocator),
            .bpm = bpm,
            .time_signature_numerator = time_signature_numerator,
        };
    }

    pub fn deinit(self: *LoadView) void {
        self.scratch_clip.deinit();
    }

    pub fn slotClip(self: *LoadView, track: usize, scene: usize) ?*clip_mod.Clip {
        return self.clip_pool.get(self.session.clips[track][scene].clip);
    }

    pub fn slotHasAudio(self: *LoadView, track: usize, scene: usize) bool {
        const clip = self.slotClip(track, scene) orelse return false;
        return clip.content == .audio and clip.content.audio.hasAudio();
    }

    pub fn releaseSlotClip(self: *LoadView, track: usize, scene: usize) void {
        const slot = &self.session.clips[track][scene];
        if (!slot.clip.isNone()) self.clip_pool.release(slot.clip, self.sample_store);
        slot.* = .{};
    }

    pub fn ensureSlotPiano(self: *LoadView, track: usize, scene: usize) *notes.PianoRollClip {
        if (self.slotClip(track, scene)) |clip| if (clip.content == .midi) return &clip.content.midi;
        const previous_length = if (self.slotClip(track, scene)) |clip| clip.lengthBeats() else 0;
        self.releaseSlotClip(track, scene);
        var piano = notes.PianoRollClip.init(self.allocator);
        if (previous_length > 0) piano.length_beats = previous_length;
        const id = self.clip_pool.addMidi(piano) catch {
            piano.deinit();
            self.scratch_clip.clear();
            return &self.scratch_clip;
        };
        self.clip_pool.retain(id);
        self.session.clips[track][scene] = .{ .state = .stopped, .clip = id };
        return &self.clip_pool.get(id).?.content.midi;
    }

    pub fn ensureSlotAudio(self: *LoadView, track: usize, scene: usize) ?*audio_clip.AudioClip {
        if (self.slotClip(track, scene)) |clip| if (clip.content == .audio) return &clip.content.audio;
        const previous_length = if (self.slotClip(track, scene)) |clip| clip.lengthBeats() else 0;
        self.releaseSlotClip(track, scene);
        var audio = audio_clip.AudioClip.init(self.allocator);
        if (previous_length > 0) audio.length_beats = previous_length;
        const id = self.clip_pool.addAudio(audio) catch {
            audio.deinit(self.sample_store);
            return null;
        };
        self.clip_pool.retain(id);
        self.session.clips[track][scene] = .{ .state = .stopped, .clip = id };
        return &self.clip_pool.get(id).?.content.audio;
    }
};

test "DVUI host view serializes session transport and MIDI clips" {
    const host_mod = @import("../ui/host.zig");
    const convert = @import("../project/convert.zig");
    const xml_writer = @import("../project/format/xml_writer.zig");
    const parse = @import("../project/format/parse.zig");
    const io_types = @import("../project/io_types.zig");
    const plugins = @import("../plugin/plugins.zig");

    const allocator = std.testing.allocator;
    var store = document_model.Store.init(allocator);
    defer store.deinit();
    store.wireInternalRefs();
    var host = host_mod.Host.init(&store);
    defer host.deinit();
    host.wireInternalRefs();
    store.session.tracks[0].setName("Roundtrip Lead");
    store.session.tracks[0].volume = 0.625;
    @import("commands.zig").createClip(&store, 0, 0, 4);
    try store.clip_pool.get(store.session.clips[0][0].clip).?.content.midi.addNote(64, 1.25, 0.5);

    var catalog = plugins.PluginCatalog{ .allocator = allocator };
    defer catalog.deinit();

    var view = View.init(
        host.document(),
        137,
        7,
        8,
        null,
        @splat(.{}),
        @splat(@splat(.{})),
    );
    var instruments: [max_tracks]io_types.TrackPluginInfo = @splat(.{});
    var effects: [max_tracks][max_fx_slots]io_types.TrackPluginInfo = @splat(@splat(.{}));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const project = try convert.fromFluxProject(aa, &view, &catalog, &instruments, &effects, .external);
    const xml = try xml_writer.toXml(aa, &project);
    const parsed = try parse.parseProjectXml(aa, xml);

    try std.testing.expectEqualStrings("Roundtrip Lead", parsed.tracks[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 0.625), parsed.tracks[0].channel.?.volume.?.value, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 137), parsed.transport.?.tempo.?.value, 0.0001);
    try std.testing.expectEqual(@as(i32, 7), parsed.transport.?.time_signature.?.numerator);
    try std.testing.expectEqual(@as(i32, 8), parsed.transport.?.time_signature.?.denominator);
    const clip = parsed.scenes[0].clip_slots[0].clip.?;
    try std.testing.expectEqual(@as(usize, 1), clip.notes.?.notes.len);
    try std.testing.expectEqual(@as(i32, 64), clip.notes.?.notes[0].key);
}
