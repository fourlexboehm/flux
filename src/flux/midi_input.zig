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

    // Protects streams[] and stream_count. The background rescan thread holds
    // this while opening/closing streams; poll() uses tryLock so it skips one
    // frame rather than blocking if the rescan is in progress.
    mutex: std.atomic.Mutex = .unlocked,
    streams: [max_streams]?*pm.Stream = [_]?*pm.Stream{null} ** max_streams,
    stream_count: usize = 0,

    // Background thread drives the slow Pm_Terminate/Pm_Initialize cycle that
    // is required on macOS to discover newly connected/disconnected devices.
    rescan_thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Set by poll() when a read error is detected (device disconnected).
    // Causes the rescan thread to wake up early instead of waiting 2 seconds.
    error_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    note_on_hold_polls: [128]u8 = [_]u8{0} ** 128,
    note_off_pending: [128]bool = [_]bool{false} ** 128,

    fn sleepMs(ms: u64) void {
        const ns = ms * std.time.ns_per_ms;
        var ts: std.c.timespec = .{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        _ = std.c.nanosleep(&ts, &ts);
    }

    // Blocking lock: spin-sleep until the mutex is available.
    // Only used from the background thread; poll() uses tryLock exclusively.
    fn lockBlocking(self: *PortMidiInput) void {
        while (!self.mutex.tryLock()) {
            sleepMs(1);
        }
    }

    pub fn init(self: *PortMidiInput, _: std.mem.Allocator) !void {
        pm.initialize();
        self.lockBlocking();
        self.openAllInputsLocked();
        self.mutex.unlock();
        self.rescan_thread = try std.Thread.spawn(.{}, rescanThread, .{self});
    }

    pub fn deinit(self: *PortMidiInput) void {
        self.stop_flag.store(true, .release);
        if (self.rescan_thread) |t| t.join();
        self.rescan_thread = null;
        self.lockBlocking();
        self.closeAllInputsLocked();
        self.mutex.unlock();
        pm.terminate();
    }

    // Background thread: periodically cycles Pm_Terminate/Pm_Initialize to let
    // PortMIDI discover device changes (required on macOS – countDevices() is
    // static between init/terminate calls and CFRunLoopRunInMode can take up to
    // several seconds, so we must not call this from the main thread).
    fn rescanThread(self: *PortMidiInput) void {
        while (!self.stop_flag.load(.acquire)) {
            // Sleep up to 2 seconds in 10 ms increments, waking early on error.
            var i: u32 = 0;
            while (i < 200) : (i += 1) {
                if (self.stop_flag.load(.acquire)) return;
                if (self.error_flag.load(.acquire)) break;
                sleepMs(10);
            }
            if (self.stop_flag.load(.acquire)) return;

            const has_error = self.error_flag.swap(false, .acq_rel);

            // Skip rescan when streams are healthy – only act on errors or when
            // no device is open (initial connect / reconnect after disconnect).
            self.lockBlocking();
            const stream_count = self.stream_count;
            self.mutex.unlock();
            if (!has_error and stream_count > 0) continue;

            // Close existing streams under the mutex so poll() sees a
            // consistent (empty) stream list during the slow reinitialisation.
            self.lockBlocking();
            self.closeAllInputsLocked();
            self.mutex.unlock();

            // Terminate + Initialize outside the mutex: this is the slow part
            // (CFRunLoopRunInMode on macOS, 20 ms – several seconds). poll()
            // will see stream_count == 0 and skip cleanly during this window.
            pm.terminate();
            pm.initialize();

            self.lockBlocking();
            self.openAllInputsLocked();
            self.mutex.unlock();
        }
    }

    pub fn poll(self: *PortMidiInput, notes: *[128]bool, velocities: *[128]f32, event_queue: *EventQueue) void {
        // Non-blocking: skip this frame if the rescan thread is manipulating streams.
        if (!self.mutex.tryLock()) return;
        defer self.mutex.unlock();

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
            self.clearInputState(notes, velocities);
            self.closeAllInputsLocked();
            // Wake the rescan thread immediately to cycle terminate/initialize.
            self.error_flag.store(true, .release);
            return;
        }

        self.flushDeferredNoteOffs(notes, velocities);
    }

    fn openAllInputsLocked(self: *PortMidiInput) void {
        self.stream_count = 0;
        const count = pm.countDevices();
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

    fn closeAllInputsLocked(self: *PortMidiInput) void {
        for (0..self.stream_count) |idx| {
            const stream = self.streams[idx];
            if (stream) |s| {
                _ = pm.close(s) catch {};
            }
            self.streams[idx] = null;
        }
        self.stream_count = 0;
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
