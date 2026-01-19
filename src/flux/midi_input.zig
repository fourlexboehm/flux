const builtin = @import("builtin");
const std = @import("std");
const pm = @import("portmidi");

const MidiEvent = struct {
    status: u8,
    data1: u8,
    data2: u8,
};

const EventQueue = struct {
    const capacity: u32 = 1024;
    const mask: u32 = capacity - 1;

    buffer: [capacity]MidiEvent = undefined,
    write: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    read: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn push(self: *EventQueue, event: MidiEvent) void {
        const write = self.write.load(.monotonic);
        const read = self.read.load(.acquire);
        if (write -% read >= capacity) {
            return;
        }
        self.buffer[write & mask] = event;
        self.write.store(write +% 1, .release);
    }

    fn pop(self: *EventQueue) ?MidiEvent {
        const read = self.read.load(.monotonic);
        const write = self.write.load(.acquire);
        if (read == write) {
            return null;
        }
        const event = self.buffer[read & mask];
        self.read.store(read +% 1, .release);
        return event;
    }
};

fn applyNoteEvent(notes: *[128]bool, event: MidiEvent) void {
    const msg = event.status & 0xF0;
    const note = event.data1;
    if (note >= 128) return;
    switch (msg) {
        0x90 => {
            if (event.data2 == 0) {
                notes[note] = false;
            } else {
                notes[note] = true;
            }
        },
        0x80 => notes[note] = false,
        else => {},
    }
}

pub const MidiInput = struct {
    note_states: [128]bool = [_]bool{false} ** 128,
    impl: Impl = undefined,
    active: bool = false,

    pub fn init(self: *MidiInput, allocator: std.mem.Allocator) !void {
        self.note_states = [_]bool{false} ** 128;
        self.impl = .{};
        errdefer self.impl.deinit();
        try self.impl.init(allocator);
        self.active = true;
    }

    pub fn disable(self: *MidiInput) void {
        self.active = false;
    }

    pub fn deinit(self: *MidiInput) void {
        if (self.active) {
            self.impl.deinit();
        }
    }

    pub fn poll(self: *MidiInput) void {
        if (!self.active) return;
        self.impl.poll(&self.note_states);
    }
};

const Impl = switch (builtin.os.tag) {
    .macos, .linux => PortMidiInput,
    else => NoopInput,
};

const NoopInput = struct {
    pub fn init(_: *NoopInput, _: std.mem.Allocator) !void {}
    pub fn deinit(_: *NoopInput) void {}
    pub fn poll(_: *NoopInput, _: *[128]bool) void {}
};

const PortMidiInput = struct {
    const max_streams = 64;

    streams: [max_streams]?*pm.Stream = [_]?*pm.Stream{null} ** max_streams,
    stream_count: usize = 0,
    device_count: i32 = 0,
    rescan_counter: u32 = 0,
    rescan_interval: u32 = 120,

    pub fn init(self: *PortMidiInput, _: std.mem.Allocator) !void {
        pm.initialize();
        self.openAllInputs();
    }

    pub fn deinit(self: *PortMidiInput) void {
        self.closeAllInputs();
        pm.terminate();
    }

    pub fn poll(self: *PortMidiInput, notes: *[128]bool) void {
        self.rescan_counter +%= 1;
        if (self.rescan_counter >= self.rescan_interval) {
            self.rescan_counter = 0;
            const count = pm.countDevices();
            if (count != self.device_count) {
                self.closeAllInputs();
                self.openAllInputs();
            }
        }

        var event: pm.Event = undefined;
        for (self.streams[0..self.stream_count]) |stream| {
            if (stream == null) continue;
            while (true) {
                const read_count = pm.read(stream.?, &event, 1) catch break;
                if (read_count <= 0) break;
                const msg = event.message;
                const status = pm.messageStatus(msg);
                const data1 = pm.messageData1(msg);
                const data2 = pm.messageData2(msg);
                applyNoteEvent(notes, .{ .status = status, .data1 = data1, .data2 = data2 });
            }
        }
    }

    fn openAllInputs(self: *PortMidiInput) void {
        self.stream_count = 0;
        const count = pm.countDevices();
        self.device_count = count;
        if (count <= 0) return;

        const filters = pm.filter.sysex | pm.filter.active_sensing | pm.filter.tick;

        var id: i32 = 0;
        while (id < count) : (id += 1) {
            const info = pm.getDeviceInfo(@intCast(id)) orelse continue;
            if (!info.input) continue;
            if (self.stream_count >= self.streams.len) break;
            var stream: ?*pm.Stream = null;
            pm.openInput(&stream, @intCast(id), null, 1024, null, null) catch continue;
            if (stream == null) continue;
            _ = pm.setFilter(stream.?, filters) catch {};
            self.streams[self.stream_count] = stream.?;
            self.stream_count += 1;
        }
    }

    fn closeAllInputs(self: *PortMidiInput) void {
        for (self.streams[0..self.stream_count]) |stream| {
            if (stream) |s| {
                _ = pm.close(s) catch {};
            }
        }
        self.stream_count = 0;
    }
};
