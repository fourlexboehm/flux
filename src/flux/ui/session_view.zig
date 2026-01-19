const std = @import("std");
const zgui = @import("zgui");
const colors = @import("colors.zig");
const selection = @import("selection.zig");

pub const max_tracks = 16;
pub const max_scenes = 32;
pub const beats_per_bar = 4;
pub const default_clip_bars = 4;

pub const ClipState = enum {
    empty,
    stopped,
    queued,
    playing,
};

pub const ClipSlot = struct {
    state: ClipState = .empty,
    length_beats: f32 = default_clip_bars * beats_per_bar,
};

pub const Track = struct {
    name: [32]u8 = undefined,
    name_len: usize = 0,
    volume: f32 = 0.8,
    mute: bool = false,
    solo: bool = false,

    pub fn init(name: []const u8) Track {
        var t = Track{};
        t.setName(name);
        return t;
    }

    pub fn setName(self: *Track, name: []const u8) void {
        const len = @min(name.len, self.name.len);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = len;
    }

    pub fn getName(self: *const Track) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Scene = struct {
    name: [32]u8 = undefined,
    name_len: usize = 0,

    pub fn init(name: []const u8) Scene {
        var s = Scene{};
        s.setName(name);
        return s;
    }

    pub fn setName(self: *Scene, name: []const u8) void {
        const len = @min(name.len, self.name.len);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = len;
    }

    pub fn getName(self: *const Scene) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Clipboard entry for clip copy/paste
pub const ClipboardEntry = struct {
    track_offset: i32,
    scene_offset: i32,
    slot: ClipSlot,
};

pub const OpenClipRequest = struct {
    track: usize,
    scene: usize,
};

pub const SessionView = struct {
    allocator: std.mem.Allocator,

    // Grid data
    tracks: [max_tracks]Track = undefined,
    scenes: [max_scenes]Scene = undefined,
    clips: [max_tracks][max_scenes]ClipSlot = undefined,
    track_count: usize = 4,
    scene_count: usize = 8,

    // Selection - simple 2D bool array
    clip_selected: [max_tracks][max_scenes]bool = [_][max_scenes]bool{[_]bool{false} ** max_scenes} ** max_tracks,
    primary_track: usize = 0,
    primary_scene: usize = 0,
    drag_select: selection.DragSelectState = .{},

    // Clipboard
    clipboard: std.ArrayListUnmanaged(ClipboardEntry) = .{},
    clipboard_origin_track: usize = 0,
    clipboard_origin_scene: usize = 0,

    // Drag move state
    drag_moving: bool = false,
    drag_start_track: usize = 0,
    drag_start_scene: usize = 0,

    // Playback state
    queued_scene: [max_tracks]?usize = [_]?usize{null} ** max_tracks,
    open_clip_request: ?OpenClipRequest = null,
    start_playback_request: bool = false,

    pub fn init(allocator: std.mem.Allocator) SessionView {
        var self = SessionView{
            .allocator = allocator,
        };

        // Initialize tracks
        const track_names = [_][]const u8{ "Track 1", "Track 2", "Track 3", "Track 4" };
        for (0..self.track_count) |i| {
            self.tracks[i] = Track.init(if (i < track_names.len) track_names[i] else "Track");
        }

        // Initialize scenes
        const scene_names = [_][]const u8{ "Intro", "Verse", "Build", "Chorus", "Bridge", "Drop", "Outro", "Ending" };
        for (0..self.scene_count) |i| {
            self.scenes[i] = Scene.init(if (i < scene_names.len) scene_names[i] else "Scene");
        }

        // Initialize all clips as empty
        for (0..max_tracks) |t| {
            for (0..max_scenes) |s| {
                self.clips[t][s] = .{};
            }
        }

        return self;
    }

    pub fn deinit(self: *SessionView) void {
        self.clipboard.deinit(self.allocator);
    }

    pub fn isSelected(self: *const SessionView, track: usize, scene: usize) bool {
        return self.clip_selected[track][scene];
    }

    pub fn selectClip(self: *SessionView, track: usize, scene: usize) void {
        self.clip_selected[track][scene] = true;
        self.primary_track = track;
        self.primary_scene = scene;
    }

    pub fn deselectClip(self: *SessionView, track: usize, scene: usize) void {
        self.clip_selected[track][scene] = false;
    }

    pub fn clearSelection(self: *SessionView) void {
        for (&self.clip_selected) |*track_sel| {
            for (track_sel) |*sel| {
                sel.* = false;
            }
        }
    }

    pub fn selectOnly(self: *SessionView, track: usize, scene: usize) void {
        self.clearSelection();
        self.selectClip(track, scene);
    }

    pub fn hasSelection(self: *const SessionView) bool {
        for (self.clip_selected) |track_sel| {
            for (track_sel) |sel| {
                if (sel) return true;
            }
        }
        return false;
    }

    pub fn handleClipClick(self: *SessionView, track: usize, scene: usize, shift_held: bool) void {
        if (shift_held) {
            if (self.isSelected(track, scene)) {
                self.deselectClip(track, scene);
            } else {
                self.selectClip(track, scene);
            }
        } else if (!self.isSelected(track, scene)) {
            self.selectOnly(track, scene);
        } else {
            self.primary_track = track;
            self.primary_scene = scene;
        }
    }

    /// Create a new clip at the given position
    pub fn createClip(self: *SessionView, track: usize, scene: usize) void {
        if (track >= self.track_count or scene >= self.scene_count) return;
        self.clips[track][scene] = .{
            .state = .stopped,
            .length_beats = default_clip_bars * beats_per_bar,
        };
    }

    /// Delete clip at position (reset to empty)
    pub fn deleteClip(self: *SessionView, track: usize, scene: usize) void {
        if (track >= self.track_count or scene >= self.scene_count) return;
        self.clips[track][scene] = .{};
    }

    /// Delete all selected clips
    pub fn deleteSelected(self: *SessionView) void {
        for (0..self.track_count) |t| {
            for (0..self.scene_count) |s| {
                if (self.clip_selected[t][s]) {
                    self.deleteClip(t, s);
                }
            }
        }
        self.clearSelection();
    }

    /// Copy selected clips to clipboard
    pub fn copySelected(self: *SessionView) void {
        if (!self.hasSelection()) return;

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
    pub fn cutSelected(self: *SessionView) void {
        self.copySelected();
        self.deleteSelected();
    }

    /// Paste clips at primary selection position
    pub fn paste(self: *SessionView) void {
        if (self.clipboard.items.len == 0) return;

        self.clearSelection();
        for (self.clipboard.items) |entry| {
            const track_i = @as(i32, @intCast(self.primary_track)) + entry.track_offset;
            const scene_i = @as(i32, @intCast(self.primary_scene)) + entry.scene_offset;

            if (track_i < 0 or scene_i < 0) continue;
            const track: usize = @intCast(track_i);
            const scene: usize = @intCast(scene_i);
            if (track >= self.track_count or scene >= self.scene_count) continue;

            self.clips[track][scene] = entry.slot;
            self.selectClip(track, scene);
        }
    }

    /// Add a new track
    pub fn addTrack(self: *SessionView) bool {
        if (self.track_count >= max_tracks) return false;

        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "Track {d}", .{self.track_count + 1}) catch "Track";
        self.tracks[self.track_count] = Track.init(name);
        self.track_count += 1;
        return true;
    }

    /// Add a new scene
    pub fn addScene(self: *SessionView) bool {
        if (self.scene_count >= max_scenes) return false;

        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "Scene {d}", .{self.scene_count + 1}) catch "Scene";
        self.scenes[self.scene_count] = Scene.init(name);
        self.scene_count += 1;
        return true;
    }

    /// Delete the last scene (if > 1)
    pub fn deleteLastScene(self: *SessionView) bool {
        if (self.scene_count <= 1) return false;

        // Clear selection in this scene
        for (0..self.track_count) |t| {
            self.deselectClip(t, self.scene_count - 1);
        }

        self.scene_count -= 1;
        if (self.primary_scene >= self.scene_count) {
            self.primary_scene = self.scene_count - 1;
        }
        return true;
    }

    /// Delete the last track (if > 1)
    pub fn deleteLastTrack(self: *SessionView) bool {
        if (self.track_count <= 1) return false;

        // Clear selection in this track
        for (0..self.scene_count) |s| {
            self.deselectClip(self.track_count - 1, s);
        }

        self.track_count -= 1;
        if (self.primary_track >= self.track_count) {
            self.primary_track = self.track_count - 1;
        }
        return true;
    }

    /// Check if any clip exists in a scene
    pub fn hasClipInScene(self: *const SessionView, scene: usize) bool {
        for (0..self.track_count) |t| {
            if (self.clips[t][scene].state != .empty) return true;
        }
        return false;
    }

    /// Stop all clips (set all non-empty clips to stopped)
    pub fn stopAllInScene(self: *SessionView, scene: usize) void {
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
    pub fn moveSelection(self: *SessionView, dx: i32, dy: i32, shift_held: bool) void {
        if (!self.hasSelection() and dx == 0 and dy == 0) return;

        const new_track_i = @as(i32, @intCast(self.primary_track)) + dx;
        const new_scene_i = @as(i32, @intCast(self.primary_scene)) + dy;

        if (new_track_i < 0 or new_track_i >= @as(i32, @intCast(self.track_count))) return;
        if (new_scene_i < 0 or new_scene_i >= @as(i32, @intCast(self.scene_count))) return;

        const new_track: usize = @intCast(new_track_i);
        const new_scene: usize = @intCast(new_scene_i);

        if (shift_held) {
            // Extend selection
            self.selectClip(new_track, new_scene);
        } else {
            // Move selection
            self.selectOnly(new_track, new_scene);
        }
    }

    /// Move selected clips by delta
    pub fn moveSelectedClips(self: *SessionView, delta_track: i32, delta_scene: i32) void {
        if (delta_track == 0 and delta_scene == 0) return;
        if (!self.hasSelection()) return;

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
        self.clearSelection();

        // Store clips temporarily
        var temp_clips: [max_tracks * max_scenes]ClipSlot = undefined;
        for (moves[0..move_count], 0..) |m, i| {
            temp_clips[i] = self.clips[m.from_t][m.from_s];
            self.clips[m.from_t][m.from_s] = .{}; // Clear source
        }

        // Place clips at new positions
        for (moves[0..move_count], 0..) |m, i| {
            self.clips[m.to_t][m.to_s] = temp_clips[i];
            self.selectClip(m.to_t, m.to_s);
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
    }

    pub fn draw(self: *SessionView, ui_scale: f32, playing: bool, is_focused: bool) void {
        const row_height = 52.0 * ui_scale;
        const header_height = 32.0 * ui_scale;
        const scene_col_w = 130.0 * ui_scale; // Wider for button + name
        const track_col_w = 160.0 * ui_scale;
        const add_btn_size = 32.0 * ui_scale;

        const grid_pos = zgui.getCursorScreenPos();
        const mouse = zgui.getMousePos();
        const shift_down = selection.isShiftDown();

        // Calculate grid dimensions first (needed for mouse checks)
        const grid_width = scene_col_w + @as(f32, @floatFromInt(self.track_count)) * track_col_w + add_btn_size + 8.0;
        const grid_height = header_height + @as(f32, @floatFromInt(self.scene_count)) * row_height + add_btn_size + 8.0;

        const in_grid = mouse[0] >= grid_pos[0] and mouse[0] < grid_pos[0] + grid_width and
            mouse[1] >= grid_pos[1] and mouse[1] < grid_pos[1] + grid_height;

        // Calculate which clip cell the mouse is over (if any)
        const cell_x = mouse[0] - grid_pos[0] - scene_col_w;
        const cell_y = mouse[1] - grid_pos[1] - header_height;
        const mouse_over_clip_area = cell_x >= 0 and cell_y >= 0;

        var hover_track: ?usize = null;
        var hover_scene: ?usize = null;
        var hover_has_content = false;

        if (mouse_over_clip_area) {
            const t = @as(usize, @intFromFloat(cell_x / track_col_w));
            const s = @as(usize, @intFromFloat(cell_y / row_height));
            if (t < self.track_count and s < self.scene_count) {
                hover_track = t;
                hover_scene = s;
                hover_has_content = self.clips[t][s].state != .empty;
            }
        }

        // Handle mouse release - reset all drag state
        if (!zgui.isMouseDown(.left)) {
            self.drag_select.active = false;
            self.drag_select.pending = false;
            self.drag_moving = false;
        }

        // On click, decide: drag move (if over clip with content) or drag select (if over empty)
        if (zgui.isMouseClicked(.left) and in_grid) {
            if (hover_has_content) {
                // Start drag move
                self.drag_moving = true;
                self.drag_start_track = hover_track.?;
                self.drag_start_scene = hover_scene.?;
                self.drag_select.pending = false;
                self.drag_select.active = false;
                // Select this clip
                self.handleClipClick(hover_track.?, hover_scene.?, shift_down);
            } else {
                // Start drag select
                self.drag_select.begin(mouse, shift_down);
                self.drag_moving = false;
                if (hover_track != null and hover_scene != null) {
                    self.primary_track = hover_track.?;
                    self.primary_scene = hover_scene.?;
                }
                if (!shift_down) {
                    self.clearSelection();
                }
            }
        }

        // Update drag select position
        if (self.drag_select.active or self.drag_select.pending) {
            self.drag_select.update(mouse);
        }

        // Activate selection rectangle after drag threshold
        if (self.drag_select.pending and zgui.isMouseDragging(.left, 4.0)) {
            self.drag_select.active = true;
            self.drag_select.pending = false;
        }

        // Handle drag moving
        if (self.drag_moving and zgui.isMouseDragging(.left, 4.0)) {
            zgui.setMouseCursor(.resize_all);
            if (hover_track != null and hover_scene != null) {
                const delta_track = @as(i32, @intCast(hover_track.?)) - @as(i32, @intCast(self.drag_start_track));
                const delta_scene = @as(i32, @intCast(hover_scene.?)) - @as(i32, @intCast(self.drag_start_scene));
                if (delta_track != 0 or delta_scene != 0) {
                    self.moveSelectedClips(delta_track, delta_scene);
                }
            }
        }

        // Calculate mixer height for later
        const mixer_height = 200.0 * ui_scale;

        if (!zgui.beginTable("session_grid", .{
            .column = @intCast(self.track_count + 2), // scenes + tracks + add button
            .flags = .{ .borders = .{ .inner_v = true }, .row_bg = false, .sizing = .fixed_fit },
        })) {
            return;
        }

        // Setup columns
        zgui.tableSetupColumn("##scenes", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = scene_col_w });
        for (0..self.track_count) |_| {
            zgui.tableSetupColumn("##track", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = track_col_w });
        }
        zgui.tableSetupColumn("##add_track", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = add_btn_size + 8.0 });

        // Track headers row
        zgui.tableNextRow(.{ .min_row_height = header_height });
        _ = zgui.tableNextColumn(); // Empty corner

        for (0..self.track_count) |t| {
            _ = zgui.tableNextColumn();
            const is_track_selected = self.primary_track == t;
            const text_color = if (is_track_selected) colors.Colors.text_bright else colors.Colors.text_dim;
            zgui.pushStyleColor4f(.{ .idx = .text, .c = text_color });

            // Make track header clickable
            var track_buf: [32]u8 = undefined;
            const track_label = std.fmt.bufPrintZ(&track_buf, "{s}##track_hdr{d}", .{ self.tracks[t].getName(), t }) catch "Track";
            if (zgui.selectable(track_label, .{ .selected = is_track_selected, .w = track_col_w - 16.0 * ui_scale })) {
                self.primary_track = t;
                self.clearSelection();
            }
            zgui.popStyleColor(.{ .count = 1 });
        }

        // Add track button in header
        _ = zgui.tableNextColumn();
        zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.Colors.bg_cell });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ 0.25, 0.25, 0.25, 1.0 } });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.accent_dim });
        if (zgui.button("+##add_track", .{ .w = add_btn_size, .h = add_btn_size })) {
            _ = self.addTrack();
        }
        zgui.popStyleColor(.{ .count = 3 });

        // Clip rows
        for (0..self.scene_count) |scene_idx| {
            zgui.tableNextRow(.{ .min_row_height = row_height });

            // Scene column
            _ = zgui.tableNextColumn();
            const draw_list = zgui.getWindowDrawList();

            // Scene launch button first (left side)
            const launch_size = 24.0 * ui_scale;
            const launch_pos = zgui.getCursorScreenPos();
            var launch_buf: [32]u8 = undefined;
            const launch_id = std.fmt.bufPrintZ(&launch_buf, "##scene_launch{d}", .{scene_idx}) catch "##launch";

            // Check if any clip exists in this scene
            const has_clip_in_scene = self.hasClipInScene(scene_idx);

            zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.Colors.bg_panel });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ 0.22, 0.22, 0.22, 1.0 } });
            zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.accent_dim });
            if (zgui.button(launch_id, .{ .w = launch_size, .h = launch_size })) {
                if (has_clip_in_scene) {
                    self.launchScene(scene_idx, playing);
                } else {
                    self.stopAllInScene(scene_idx);
                }
            }
            zgui.popStyleColor(.{ .count = 3 });

            // Draw play triangle or stop square
            const icon_size = 10.0 * ui_scale;
            const cx = launch_pos[0] + launch_size / 2.0 + 1.0 * ui_scale;
            const cy = launch_pos[1] + launch_size / 2.0;
            if (has_clip_in_scene) {
                // Play triangle
                draw_list.addTriangleFilled(.{
                    .p1 = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
                    .p2 = .{ cx - icon_size / 2.0, cy + icon_size / 2.0 },
                    .p3 = .{ cx + icon_size / 2.0, cy },
                    .col = zgui.colorConvertFloat4ToU32(colors.Colors.accent),
                });
            } else {
                // Stop square
                draw_list.addRectFilled(.{
                    .pmin = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
                    .pmax = .{ cx + icon_size / 2.0, cy + icon_size / 2.0 },
                    .col = zgui.colorConvertFloat4ToU32(colors.Colors.text_dim),
                });
            }

            zgui.sameLine(.{ .spacing = 4.0 * ui_scale });

            // Scene name (clickable to select scene)
            const is_scene_selected = self.primary_scene == scene_idx;
            const scene_text_color = if (is_scene_selected) colors.Colors.text_bright else colors.Colors.text_dim;
            zgui.pushStyleColor4f(.{ .idx = .text, .c = scene_text_color });

            var scene_buf: [48]u8 = undefined;
            const scene_label = std.fmt.bufPrintZ(&scene_buf, "{s}##scene_hdr{d}", .{ self.scenes[scene_idx].getName(), scene_idx }) catch "Scene";
            if (zgui.selectable(scene_label, .{ .selected = is_scene_selected, .w = scene_col_w - launch_size - 12.0 * ui_scale })) {
                self.primary_scene = scene_idx;
                self.clearSelection();
            }
            zgui.popStyleColor(.{ .count = 1 });

            // Clip slots
            for (0..self.track_count) |track_idx| {
                _ = zgui.tableNextColumn();
                self.drawClipSlot(track_idx, scene_idx, track_col_w - 8.0 * ui_scale, row_height - 6.0 * ui_scale, ui_scale, playing);
            }

            // Empty cell for add track column
            _ = zgui.tableNextColumn();
        }

        // Add scene row
        zgui.tableNextRow(.{ .min_row_height = add_btn_size + 8.0 });
        _ = zgui.tableNextColumn();

        zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.Colors.bg_cell });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ 0.25, 0.25, 0.25, 1.0 } });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.accent_dim });
        if (zgui.button("+##add_scene", .{ .w = add_btn_size, .h = add_btn_size })) {
            _ = self.addScene();
        }
        zgui.popStyleColor(.{ .count = 3 });

        // Handle keyboard shortcuts (only when this pane is focused)
        const keyboard_free = !zgui.isAnyItemActive();
        const modifier_down = selection.isModifierDown();

        if (is_focused and keyboard_free) {
            // Copy
            if (modifier_down and zgui.isKeyPressed(.c, false)) {
                self.copySelected();
            }

            // Cut
            if (modifier_down and zgui.isKeyPressed(.x, false)) {
                self.cutSelected();
            }

            // Paste
            if (modifier_down and zgui.isKeyPressed(.v, false)) {
                self.paste();
            }

            // Delete
            if (zgui.isKeyPressed(.delete, false) or zgui.isKeyPressed(.back_space, false)) {
                self.deleteSelected();
            }

            // Select all
            if (modifier_down and zgui.isKeyPressed(.a, false)) {
                self.clearSelection();
                for (0..self.track_count) |t| {
                    for (0..self.scene_count) |s| {
                        if (self.clips[t][s].state != .empty) {
                            self.selectClip(t, s);
                        }
                    }
                }
            }

            // Arrow keys for navigation
            if (zgui.isKeyPressed(.left_arrow, true)) {
                self.moveSelection(-1, 0, shift_down);
            }
            if (zgui.isKeyPressed(.right_arrow, true)) {
                self.moveSelection(1, 0, shift_down);
            }
            if (zgui.isKeyPressed(.up_arrow, true)) {
                self.moveSelection(0, -1, shift_down);
            }
            if (zgui.isKeyPressed(.down_arrow, true)) {
                self.moveSelection(0, 1, shift_down);
            }

            // Enter to create clip at selection
            if (zgui.isKeyPressed(.enter, false)) {
                if (self.clips[self.primary_track][self.primary_scene].state == .empty) {
                    self.createClip(self.primary_track, self.primary_scene);
                }
            }
        }

        // Right-click context menu
        if (in_grid and zgui.isMouseClicked(.right)) {
            zgui.openPopup("session_ctx", .{});
        }

        if (zgui.beginPopup("session_ctx", .{})) {
            const has_selection = self.hasSelection();
            const can_paste = self.clipboard.items.len > 0;

            if (zgui.menuItem("Copy", .{ .shortcut = "Cmd/Ctrl+C", .enabled = has_selection })) {
                self.copySelected();
            }
            if (zgui.menuItem("Cut", .{ .shortcut = "Cmd/Ctrl+X", .enabled = has_selection })) {
                self.cutSelected();
            }
            if (zgui.menuItem("Paste", .{ .shortcut = "Cmd/Ctrl+V", .enabled = can_paste })) {
                self.paste();
            }
            if (zgui.menuItem("Delete", .{ .shortcut = "Del", .enabled = has_selection })) {
                self.deleteSelected();
            }
            zgui.separator();
            if (zgui.menuItem("Select All", .{ .shortcut = "Cmd/Ctrl+A" })) {
                self.clearSelection();
                for (0..self.track_count) |t| {
                    for (0..self.scene_count) |s| {
                        if (self.clips[t][s].state != .empty) {
                            self.selectClip(t, s);
                        }
                    }
                }
            }
            zgui.endPopup();
        }

        // Draw selection rectangle if active
        if (self.drag_select.active) {
            const dl = zgui.getForegroundDrawList();
            dl.pushClipRect(.{
                .pmin = grid_pos,
                .pmax = .{ grid_pos[0] + grid_width, grid_pos[1] + grid_height },
                .intersect_with_current = true,
            });
            self.drag_select.draw(dl);
            dl.popClipRect();
        }

        zgui.endTable();

        // Draw mixer strip at bottom of view
        const avail = zgui.getContentRegionAvail();
        if (avail[1] > mixer_height) {
            zgui.setCursorPosY(zgui.getCursorPosY() + avail[1] - mixer_height);
        }

        // Draw mixer using a table to guarantee alignment with grid
        zgui.pushStyleColor4f(.{ .idx = .table_row_bg, .c = colors.Colors.bg_header });
        if (zgui.beginTable("mixer_strip", .{
            .column = @intCast(self.track_count + 2),
            .flags = .{ .borders = .{ .inner_v = true }, .row_bg = true, .sizing = .fixed_fit },
        })) {
            // Setup columns to match grid exactly
            zgui.tableSetupColumn("##mix_scenes", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = scene_col_w });
            for (0..self.track_count) |_| {
                zgui.tableSetupColumn("##mix_track", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = track_col_w });
            }
            zgui.tableSetupColumn("##mix_add", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = add_btn_size + 8.0 });

            zgui.tableNextRow(.{ .min_row_height = mixer_height - 8.0 * ui_scale });
            _ = zgui.tableNextColumn(); // Empty scene column

            for (0..self.track_count) |t| {
                _ = zgui.tableNextColumn();
                self.drawTrackMixer(t, track_col_w, mixer_height - 8.0 * ui_scale, ui_scale);
            }

            zgui.endTable();
        }
        zgui.popStyleColor(.{ .count = 1 });
    }

    fn drawClipSlot(self: *SessionView, track: usize, scene: usize, width: f32, height: f32, ui_scale: f32, playing: bool) void {
        const draw_list = zgui.getWindowDrawList();
        const pos = zgui.getCursorScreenPos();
        const mouse = zgui.getMousePos();

        const slot = &self.clips[track][scene];
        const is_selected = self.isSelected(track, scene);

        // Clip colors based on state
        const clip_color = switch (slot.state) {
            .empty => colors.Colors.clip_empty,
            .stopped => colors.Colors.clip_stopped,
            .queued => colors.Colors.clip_queued,
            .playing => colors.Colors.clip_playing,
        };

        // Play button dimensions
        const play_btn_w = 24.0 * ui_scale;
        const clip_w = width - play_btn_w - 4.0 * ui_scale;
        const rounding = 3.0 * ui_scale;

        // Check drag select intersection
        if (self.drag_select.active) {
            const clip_min = pos;
            const clip_max = [2]f32{ pos[0] + clip_w, pos[1] + height };
            if (self.drag_select.intersects(clip_min, clip_max)) {
                if (!self.isSelected(track, scene) and slot.state != .empty) {
                    self.selectClip(track, scene);
                }
            }
        }

        // Background
        var bg_color = clip_color;
        if (is_selected) {
            bg_color = .{
                @min(1.0, clip_color[0] + 0.12),
                @min(1.0, clip_color[1] + 0.12),
                @min(1.0, clip_color[2] + 0.12),
                1.0,
            };
        }

        draw_list.addRectFilled(.{
            .pmin = pos,
            .pmax = .{ pos[0] + clip_w, pos[1] + height },
            .col = zgui.colorConvertFloat4ToU32(bg_color),
            .rounding = rounding,
            .flags = zgui.DrawFlags.round_corners_all,
        });

        // Selection border
        if (is_selected) {
            draw_list.addRect(.{
                .pmin = pos,
                .pmax = .{ pos[0] + clip_w, pos[1] + height },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.selected),
                .rounding = rounding,
                .flags = zgui.DrawFlags.round_corners_all,
                .thickness = 2.0,
            });
        }

        // Clip content indicator (bars)
        if (slot.state != .empty) {
            const bars = slot.length_beats / beats_per_bar;
            var buf: [16]u8 = undefined;
            const label = std.fmt.bufPrintZ(&buf, "{d:.0} bars", .{bars}) catch "";
            const text_color = if (slot.state == .playing or slot.state == .queued)
                zgui.colorConvertFloat4ToU32(.{ 0.1, 0.1, 0.1, 1.0 })
            else
                zgui.colorConvertFloat4ToU32(colors.Colors.text_dim);
            draw_list.addText(.{ pos[0] + 8.0 * ui_scale, pos[1] + height / 2.0 - 8.0 }, text_color, "{s}", .{label});
        }

        // Invisible button for clip interaction
        var clip_buf: [32]u8 = undefined;
        const clip_id = std.fmt.bufPrintZ(&clip_buf, "##clip_t{d}s{d}", .{ track, scene }) catch "##clip";

        const over_clip = mouse[0] >= pos[0] and mouse[0] < pos[0] + clip_w and
            mouse[1] >= pos[1] and mouse[1] < pos[1] + height;

        // Show move cursor when hovering over a clip with content
        if (over_clip and slot.state != .empty and !self.drag_moving) {
            zgui.setMouseCursor(.resize_all);
        }

        // Invisible button for double-click detection
        _ = zgui.invisibleButton(clip_id, .{ .w = clip_w, .h = height });

        // Handle double-click to create/open clip
        if (over_clip and zgui.isMouseDoubleClicked(.left)) {
            if (slot.state == .empty) {
                self.createClip(track, scene);
            }
            self.selectOnly(track, scene);
            self.open_clip_request = .{ .track = track, .scene = scene };
        }

        zgui.sameLine(.{ .spacing = 4.0 * ui_scale });

        // Play button
        const play_pos = zgui.getCursorScreenPos();
        var play_buf: [32]u8 = undefined;
        const play_id = std.fmt.bufPrintZ(&play_buf, "##play_t{d}s{d}", .{ track, scene }) catch "##play";

        const is_playing_clip = slot.state == .playing;
        const is_queued = slot.state == .queued;
        const play_bg = if (is_playing_clip) colors.Colors.clip_playing else if (is_queued) colors.Colors.clip_queued else colors.Colors.bg_cell;

        zgui.pushStyleColor4f(.{ .idx = .button, .c = play_bg });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ play_bg[0] + 0.08, play_bg[1] + 0.08, play_bg[2] + 0.08, 1.0 } });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.accent_dim });
        if (zgui.button(play_id, .{ .w = play_btn_w, .h = height })) {
            self.toggleClipPlayback(track, scene, playing);
        }
        zgui.popStyleColor(.{ .count = 3 });

        // Draw play/stop icon
        const icon_size = 10.0 * ui_scale;
        const cx = play_pos[0] + play_btn_w / 2.0;
        const cy = play_pos[1] + height / 2.0;
        const is_empty = slot.state == .empty;

        if (is_playing_clip) {
            // Stop square (for playing clip)
            draw_list.addRectFilled(.{
                .pmin = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
                .pmax = .{ cx + icon_size / 2.0, cy + icon_size / 2.0 },
                .col = zgui.colorConvertFloat4ToU32(.{ 0.1, 0.1, 0.1, 1.0 }),
            });
        } else if (is_queued) {
            // Queued indicator
            draw_list.addTriangleFilled(.{
                .p1 = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
                .p2 = .{ cx - icon_size / 2.0, cy + icon_size / 2.0 },
                .p3 = .{ cx + icon_size / 2.0 + 1.0, cy },
                .col = zgui.colorConvertFloat4ToU32(.{ 0.3, 0.18, 0.03, 1.0 }),
            });
            draw_list.addTriangle(.{
                .p1 = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
                .p2 = .{ cx - icon_size / 2.0, cy + icon_size / 2.0 },
                .p3 = .{ cx + icon_size / 2.0 + 1.0, cy },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.clip_queued),
                .thickness = 2.0,
            });
        } else if (is_empty) {
            // Stop square for empty slot (stops this track)
            draw_list.addRectFilled(.{
                .pmin = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
                .pmax = .{ cx + icon_size / 2.0, cy + icon_size / 2.0 },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.text_dim),
            });
        } else {
            // Play triangle (for stopped clip with content)
            draw_list.addTriangleFilled(.{
                .p1 = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
                .p2 = .{ cx - icon_size / 2.0, cy + icon_size / 2.0 },
                .p3 = .{ cx + icon_size / 2.0 + 1.0, cy },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.text_dim),
            });
        }
    }

    fn drawTrackMixer(self: *SessionView, track: usize, width: f32, height: f32, ui_scale: f32) void {
        const padding = 4.0 * ui_scale;
        const spacing = 4.0 * ui_scale;
        const usable_width = width - padding * 2;
        const btn_width = (usable_width - spacing) / 2.0;
        const btn_height = 36.0 * ui_scale;
        const slider_width = 28.0 * ui_scale;
        const label_height = 24.0 * ui_scale;
        const slider_height = height - btn_height - spacing * 2 - label_height - 4.0 * ui_scale;

        const base_x = zgui.getCursorPosX();
        const base_y = zgui.getCursorPosY();

        // Row 1: M and S buttons side by side (fill track width)
        zgui.setCursorPosX(base_x + padding);

        // Mute button
        var mute_buf: [32]u8 = undefined;
        const mute_id = std.fmt.bufPrintZ(&mute_buf, "M##mute{d}", .{track}) catch "M";

        const mute_bg = if (self.tracks[track].mute) colors.Colors.clip_stopped else colors.Colors.bg_cell;
        const mute_text = if (self.tracks[track].mute) colors.Colors.text_bright else colors.Colors.text_dim;

        zgui.pushStyleColor4f(.{ .idx = .button, .c = mute_bg });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ mute_bg[0] + 0.1, mute_bg[1] + 0.1, mute_bg[2] + 0.1, 1.0 } });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.accent_dim });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = mute_text });

        if (zgui.button(mute_id, .{ .w = btn_width, .h = btn_height })) {
            self.tracks[track].mute = !self.tracks[track].mute;
        }
        zgui.popStyleColor(.{ .count = 4 });

        zgui.sameLine(.{ .spacing = spacing });

        // Solo button
        var solo_buf: [32]u8 = undefined;
        const solo_id = std.fmt.bufPrintZ(&solo_buf, "S##solo{d}", .{track}) catch "S";

        const solo_bg = if (self.tracks[track].solo) colors.Colors.clip_queued else colors.Colors.bg_cell;
        const solo_text = if (self.tracks[track].solo) [4]f32{ 0.1, 0.1, 0.1, 1.0 } else colors.Colors.text_dim;

        zgui.pushStyleColor4f(.{ .idx = .button, .c = solo_bg });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ solo_bg[0] + 0.1, solo_bg[1] + 0.1, solo_bg[2] + 0.1, 1.0 } });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.accent_dim });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = solo_text });

        if (zgui.button(solo_id, .{ .w = btn_width, .h = btn_height })) {
            self.tracks[track].solo = !self.tracks[track].solo;
        }
        zgui.popStyleColor(.{ .count = 4 });

        // Row 2: Volume slider (centered, wider)
        zgui.setCursorPosY(base_y + btn_height + spacing);
        zgui.setCursorPosX(base_x + (width - slider_width) / 2.0);

        var vol_buf: [32]u8 = undefined;
        const vol_id = std.fmt.bufPrintZ(&vol_buf, "##vol{d}", .{track}) catch "##vol";

        zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = colors.Colors.bg_cell });
        zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = .{ 0.22, 0.22, 0.22, 1.0 } });
        zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = .{ 0.25, 0.25, 0.25, 1.0 } });
        zgui.pushStyleColor4f(.{ .idx = .slider_grab, .c = colors.Colors.accent });
        zgui.pushStyleColor4f(.{ .idx = .slider_grab_active, .c = .{ 1.0, 0.6, 0.2, 1.0 } });

        _ = zgui.vsliderFloat(vol_id, .{
            .w = slider_width,
            .h = slider_height,
            .v = &self.tracks[track].volume,
            .min = 0.0,
            .max = 1.5,
            .cfmt = "",
        });

        zgui.popStyleColor(.{ .count = 5 });

        // Row 3: dB label (centered)
        zgui.setCursorPosY(base_y + btn_height + spacing + slider_height + spacing);
        zgui.setCursorPosX(base_x + padding);

        const db = if (self.tracks[track].volume > 0.0001)
            20.0 * @log10(self.tracks[track].volume)
        else
            -60.0;
        var label_buf: [16]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "{d:.0}dB", .{db}) catch "";
        zgui.textColored(colors.Colors.text_dim, "{s}", .{label});
    }

    fn launchScene(self: *SessionView, scene: usize, playing: bool) void {
        if (playing) {
            // Queue all tracks
            for (0..self.track_count) |t| {
                for (0..self.scene_count) |s| {
                    if (self.clips[t][s].state == .queued) {
                        self.clips[t][s].state = .stopped;
                    }
                }
                if (self.clips[t][scene].state != .empty) {
                    self.clips[t][scene].state = .queued;
                }
                // Always queue the scene switch - this ensures clips in other scenes
                // are stopped even if this track has no clip in the target scene
                self.queued_scene[t] = scene;
            }
        } else {
            // Immediate switch and start playback
            for (0..self.track_count) |t| {
                for (0..self.scene_count) |s| {
                    if (self.clips[t][s].state != .empty) {
                        self.clips[t][s].state = if (s == scene) .playing else .stopped;
                    }
                }
            }
            self.start_playback_request = true;
        }
    }

    fn toggleClipPlayback(self: *SessionView, track: usize, scene: usize, playing: bool) void {
        const slot = &self.clips[track][scene];

        self.primary_track = track;
        self.primary_scene = scene;

        // Empty slot = stop this track
        if (slot.state == .empty) {
            self.clearSelection();
            // Stop all clips in this track
            for (0..self.scene_count) |s| {
                if (self.clips[track][s].state == .playing or self.clips[track][s].state == .queued) {
                    self.clips[track][s].state = .stopped;
                }
            }
            self.queued_scene[track] = null;
            return;
        }

        // Also select/focus this clip
        self.selectOnly(track, scene);

        if (slot.state == .playing) {
            slot.state = .stopped;
            self.queued_scene[track] = null;
        } else if (slot.state == .queued) {
            slot.state = .stopped;
            self.queued_scene[track] = null;
        } else if (playing) {
            // Clear other queued
            for (0..self.scene_count) |s| {
                if (self.clips[track][s].state == .queued) {
                    self.clips[track][s].state = .stopped;
                }
            }
            slot.state = .queued;
            self.queued_scene[track] = scene;
        } else {
            // Immediate switch and start playback
            for (0..self.scene_count) |s| {
                if (self.clips[track][s].state != .empty) {
                    self.clips[track][s].state = if (s == scene) .playing else .stopped;
                }
            }
            self.start_playback_request = true;
        }
    }

    /// Process quantized scene switches (called from tick)
    pub fn processQuantizedSwitches(self: *SessionView) void {
        for (0..self.track_count) |track| {
            if (self.queued_scene[track]) |queued| {
                for (0..self.scene_count) |scene| {
                    if (self.clips[track][scene].state != .empty) {
                        self.clips[track][scene].state = if (scene == queued) .playing else .stopped;
                    }
                }
                self.queued_scene[track] = null;
            }
        }
    }
};
