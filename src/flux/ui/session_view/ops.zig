const std = @import("std");
const session_view = @import("../session_view.zig");
const constants = @import("constants.zig");

const max_tracks = constants.max_tracks;
const max_scenes = constants.max_scenes;
const beats_per_bar = constants.beats_per_bar;
const default_clip_bars = constants.default_clip_bars;

pub fn init(allocator: std.mem.Allocator) session_view.SessionView {
    var self = session_view.SessionView{
        .allocator = allocator,
    };

    // Initialize tracks
    const TrackType = @TypeOf(self.tracks[0]);
    for (0..self.track_count) |i| {
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "Inst {d}", .{i + 1}) catch "Inst";
        self.tracks[i] = TrackType.init(name);
    }
    self.tracks[session_view.master_track_index] = TrackType.init("Master");
    self.tracks[session_view.master_track_index].is_master = true;
    self.tracks[session_view.master_track_index].volume = 0.9;

    // Initialize scenes
    const SceneType = @TypeOf(self.scenes[0]);
    for (0..self.scene_count) |i| {
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "{d}", .{i + 1}) catch "1";
        self.scenes[i] = SceneType.init(name);
    }

    // Initialize all clips as empty
    for (0..max_tracks) |t| {
        for (0..max_scenes) |s| {
            self.clips[t][s] = .{};
        }
    }

    self.mixer_target = .track;

    return self;
}

pub fn deinit(self: *session_view.SessionView) void {
    self.clipboard.deinit(self.allocator);
}

pub fn isSelected(self: *const session_view.SessionView, track: usize, scene: usize) bool {
    return self.clip_selected[track][scene];
}

pub fn selectClip(self: *session_view.SessionView, track: usize, scene: usize) void {
    self.clip_selected[track][scene] = true;
    self.primary_track = track;
    self.primary_scene = scene;
    self.mixer_target = .track;
}

pub fn deselectClip(self: *session_view.SessionView, track: usize, scene: usize) void {
    self.clip_selected[track][scene] = false;
}

pub fn clearSelection(self: *session_view.SessionView) void {
    for (&self.clip_selected) |*track_sel| {
        for (track_sel) |*sel| {
            sel.* = false;
        }
    }
}

pub fn selectAllClips(self: *session_view.SessionView) void {
    clearSelection(self);
    for (0..self.track_count) |t| {
        for (0..self.scene_count) |s| {
            if (self.clips[t][s].state != .empty) {
                selectClip(self, t, s);
            }
        }
    }
}

pub fn selectOnly(self: *session_view.SessionView, track: usize, scene: usize) void {
    clearSelection(self);
    selectClip(self, track, scene);
}

pub fn hasSelection(self: *const session_view.SessionView) bool {
    for (self.clip_selected) |track_sel| {
        for (track_sel) |sel| {
            if (sel) return true;
        }
    }
    return false;
}

pub fn handleClipClick(self: *session_view.SessionView, track: usize, scene: usize, shift_held: bool) void {
    if (shift_held) {
        if (isSelected(self, track, scene)) {
            deselectClip(self, track, scene);
        } else {
            selectClip(self, track, scene);
        }
    } else if (!isSelected(self, track, scene)) {
        selectOnly(self, track, scene);
    } else {
        self.primary_track = track;
        self.primary_scene = scene;
    }
    self.mixer_target = .track;
}

/// Create a new clip at the given position
pub fn createClip(self: *session_view.SessionView, track: usize, scene: usize) void {
    if (track >= self.track_count or scene >= self.scene_count) return;
    const length_beats = default_clip_bars * beats_per_bar;
    self.clips[track][scene] = .{
        .state = .stopped,
        .length_beats = length_beats,
    };
    // Emit undo request
    if (self.undo_request_count < self.undo_requests.len) {
        self.undo_requests[self.undo_request_count] = .{
            .kind = .clip_create,
            .track = track,
            .scene = scene,
            .length_beats = length_beats,
        };
        self.undo_request_count += 1;
    }
}

/// Delete clip at position (reset to empty)
pub fn deleteClip(self: *session_view.SessionView, track: usize, scene: usize) void {
    if (track >= self.track_count or scene >= self.scene_count) return;
    // Capture old state before deleting
    const old_clip = self.clips[track][scene];
    if (old_clip.state == .empty) return; // Don't record deleting empty slots
    self.clips[track][scene] = .{};
    // Emit undo request
    if (self.undo_request_count < self.undo_requests.len) {
        self.undo_requests[self.undo_request_count] = .{
            .kind = .clip_delete,
            .track = track,
            .scene = scene,
            .length_beats = old_clip.length_beats,
            .old_clip = old_clip,
        };
        self.undo_request_count += 1;
    }
}

/// Delete all selected clips
pub fn deleteSelected(self: *session_view.SessionView) void {
    for (0..self.track_count) |t| {
        for (0..self.scene_count) |s| {
            if (self.clip_selected[t][s]) {
                deleteClip(self, t, s);
            }
        }
    }
    clearSelection(self);
}

/// Copy selected clips to clipboard
pub fn copySelected(self: *session_view.SessionView) void {
    if (!hasSelection(self)) return;

    // Find min track/scene for relative positioning
    var min_track: usize = max_tracks;
    var min_scene: usize = max_scenes;
    for (0..self.track_count) |t| {
        for (0..self.scene_count) |s| {
            if (self.clip_selected[t][s]) {
                min_track = @min(min_track, t);
                min_scene = @min(min_scene, s);
            }
        }
    }

    self.clipboard.clearRetainingCapacity();
    self.clipboard_origin_track = min_track;
    self.clipboard_origin_scene = min_scene;

    for (0..self.track_count) |t| {
        for (0..self.scene_count) |s| {
            if (!self.clip_selected[t][s]) continue;
            const slot = self.clips[t][s];
            // Only copy non-empty clips
            if (slot.state != .empty) {
                self.clipboard.append(self.allocator, .{
                    .src_track = t,
                    .src_scene = s,
                    .track_offset = @as(i32, @intCast(t)) - @as(i32, @intCast(min_track)),
                    .scene_offset = @as(i32, @intCast(s)) - @as(i32, @intCast(min_scene)),
                    .slot = .{
                        .state = if (slot.state == .playing) .stopped else slot.state,
                        .length_beats = slot.length_beats,
                    },
                }) catch {};
            }
        }
    }
}

/// Cut selected clips (copy + delete)
pub fn cutSelected(self: *session_view.SessionView) void {
    copySelected(self);
    deleteSelected(self);
}

/// Paste clips at primary selection position
pub fn paste(self: *session_view.SessionView) void {
    if (self.clipboard.items.len == 0) return;

    clearSelection(self);
    self.piano_copy_count = 0;
    for (self.clipboard.items) |entry| {
        const track_i = @as(i32, @intCast(self.primary_track)) + entry.track_offset;
        const scene_i = @as(i32, @intCast(self.primary_scene)) + entry.scene_offset;

        if (track_i < 0 or scene_i < 0) continue;
        const track: usize = @intCast(track_i);
        const scene: usize = @intCast(scene_i);
        if (track >= self.track_count or scene >= self.scene_count) continue;

        const old_clip = self.clips[track][scene];
        self.clips[track][scene] = entry.slot;
        selectClip(self, track, scene);
        if (self.piano_copy_count < self.piano_copy_requests.len) {
            self.piano_copy_requests[self.piano_copy_count] = .{
                .src_track = entry.src_track,
                .src_scene = entry.src_scene,
                .dst_track = track,
                .dst_scene = scene,
            };
            self.piano_copy_count += 1;
        }

        if (self.undo_request_count < self.undo_requests.len) {
            self.undo_requests[self.undo_request_count] = .{
                .kind = .clip_paste,
                .track = track,
                .scene = scene,
                .src_track = entry.src_track,
                .src_scene = entry.src_scene,
                .length_beats = entry.slot.length_beats,
                .old_clip = old_clip,
            };
            self.undo_request_count += 1;
        }
    }
    self.pending_piano_copies = self.piano_copy_count > 0;
}

/// Add a new track
pub fn addTrack(self: *session_view.SessionView) bool {
    if (self.track_count >= max_tracks - 1) return false;

    var buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "Inst {d}", .{self.track_count + 1}) catch "Inst";
    const TrackType = @TypeOf(self.tracks[0]);
    self.tracks[self.track_count] = TrackType.init(name);
    self.track_count += 1;
    // Emit undo request
    if (self.undo_request_count < self.undo_requests.len) {
        self.undo_requests[self.undo_request_count] = .{
            .kind = .track_add,
            .track = self.track_count - 1,
        };
        self.undo_request_count += 1;
    }
    return true;
}

/// Add a new scene
pub fn addScene(self: *session_view.SessionView) bool {
    if (self.scene_count >= max_scenes) return false;

    var buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{d}", .{self.scene_count + 1}) catch "1";
    const SceneType = @TypeOf(self.scenes[0]);
    self.scenes[self.scene_count] = SceneType.init(name);
    self.scene_count += 1;
    // Emit undo request
    if (self.undo_request_count < self.undo_requests.len) {
        self.undo_requests[self.undo_request_count] = .{
            .kind = .scene_add,
            .scene = self.scene_count - 1,
        };
        self.undo_request_count += 1;
    }
    return true;
}

/// Delete a specific scene (if > 1)
pub fn deleteScene(self: *session_view.SessionView, scene: usize) bool {
    if (self.scene_count <= 1) return false;
    if (scene >= self.scene_count) return false;

    if (self.undo_request_count < self.undo_requests.len) {
        var clip_snapshots: [max_tracks]@TypeOf(self.undo_requests[0].scene_clips[0]) = undefined;
        for (0..self.track_count) |t| {
            const slot = self.clips[t][scene];
            clip_snapshots[t] = .{
                .has_clip = slot.state != .empty,
                .length_beats = slot.length_beats,
            };
        }
        self.undo_requests[self.undo_request_count] = .{
            .kind = .scene_delete,
            .scene = scene,
            .scene_data = .{
                .name = self.scenes[scene].name,
            },
            .scene_clips = clip_snapshots,
        };
        self.undo_request_count += 1;
    }

    // Clear selection in this scene
    for (0..self.track_count) |t| {
        deselectClip(self, t, scene);
    }

    // Shift all subsequent scenes down
    for (scene..self.scene_count - 1) |s| {
        self.scenes[s] = self.scenes[s + 1];
        for (0..max_tracks) |t| {
            self.clips[t][s] = self.clips[t][s + 1];
            self.clip_selected[t][s] = self.clip_selected[t][s + 1];
        }
    }

    // Clear the last scene slot
    for (0..max_tracks) |t| {
        self.clips[t][self.scene_count - 1] = .{};
        self.clip_selected[t][self.scene_count - 1] = false;
    }

    self.scene_count -= 1;
    if (self.primary_scene >= self.scene_count) {
        self.primary_scene = self.scene_count - 1;
    }
    return true;
}

/// Delete the last scene (if > 1)
pub fn deleteLastScene(self: *session_view.SessionView) bool {
    return deleteScene(self, self.scene_count - 1);
}

/// Delete a specific track (if > 1)
pub fn deleteTrack(self: *session_view.SessionView, track: usize) bool {
    if (self.track_count <= 1) return false;
    if (track >= self.track_count) return false;

    if (self.undo_request_count < self.undo_requests.len) {
        var clip_snapshots: [max_scenes]@TypeOf(self.undo_requests[0].track_clips[0]) = undefined;
        for (0..self.scene_count) |s| {
            const slot = self.clips[track][s];
            clip_snapshots[s] = .{
                .has_clip = slot.state != .empty,
                .length_beats = slot.length_beats,
            };
        }
        self.undo_requests[self.undo_request_count] = .{
            .kind = .track_delete,
            .track = track,
            .track_data = .{
                .name = self.tracks[track].name,
                .volume = self.tracks[track].volume,
                .mute = self.tracks[track].mute,
                .solo = self.tracks[track].solo,
            },
            .track_clips = clip_snapshots,
        };
        self.undo_request_count += 1;
    }

    // Clear selection in this track
    for (0..self.scene_count) |s| {
        deselectClip(self, track, s);
    }

    // Shift all subsequent tracks left
    for (track..self.track_count - 1) |t| {
        self.tracks[t] = self.tracks[t + 1];
        for (0..max_scenes) |s| {
            self.clips[t][s] = self.clips[t + 1][s];
            self.clip_selected[t][s] = self.clip_selected[t + 1][s];
        }
    }

    // Clear the last track slot
    for (0..max_scenes) |s| {
        self.clips[self.track_count - 1][s] = .{};
        self.clip_selected[self.track_count - 1][s] = false;
    }

    self.track_count -= 1;
    if (self.primary_track >= self.track_count) {
        self.primary_track = self.track_count - 1;
    }
    return true;
}

/// Delete the last track (if > 1)
pub fn deleteLastTrack(self: *session_view.SessionView) bool {
    return deleteTrack(self, self.track_count - 1);
}

/// Check if any clip exists in a scene
pub fn hasClipInScene(self: *const session_view.SessionView, scene: usize) bool {
    for (0..self.track_count) |t| {
        if (self.clips[t][scene].state != .empty) return true;
    }
    return false;
}

/// Stop all clips (set all non-empty clips to stopped)
pub fn stopAllInScene(self: *session_view.SessionView, scene: usize) void {
    _ = scene;
    for (0..self.track_count) |t| {
        for (0..self.scene_count) |s| {
            if (self.clips[t][s].state != .empty) {
                self.clips[t][s].state = .stopped;
            }
        }
        self.queued_scene[t] = null;
    }
}

/// Move selection with arrow keys
pub fn moveSelection(self: *session_view.SessionView, dx: i32, dy: i32, shift_held: bool) void {
    if (!hasSelection(self) and dx == 0 and dy == 0) return;

    const new_track_i = @as(i32, @intCast(self.primary_track)) + dx;
    const new_scene_i = @as(i32, @intCast(self.primary_scene)) + dy;

    if (new_track_i < 0 or new_track_i >= @as(i32, @intCast(self.track_count))) return;
    if (new_scene_i < 0 or new_scene_i >= @as(i32, @intCast(self.scene_count))) return;

    const new_track: usize = @intCast(new_track_i);
    const new_scene: usize = @intCast(new_scene_i);

    if (shift_held) {
        // Extend selection
        selectClip(self, new_track, new_scene);
    } else {
        // Move selection
        selectOnly(self, new_track, new_scene);
    }
}

/// Move selected clips by delta
pub fn moveSelectedClips(self: *session_view.SessionView, delta_track: i32, delta_scene: i32) void {
    if (delta_track == 0 and delta_scene == 0) return;
    if (!hasSelection(self)) return;

    // Collect selected clips and check bounds
    var moves: [max_tracks * max_scenes]struct { from_t: usize, from_s: usize, to_t: usize, to_s: usize } = undefined;
    var move_count: usize = 0;

    for (0..self.track_count) |t| {
        for (0..self.scene_count) |s| {
            if (self.clip_selected[t][s] and self.clips[t][s].state != .empty) {
                const new_t_i = @as(i32, @intCast(t)) + delta_track;
                const new_s_i = @as(i32, @intCast(s)) + delta_scene;

                // Check bounds
                if (new_t_i < 0 or new_t_i >= @as(i32, @intCast(self.track_count))) return;
                if (new_s_i < 0 or new_s_i >= @as(i32, @intCast(self.scene_count))) return;

                moves[move_count] = .{
                    .from_t = t,
                    .from_s = s,
                    .to_t = @intCast(new_t_i),
                    .to_s = @intCast(new_s_i),
                };
                move_count += 1;
            }
        }
    }

    if (move_count == 0) return;

    // Clear selection first
    clearSelection(self);

    // Store clips temporarily
    var temp_clips: [max_tracks * max_scenes]@TypeOf(self.clips[0][0]) = undefined;
    for (moves[0..move_count], 0..) |m, i| {
        temp_clips[i] = self.clips[m.from_t][m.from_s];
        self.clips[m.from_t][m.from_s] = .{}; // Clear source
    }

    // Place clips at new positions
    for (moves[0..move_count], 0..) |m, i| {
        self.clips[m.to_t][m.to_s] = temp_clips[i];
        selectClip(self, m.to_t, m.to_s);
    }

    // Update primary selection
    const new_primary_t = @as(i32, @intCast(self.drag_start_track)) + delta_track;
    const new_primary_s = @as(i32, @intCast(self.drag_start_scene)) + delta_scene;
    if (new_primary_t >= 0 and new_primary_t < @as(i32, @intCast(self.track_count))) {
        self.primary_track = @intCast(new_primary_t);
    }
    if (new_primary_s >= 0 and new_primary_s < @as(i32, @intCast(self.scene_count))) {
        self.primary_scene = @intCast(new_primary_s);
    }
    self.drag_start_track = self.primary_track;
    self.drag_start_scene = self.primary_scene;

    // Emit undo request for clip moves (also signals ui.zig to move piano clips)
    self.clip_move_count = 0;
    for (moves[0..move_count]) |m| {
        if (self.clip_move_count < self.clip_move_requests.len) {
            self.clip_move_requests[self.clip_move_count] = .{
                .src_track = m.from_t,
                .src_scene = m.from_s,
                .dst_track = m.to_t,
                .dst_scene = m.to_s,
            };
            self.clip_move_count += 1;
        }
    }
    self.pending_piano_moves = true;
}
