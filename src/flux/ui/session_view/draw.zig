const std = @import("std");
const session_view = @import("../session_view.zig");
const builtin = @import("builtin");
const zgui = @import("zgui");
const colors = @import("../colors.zig");
const selection = @import("../selection.zig");
const edit_actions = @import("../edit_actions.zig");
const ops = @import("ops.zig");
const playback_impl = @import("playback.zig");
const recording_impl = @import("recording.zig");
const tokens = @import("../tokens.zig");
const widgets = @import("../widgets.zig");
const draw_clip_slot = @import("draw_clip_slot.zig");

pub const ClipAudioCtx = draw_clip_slot.ClipAudioCtx;

pub fn draw(
    self: *session_view.SessionView,
    ui_scale: f32,
    playing: bool,
    is_focused: bool,
    playhead_beat: f32,
    beats_per_bar_in: f32,
    audio_ctx: ?ClipAudioCtx,
) void {
    const row_height = tokens.sessionRowH(ui_scale);
    const header_height = tokens.sessionHeaderH(ui_scale);
    const scene_col_w = tokens.sceneColW(ui_scale);
    const track_col_w = tokens.trackColW(ui_scale);
    const add_btn_size = tokens.controlH(.md, ui_scale);

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
    const ctrl_click = zgui.isMouseClicked(.left) and (zgui.isKeyDown(.mod_ctrl) or zgui.isKeyDown(.left_ctrl) or zgui.isKeyDown(.right_ctrl));
    if (in_grid and (zgui.isMouseClicked(.right) or (builtin.os.tag == .macos and ctrl_click))) {
        if (hover_track != null and hover_scene != null) {
            if (hover_has_content) {
                if (!ops.isSelected(self, hover_track.?, hover_scene.?)) {
                    ops.selectOnly(self, hover_track.?, hover_scene.?);
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
        const track_del_label = std.fmt.bufPrintSentinel(&track_label_buf, "Delete Track \"{s}\"", .{self.tracks[self.primary_track].getName()}, 0) catch "Delete Track";
        if (zgui.menuItem(track_del_label, .{ .enabled = self.track_count > 1 })) {
            _ = ops.deleteTrack(self, self.primary_track);
            menu_action = true;
        }
        var scene_label_buf: [48]u8 = undefined;
        const scene_del_label = std.fmt.bufPrintSentinel(&scene_label_buf, "Delete Scene \"{s}\"", .{self.scenes[self.primary_scene].getName()}, 0) catch "Delete Scene";
        if (zgui.menuItem(scene_del_label, .{ .enabled = self.scene_count > 1 })) {
            _ = ops.deleteScene(self, self.primary_scene);
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
                ops.moveSelectedClips(self, delta_track, delta_scene);
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
            ops.handleClipClick(self, hover_track.?, hover_scene.?, shift_down);
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
        // Track color stripe under header text
        {
            const hdr_pos = zgui.getCursorScreenPos();
            zgui.getWindowDrawList().addRectFilled(.{
                .pmin = .{ hdr_pos[0], hdr_pos[1] + header_height - tokens.s(2, ui_scale) },
                .pmax = .{ hdr_pos[0] + track_col_w - tokens.s(4, ui_scale), hdr_pos[1] + header_height },
                .col = zgui.colorConvertFloat4ToU32(colors.Colors.trackColor(t)),
            });
        }
        zgui.pushStyleColor4f(.{ .idx = .text, .c = text_color });

        var track_buf: [32]u8 = undefined;
        const track_label = std.fmt.bufPrintSentinel(&track_buf, "{s}##track_hdr{d}", .{ self.tracks[t].getName(), t }, 0) catch "Track";
        const track_pad = tokens.s(4, ui_scale);
        zgui.setCursorPosX(zgui.getCursorPosX() + track_pad);
        if (zgui.selectable(track_label, .{ .selected = is_track_selected, .w = track_col_w - track_pad * 2.0 })) {
            self.primary_track = t;
            ops.clearSelection(self);
            self.mixer_target = .track;
        }
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
        const launch_id = std.fmt.bufPrintSentinel(&launch_buf, "##scene_launch{d}", .{scene_idx}, 0) catch "##launch";

        // Check if any clip exists in this scene
        const has_clip_in_scene = ops.hasClipInScene(self, scene_idx);

        zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.Colors.current.bg_panel });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = colors.Colors.current.bg_cell_hover });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
        if (zgui.button(launch_id, .{ .w = launch_size, .h = launch_size })) {
            if (has_clip_in_scene) {
                playback_impl.launchScene(self, scene_idx, playing);
            } else {
                ops.stopAllInScene(self, scene_idx);
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
        const scene_label = std.fmt.bufPrintSentinel(&scene_buf, "{s}##scene_hdr{d}", .{ scene_name, scene_idx }, 0) catch "Scene";
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
            draw_clip_slot.drawClipSlot(self, track_idx, scene_idx, track_col_w - track_pad * 2.0, row_height - 6.0 * ui_scale, ui_scale, playing, playhead_beat, beats_per_bar_in, audio_ctx);
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
            ops.moveSelection(self, -1, 0, shift_down);
        }
        if (zgui.isKeyPressed(.right_arrow, true)) {
            ops.moveSelection(self, 1, 0, shift_down);
        }
        if (zgui.isKeyPressed(.up_arrow, true)) {
            ops.moveSelection(self, 0, -1, shift_down);
        }
        if (zgui.isKeyPressed(.down_arrow, true)) {
            ops.moveSelection(self, 0, 1, shift_down);
        }

        // Enter to create clip at selection
        if (zgui.isKeyPressed(.enter, false)) {
            if (self.clips[self.primary_track][self.primary_scene].state == .empty) {
                ops.createClip(self, self.primary_track, self.primary_scene, beats_per_bar_in);
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

fn drawTrackMixer(self: *session_view.SessionView, track: usize, width: f32, height: f32, ui_scale: f32) void {
    const padding = tokens.s(4, ui_scale);
    const spacing = tokens.s(3, ui_scale);
    const usable_width = width - padding * 2;
    const is_master = self.tracks[track].is_master;
    const btn_height = tokens.controlH(.lg, ui_scale);
    const btn_width = if (is_master) usable_width else (usable_width - spacing * 2) / 3.0;
    const slider_width = tokens.s(26, ui_scale);
    const label_height = tokens.s(20, ui_scale);
    const slider_height = height - btn_height - spacing * 2 - label_height - tokens.s(4, ui_scale);
    const frame_padding = zgui.getStyle().frame_padding;
    const text_height = zgui.getFontSize();
    const centered_pad_y = @max(0.0, (btn_height - text_height) / 2.0);

    const base_x = zgui.getCursorPosX();
    const base_y = zgui.getCursorPosY();

    // Track color accent under mixer
    {
        const strip = colors.Colors.trackColor(track);
        const dl = zgui.getWindowDrawList();
        const sp = zgui.getCursorScreenPos();
        dl.addRectFilled(.{
            .pmin = .{ sp[0], sp[1] },
            .pmax = .{ sp[0] + width, sp[1] + tokens.s(2, ui_scale) },
            .col = zgui.colorConvertFloat4ToU32(strip),
        });
    }

    zgui.setCursorPosX(base_x + padding);
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ frame_padding[0], centered_pad_y } });

    // Mute
    var mute_buf: [32]u8 = undefined;
    const mute_id = std.fmt.bufPrintSentinel(&mute_buf, "M##mute{d}", .{track}, 0) catch "M";
    const mute_on = self.tracks[track].mute;
    const mute_bg = if (mute_on) colors.Colors.current.mute_on else colors.Colors.current.bg_cell;
    const mute_text = if (mute_on) colors.Colors.textOn(mute_bg) else colors.Colors.current.text_dim;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = mute_bg });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (mute_on) colors.Colors.current.mute_on_hover else colors.Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = mute_text });
    if (zgui.button(mute_id, .{ .w = btn_width, .h = btn_height })) {
        self.tracks[track].mute = !self.tracks[track].mute;
        if (!is_master) self.primary_track = track;
        self.mixer_target = if (is_master) .master else .track;
    }
    widgets.itemTooltip("Mute");
    zgui.popStyleColor(.{ .count = 4 });

    if (!is_master) {
        zgui.sameLine(.{ .spacing = spacing });

        var solo_buf: [32]u8 = undefined;
        const solo_id = std.fmt.bufPrintSentinel(&solo_buf, "S##solo{d}", .{track}, 0) catch "S";
        const solo_on = self.tracks[track].solo;
        const solo_bg = if (solo_on) colors.Colors.current.solo_on else colors.Colors.current.bg_cell;
        const solo_text = if (solo_on) colors.Colors.textOn(solo_bg) else colors.Colors.current.text_dim;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = solo_bg });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (solo_on) colors.Colors.current.solo_on_hover else colors.Colors.current.bg_cell_hover });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = solo_text });
        if (zgui.button(solo_id, .{ .w = btn_width, .h = btn_height })) {
            self.tracks[track].solo = !self.tracks[track].solo;
            self.primary_track = track;
            self.mixer_target = .track;
        }
        widgets.itemTooltip("Solo");
        zgui.popStyleColor(.{ .count = 4 });

        zgui.sameLine(.{ .spacing = spacing });

        var arm_buf: [32]u8 = undefined;
        const arm_id = std.fmt.bufPrintSentinel(&arm_buf, "R##arm{d}", .{track}, 0) catch "R";
        const is_armed = self.armed_track != null and self.armed_track.? == track;
        const arm_bg = if (is_armed) colors.Colors.current.arm_on else colors.Colors.current.bg_cell;
        const arm_text = if (is_armed) colors.Colors.textOn(arm_bg) else colors.Colors.current.text_dim;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = arm_bg });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (is_armed) colors.Colors.current.arm_on_hover else colors.Colors.current.bg_cell_hover });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = arm_text });
        if (zgui.button(arm_id, .{ .w = btn_width, .h = btn_height })) {
            if (is_armed) {
                if (self.recording.isRecording()) {
                    recording_impl.stopRecording(self, .stop);
                }
                self.armed_track = null;
            } else {
                if (self.recording.isRecording()) {
                    recording_impl.stopRecording(self, .stop);
                }
                self.armed_track = track;
            }
            self.primary_track = track;
            self.mixer_target = .track;
        }
        widgets.itemTooltip("Record arm");
        zgui.popStyleColor(.{ .count = 4 });
    }
    zgui.popStyleVar(.{ .count = 1 });

    // Row 2: Volume slider (centered, wider)
    zgui.setCursorPosY(base_y + btn_height + spacing);
    const slider_x = base_x + (width - slider_width) / 2.0;
    zgui.setCursorPosX(slider_x);

    const slider_screen_pos = zgui.getCursorScreenPos();

    var vol_buf: [32]u8 = undefined;
    const vol_id = std.fmt.bufPrintSentinel(&vol_buf, "##vol{d}", .{track}, 0) catch "##vol";

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
            self.emitUndoRequest(.{
                .kind = .track_volume,
                .track = track,
                .old_volume = self.volume_drag_start,
                .new_volume = self.tracks[track].volume,
            });
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
        std.fmt.bufPrintSentinel(&label_buf, "Master {d:.0}dB", .{db}, 0) catch "Master"
    else
        std.fmt.bufPrintSentinel(&label_buf, "{d:.0}dB", .{db}, 0) catch "";
    zgui.textColored(colors.Colors.current.text_dim, "{s}", .{label});
}
