//! Shared clip pool.
//!
//! A `Clip` (MIDI notes or an audio sample reference, plus its intrinsic
//! length) lives here exactly once and is identified by a stable `ClipId`
//! handle. The session grid and arrangement timeline hold lightweight
//! *placements* that reference a clip by handle — they never own content.
//!
//! `ClipId` is a generational handle so that a slot freed and later reused
//! does not silently alias a stale reference held elsewhere (e.g. in an undo
//! record): the freed slot's generation is bumped, so the old handle fails
//! validation instead of resolving to the new occupant.
//!
//! Nothing wires this into the runtime yet.

const std = @import("std");
const notes = @import("notes.zig");
const audio_clip = @import("audio_clip.zig");
const types = @import("types.zig");

const PianoRollClip = notes.PianoRollClip;
const AudioClip = audio_clip.AudioClip;
const NameField = types.NameField;
const SampleStore = @import("../audio/sample_store.zig").SampleStore;

/// Stable, generation-checked handle to a `Clip` in a `ClipPool`.
pub const ClipId = struct {
    index: u32,
    generation: u32,

    /// Sentinel "no clip" handle. `index` is out of any pool's range, so it
    /// resolves to null through the normal `get`/`retain`/`release` paths.
    pub const none: ClipId = .{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn eql(a: ClipId, b: ClipId) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    pub fn isNone(self: ClipId) bool {
        return self.index == std.math.maxInt(u32);
    }
};

pub const ClipKind = enum { midi, audio };

/// A clip owns its content and intrinsic length; placements own position.
pub const ClipContent = union(ClipKind) {
    midi: PianoRollClip,
    audio: AudioClip,
};

pub const Clip = struct {
    content: ClipContent,
    name: NameField = .{},
    /// Packed RGBA (0 == "unset"); resolved to a default at draw time.
    color: u32 = 0,
    /// Number of placements referencing this clip. 0 => collectable.
    refcount: u32 = 0,

    /// Intrinsic content length; the source of truth lives in the content.
    pub fn lengthBeats(self: *const Clip) f32 {
        return switch (self.content) {
            .midi => |*m| m.length_beats,
            .audio => |*a| a.length_beats,
        };
    }

    fn deinitContent(self: *Clip, store: ?*SampleStore) void {
        switch (self.content) {
            .midi => |*m| m.deinit(),
            .audio => |*a| a.deinit(store),
        }
    }
};

const Entry = struct {
    /// Bumped on free so stale `ClipId`s pointing at this slot invalidate.
    generation: u32 = 0,
    /// null => slot is free and available for reuse via `free_list`.
    clip: ?Clip = null,
};

pub const ClipPool = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    free_list: std.ArrayListUnmanaged(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) ClipPool {
        return .{ .allocator = allocator };
    }

    /// `store` frees any sample references held by audio clips still resident.
    pub fn deinit(self: *ClipPool, store: ?*SampleStore) void {
        for (self.entries.items) |*e| {
            if (e.clip) |*c| c.deinitContent(store);
        }
        self.entries.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
    }

    /// Insert a clip, reusing a free slot when available. The returned handle
    /// starts at refcount 0; callers `retain` it when creating a placement.
    pub fn add(self: *ClipPool, clip: Clip) !ClipId {
        if (self.free_list.pop()) |idx| {
            const e = &self.entries.items[idx];
            e.clip = clip;
            return .{ .index = idx, .generation = e.generation };
        }
        const idx: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, .{ .generation = 0, .clip = clip });
        return .{ .index = idx, .generation = 0 };
    }

    /// Convenience: insert a fresh MIDI clip. Refcount starts at 0.
    pub fn addMidi(self: *ClipPool, clip: PianoRollClip) !ClipId {
        return self.add(.{ .content = .{ .midi = clip } });
    }

    /// Convenience: insert a fresh audio clip. Refcount starts at 0.
    pub fn addAudio(self: *ClipPool, clip: AudioClip) !ClipId {
        return self.add(.{ .content = .{ .audio = clip } });
    }

    /// Deep-copy a clip's content into a new pool entry ("Make Unique" /
    /// clipboard). The copy starts at refcount 0. Returns `.none` if the
    /// source handle is stale or the copy fails. `store` is required for
    /// audio clips (to retain the shared sample).
    pub fn dupe(self: *ClipPool, id: ClipId, store: ?*SampleStore) ClipId {
        const src = self.get(id) orelse return .none;
        const name = src.name;
        const color = src.color;
        var new_content: ClipContent = undefined;
        switch (src.content) {
            .midi => |*m| {
                var dst = PianoRollClip.init(self.allocator);
                dst.copyFromFallible(m) catch {
                    dst.deinit();
                    return .none;
                };
                new_content = .{ .midi = dst };
            },
            .audio => |*a| {
                const s = store orelse return .none;
                var dst = AudioClip.init(self.allocator);
                a.copyTo(&dst, s) catch {
                    dst.deinit(s);
                    return .none;
                };
                new_content = .{ .audio = dst };
            },
        }
        // `src` may be invalidated by the append below; do not touch it after.
        return self.add(.{ .content = new_content, .name = name, .color = color }) catch {
            switch (new_content) {
                .midi => |*m| m.deinit(),
                .audio => |*a| a.deinit(store),
            }
            return .none;
        };
    }

    fn entryFor(self: *ClipPool, id: ClipId) ?*Entry {
        if (id.index >= self.entries.items.len) return null;
        const e = &self.entries.items[id.index];
        if (e.generation != id.generation) return null;
        if (e.clip == null) return null;
        return e;
    }

    /// Resolve a handle to its clip, or null if the handle is stale/freed.
    pub fn get(self: *ClipPool, id: ClipId) ?*Clip {
        const e = self.entryFor(id) orelse return null;
        return &e.clip.?;
    }

    /// Const view of `get`, for read-only callers (e.g. project save).
    pub fn getConst(self: *const ClipPool, id: ClipId) ?*const Clip {
        if (id.index >= self.entries.items.len) return null;
        const e = &self.entries.items[id.index];
        if (e.generation != id.generation) return null;
        if (e.clip == null) return null;
        return &e.clip.?;
    }

    /// Record a new placement referencing this clip.
    pub fn retain(self: *ClipPool, id: ClipId) void {
        if (self.entryFor(id)) |e| e.clip.?.refcount += 1;
    }

    /// Drop a placement's reference; frees the clip when the last one goes.
    pub fn release(self: *ClipPool, id: ClipId, store: ?*SampleStore) void {
        const e = self.entryFor(id) orelse return;
        std.debug.assert(e.clip.?.refcount > 0);
        e.clip.?.refcount -= 1;
        if (e.clip.?.refcount == 0) self.freeEntry(id.index, store);
    }

    fn freeEntry(self: *ClipPool, idx: u32, store: ?*SampleStore) void {
        const e = &self.entries.items[idx];
        if (e.clip) |*c| c.deinitContent(store);
        e.clip = null;
        e.generation +%= 1;
        // If recording the free slot fails, the slot is simply not reused —
        // its generation is already bumped, so no stale handle can alias it.
        self.free_list.append(self.allocator, idx) catch {};
    }

    /// Count of live (occupied) clips; for tests and diagnostics.
    pub fn liveCount(self: *const ClipPool) usize {
        var n: usize = 0;
        for (self.entries.items) |*e| {
            if (e.clip != null) n += 1;
        }
        return n;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn testMidiClip(allocator: std.mem.Allocator) Clip {
    return .{ .content = .{ .midi = PianoRollClip.init(allocator) } };
}

test "add then get resolves to the same clip" {
    var pool = ClipPool.init(testing.allocator);
    defer pool.deinit(null);

    const id = try pool.add(testMidiClip(testing.allocator));
    const clip = pool.get(id) orelse return error.Unexpected;
    try testing.expect(clip.content == .midi);
    try testing.expectEqual(@as(u32, 0), clip.refcount);
    try testing.expectEqual(@as(usize, 1), pool.liveCount());
}

test "retain/release governs lifetime and frees on last release" {
    var pool = ClipPool.init(testing.allocator);
    defer pool.deinit(null);

    const id = try pool.add(testMidiClip(testing.allocator));
    pool.retain(id);
    pool.retain(id);
    try testing.expectEqual(@as(u32, 2), pool.get(id).?.refcount);

    pool.release(id, null);
    try testing.expect(pool.get(id) != null); // still one placement
    pool.release(id, null);
    try testing.expect(pool.get(id) == null); // last placement gone → freed
    try testing.expectEqual(@as(usize, 0), pool.liveCount());
}

test "freed handle is invalidated by generation bump after reuse" {
    var pool = ClipPool.init(testing.allocator);
    defer pool.deinit(null);

    const first = try pool.add(testMidiClip(testing.allocator));
    pool.retain(first);
    pool.release(first, null); // frees slot 0, bumps its generation

    // Reuse should recycle slot 0 with a higher generation.
    const second = try pool.add(testMidiClip(testing.allocator));
    try testing.expectEqual(first.index, second.index);
    try testing.expect(first.generation != second.generation);

    // The stale handle must not resolve to the new occupant.
    try testing.expect(pool.get(first) == null);
    try testing.expect(pool.get(second) != null);
}

test "out-of-range handle resolves to null" {
    var pool = ClipPool.init(testing.allocator);
    defer pool.deinit(null);
    try testing.expect(pool.get(.{ .index = 99, .generation = 0 }) == null);
}

test "none sentinel resolves to null and is inert" {
    var pool = ClipPool.init(testing.allocator);
    defer pool.deinit(null);
    try testing.expect(ClipId.none.isNone());
    try testing.expect(pool.get(ClipId.none) == null);
    pool.retain(ClipId.none); // no-op, must not crash
    pool.release(ClipId.none, null); // no-op, must not crash
    try testing.expectEqual(@as(usize, 0), pool.liveCount());
}

test "dupe makes an independent copy of MIDI content" {
    var pool = ClipPool.init(testing.allocator);
    defer pool.deinit(null);

    const src = try pool.add(testMidiClip(testing.allocator));
    pool.retain(src);
    pool.get(src).?.content.midi.addNote(60, 0, 1) catch unreachable;
    pool.get(src).?.name.set("orig");

    const copy = pool.dupe(src, null);
    try testing.expect(!copy.isNone());
    try testing.expect(!copy.eql(src));
    pool.retain(copy);

    // Same content, independent storage.
    try testing.expectEqual(@as(usize, 1), pool.get(copy).?.content.midi.notes.items.len);
    try testing.expectEqualStrings("orig", pool.get(copy).?.name.get());

    // Editing the copy must not touch the source.
    pool.get(copy).?.content.midi.addNote(64, 1, 1) catch unreachable;
    try testing.expectEqual(@as(usize, 1), pool.get(src).?.content.midi.notes.items.len);
    try testing.expectEqual(@as(usize, 2), pool.get(copy).?.content.midi.notes.items.len);

    pool.release(src, null);
    pool.release(copy, null);
    try testing.expectEqual(@as(usize, 0), pool.liveCount());
}
