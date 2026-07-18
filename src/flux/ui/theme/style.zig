const zgui = @import("zgui");
const colors = @import("colors.zig");
const tokens = @import("tokens.zig");
const Colors = colors.Colors;

/// Number of colors pushed by pushAbletonStyle — keep in sync.
pub const ableton_style_color_count: i32 = 38;

pub fn pushAbletonStyle() void {
    const c = Colors.current;
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = c.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = c.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .popup_bg, .c = c.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = c.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = c.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = c.bg_cell_active });
    zgui.pushStyleColor4f(.{ .idx = .header, .c = c.bg_header });
    zgui.pushStyleColor4f(.{ .idx = .header_hovered, .c = c.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .header_active, .c = c.accent_dim });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = c.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = c.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = c.accent_dim });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab, .c = c.accent });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab_active, .c = c.accent });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = c.text_bright });
    zgui.pushStyleColor4f(.{ .idx = .text_disabled, .c = c.text_dim });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = c.border });
    zgui.pushStyleColor4f(.{ .idx = .separator, .c = c.border });
    zgui.pushStyleColor4f(.{ .idx = .separator_hovered, .c = c.accent_dim });
    zgui.pushStyleColor4f(.{ .idx = .separator_active, .c = c.accent });
    zgui.pushStyleColor4f(.{ .idx = .table_header_bg, .c = c.bg_header });
    zgui.pushStyleColor4f(.{ .idx = .table_row_bg, .c = c.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .table_row_bg_alt, .c = c.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .table_border_strong, .c = c.border });
    zgui.pushStyleColor4f(.{ .idx = .table_border_light, .c = c.border_light });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_bg, .c = c.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab, .c = c.bg_cell_active });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab_hovered, .c = c.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab_active, .c = c.accent_dim });
    zgui.pushStyleColor4f(.{ .idx = .check_mark, .c = c.accent });
    zgui.pushStyleColor4f(.{ .idx = .text_selected_bg, .c = .{ c.accent[0], c.accent[1], c.accent[2], 0.35 } });
    zgui.pushStyleColor4f(.{ .idx = .nav_cursor, .c = c.focus_ring });
    zgui.pushStyleColor4f(.{ .idx = .nav_windowing_highlight, .c = c.focus_ring });
    zgui.pushStyleColor4f(.{ .idx = .nav_windowing_dim_bg, .c = .{ 0, 0, 0, 0.35 } });
    zgui.pushStyleColor4f(.{ .idx = .modal_window_dim_bg, .c = .{ 0, 0, 0, 0.45 } });
    zgui.pushStyleColor4f(.{ .idx = .drag_drop_target, .c = c.accent });
    zgui.pushStyleColor4f(.{ .idx = .title_bg, .c = c.bg_header });
    zgui.pushStyleColor4f(.{ .idx = .title_bg_active, .c = c.bg_header });
}

pub fn popAbletonStyle() void {
    zgui.popStyleColor(.{ .count = ableton_style_color_count });
}

pub fn applyMinimalStyle(ui_scale: f32) void {
    const style = zgui.getStyle();
    const scale = if (ui_scale > 0) ui_scale else 1.0;
    style.window_rounding = tokens.radius(.lg, scale);
    style.child_rounding = tokens.radius(.lg, scale);
    style.popup_rounding = tokens.radius(.lg, scale);
    style.frame_rounding = tokens.radius(.md, scale);
    style.scrollbar_rounding = tokens.radius(.lg, scale);
    style.grab_rounding = tokens.radius(.md, scale);
    style.tab_rounding = tokens.radius(.md, scale);
    style.window_border_size = tokens.s(1, scale);
    style.child_border_size = tokens.s(1, scale);
    style.popup_border_size = tokens.s(1, scale);
    style.frame_border_size = tokens.s(1, scale);
    style.item_spacing = .{ tokens.s(8, scale), tokens.s(6, scale) };
    style.item_inner_spacing = .{ tokens.s(6, scale), tokens.s(4, scale) };
    style.frame_padding = .{ tokens.s(8, scale), tokens.s(5, scale) };
    style.window_padding = .{ tokens.s(10, scale), tokens.s(8, scale) };
    style.cell_padding = .{ tokens.s(6, scale), tokens.s(4, scale) };
    style.indent_spacing = tokens.s(16, scale);
    style.scrollbar_size = tokens.s(12, scale);
    style.grab_min_size = tokens.s(10, scale);
}
