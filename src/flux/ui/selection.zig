const std = @import("std");
const zgui = @import("zgui");
const colors = @import("colors.zig");

/// Generic selection state for grid-based items (clips, notes, etc.)
pub fn SelectionState(comptime IndexType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// Set of selected item indices
        selected: std.AutoArrayHashMapUnmanaged(IndexType, void),
        /// Primary selection for keyboard navigation (last clicked)
        primary: ?IndexType,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .selected = .{},
                .primary = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.selected.deinit(self.allocator);
        }

        pub fn clear(self: *Self) void {
            self.selected.clearRetainingCapacity();
            self.primary = null;
        }

        pub fn clearKeepPrimary(self: *Self) void {
            self.selected.clearRetainingCapacity();
        }

        pub fn contains(self: *const Self, index: IndexType) bool {
            return self.selected.contains(index);
        }

        pub fn count(self: *const Self) usize {
            return self.selected.count();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.selected.count() == 0;
        }

        pub fn add(self: *Self, index: IndexType) void {
            self.selected.put(self.allocator, index, {}) catch {};
            self.primary = index;
        }

        pub fn remove(self: *Self, index: IndexType) void {
            _ = self.selected.orderedRemove(index);
            if (self.primary == index) {
                self.primary = if (self.selected.count() > 0) self.selected.keys()[0] else null;
            }
        }

        pub fn toggle(self: *Self, index: IndexType) void {
            if (self.contains(index)) {
                self.remove(index);
            } else {
                self.add(index);
            }
        }

        pub fn selectOnly(self: *Self, index: IndexType) void {
            self.selected.clearRetainingCapacity();
            self.add(index);
        }

        pub fn keys(self: *const Self) []const IndexType {
            return self.selected.keys();
        }

        /// Handle click on an item with shift modifier support
        pub fn handleClick(self: *Self, index: IndexType, shift_held: bool) void {
            if (shift_held) {
                self.toggle(index);
            } else if (!self.contains(index)) {
                self.selectOnly(index);
            } else {
                // Already selected, just update primary for drag
                self.primary = index;
            }
        }
    };
}

/// State for drag-to-select rectangle
pub const DragSelectState = struct {
    active: bool = false,
    pending: bool = false,
    additive: bool = false, // Shift was held when starting
    start: [2]f32 = .{ 0, 0 },
    current: [2]f32 = .{ 0, 0 },

    pub fn reset(self: *DragSelectState) void {
        self.active = false;
        self.pending = false;
        self.additive = false;
    }

    pub fn begin(self: *DragSelectState, pos: [2]f32, shift_held: bool) void {
        self.pending = true;
        self.start = pos;
        self.current = pos;
        self.additive = shift_held;
    }

    pub fn update(self: *DragSelectState, pos: [2]f32) void {
        self.current = pos;
    }

    /// Check if drag threshold exceeded and activate
    pub fn checkThreshold(self: *DragSelectState, threshold: f32) bool {
        if (self.pending and !self.active) {
            const dx = self.current[0] - self.start[0];
            const dy = self.current[1] - self.start[1];
            if (@abs(dx) > threshold or @abs(dy) > threshold) {
                self.active = true;
                self.pending = false;
                return true;
            }
        }
        return false;
    }

    pub fn getRect(self: *const DragSelectState) struct { min: [2]f32, max: [2]f32 } {
        return .{
            .min = .{
                @min(self.start[0], self.current[0]),
                @min(self.start[1], self.current[1]),
            },
            .max = .{
                @max(self.start[0], self.current[0]),
                @max(self.start[1], self.current[1]),
            },
        };
    }

    /// Draw selection rectangle overlay
    pub fn draw(self: *const DragSelectState, draw_list: zgui.DrawList) void {
        if (!self.active) return;

        const rect = self.getRect();
        const fill_color = zgui.colorConvertFloat4ToU32(.{
            colors.Colors.current.selected[0],
            colors.Colors.current.selected[1],
            colors.Colors.current.selected[2],
            0.2,
        });
        const border_color = zgui.colorConvertFloat4ToU32(colors.Colors.current.selected);

        draw_list.addRectFilled(.{ .pmin = rect.min, .pmax = rect.max, .col = fill_color });
        draw_list.addRect(.{ .pmin = rect.min, .pmax = rect.max, .col = border_color, .thickness = 1.0 });
    }

    /// Check if a rectangle intersects with the selection rectangle
    pub fn intersects(self: *const DragSelectState, item_min: [2]f32, item_max: [2]f32) bool {
        const rect = self.getRect();
        return !(item_max[0] < rect.min[0] or item_min[0] > rect.max[0] or
            item_max[1] < rect.min[1] or item_min[1] > rect.max[1]);
    }
};

/// Helper to check if modifier key (Cmd/Ctrl) is pressed
pub fn isModifierDown() bool {
    return zgui.io.getKeySuper() or zgui.io.getKeyCtrl() or
        zgui.isKeyDown(.left_super) or zgui.isKeyDown(.right_super) or
        zgui.isKeyDown(.left_ctrl) or zgui.isKeyDown(.right_ctrl);
}

/// Helper to check if shift is pressed
pub fn isShiftDown() bool {
    return zgui.io.getKeyShift() or
        zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift);
}

/// Snap a value to a grid step
pub fn snapToStep(value: f32, step: f32) f32 {
    if (step <= 0) return value;
    return @floor(value / step) * step;
}

/// Sort indices in descending order for safe deletion
pub fn sortDescending(indices: []usize) void {
    std.mem.sort(usize, indices, {}, std.sort.desc(usize));
}
