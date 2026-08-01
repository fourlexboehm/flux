//! Main content pane: session grid or arrangement timeline.

const dvui = @import("dvui");
const state_mod = @import("../state.zig");
const session = @import("session.zig");
const arrangement = @import("arrangement.zig");

pub fn draw(state: *state_mod.State) void {
    var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 3, .y = 0, .w = 2, .h = 0 },
    });
    defer wrap.deinit();

    switch (state.view_mode) {
        .session => session.draw(state),
        .arrangement => arrangement.draw(state),
    }
}
