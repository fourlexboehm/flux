const std = @import("std");
const arr_track = @import("track.zig");
const arr_clip = @import("clip.zig");
const timeline = @import("timeline.zig");

pub const ArrangementView = struct {
    allocator: std.mem.Allocator,

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

    /// Drop all tracks/clips (keeps allocator and zoom/scroll).
    pub fn clearTracks(self: *ArrangementView) void {
        for (self.tracks.items) |*track| {
            track.deinit(self.allocator);
        }
        self.tracks.clearRetainingCapacity();
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
