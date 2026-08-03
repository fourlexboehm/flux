//! Shared editor action vocabulary for session, arrangement, and piano roll.
//!
//! Views own their data-specific implementations; this module keeps keyboard
//! bindings and context-menu ordering identical without introducing a generic
//! command framework.

const dvui = @import("dvui");
const theme = @import("theme.zig");

pub const Action = enum {
    copy,
    cut,
    paste,
    duplicate,
    delete,
    select_all,
    undo,
    redo,
    quantize,
    move_left,
    move_right,
    move_up,
    move_down,
};

pub const Availability = packed struct {
    copy: bool = false,
    cut: bool = false,
    paste: bool = false,
    duplicate: bool = false,
    delete: bool = false,
    select_all: bool = true,
    undo: bool = false,
    redo: bool = false,
    quantize: bool = false,
    move_left: bool = false,
    move_right: bool = false,
    move_up: bool = false,
    move_down: bool = false,

    pub fn enabled(self: Availability, action: Action) bool {
        return switch (action) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
};

const Entry = struct {
    action: Action,
    label: []const u8,
    starts_group: bool = false,
};

const entries = [_]Entry{
    .{ .action = .undo, .label = "Undo                 Cmd/Ctrl+Z" },
    .{ .action = .redo, .label = "Redo          Cmd/Ctrl+Shift+Z" },
    .{ .action = .copy, .label = "Copy                 Cmd/Ctrl+C", .starts_group = true },
    .{ .action = .cut, .label = "Cut                    Cmd/Ctrl+X" },
    .{ .action = .paste, .label = "Paste                Cmd/Ctrl+V" },
    .{ .action = .duplicate, .label = "Duplicate          Cmd/Ctrl+D" },
    .{ .action = .delete, .label = "Delete                         Del" },
    .{ .action = .select_all, .label = "Select All          Cmd/Ctrl+A", .starts_group = true },
    .{ .action = .quantize, .label = "Quantize                          Q" },
    .{ .action = .move_left, .label = "Move Left", .starts_group = true },
    .{ .action = .move_right, .label = "Move Right" },
    .{ .action = .move_up, .label = "Move Up" },
    .{ .action = .move_down, .label = "Move Down" },
};

/// Draw standard edit items inside an active `floatingMenu`.
pub fn drawMenu(available: Availability) ?Action {
    for (entries, 0..) |entry, i| {
        if (entry.starts_group and i != 0) separator(i);
        if (!available.enabled(entry.action)) {
            dvui.labelNoFmt(@src(), entry.label, .{}, .{
                .expand = .horizontal,
                .color_text = theme.text_soft,
                .padding = dvui.Rect.all(6),
                .id_extra = i,
            });
            continue;
        }
        if (dvui.menuItemLabel(@src(), entry.label, .{}, .{
            .expand = .horizontal,
            .id_extra = i,
        }) != null) return entry.action;
    }
    return null;
}

/// Common platform shortcut mapping. Views can add their own editor-specific
/// keys after this returns null.
pub fn fromKey(key: dvui.Event.Key) ?Action {
    if (key.action != .down and key.action != .repeat) return null;
    const command = key.mod.control() or key.mod.command();
    if (command) {
        if (key.code == .z) return if (key.mod.shift()) .redo else .undo;
        if (key.code == .y and !key.mod.shift()) return .redo;
        return switch (key.code) {
            .a => .select_all,
            .c => .copy,
            .x => .cut,
            .v => .paste,
            .d => .duplicate,
            else => null,
        };
    }
    return switch (key.code) {
        .delete, .backspace => .delete,
        else => null,
    };
}

fn separator(id_extra: usize) void {
    var line = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 1 },
        .background = true,
        .color_fill = theme.grid,
        .margin = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
        .id_extra = id_extra,
    });
    line.deinit();
}

test "availability follows action tags" {
    const available: Availability = .{ .copy = true, .move_down = true };
    try @import("std").testing.expect(available.enabled(.copy));
    try @import("std").testing.expect(available.enabled(.move_down));
    try @import("std").testing.expect(!available.enabled(.paste));
}
