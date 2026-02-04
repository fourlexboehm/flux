const zgui = @import("zgui");
const colors = @import("colors.zig");
const Colors = colors.Colors;

pub fn pushAbletonStyle() void {
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = Colors.current.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = Colors.current.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .popup_bg, .c = Colors.current.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = Colors.current.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = Colors.current.bg_cell_active });
    zgui.pushStyleColor4f(.{ .idx = .header, .c = Colors.current.bg_header });
    zgui.pushStyleColor4f(.{ .idx = .header_hovered, .c = Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .header_active, .c = Colors.current.accent_dim });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = Colors.current.bg_cell });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = Colors.current.accent_dim });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab, .c = Colors.current.accent });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab_active, .c = Colors.current.accent });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = Colors.current.text_bright });
    zgui.pushStyleColor4f(.{ .idx = .text_disabled, .c = Colors.current.text_dim });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = Colors.current.border });
    zgui.pushStyleColor4f(.{ .idx = .separator, .c = Colors.current.border });
    zgui.pushStyleColor4f(.{ .idx = .table_header_bg, .c = Colors.current.bg_header });
    zgui.pushStyleColor4f(.{ .idx = .table_row_bg, .c = Colors.current.bg_panel });
    zgui.pushStyleColor4f(.{ .idx = .table_row_bg_alt, .c = Colors.current.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .table_border_strong, .c = Colors.current.border });
    zgui.pushStyleColor4f(.{ .idx = .table_border_light, .c = Colors.current.border_light });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_bg, .c = Colors.current.bg_dark });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab, .c = Colors.current.bg_cell_active });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab_hovered, .c = Colors.current.bg_cell_hover });
    zgui.pushStyleColor4f(.{ .idx = .scrollbar_grab_active, .c = Colors.current.accent_dim });
}

pub fn popAbletonStyle() void {
    zgui.popStyleColor(.{ .count = 27 });
}

pub fn applyMinimalStyle(ui_scale: f32) void {
    const style = zgui.getStyle();
    const scale = if (ui_scale > 0) ui_scale else 1.0;
    style.window_rounding = 6.0 * scale;
    style.child_rounding = 6.0 * scale;
    style.popup_rounding = 6.0 * scale;
    style.frame_rounding = 6.0 * scale;
    style.scrollbar_rounding = 6.0 * scale;
    style.grab_rounding = 6.0 * scale;
    style.tab_rounding = 6.0 * scale;
    style.window_border_size = 1.0 * scale;
    style.child_border_size = 1.0 * scale;
    style.popup_border_size = 1.0 * scale;
    style.frame_border_size = 1.0 * scale;
    style.item_spacing = .{ 10.0 * scale, 8.0 * scale };
    style.frame_padding = .{ 10.0 * scale, 6.0 * scale };
    style.window_padding = .{ 12.0 * scale, 12.0 * scale };
    style.cell_padding = .{ 8.0 * scale, 6.0 * scale };
}
