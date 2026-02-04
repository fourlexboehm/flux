// UI module root - re-exports all UI components
pub const colors = @import("colors.zig");
pub const selection = @import("selection.zig");
pub const session_view = @import("session_view.zig");
pub const session_view_constants = @import("session_view/constants.zig");
pub const piano_roll_types = @import("piano_roll/types.zig");
pub const piano_roll_draw = @import("piano_roll/draw.zig");
pub const edit_actions = @import("edit_actions.zig");

// Re-export commonly used types
pub const Colors = colors.Colors;

// Helper re-exports
pub const isModifierDown = selection.isModifierDown;
pub const isShiftDown = selection.isShiftDown;
pub const snapToStep = selection.snapToStep;
