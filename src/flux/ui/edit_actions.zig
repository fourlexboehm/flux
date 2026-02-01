const zgui = @import("zgui");

pub const MenuState = struct {
    has_selection: bool,
    can_paste: bool,
};

pub fn Actions(comptime Ctx: type) type {
    return struct {
        copy: ?*const fn (*Ctx) void = null,
        cut: ?*const fn (*Ctx) void = null,
        paste: ?*const fn (*Ctx) void = null,
        delete: ?*const fn (*Ctx) void = null,
        select_all: ?*const fn (*Ctx) void = null,
    };
}

fn callIf(comptime Ctx: type, ctx: *Ctx, action: ?*const fn (*Ctx) void) void {
    if (action) |func| {
        func(ctx);
    }
}

pub fn handleShortcuts(
    ctx: anytype,
    modifier_down: bool,
    state: MenuState,
    actions: Actions(@TypeOf(ctx.*)),
) void {
    const Ctx = @TypeOf(ctx.*);

    if (modifier_down and zgui.isKeyPressed(.c, false) and state.has_selection) {
        callIf(Ctx, ctx, actions.copy);
    }

    if (modifier_down and zgui.isKeyPressed(.x, false) and state.has_selection) {
        callIf(Ctx, ctx, actions.cut);
    }

    if (modifier_down and zgui.isKeyPressed(.v, false) and state.can_paste) {
        callIf(Ctx, ctx, actions.paste);
    }

    if (zgui.isKeyPressed(.delete, false) or zgui.isKeyPressed(.back_space, false)) {
        if (state.has_selection) {
            callIf(Ctx, ctx, actions.delete);
        }
    }

    if (modifier_down and zgui.isKeyPressed(.a, false)) {
        callIf(Ctx, ctx, actions.select_all);
    }
}

pub fn drawMenu(
    ctx: anytype,
    state: MenuState,
    actions: Actions(@TypeOf(ctx.*)),
) void {
    const Ctx = @TypeOf(ctx.*);

    if (actions.copy != null and zgui.menuItem("Copy", .{ .shortcut = "Cmd/Ctrl+C", .enabled = state.has_selection })) {
        callIf(Ctx, ctx, actions.copy);
    }
    if (actions.cut != null and zgui.menuItem("Cut", .{ .shortcut = "Cmd/Ctrl+X", .enabled = state.has_selection })) {
        callIf(Ctx, ctx, actions.cut);
    }
    if (actions.paste != null and zgui.menuItem("Paste", .{ .shortcut = "Cmd/Ctrl+V", .enabled = state.can_paste })) {
        callIf(Ctx, ctx, actions.paste);
    }
    if (actions.delete != null and zgui.menuItem("Delete", .{ .shortcut = "Del", .enabled = state.has_selection })) {
        callIf(Ctx, ctx, actions.delete);
    }

    if (actions.select_all != null) {
        zgui.separator();
        if (zgui.menuItem("Select All", .{ .shortcut = "Cmd/Ctrl+A" })) {
            callIf(Ctx, ctx, actions.select_all);
        }
    }
}
