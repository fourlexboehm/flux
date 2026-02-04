const std = @import("std");
const session_view = @import("../session_view.zig");
const builtin = @import("builtin");
const zgui = @import("zgui");
const colors = @import("../colors.zig");
const selection = @import("../selection.zig");
const edit_actions = @import("../edit_actions.zig");
const ops = @import("ops.zig");
const constants = @import("constants.zig");
const playback_impl = @import("playback.zig");
const recording_impl = @import("recording.zig");

const beats_per_bar = constants.beats_per_bar;

pub fn draw(self: *session_view.SessionView, ui_scale: f32, playing: bool, is_focused: bool, playhead_beat: f32) void {
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

    // Use render-time hover from previous frame for accurate hit detection
    // (updated during clip slot rendering to match actual cell positions)
    const hover_track = self.render_hover_track;
    const hover_scene = self.render_hover_scene;
    const hover_has_content = self.render_hover_has_content;

    // Reset render-time hover tracking (will be updated during this frame's clip slot rendering)
    self.render_hover_track = null;
    self.render_hover_scene = null;
    self.render_hover_has_content = false;

    // Right-click context menu (handle before left-click selection)
    const ctrl_click = zgui.isMouseClicked(.left) and zgui.io.getKeyCtrl();
    if (in_grid and (zgui.isMouseClicked(.right) or (builtin.os.tag == .macos and ctrl_click))) {
        if (hover_track != null and hover_scene != null) {
            if (hover_has_content) {
                if (!ops.isSelected(self,hover_track.?, hover_scene.?)) {
                    ops.selectOnly(self,hover_track.?, hover_scene.?);
                } else {
                    self.primary_track = hover_track.?;
                    self.primary_scene = hover_scene.?;
                }
            } else {
                ops.clearSelection(self);
                self.primary_track = hover_track.?;
                self.primary_scene = hover_scene.?;
            }
        }
        zgui.openPopup("session_ctx", .{});
    }

    var menu_action = false;
    var popup_open = zgui.isPopupOpen("session_ctx", .{});
    if (zgui.beginPopup("session_ctx", .{})) {
        popup_open = true;
        menu_action = edit_actions.drawMenu(self, .{
            .has_selection = ops.hasSelection(self),
            .can_paste = self.clipboard.items.len > 0,
        }, .{
            .copy = ops.copySelected,
            .cut = ops.cutSelected,
            .paste = ops.paste,
            .delete = ops.deleteSelected,
            .select_all = ops.selectAllClips,
        });
        zgui.separator();
        // Delete track/scene options
        var track_label_buf: [48]u8 = undefined;
        const track_del_label = std.fmt.bufPrintZ(&track_label_buf, "Delete Track \"{s}\"", .{self.tracks[self.primary_track].getName()}) catch "Delete Track";
        if (zgui.menuItem(track_del_label, .{ .enabled = self.track_count > 1 })) {
            _ = ops.deleteTrack(self,self.primary_track);
            menu_action = true;
        }
        var scene_label_buf: [48]u8 = undefined;
        const scene_del_label = std.fmt.bufPrintZ(&scene_label_buf, "Delete Scene \"{s}\"", .{self.scenes[self.primary_scene].getName()}) catch "Delete Scene";
        if (zgui.menuItem(scene_del_label, .{ .enabled = self.scene_count > 1 })) {
            _ = ops.deleteScene(self,self.primary_scene);
            menu_action = true;
        }
        zgui.endPopup();
    }

    // Handle mouse release - complete drag move and reset all drag state
    if (!zgui.isMouseDown(.left)) {
        // If we were dragging clips and have a valid target, do the actual move now
        if (self.drag_moving and self.drag_target_track != null and self.drag_target_scene != null) {
            const delta_track = @as(i32, @intCast(self.drag_target_track.?)) - @as(i32, @intCast(self.drag_start_track));
            const delta_scene = @as(i32, @intCast(self.drag_target_scene.?)) - @as(i32, @intCast(self.drag_start_scene));
            if (delta_track != 0 or delta_scene != 0) {
                ops.moveSelectedClips(self,delta_track, delta_scene);
            }
        }
        self.drag_select.active = false;
        self.drag_select.pending = false;
        self.drag_moving = false;
        self.drag_target_track = null;
        self.drag_target_scene = null;
    }

    // On click, decide: drag move (if over clip with content) or drag select (if over empty)
    if (!popup_open and !menu_action and zgui.isMouseClicked(.left) and in_grid) {
        if (hover_has_content) {
            // Start drag move
            self.drag_moving = true;
            self.drag_start_track = hover_track.?;
            self.drag_start_scene = hover_scene.?;
            self.drag_select.pending = false;
            self.drag_select.active = false;
            // Select this clip
            ops.handleClipClick(self,hover_track.?, hover_scene.?, shift_down);
        } else {
            // Start drag select
            self.drag_select.begin(mouse, shift_down);
            self.drag_moving = false;
            if (hover_track != null and hover_scene != null) {
                self.primary_track = hover_track.?;
                self.primary_scene = hover_scene.?;
            }
            if (!shift_down) {
                ops.clearSelection(self);
            }
        }
    }

    // Update drag select position
    if (self.drag_select.active or self.drag_select.pending) {
        self.drag_select.update(mouse);
    }

    // Activate selection rectangle after drag threshold
    _ = self.drag_select.checkThreshold(4.0);

    // Handle drag moving - track target position for preview (actual move happens on release)
    if (self.drag_moving and zgui.isMouseDragging(.left, 4.0)) {
        zgui.setMouseCursor(.resize_all);
        if (hover_track != null and hover_scene != null) {
            // Just track the target, don't actually move yet
            self.drag_target_track = hover_track;
            self.drag_target_scene = hover_scene;
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
        const text_color = if (is_track_selected) colors.Colors.current.text_bright else colors.Colors.current.text_dim;
        zgui.pushStyleColor4f(.{ .idx = .text, .c = text_color });

        // Make track header clickable
        var track_buf: [32]u8 = undefined;
        const track_label = std.fmt.bufPrintZ(&track_buf, "{s}##track_hdr{d}", .{ self.tracks[t].getName(), t }) catch "Track";
        const track_pad = 4.0 * ui_scale;
        zgui.setCursorPosX(zgui.getCursorPosX() + track_pad);
        if (zgui.selectable(track_label, .{ .selected = is_track_selected, .w = track_col_w - track_pad * 2.0 })) {
            self.primary_track = t;
            ops.clearSelection(self);
            self.mixer_target = .track;
        }
        // Right-click on track header opens context menu
        if (zgui.isItemClicked(.right)) {
            self.primary_track = t;
            self.mixer_target = .track;
            zgui.openPopup("session_ctx", .{});
        }
        zgui.popStyleColor(.{ .count = 1 });
    }

    // Add track button in header
    _ = zgui.tableNextColumn();
    zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.Colors.current.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = colors.Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 10.0 * ui_scale, 6.0 * ui_scale } });
    if (zgui.button("+##add_track", .{})) {
        _ = ops.addTrack(self);
    }
    zgui.popStyleVar(.{ .count = 1 });
    zgui.popStyleColor(.{ .count = 3 });

    // Clip rows
    for (0..self.scene_count) |scene_idx| {
        zgui.tableNextRow(.{ .min_row_height = row_height });

        // Scene column
        _ = zgui.tableNextColumn();
        const row_start_y = zgui.getCursorPosY();
        const draw_list = zgui.getWindowDrawList();

        // Scene launch button first (left side), vertically centered
        const launch_size = 24.0 * ui_scale;
        const vertical_padding = (row_height - launch_size) / 2.0;
        zgui.setCursorPosY(row_start_y + vertical_padding);
        const launch_pos = zgui.getCursorScreenPos();
        var launch_buf: [32]u8 = undefined;
        const launch_id = std.fmt.bufPrintZ(&launch_buf, "##scene_launch{d}", .{scene_idx}) catch "##launch";

        // Check if any clip exists in this scene
        const has_clip_in_scene = ops.hasClipInScene(self, scene_idx);

        zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.Colors.current.bg_panel });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = colors.Colors.current.bg_cell_hover });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
        if (zgui.button(launch_id, .{ .w = launch_size, .h = launch_size })) {
            if (has_clip_in_scene) {
                playback_impl.launchScene(self, scene_idx, playing);
            } else {
                ops.stopAllInScene(self,scene_idx);
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
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.accent),
            });
        } else {
            // Stop square
            draw_list.addRectFilled(.{
                .pmin = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
                .pmax = .{ cx + icon_size / 2.0, cy + icon_size / 2.0 },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_dim),
            });
        }

        zgui.sameLine(.{ .spacing = 4.0 * ui_scale });

        // Scene name (clickable to select scene)
        const is_scene_selected = self.primary_scene == scene_idx;
        const scene_text_color = if (is_scene_selected) colors.Colors.current.text_bright else colors.Colors.current.text_dim;
        zgui.pushStyleColor4f(.{ .idx = .text, .c = scene_text_color });

        var scene_buf: [48]u8 = undefined;
        const scene_name = self.scenes[scene_idx].getName();
        const scene_text_size = zgui.calcTextSize(scene_name, .{});
        const frame_padding = zgui.getStyle().frame_padding;
        const selectable_height = scene_text_size[1] + frame_padding[1] * 2.0;
        zgui.setCursorPosY(row_start_y + (row_height - selectable_height) / 2.0);
        const scene_label = std.fmt.bufPrintZ(&scene_buf, "{s}##scene_hdr{d}", .{ scene_name, scene_idx }) catch "Scene";
        if (zgui.selectable(scene_label, .{ .selected = is_scene_selected, .w = scene_col_w - launch_size - 12.0 * ui_scale })) {
            self.primary_scene = scene_idx;
            ops.clearSelection(self);
        }
        // Right-click on scene label opens context menu
        if (zgui.isItemClicked(.right)) {
            self.primary_scene = scene_idx;
            zgui.openPopup("session_ctx", .{});
        }
        zgui.popStyleColor(.{ .count = 1 });

        // Clip slots
        for (0..self.track_count) |track_idx| {
            _ = zgui.tableNextColumn();
            const track_pad = 4.0 * ui_scale;
            zgui.setCursorPosX(zgui.getCursorPosX() + track_pad);
            drawClipSlot(self, track_idx, scene_idx, track_col_w - track_pad * 2.0, row_height - 6.0 * ui_scale, ui_scale, playing, playhead_beat);
        }

        // Empty cell for add track column
        _ = zgui.tableNextColumn();
    }

    // Add scene row
    zgui.tableNextRow(.{ .min_row_height = add_btn_size + 8.0 });
    _ = zgui.tableNextColumn();

    zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.Colors.current.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = colors.Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 10.0 * ui_scale, 6.0 * ui_scale } });
    if (zgui.button("+##add_scene", .{})) {
        _ = ops.addScene(self);
    }
    zgui.popStyleVar(.{ .count = 1 });
    zgui.popStyleColor(.{ .count = 3 });

    // Handle keyboard shortcuts (only when this pane is focused)
    const keyboard_free = !zgui.isAnyItemActive();
    const modifier_down = selection.isModifierDown();

    if (is_focused and keyboard_free) {
        edit_actions.handleShortcuts(self, modifier_down, .{
            .has_selection = ops.hasSelection(self),
            .can_paste = self.clipboard.items.len > 0,
        }, .{
            .copy = ops.copySelected,
            .cut = ops.cutSelected,
            .paste = ops.paste,
            .delete = ops.deleteSelected,
            .select_all = ops.selectAllClips,
        });

        // Arrow keys for navigation
        if (zgui.isKeyPressed(.left_arrow, true)) {
            ops.moveSelection(self,-1, 0, shift_down);
        }
        if (zgui.isKeyPressed(.right_arrow, true)) {
            ops.moveSelection(self,1, 0, shift_down);
        }
        if (zgui.isKeyPressed(.up_arrow, true)) {
            ops.moveSelection(self,0, -1, shift_down);
        }
        if (zgui.isKeyPressed(.down_arrow, true)) {
            ops.moveSelection(self,0, 1, shift_down);
        }

        // Enter to create clip at selection
        if (zgui.isKeyPressed(.enter, false)) {
            if (self.clips[self.primary_track][self.primary_scene].state == .empty) {
                ops.createClip(self,self.primary_track, self.primary_scene);
            }
        }
    }

    // Draw selection rectangle if active
    if (self.drag_select.active) {
        const dl = zgui.getForegroundDrawList();
        const fill = .{
            colors.Colors.current.selected[0],
            colors.Colors.current.selected[1],
            colors.Colors.current.selected[2],
            0.2,
        };
        const border = colors.Colors.current.selected;
        self.drag_select.drawClipped(
            dl,
            grid_pos,
            .{ grid_pos[0] + grid_width, grid_pos[1] + grid_height },
            fill,
            border,
        );
    }

    zgui.endTable();

    // Draw mixer strip at bottom of view
    const avail = zgui.getContentRegionAvail();
    if (avail[1] > mixer_height) {
        zgui.setCursorPosY(zgui.getCursorPosY() + avail[1] - mixer_height);
    }

    // Draw mixer using a table to guarantee alignment with grid
    zgui.pushStyleColor4f(.{ .idx = .table_row_bg, .c = colors.Colors.current.bg_header });
    if (zgui.beginTable("mixer_strip", .{
        .column = @intCast(self.track_count + 4),
        .flags = .{ .borders = .{ .inner_v = true }, .row_bg = true, .sizing = .fixed_fit },
    })) {
        // Setup columns to match grid exactly
        zgui.tableSetupColumn("##mix_scenes", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = scene_col_w });
        for (0..self.track_count) |_| {
            zgui.tableSetupColumn("##mix_track", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = track_col_w });
        }
        zgui.tableSetupColumn("##mix_add", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = add_btn_size + 8.0 });
        zgui.tableSetupColumn("##mix_spacer", .{ .flags = .{ .width_stretch = true } });
        zgui.tableSetupColumn("##mix_master", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = track_col_w });

        zgui.tableNextRow(.{ .min_row_height = mixer_height - 8.0 * ui_scale });
        _ = zgui.tableNextColumn(); // Empty scene column

        for (0..self.track_count) |t| {
            _ = zgui.tableNextColumn();
            drawTrackMixer(self, t, track_col_w, mixer_height - 8.0 * ui_scale, ui_scale);
        }
        _ = zgui.tableNextColumn(); // Empty add column
        _ = zgui.tableNextColumn(); // Stretch spacer
        _ = zgui.tableNextColumn();
        drawTrackMixer(self, session_view.master_track_index, track_col_w, mixer_height - 8.0 * ui_scale, ui_scale);

        zgui.endTable();
    }
    zgui.popStyleColor(.{ .count = 1 });
}

fn drawClipSlot(self: *session_view.SessionView, track: usize, scene: usize, width: f32, height: f32, ui_scale: f32, playing: bool, playhead_beat: f32) void {
    const draw_list = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    const mouse = zgui.getMousePos();

    // Store cell position for ghost rendering
    self.cell_positions[track][scene] = pos;

    const slot = &self.clips[track][scene];
    const is_selected = ops.isSelected(self,track, scene);

    // Check if this clip is being overdubbed (playing + recording)
    const is_overdub_clip = slot.state == .playing and self.recording.track == track and self.recording.scene == scene;

    // Clip colors based on state
    const clip_color = if (is_overdub_clip)
        colors.Colors.current.clip_recording // Use recording color for overdub
    else switch (slot.state) {
        .empty => colors.Colors.current.clip_empty,
        .stopped => colors.Colors.current.clip_stopped,
        .queued => colors.Colors.current.clip_queued,
        .playing => colors.Colors.current.clip_playing,
        .recording => colors.Colors.current.clip_recording,
        .record_queued => colors.Colors.current.clip_queued,
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
            if (!ops.isSelected(self,track, scene) and slot.state != .empty) {
                ops.selectClip(self,track, scene);
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
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.selected),
            .rounding = rounding,
            .flags = zgui.DrawFlags.round_corners_all,
            .thickness = 2.0,
        });

        // Draw ghost outline at drag target position (if dragging)
        if (self.drag_moving and self.drag_target_track != null and self.drag_target_scene != null) {
            const target_t = self.drag_target_track.?;
            const target_s = self.drag_target_scene.?;
            if (target_t != track or target_s != scene) {
                // Calculate where this clip would end up relative to the drag target
                const rel_track = @as(i32, @intCast(track)) - @as(i32, @intCast(self.drag_start_track));
                const rel_scene = @as(i32, @intCast(scene)) - @as(i32, @intCast(self.drag_start_scene));
                const final_track = @as(i32, @intCast(target_t)) + rel_track;
                const final_scene = @as(i32, @intCast(target_s)) + rel_scene;

                // Only draw if target is in bounds
                if (final_track >= 0 and final_track < @as(i32, @intCast(self.track_count)) and
                    final_scene >= 0 and final_scene < @as(i32, @intCast(self.scene_count)))
                {
                    const ghost_pos = self.cell_positions[@intCast(final_track)][@intCast(final_scene)];
                    const ghost_min = ghost_pos;
                    const ghost_max = [2]f32{ ghost_min[0] + clip_w, ghost_min[1] + height };

                    // Draw on foreground so it appears on top
                    const fg_draw_list = zgui.getForegroundDrawList();
                    fg_draw_list.addRectFilled(.{
                        .pmin = ghost_min,
                        .pmax = ghost_max,
                        .col = zgui.colorConvertFloat4ToU32(.{ colors.Colors.current.selected[0], colors.Colors.current.selected[1], colors.Colors.current.selected[2], 0.4 }),
                        .rounding = rounding,
                        .flags = zgui.DrawFlags.round_corners_all,
                    });
                    fg_draw_list.addRect(.{
                        .pmin = ghost_min,
                        .pmax = ghost_max,
                        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.selected),
                        .rounding = rounding,
                        .flags = zgui.DrawFlags.round_corners_all,
                        .thickness = 2.0,
                    });
                }
            }
        }
    }

    // Check if we're overdubbing this clip
    const clip_is_overdubbing = slot.state == .playing and self.recording.track == track and self.recording.scene == scene;

    // Clip content indicator (bars) or recording progress
    if (slot.state == .recording) {
        // Show "REC" label for recording clips
        const text_color = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright);
        const rec_label = "REC";
        const rec_size = zgui.calcTextSize(rec_label, .{});
        draw_list.addText(.{ pos[0] + 8.0 * ui_scale, pos[1] + (height - rec_size[1]) / 2.0 }, text_color, rec_label, .{});

        // Draw progress bar at bottom of clip
        if (self.recording.track == track and self.recording.scene == scene) {
            const progress_height = 4.0 * ui_scale;
            const elapsed = playhead_beat - self.recording.start_beat;
            const progress = @min(1.0, @max(0.0, elapsed / self.recording.target_length_beats));
            const progress_width = clip_w * progress;
            draw_list.addRectFilled(.{
                .pmin = .{ pos[0], pos[1] + height - progress_height },
                .pmax = .{ pos[0] + progress_width, pos[1] + height },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.clip_recording),
            });
        }
    } else if (clip_is_overdubbing) {
        // Show "OVERDUB" label when playing and recording
        const text_color = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright);
        const overdub_label = "OVERDUB";
        const overdub_size = zgui.calcTextSize(overdub_label, .{});
        draw_list.addText(.{ pos[0] + 4.0 * ui_scale, pos[1] + (height - overdub_size[1]) / 2.0 }, text_color, overdub_label, .{});
    } else if (slot.state == .record_queued) {
        // Show "ARMED" label for queued recording
        const text_color = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright);
        const armed_label = "ARMED";
        const armed_size = zgui.calcTextSize(armed_label, .{});
        draw_list.addText(.{ pos[0] + 8.0 * ui_scale, pos[1] + (height - armed_size[1]) / 2.0 }, text_color, armed_label, .{});
    } else if (slot.state != .empty) {
        const bars = slot.length_beats / beats_per_bar;
        var buf: [16]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{d:.0} bars", .{bars}) catch "";
        // Use dark text for all non-empty clips (better contrast on colored backgrounds)
        const text_color = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright);
        const label_size = zgui.calcTextSize(label, .{});
        draw_list.addText(.{ pos[0] + 8.0 * ui_scale, pos[1] + (height - label_size[1]) / 2.0 }, text_color, "{s}", .{label});
    }

    // Invisible button for clip interaction
    var clip_buf: [32]u8 = undefined;
    const clip_id = std.fmt.bufPrintZ(&clip_buf, "##clip_t{d}s{d}", .{ track, scene }) catch "##clip";

    const over_clip = mouse[0] >= pos[0] and mouse[0] < pos[0] + clip_w and
        mouse[1] >= pos[1] and mouse[1] < pos[1] + height;

    // Check if mouse is over the entire cell (clip + play button)
    const over_cell = mouse[0] >= pos[0] and mouse[0] < pos[0] + width and
        mouse[1] >= pos[1] and mouse[1] < pos[1] + height;

    // Update render-time hover tracking for accurate hit detection next frame
    if (over_cell) {
        self.render_hover_track = track;
        self.render_hover_scene = scene;
        self.render_hover_has_content = slot.state != .empty;
    }

    // Show move cursor when hovering over a clip with content (but not recording clips)
    const is_recording_state = slot.state == .recording or slot.state == .record_queued;
    if (over_clip and slot.state != .empty and !is_recording_state and !self.drag_moving) {
        zgui.setMouseCursor(.resize_all);
    }

    // Invisible button for double-click detection
    _ = zgui.invisibleButton(clip_id, .{ .w = clip_w, .h = height });

    // Handle double-click to create/open clip
    if (over_clip and zgui.isMouseDoubleClicked(.left)) {
        if (slot.state == .empty) {
            ops.createClip(self,track, scene);
        }
        ops.selectOnly(self,track, scene);
        self.open_clip_request = .{ .track = track, .scene = scene };
    }

    zgui.sameLine(.{ .spacing = 4.0 * ui_scale });

    // Play/Record button
    const play_pos = zgui.getCursorScreenPos();
    var play_buf: [32]u8 = undefined;
    const play_id = std.fmt.bufPrintZ(&play_buf, "##play_t{d}s{d}", .{ track, scene }) catch "##play";

    const is_playing_clip = slot.state == .playing;
    const is_queued = slot.state == .queued;
    const is_recording = slot.state == .recording;
    const is_record_queued = slot.state == .record_queued;
    const is_empty = slot.state == .empty;
    const is_armed_track = self.armed_track != null and self.armed_track.? == track;
    // Check if we're overdubbing (playing + recording on this clip)
    const is_overdubbing = is_playing_clip and self.recording.track == track and self.recording.scene == scene;

    // Determine button background color
    // For armed track: show record button style for empty slots or stopped clips
    // For recording/record_queued/overdubbing: show recording color
    // Otherwise: normal play button style
    const play_bg = if (is_recording or is_record_queued or is_overdubbing)
        colors.Colors.current.record_armed
    else if (is_playing_clip)
        colors.Colors.current.clip_playing
    else if (is_queued)
        colors.Colors.current.clip_queued
    else if (is_armed_track and (is_empty or slot.state == .stopped))
        colors.Colors.current.record_armed
    else
        colors.Colors.current.bg_cell;

    const hover_bg = if (is_recording or is_record_queued or is_overdubbing or (is_armed_track and (is_empty or slot.state == .stopped)))
        colors.Colors.current.record_armed_hover
    else
        [4]f32{ play_bg[0] + 0.08, play_bg[1] + 0.08, play_bg[2] + 0.08, 1.0 };

    zgui.pushStyleColor4f(.{ .idx = .button, .c = play_bg });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = hover_bg });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
    if (zgui.button(play_id, .{ .w = play_btn_w, .h = height })) {
        // Handle button click based on state
        if (is_recording or is_record_queued or is_overdubbing) {
            // Click on recording/queued/overdubbing clip -> stop recording
            self.armed_track = null;
            if (is_recording) {
                recording_impl.stopRecording(self,.loop);
            } else if (is_overdubbing) {
                // Stop overdub - just clear recording state, clip keeps playing
                self.recording.reset();
            } else {
                recording_impl.cancelRecording(self,);
            }
        } else if (is_armed_track and (is_empty or slot.state == .stopped)) {
            // Click record button on armed track -> start recording
            recording_impl.startRecording(self,track, scene, playing, playhead_beat);
        } else {
            // Normal play/stop behavior
                playback_impl.toggleClipPlayback(self, track, scene, playing);
        }
    }
    zgui.popStyleColor(.{ .count = 3 });

    // Draw play/stop/record icon
    const icon_size = 10.0 * ui_scale;
    const cx = play_pos[0] + play_btn_w / 2.0;
    const cy = play_pos[1] + height / 2.0;

    if (is_recording or is_record_queued or is_overdubbing) {
        // Filled record circle during recording/queued/overdubbing
        draw_list.addCircleFilled(.{
            .p = .{ cx, cy },
            .r = icon_size / 2.0,
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright),
        });
    } else if (is_playing_clip) {
        // Stop square (for playing clip)
        draw_list.addRectFilled(.{
            .pmin = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
            .pmax = .{ cx + icon_size / 2.0, cy + icon_size / 2.0 },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright),
        });
    } else if (is_queued) {
        // Queued indicator
        draw_list.addTriangleFilled(.{
            .p1 = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
            .p2 = .{ cx - icon_size / 2.0, cy + icon_size / 2.0 },
            .p3 = .{ cx + icon_size / 2.0 + 1.0, cy },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.clip_queued),
        });
        draw_list.addTriangle(.{
            .p1 = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
            .p2 = .{ cx - icon_size / 2.0, cy + icon_size / 2.0 },
            .p3 = .{ cx + icon_size / 2.0 + 1.0, cy },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.clip_queued),
            .thickness = 2.0,
        });
    } else if (is_armed_track and (is_empty or slot.state == .stopped)) {
        // Record circle for armed track (empty or stopped clips)
        draw_list.addCircleFilled(.{
            .p = .{ cx, cy },
            .r = icon_size / 2.0,
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright),
        });
    } else if (is_empty) {
        // Stop square for empty slot on non-armed track
        draw_list.addRectFilled(.{
            .pmin = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
            .pmax = .{ cx + icon_size / 2.0, cy + icon_size / 2.0 },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_dim),
        });
    } else {
        // Play triangle (for stopped clip with content)
        draw_list.addTriangleFilled(.{
            .p1 = .{ cx - icon_size / 2.0, cy - icon_size / 2.0 },
            .p2 = .{ cx - icon_size / 2.0, cy + icon_size / 2.0 },
            .p3 = .{ cx + icon_size / 2.0 + 1.0, cy },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_dim),
        });
    }
}

fn drawTrackMixer(self: *session_view.SessionView, track: usize, width: f32, height: f32, ui_scale: f32) void {
    const padding = 4.0 * ui_scale;
    const spacing = 4.0 * ui_scale;
    const usable_width = width - padding * 2;
    const is_master = self.tracks[track].is_master;
    const btn_height = 36.0 * ui_scale;
    const btn_width = if (is_master) usable_width else (usable_width - spacing * 2) / 3.0; // 3 buttons: M, S, R
    const slider_width = 28.0 * ui_scale;
    const label_height = 24.0 * ui_scale;
    const slider_height = height - btn_height - spacing * 2 - label_height - 4.0 * ui_scale;
    const frame_padding = zgui.getStyle().frame_padding;
    const text_height = zgui.getFontSize();
    const centered_pad_y = @max(0.0, (btn_height - text_height) / 2.0);

    const base_x = zgui.getCursorPosX();
    const base_y = zgui.getCursorPosY();

    // Row 1: M, S, R buttons side by side (fill track width)
    zgui.setCursorPosX(base_x + padding);
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ frame_padding[0], centered_pad_y } });

    // Mute button
    var mute_buf: [32]u8 = undefined;
    const mute_id = std.fmt.bufPrintZ(&mute_buf, "M##mute{d}", .{track}) catch "M";

    const mute_bg = if (self.tracks[track].mute) colors.Colors.current.clip_stopped else colors.Colors.current.bg_cell;
    const mute_text = if (self.tracks[track].mute) colors.Colors.current.text_bright else colors.Colors.current.text_dim;

    zgui.pushStyleColor4f(.{ .idx = .button, .c = mute_bg });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ mute_bg[0] + 0.1, mute_bg[1] + 0.1, mute_bg[2] + 0.1, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = mute_text });

    if (zgui.button(mute_id, .{ .w = btn_width, .h = btn_height })) {
        self.tracks[track].mute = !self.tracks[track].mute;
        if (!is_master) {
            self.primary_track = track;
        }
        self.mixer_target = if (is_master) .master else .track;
    }
    zgui.popStyleColor(.{ .count = 4 });

    if (!is_master) {
        zgui.sameLine(.{ .spacing = spacing });

        // Solo button
        var solo_buf: [32]u8 = undefined;
        const solo_id = std.fmt.bufPrintZ(&solo_buf, "S##solo{d}", .{track}) catch "S";

        const solo_bg = if (self.tracks[track].solo) colors.Colors.current.clip_queued else colors.Colors.current.bg_cell;
        const solo_text = if (self.tracks[track].solo) colors.Colors.current.text_bright else colors.Colors.current.text_dim;

        zgui.pushStyleColor4f(.{ .idx = .button, .c = solo_bg });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ solo_bg[0] + 0.1, solo_bg[1] + 0.1, solo_bg[2] + 0.1, 1.0 } });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = solo_text });

        if (zgui.button(solo_id, .{ .w = btn_width, .h = btn_height })) {
            self.tracks[track].solo = !self.tracks[track].solo;
            self.primary_track = track;
            self.mixer_target = .track;
        }
        zgui.popStyleColor(.{ .count = 4 });

        zgui.sameLine(.{ .spacing = spacing });

        // Record Arm button
        var arm_buf: [32]u8 = undefined;
        const arm_id = std.fmt.bufPrintZ(&arm_buf, "R##arm{d}", .{track}) catch "R";

        const is_armed = self.armed_track != null and self.armed_track.? == track;
        const arm_bg = if (is_armed) colors.Colors.current.record_armed else colors.Colors.current.bg_cell;
        const arm_text = if (is_armed) colors.Colors.current.text_bright else colors.Colors.current.text_dim;

        zgui.pushStyleColor4f(.{ .idx = .button, .c = arm_bg });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (is_armed) colors.Colors.current.record_armed_hover else .{ arm_bg[0] + 0.1, arm_bg[1] + 0.1, arm_bg[2] + 0.1, 1.0 } });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = arm_text });

        if (zgui.button(arm_id, .{ .w = btn_width, .h = btn_height })) {
            if (is_armed) {
                // Disarm - also stop any active recording
                if (self.recording.isRecording()) {
                    recording_impl.stopRecording(self,.stop);
                }
                self.armed_track = null;
            } else {
                // Arm this track (disarm any other)
                if (self.recording.isRecording()) {
                    recording_impl.stopRecording(self,.stop);
                }
                self.armed_track = track;
            }
            self.primary_track = track;
            self.mixer_target = .track;
        }
        zgui.popStyleColor(.{ .count = 4 });
    }
    zgui.popStyleVar(.{ .count = 1 });

    // Row 2: Volume slider (centered, wider)
    zgui.setCursorPosY(base_y + btn_height + spacing);
    const slider_x = base_x + (width - slider_width) / 2.0;
    zgui.setCursorPosX(slider_x);

    const slider_screen_pos = zgui.getCursorScreenPos();

    var vol_buf: [32]u8 = undefined;
    const vol_id = std.fmt.bufPrintZ(&vol_buf, "##vol{d}", .{track}) catch "##vol";

    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = colors.Colors.current.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = colors.Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = colors.Colors.current.bg_cell_active });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab, .c = colors.Colors.current.accent });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab_active, .c = colors.Colors.current.accent_dim });

    const volume_before = self.tracks[track].volume;
    _ = zgui.vsliderFloat(vol_id, .{
        .w = slider_width,
        .h = slider_height,
        .v = &self.tracks[track].volume,
        .min = 0.0,
        .max = 1.5,
        .cfmt = "",
    });

    // Track volume drag for undo
    if (zgui.isItemActive()) {
        if (self.volume_drag_track == null) {
            // Drag started
            self.volume_drag_track = track;
            self.volume_drag_start = volume_before;
        }
        if (!is_master) {
            self.primary_track = track;
        }
        self.mixer_target = if (is_master) .master else .track;
    } else if (self.volume_drag_track == track) {
        // Drag ended - emit undo request if changed
        if (self.tracks[track].volume != self.volume_drag_start) {
            if (self.undo_request_count < self.undo_requests.len) {
                self.undo_requests[self.undo_request_count] = .{
                    .kind = .track_volume,
                    .track = track,
                    .old_volume = self.volume_drag_start,
                    .new_volume = self.tracks[track].volume,
                };
                self.undo_request_count += 1;
            }
        }
        self.volume_drag_track = null;
    }

    zgui.popStyleColor(.{ .count = 5 });

    // Draw 0dB tick marks on the sides AFTER the slider (so they're visible)
    // Volume = 1.0 is at 1.0/1.5 = 0.667 from bottom
    const draw_list = zgui.getWindowDrawList();
    const zero_db_ratio = 1.0 / 1.5; // 0dB = volume 1.0
    const zero_db_y = slider_screen_pos[1] + slider_height * (1.0 - zero_db_ratio);
    const tick_width = 6.0 * ui_scale;
    const tick_height = 3.0 * ui_scale;
    // Left tick mark
    draw_list.addRectFilled(.{
        .pmin = .{ slider_screen_pos[0] - tick_width - 2.0, zero_db_y - tick_height / 2.0 },
        .pmax = .{ slider_screen_pos[0] - 2.0, zero_db_y + tick_height / 2.0 },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright),
    });
    // Right tick mark
    draw_list.addRectFilled(.{
        .pmin = .{ slider_screen_pos[0] + slider_width + 2.0, zero_db_y - tick_height / 2.0 },
        .pmax = .{ slider_screen_pos[0] + slider_width + tick_width + 2.0, zero_db_y + tick_height / 2.0 },
        .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.text_bright),
    });

    // Row 3: dB label (centered)
    zgui.setCursorPosY(base_y + btn_height + spacing + slider_height + spacing);
    zgui.setCursorPosX(base_x + padding);

    const db = if (self.tracks[track].volume > 0.0001)
        20.0 * @log10(self.tracks[track].volume)
    else
        -60.0;
    var label_buf: [24]u8 = undefined;
    const label = if (is_master)
        std.fmt.bufPrintZ(&label_buf, "Master {d:.0}dB", .{db}) catch "Master"
    else
        std.fmt.bufPrintZ(&label_buf, "{d:.0}dB", .{db}) catch "";
    zgui.textColored(colors.Colors.current.text_dim, "{s}", .{label});
}
