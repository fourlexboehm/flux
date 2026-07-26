// UI module root - re-exports all UI components
pub const colors = @import("theme/colors.zig");
pub const selection = @import("input/selection.zig");
pub const session_view = @import("../session/types.zig");
pub const session_view_constants = @import("../session/constants.zig");
pub const piano_roll_types = @import("../session/notes.zig");
pub const piano_roll_draw = @import("views/piano_roll/draw.zig");
pub const edit_actions = @import("input/edit_actions.zig");

// Re-export commonly used types
pub const Colors = colors.Colors;

// Helper re-exports
pub const isModifierDown = selection.isModifierDown;
pub const isShiftDown = selection.isShiftDown;
pub const snapToStep = selection.snapToStep;
