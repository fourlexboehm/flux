const builtin = @import("builtin");
const std = @import("std");
const pm = @import("portmidi");

pub const MidiEvent = struct {
    status: u8,
    data1: u8,
    data2: u8,

    pub fn message(self: MidiEvent) u8 {
        return self.status & 0xF0;
    }

    pub fn channel(self: MidiEvent) u8 {
        return self.status & 0x0F;
    }
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

fn applyNoteEvent(notes: *[128]bool, velocities: *[128]f32, event: MidiEvent) void {
    const msg = event.status & 0xF0;
    const note = event.data1;
    if (note >= 128) return;
    switch (msg) {
        0x90 => {
            if (event.data2 == 0) {
                notes[note] = false;
                velocities[note] = 0.0;
            } else {
                notes[note] = true;
                velocities[note] = @as(f32, @floatFromInt(event.data2)) / 127.0;
            }
        },
        0x80 => {
            notes[note] = false;
            velocities[note] = 0.0;
        },
        else => {},
    }
}

pub const MidiInput = struct {
    note_states: [128]bool = [_]bool{false} ** 128,
    note_velocities: [128]f32 = [_]f32{0.0} ** 128,
    event_queue: EventQueue = .{},
    impl: Impl = undefined,
    active: bool = false,

    pub fn init(self: *MidiInput, allocator: std.mem.Allocator) !void {
        self.note_states = [_]bool{false} ** 128;
        self.note_velocities = [_]f32{0.0} ** 128;
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
        self.impl.poll(&self.note_states, &self.note_velocities, &self.event_queue);
    }

    pub fn drainEvents(self: *MidiInput, out: []MidiEvent) usize {
        var count: usize = 0;
        while (count < out.len) : (count += 1) {
            const ev = self.event_queue.pop() orelse break;
            out[count] = ev;
        }
        return count;
    }
};

const Impl = switch (builtin.os.tag) {
    .macos, .linux => PortMidiInput,
    else => NoopInput,
};

const NoopInput = struct {
    pub fn init(_: *NoopInput, _: std.mem.Allocator) !void {}
    pub fn deinit(_: *NoopInput) void {}
    pub fn poll(_: *NoopInput, _: *[128]bool, _: *[128]f32, _: *EventQueue) void {}
};

const PortMidiInput = struct {
    const max_streams = 64;
    const short_note_hold_polls: u8 = 2;

    streams: [max_streams]?*pm.Stream = [_]?*pm.Stream{null} ** max_streams,
    stream_count: usize = 0,
    device_count: i32 = 0,
    rescan_counter: u32 = 0,
    rescan_interval: u32 = 120,
    note_on_hold_polls: [128]u8 = [_]u8{0} ** 128,
    note_off_pending: [128]bool = [_]bool{false} ** 128,

    pub fn init(self: *PortMidiInput, _: std.mem.Allocator) !void {
        pm.initialize();
        self.openAllInputs();
    }

    pub fn deinit(self: *PortMidiInput) void {
        self.closeAllInputs();
        pm.terminate();
    }

    pub fn poll(self: *PortMidiInput, notes: *[128]bool, velocities: *[128]f32, event_queue: *EventQueue) void {
        self.rescan_counter +%= 1;
        if (self.rescan_counter >= self.rescan_interval) {
            self.rescan_counter = 0;
            const count = pm.countDevices();
            if (count != self.device_count or (count > 0 and self.stream_count == 0)) {
                self.reopenInputs(notes, velocities);
            }
        }

        var need_reopen = false;
        var event: pm.Event = undefined;
        for (self.streams[0..self.stream_count]) |stream| {
            if (stream == null) continue;
            while (true) {
                const read_count = pm.read(stream.?, &event, 1) catch {
                    need_reopen = true;
                    break;
                };
                if (read_count <= 0) break;
                const msg = event.message;
                const status = pm.messageStatus(msg);
                const data1 = pm.messageData1(msg);
                const data2 = pm.messageData2(msg);
                self.applyMidiMessage(notes, velocities, event_queue, status, data1, data2);
            }
            if (need_reopen) break;
        }

        if (need_reopen) {
            self.reopenInputs(notes, velocities);
            return;
        }

        self.flushDeferredNoteOffs(notes, velocities);
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
        for (0..self.stream_count) |idx| {
            const stream = self.streams[idx];
            if (stream) |s| {
                _ = pm.close(s) catch {};
            }
            self.streams[idx] = null;
        }
        self.stream_count = 0;
    }

    fn reopenInputs(self: *PortMidiInput, notes: *[128]bool, velocities: *[128]f32) void {
        self.clearInputState(notes, velocities);
        self.closeAllInputs();
        self.openAllInputs();
    }

    fn clearInputState(self: *PortMidiInput, notes: *[128]bool, velocities: *[128]f32) void {
        notes.* = [_]bool{false} ** 128;
        velocities.* = [_]f32{0.0} ** 128;
        self.note_on_hold_polls = [_]u8{0} ** 128;
        self.note_off_pending = [_]bool{false} ** 128;
    }

    fn applyMidiMessage(
        self: *PortMidiInput,
        notes: *[128]bool,
        velocities: *[128]f32,
        event_queue: *EventQueue,
        status: u8,
        data1: u8,
        data2: u8,
    ) void {
        const msg = status & 0xF0;
        // Keep a raw event feed for controller mapping and transport.
        if (msg == 0x90 or msg == 0x80 or msg == 0xB0 or msg == 0xC0 or msg == 0xE0) {
            event_queue.push(.{
                .status = status,
                .data1 = data1,
                .data2 = data2,
            });
        }
        if (data1 >= 128) return;
        const note: usize = data1;
        switch (msg) {
            0x90 => {
                if (data2 == 0) {
                    self.queueNoteOff(notes, velocities, note);
                } else {
                    notes[note] = true;
                    velocities[note] = @as(f32, @floatFromInt(data2)) / 127.0;
                    self.note_on_hold_polls[note] = short_note_hold_polls;
                    self.note_off_pending[note] = false;
                }
            },
            0x80 => self.queueNoteOff(notes, velocities, note),
            else => {},
        }
    }

    fn queueNoteOff(self: *PortMidiInput, notes: *[128]bool, velocities: *[128]f32, note: usize) void {
        if (self.note_on_hold_polls[note] > 0) {
            self.note_off_pending[note] = true;
            return;
        }
        notes[note] = false;
        velocities[note] = 0.0;
        self.note_off_pending[note] = false;
    }

    fn flushDeferredNoteOffs(self: *PortMidiInput, notes: *[128]bool, velocities: *[128]f32) void {
        for (0..128) |note| {
            if (self.note_on_hold_polls[note] > 0) {
                self.note_on_hold_polls[note] -= 1;
                notes[note] = true;
                continue;
            }
            if (self.note_off_pending[note]) {
                notes[note] = false;
                velocities[note] = 0.0;
                self.note_off_pending[note] = false;
            }
        }
    }
};
