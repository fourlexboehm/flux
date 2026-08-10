//! UI-neutral ownership and borrowed view of the editable Flux document.
//!
//! `Store` owns all durable document-domain storage. UI and audio layers only
//! retain a pointer to the store or consume the lightweight `Model` view.

const std = @import("std");
const session_types = @import("../session/types.zig");
const session_ops = @import("../session/ops.zig");
const clip_pool = @import("../session/clip_pool.zig");
const sample_store = @import("../audio/sample_store.zig");
const arrangement = @import("../arrangement/types.zig");
const midi_history = @import("midi_history.zig");
const undo = @import("../undo/root.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    session: session_types.SessionView,
    arrangement: arrangement.ArrangementView,
    clip_pool: clip_pool.ClipPool,
    sample_store: sample_store.SampleStore,
    /// Gesture capture for piano-roll (pending only); stack lives in `undo_history`.
    midi_history: midi_history.History,
    /// Global document undo/redo (session, arrangement, mixer, MIDI notes).
    undo_history: undo.UndoHistory,
    /// When true, session/MIDI capture paths do not push history (undo/redo apply).
    suppress_undo_capture: bool = false,
    /// Monotonic main-thread mutation generation for derived projections.
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .session = session_ops.init(allocator),
            .arrangement = arrangement.ArrangementView.init(allocator),
            .clip_pool = clip_pool.ClipPool.init(allocator),
            .sample_store = sample_store.SampleStore.init(allocator),
            .midi_history = midi_history.History.init(allocator),
            .undo_history = undo.UndoHistory.init(allocator),
        };
    }

    /// Must run after the store reaches its stable address.
    pub fn wireInternalRefs(self: *Store) void {
        self.session.clip_pool = &self.clip_pool;
        self.session.sample_store = &self.sample_store;
        self.arrangement.clip_pool = &self.clip_pool;
        self.arrangement.sample_store = &self.sample_store;
    }

    pub fn deinit(self: *Store) void {
        self.midi_history.deinit();
        self.undo_history.deinit();
        session_ops.deinit(&self.session);
        self.arrangement.deinit();
        self.clip_pool.deinit(&self.sample_store);
        self.sample_store.deinit();
        self.* = undefined;
    }

    pub fn reset(self: *Store) void {
        const allocator = self.allocator;
        self.deinit();
        self.* = Store.init(allocator);
        self.wireInternalRefs();
    }

    pub fn markChanged(self: *Store) void {
        // Drain session-domain undo_requests into the global history before
        // advancing revision so projections see a consistent document.
        const cmd_undo = @import("cmd_undo.zig");
        cmd_undo.flushSessionRequests(self);
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }

    pub fn view(self: *Store) Model {
        return .init(&self.session, &self.arrangement, &self.clip_pool, &self.sample_store, self.revision);
    }

    /// Bounds-checked lookup of the clip occupying a session slot, if any.
    pub fn slotClip(self: *Store, track: usize, scene: usize) ?*clip_pool.Clip {
        if (track >= self.session.track_count or scene >= self.session.scene_count) return null;
        return self.clip_pool.get(self.session.clips[track][scene].clip);
    }

    pub fn slotClipConst(self: *const Store, track: usize, scene: usize) ?*const clip_pool.Clip {
        if (track >= self.session.track_count or scene >= self.session.scene_count) return null;
        return self.clip_pool.getConst(self.session.clips[track][scene].clip);
    }

    pub fn slotMidiClip(self: *Store, track: usize, scene: usize) ?*@import("../session/notes.zig").PianoRollClip {
        const clip = self.slotClip(track, scene) orelse return null;
        return if (clip.content == .midi) &clip.content.midi else null;
    }

    pub fn slotMidiClipConst(self: *const Store, track: usize, scene: usize) ?*const @import("../session/notes.zig").PianoRollClip {
        const clip = self.slotClipConst(track, scene) orelse return null;
        return if (clip.content == .midi) &clip.content.midi else null;
    }

    pub fn slotAudioClipConst(self: *const Store, track: usize, scene: usize) ?*const @import("../session/audio_clip.zig").AudioClip {
        const clip = self.slotClipConst(track, scene) orelse return null;
        return if (clip.content == .audio) &clip.content.audio else null;
    }
};

pub const Model = struct {
    session: *session_types.SessionView,
    arrangement: *arrangement.ArrangementView,
    clip_pool: *clip_pool.ClipPool,
    sample_store: *sample_store.SampleStore,
    revision: u64,

    pub fn init(
        session: *session_types.SessionView,
        arrangement_view: *arrangement.ArrangementView,
        pool: *clip_pool.ClipPool,
        samples: *sample_store.SampleStore,
        revision: u64,
    ) Model {
        return .{
            .session = session,
            .arrangement = arrangement_view,
            .clip_pool = pool,
            .sample_store = samples,
            .revision = revision,
        };
    }
};

pub var g: Store = undefined;
pub var g_ready = false;

pub fn initGlobal(allocator: std.mem.Allocator) void {
    g = Store.init(allocator);
    g.wireInternalRefs();
    g_ready = true;
}

pub fn deinitGlobal() void {
    if (!g_ready) return;
    g.deinit();
    g_ready = false;
}

pub fn ready() bool {
    return g_ready;
}

test "store owns and rewires document data" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    store.wireInternalRefs();
    try std.testing.expect(store.session.clip_pool == &store.clip_pool);
    try std.testing.expect(store.arrangement.sample_store == &store.sample_store);
    try std.testing.expectEqual(@as(usize, 4), store.view().session.track_count);
}
