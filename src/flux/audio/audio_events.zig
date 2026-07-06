const clap = @import("clap-bindings");

pub const max_input_events = 256;

pub const EventList = struct {
    const max_event_size = @max(@sizeOf(clap.events.Note), @sizeOf(clap.events.ParamValue));
    const max_event_align = @max(@alignOf(clap.events.Note), @alignOf(clap.events.ParamValue));

    const EventStorage = struct {
        data: [max_event_size]u8 align(max_event_align) = undefined,
    };

    events: [max_input_events]EventStorage = undefined,
    count: u32 = 0,

    pub fn reset(self: *EventList) void {
        self.count = 0;
    }

    pub fn pushNote(self: *EventList, event: clap.events.Note) void {
        if (self.count >= max_input_events) return;
        const bytes = @import("std").mem.asBytes(&event);
        @memcpy(self.events[self.count].data[0..bytes.len], bytes);
        self.count += 1;
    }

    pub fn pushParam(self: *EventList, event: clap.events.ParamValue) void {
        if (self.count >= max_input_events) return;
        const bytes = @import("std").mem.asBytes(&event);
        @memcpy(self.events[self.count].data[0..bytes.len], bytes);
        self.count += 1;
    }
};

pub fn inputEventsSize(list: *const clap.events.InputEvents) callconv(.c) u32 {
    const ctx: *const EventList = @ptrCast(@alignCast(list.context));
    return ctx.count;
}

pub fn inputEventsGet(list: *const clap.events.InputEvents, index: u32) callconv(.c) *const clap.events.Header {
    const ctx: *const EventList = @ptrCast(@alignCast(list.context));
    return @ptrCast(@alignCast(&ctx.events[index].data));
}

pub const OutputEventList = struct {
    events: [max_input_events]clap.events.Note = undefined,
    count: u32 = 0,
};

pub fn outputEventsTryPush(list: *const clap.events.OutputEvents, event: *const clap.events.Header) callconv(.c) bool {
    const ctx: *OutputEventList = @ptrCast(@alignCast(list.context));
    if (ctx.count >= max_input_events) return true;

    switch (event.type) {
        .note_on, .note_off, .note_end, .note_choke => {
            const note: *const clap.events.Note = @ptrCast(@alignCast(event));
            ctx.events[ctx.count] = note.*;
            ctx.count += 1;
        },
        else => {},
    }
    return true;
}

pub fn emptyInputEvents(event_list: *const EventList) clap.events.InputEvents {
    return .{
        .context = @constCast(event_list),
        .size = inputEventsSize,
        .get = inputEventsGet,
    };
}
