const builtin = @import("builtin");
const std = @import("std");
const pm = @import("portmidi");
const sleep_io: std.Io = std.Io.Threaded.global_single_threaded.ioBasic();

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

pub const MidiInput = struct {
    note_states: [128]bool = [_]bool{false} ** 128,
    note_velocities: [128]f32 = [_]f32{0.0} ** 128,
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
        self.impl.poll(&self.note_states, &self.note_velocities);
    }
};

const Impl = switch (builtin.os.tag) {
    .macos, .linux => PortMidiInput,
    else => NoopInput,
};

const NoopInput = struct {
    pub fn init(_: *NoopInput, _: std.mem.Allocator) !void {}
    pub fn deinit(_: *NoopInput) void {}
    pub fn poll(_: *NoopInput, _: *[128]bool, _: *[128]f32) void {}
};

const PortMidiInput = struct {
    const max_streams = 64;
    const short_note_hold_polls: u8 = 2;
    const capture_sleep_ns: u64 = 1_000_000; // 1ms
    const rescan_interval_loops: u32 = 500;

    streams: [max_streams]?*pm.Stream = [_]?*pm.Stream{null} ** max_streams,
    stream_count: usize = 0,
    device_count: i32 = 0,
    note_on_hold_polls: [128]u8 = [_]u8{0} ** 128,
    note_off_pending: [128]bool = [_]bool{false} ** 128,
    event_queue: EventQueue = .{},
    reset_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    capture_thread: ?std.Thread = null,

    pub fn init(self: *PortMidiInput, _: std.mem.Allocator) !void {
        pm.initialize();
        errdefer pm.terminate();

        self.openAllInputs();
        errdefer self.closeAllInputs();

        self.running.store(true, .release);
        self.capture_thread = try std.Thread.spawn(.{}, captureMain, .{self});
    }

    pub fn deinit(self: *PortMidiInput) void {
        self.running.store(false, .release);
        if (self.capture_thread) |thread| {
            thread.join();
            self.capture_thread = null;
        }
        self.closeAllInputs();
        pm.terminate();
    }

    pub fn poll(self: *PortMidiInput, notes: *[128]bool, velocities: *[128]f32) void {
        if (self.reset_requested.swap(false, .acq_rel)) {
            self.clearInputState(notes, velocities);
        }

        while (self.event_queue.pop()) |event| {
            self.applyMidiMessage(notes, velocities, event.status, event.data1, event.data2);
        }

        self.flushDeferredNoteOffs(notes, velocities);
    }

    fn captureMain(self: *PortMidiInput) void {
        applyCaptureThreadQosHint();

        var rescan_counter: u32 = 0;
        var event: pm.Event = undefined;
        while (self.running.load(.acquire)) {
            var need_reopen = false;
            var had_event = false;

            rescan_counter +%= 1;
            if (rescan_counter >= rescan_interval_loops) {
                rescan_counter = 0;
                const count = pm.countDevices();
                if (count != self.device_count or (count > 0 and self.stream_count == 0)) {
                    self.reopenInputs();
                }
            }

            for (self.streams[0..self.stream_count]) |stream| {
                if (stream == null) continue;
                while (true) {
                    const read_count = pm.read(stream.?, &event, 1) catch {
                        need_reopen = true;
                        break;
                    };
                    if (read_count <= 0) break;
                    had_event = true;
                    const msg = event.message;
                    self.event_queue.push(.{
                        .status = pm.messageStatus(msg),
                        .data1 = pm.messageData1(msg),
                        .data2 = pm.messageData2(msg),
                    });
                }
                if (need_reopen) break;
            }

            if (need_reopen) {
                self.reopenInputs();
                continue;
            }

            if (!had_event) {
                _ = sleep_io.sleep(std.Io.Duration.fromNanoseconds(capture_sleep_ns), .awake) catch {};
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
        for (0..self.stream_count) |idx| {
            const stream = self.streams[idx];
            if (stream) |s| {
                _ = pm.close(s) catch {};
            }
            self.streams[idx] = null;
        }
        self.stream_count = 0;
    }

    fn reopenInputs(self: *PortMidiInput) void {
        self.reset_requested.store(true, .release);
        self.closeAllInputs();
        self.openAllInputs();
    }

    fn clearInputState(self: *PortMidiInput, notes: *[128]bool, velocities: *[128]f32) void {
        notes.* = [_]bool{false} ** 128;
        velocities.* = [_]f32{0.0} ** 128;
        self.note_on_hold_polls = [_]u8{0} ** 128;
        self.note_off_pending = [_]bool{false} ** 128;
    }

    fn applyMidiMessage(self: *PortMidiInput, notes: *[128]bool, velocities: *[128]f32, status: u8, data1: u8, data2: u8) void {
        const msg = status & 0xF0;
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

    fn applyCaptureThreadQosHint() void {
        if (builtin.os.tag != .macos) return;
        _ = std.c.pthread_set_qos_class_self_np(std.c.qos_class_t.USER_INITIATED, 0);
    }
};
