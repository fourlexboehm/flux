const std = @import("std");
const arr_track = @import("track.zig");
const arr_clip = @import("clip.zig");
const timeline = @import("timeline.zig");
const clip_pool = @import("../session/clip_pool.zig");
const notes = @import("../session/notes.zig");
const audio_clip = @import("../session/audio_clip.zig");

const ClipPool = clip_pool.ClipPool;
const ClipId = clip_pool.ClipId;
const ClipKind = clip_pool.ClipKind;
const Clip = clip_pool.Clip;
const PianoRollClip = notes.PianoRollClip;
const AudioClip = audio_clip.AudioClip;
const SampleStore = @import("../audio/sample_store.zig").SampleStore;

pub const ArrangementView = struct {
    allocator: std.mem.Allocator,

    // Back-references into `State`, wired once via `State.wireInternalRefs`.
    // Placements reference pooled clip content through these; standalone
    // (unit-test) views leave them null and only exercise placement geometry.
    clip_pool: ?*ClipPool = null,
    sample_store: ?*SampleStore = null,

    tracks: std.ArrayListUnmanaged(arr_track.ArrangementTrack) = .empty,
    zoom: f32 = 1.0,
    scroll_x: f32 = 0,
    bpm: f32 = 120,
    beats_per_bar: u8 = 4,
    current_tick: i64 = 0,

    snap_division_ticks: i64 = timeline.ppq / 4,

    pub fn init(allocator: std.mem.Allocator) ArrangementView {
        var view = ArrangementView{ .allocator = allocator };
        view.tracks.append(allocator, arr_track.ArrangementTrack.init("Track 1", 0, .{ 0.40, 0.62, 0.82, 1.0 })) catch {};
        view.tracks.append(allocator, arr_track.ArrangementTrack.init("Track 2", 1, .{ 0.42, 0.72, 0.48, 1.0 })) catch {};
        return view;
    }

    pub fn deinit(self: *ArrangementView) void {
        self.clearTracks();
        self.tracks.deinit(self.allocator);
    }

    /// Drop all tracks/clips (keeps allocator and zoom/scroll). Releases each
    /// placement's pooled clip reference.
    pub fn clearTracks(self: *ArrangementView) void {
        for (self.tracks.items) |*track| {
            track.deinit(self.allocator, self.clip_pool, self.sample_store);
        }
        self.tracks.clearRetainingCapacity();
    }

    // ── Pool accessors for placements ────────────────────────────────────

    /// The pooled clip a placement references, or null when empty/stale/no pool.
    pub fn placementClip(self: *ArrangementView, placement: *const arr_clip.ArrangementClip) ?*Clip {
        const pool = self.clip_pool orelse return null;
        return pool.get(placement.clip);
    }

    /// The placement's MIDI content, or null if it is empty or holds audio.
    pub fn placementMidi(self: *ArrangementView, placement: *const arr_clip.ArrangementClip) ?*PianoRollClip {
        if (self.placementClip(placement)) |c| {
            if (c.content == .midi) return &c.content.midi;
        }
        return null;
    }

    /// The placement's audio content, or null if it is empty or holds MIDI.
    pub fn placementAudio(self: *ArrangementView, placement: *const arr_clip.ArrangementClip) ?*AudioClip {
        if (self.placementClip(placement)) |c| {
            if (c.content == .audio) return &c.content.audio;
        }
        return null;
    }

    /// Content kind of a placement's clip, or null when empty/stale.
    pub fn placementKind(self: *ArrangementView, placement: *const arr_clip.ArrangementClip) ?ClipKind {
        if (self.placementClip(placement)) |c| return c.content;
        return null;
    }

    /// Create a fresh pooled clip of `kind` (refcount 1) and return its handle,
    /// or `.none` on failure / when no pool is wired.
    pub fn addPooledClip(self: *ArrangementView, kind: ClipKind, length_beats: f32) ClipId {
        const pool = self.clip_pool orelse return ClipId.none;
        switch (kind) {
            .midi => {
                var pc = PianoRollClip.init(self.allocator);
                if (length_beats > 0) pc.length_beats = length_beats;
                const id = pool.addMidi(pc) catch {
                    pc.deinit();
                    return ClipId.none;
                };
                pool.retain(id);
                return id;
            },
            .audio => {
                var ac = AudioClip.init(self.allocator);
                if (length_beats > 0) ac.length_beats = length_beats;
                const id = pool.addAudio(ac) catch {
                    ac.deinit(self.sample_store);
                    return ClipId.none;
                };
                pool.retain(id);
                return id;
            },
        }
    }

    /// Deep-copy a pooled clip into a new independent handle (refcount 1), or
    /// `.none` on failure / when no pool is wired.
    pub fn dupePooledClip(self: *ArrangementView, id: ClipId) ClipId {
        const pool = self.clip_pool orelse return ClipId.none;
        const new_id = pool.dupe(id, self.sample_store);
        if (new_id.isNone()) return ClipId.none;
        pool.retain(new_id);
        return new_id;
    }

    /// Drop a placement's reference to its pooled clip.
    pub fn releasePlacement(self: *ArrangementView, placement: *const arr_clip.ArrangementClip) void {
        const pool = self.clip_pool orelse return;
        if (!placement.clip.isNone()) pool.release(placement.clip, self.sample_store);
    }

    pub fn clearSelection(self: *ArrangementView) void {
        for (self.tracks.items) |*track| {
            for (track.clips.items) |*clip| {
                clip.selected = false;
            }
        }
    }

    pub fn selectAllClips(self: *ArrangementView) void {
        for (self.tracks.items) |*track| {
            for (track.clips.items) |*clip| clip.selected = true;
        }
    }

    pub fn hasSelection(self: *const ArrangementView) bool {
        for (self.tracks.items) |track| {
            for (track.clips.items) |clip| {
                if (clip.selected) return true;
            }
        }
        return false;
    }

    pub fn selectedClips(self: *ArrangementView, ctx: *SelectIterContext) ?[2]usize {
        while (ctx.track_index < self.tracks.items.len) : (ctx.track_index += 1) {
            const track = &self.tracks.items[ctx.track_index];
            while (ctx.clip_index < track.clips.items.len) : (ctx.clip_index += 1) {
                if (track.clips.items[ctx.clip_index].selected) {
                    ctx.clip_index += 1;
                    return .{ ctx.track_index, ctx.clip_index - 1 };
                }
            }
            ctx.clip_index = 0;
        }
        return null;
    }

    pub const SelectIterContext = struct {
        track_index: usize = 0,
        clip_index: usize = 0,
    };
};
