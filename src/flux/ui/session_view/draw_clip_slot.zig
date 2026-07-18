//! Session grid clip cell drawing (MIDI bars + audio waveform thumbnails).

const std = @import("std");
const zgui = @import("zgui");
const session_view = @import("../session_view.zig");
const colors = @import("../colors.zig");
const ops = @import("ops.zig");
const playback_impl = @import("playback.zig");
const recording_impl = @import("recording.zig");
const tokens = @import("../tokens.zig");
const audio_clip_types = @import("../audio_clip/types.zig");
const sample_store_mod = @import("../../audio/sample_store.zig");
const draw_waveform = @import("../audio_clip/draw_waveform.zig");
const session_constants = @import("constants.zig");

const AudioClip = audio_clip_types.AudioClip;
const SampleStore = sample_store_mod.SampleStore;

/// Optional audio data for session-cell waveforms (main thread).
pub const ClipAudioCtx = struct {
    audio_clips: *const [session_constants.max_tracks][session_constants.max_scenes]AudioClip,
    sample_store: *const SampleStore,
};

pub fn drawClipSlot(
    self: *session_view.SessionView,
    track: usize,
    scene: usize,
    width: f32,
    height: f32,
    ui_scale: f32,
    playing: bool,
    playhead_beat: f32,
    beats_per_bar_in: f32,
    audio_ctx: ?ClipAudioCtx,
) void {
    const draw_list = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    const mouse = zgui.getMousePos();

    // Store cell position for ghost rendering
    self.cell_positions[track][scene] = pos;

    const slot = &self.clips[track][scene];
    const is_selected = ops.isSelected(self, track, scene);

    const audio_clip: ?*const AudioClip = if (audio_ctx) |ctx|
        if (track < session_constants.max_tracks and scene < session_constants.max_scenes)
            &ctx.audio_clips[track][scene]
        else
            null
    else
        null;
    const is_audio = if (audio_clip) |ac| ac.hasAudio() else false;
    const sample_asset = blk: {
        if (!is_audio) break :blk null;
        const ac = audio_clip.?;
        const id = ac.sample_id orelse break :blk null;
        if (audio_ctx) |ctx| break :blk ctx.sample_store.get(id);
        break :blk null;
    };

    // Check if this clip is being overdubbed (playing + recording)
    const is_overdub_clip = slot.state == .playing and self.recording.track == track and self.recording.scene == scene;

    // Clip colors based on state (audio clips get a cooler teal tint when stopped)
    const clip_color = if (is_overdub_clip)
        colors.Colors.current.clip_recording
    else switch (slot.state) {
        .empty => colors.Colors.current.empty_slot_fill,
        .stopped => if (is_audio) colors.Colors.current.clip_audio_stopped else colors.Colors.current.clip_stopped,
        .queued => colors.Colors.current.clip_queued,
        .playing => if (is_audio) colors.Colors.current.clip_audio_playing else colors.Colors.current.clip_playing,
        .recording => colors.Colors.current.clip_recording,
        .record_queued => colors.Colors.current.clip_queued,
    };

    // Play button dimensions
    const play_btn_w = tokens.s(22, ui_scale);
    const clip_w = width - play_btn_w - tokens.s(4, ui_scale);
    const rounding = tokens.radius(.md, ui_scale);
    const strip_w = tokens.s(3, ui_scale);

    // Check drag select intersection
    if (self.drag_select.active) {
        const clip_min = pos;
        const clip_max = [2]f32{ pos[0] + clip_w, pos[1] + height };
        if (self.drag_select.intersects(clip_min, clip_max)) {
            if (!ops.isSelected(self, track, scene) and slot.state != .empty) {
                ops.selectClip(self, track, scene);
            }
        }
    }

    // Background
    var bg_color = clip_color;
    if (is_selected and slot.state != .empty) {
        bg_color = colors.Colors.lighten(clip_color, 0.10);
    }

    draw_list.addRectFilled(.{
        .pmin = pos,
        .pmax = .{ pos[0] + clip_w, pos[1] + height },
        .col = zgui.colorConvertFloat4ToU32(bg_color),
        .rounding = rounding,
        .flags = zgui.DrawFlags.round_corners_all,
    });

    // Empty slot inset border
    if (slot.state == .empty) {
        draw_list.addRect(.{
            .pmin = .{ pos[0] + 0.5, pos[1] + 0.5 },
            .pmax = .{ pos[0] + clip_w - 0.5, pos[1] + height - 0.5 },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.empty_slot_border),
            .rounding = rounding,
            .flags = zgui.DrawFlags.round_corners_all,
            .thickness = 1.0,
        });
    } else {
        // Track color strip on filled clips
        const strip = colors.Colors.trackColor(track);
        draw_list.addRectFilled(.{
            .pmin = pos,
            .pmax = .{ pos[0] + strip_w, pos[1] + height },
            .col = zgui.colorConvertFloat4ToU32(strip),
            .rounding = rounding,
            .flags = zgui.DrawFlags.round_corners_left,
        });
    }

    // Selection border
    if (is_selected) {
        draw_list.addRect(.{
            .pmin = pos,
            .pmax = .{ pos[0] + clip_w, pos[1] + height },
            .col = zgui.colorConvertFloat4ToU32(colors.Colors.current.selected),
            .rounding = rounding,
            .flags = zgui.DrawFlags.round_corners_all,
            .thickness = tokens.s(1.5, ui_scale),
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

    // Waveform thumbnail for audio clips (behind labels)
    if (sample_asset) |asset| {
        const wave_pad_x = strip_w + tokens.s(3, ui_scale);
        const wave_pad_y = tokens.s(3, ui_scale);
        const wave_col = waveformColor(bg_color);
        draw_waveform.drawPeaks(draw_list, .{
            .pmin = .{ pos[0] + wave_pad_x, pos[1] + wave_pad_y },
            .pmax = .{ pos[0] + clip_w - tokens.s(3, ui_scale), pos[1] + height - wave_pad_y },
            .peaks = asset.peaks[0..],
            .col = zgui.colorConvertFloat4ToU32(wave_col),
            .amp_frac = 0.90,
        });
    }

    // Clip content indicator (bars) or recording progress
    const label_x = pos[0] + strip_w + tokens.s(6, ui_scale);
    if (slot.state == .recording) {
        const text_color = zgui.colorConvertFloat4ToU32(colors.Colors.textOn(bg_color));
        const rec_label = "REC";
        const rec_size = zgui.calcTextSize(rec_label, .{});
        draw_list.addText(.{ label_x, pos[1] + (height - rec_size[1]) / 2.0 }, text_color, "{s}", .{rec_label});

        if (self.recording.track == track and self.recording.scene == scene) {
            const progress_height = tokens.s(3, ui_scale);
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
        const text_color = zgui.colorConvertFloat4ToU32(colors.Colors.textOn(bg_color));
        const overdub_label = "OVERDUB";
        const overdub_size = zgui.calcTextSize(overdub_label, .{});
        draw_list.addText(.{ label_x, pos[1] + (height - overdub_size[1]) / 2.0 }, text_color, "{s}", .{overdub_label});
    } else if (slot.state == .record_queued) {
        const text_color = zgui.colorConvertFloat4ToU32(colors.Colors.textOn(bg_color));
        const armed_label = "ARMED";
        const armed_size = zgui.calcTextSize(armed_label, .{});
        draw_list.addText(.{ label_x, pos[1] + (height - armed_size[1]) / 2.0 }, text_color, "{s}", .{armed_label});
    } else if (slot.state != .empty and !is_audio) {
        const bars = slot.length_beats / beats_per_bar_in;
        var buf: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d:.0} bars", .{bars}) catch "";
        const text_color = zgui.colorConvertFloat4ToU32(colors.Colors.textOn(bg_color));
        const label_size = zgui.calcTextSize(label, .{});
        draw_list.addText(.{ label_x, pos[1] + (height - label_size[1]) / 2.0 }, text_color, "{s}", .{label});
    } else if (slot.state != .empty and is_audio) {
        // Compact bar length in top-left so the waveform stays readable
        const bars = slot.length_beats / beats_per_bar_in;
        var buf: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d:.0}b", .{bars}) catch "";
        const text_color = zgui.colorConvertFloat4ToU32(withAlpha(colors.Colors.textOn(bg_color), 0.85));
        draw_list.addText(.{ label_x, pos[1] + tokens.s(2, ui_scale) }, text_color, "{s}", .{label});
    }

    // Invisible button for clip interaction
    var clip_buf: [32]u8 = undefined;
    const clip_id = std.fmt.bufPrintSentinel(&clip_buf, "##clip_t{d}s{d}", .{ track, scene }, 0) catch "##clip";

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
            ops.createClip(self, track, scene, beats_per_bar_in);
        }
        ops.selectOnly(self, track, scene);
        self.open_clip_request = .{ .track = track, .scene = scene };
    }

    zgui.sameLine(.{ .spacing = 4.0 * ui_scale });

    // Play/Record button
    const play_pos = zgui.getCursorScreenPos();
    var play_buf: [32]u8 = undefined;
    const play_id = std.fmt.bufPrintSentinel(&play_buf, "##play_t{d}s{d}", .{ track, scene }, 0) catch "##play";

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
        colors.Colors.lighten(play_bg, 0.08);

    zgui.pushStyleColor4f(.{ .idx = .button, .c = play_bg });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = hover_bg });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.Colors.current.accent_dim });
    if (zgui.button(play_id, .{ .w = play_btn_w, .h = height })) {
        // Handle button click based on state
        if (is_recording or is_record_queued or is_overdubbing) {
            // Click on recording/queued/overdubbing clip -> stop recording
            self.armed_track = null;
            if (is_recording) {
                recording_impl.stopRecording(self, .loop);
            } else if (is_overdubbing) {
                // Stop overdub - just clear recording state, clip keeps playing
                self.recording.reset();
            } else {
                recording_impl.cancelRecording(
                    self,
                );
            }
        } else if (is_armed_track and (is_empty or slot.state == .stopped)) {
            // Click record button on armed track -> start recording
            recording_impl.startRecording(self, track, scene, playing, playhead_beat, beats_per_bar_in);
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

fn withAlpha(c: [4]f32, a: f32) [4]f32 {
    return .{ c[0], c[1], c[2], a };
}

/// Semi-transparent waveform color that stays readable on the clip fill.
fn waveformColor(fill: [4]f32) [4]f32 {
    const on = colors.Colors.textOn(fill);
    // Soft ink over fill — not full opacity so the cell color still reads
    return .{ on[0], on[1], on[2], 0.55 };
}
