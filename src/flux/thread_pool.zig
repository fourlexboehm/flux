const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");
const main = @import("main.zig");

const max_batch_slots = 16; // Max nesting depth

const BatchSlot = struct {
    exec_fn: ?*const fn (*const clap.Plugin, u32) callconv(.c) void = null,
    generic_fn: ?*const fn (*anyopaque, u32) void = null,
    plugin: ?*const clap.Plugin = null,
    context: ?*anyopaque = null,
    next_task: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    task_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    tasks_remaining: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const ThreadPool = struct {
    workers: []std.Thread,
    allocator: std.mem.Allocator,
    shutdown: std.atomic.Value(bool),
    generation: std.atomic.Value(u32),
    batch_slots: [max_batch_slots]BatchSlot,
    worker_thread_ids: []std.Thread.Id,

    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !*ThreadPool {
        const pool = try allocator.create(ThreadPool);
        pool.* = ThreadPool{
            .workers = &.{},
            .allocator = allocator,
            .shutdown = std.atomic.Value(bool).init(false),
            .generation = std.atomic.Value(u32).init(0),
            .batch_slots = [_]BatchSlot{.{}} ** max_batch_slots,
            .worker_thread_ids = &.{},
        };

        const worker_count = if (num_workers > 1) num_workers - 1 else 0;
        if (worker_count > 0) {
            pool.workers = try allocator.alloc(std.Thread, worker_count);
            pool.worker_thread_ids = try allocator.alloc(std.Thread.Id, worker_count);
            for (pool.workers, pool.worker_thread_ids, 0..) |*worker, *tid, i| {
                worker.* = std.Thread.spawn(.{}, workerMain, .{ pool, tid }) catch |err| {
                    pool.shutdown.store(true, .release);
                    std.Thread.Futex.wake(&pool.generation, @intCast(i));
                    for (pool.workers[0..i]) |*w| {
                        w.join();
                    }
                    allocator.free(pool.workers);
                    allocator.free(pool.worker_thread_ids);
                    allocator.destroy(pool);
                    return err;
                };
            }
        }

        return pool;
    }

    pub fn deinit(self: *ThreadPool) void {
        self.shutdown.store(true, .release);
        std.Thread.Futex.wake(&self.generation, @intCast(self.workers.len));

        for (self.workers) |*worker| {
            worker.join();
        }

        if (self.workers.len > 0) {
            self.allocator.free(self.workers);
            self.allocator.free(self.worker_thread_ids);
        }
        self.allocator.destroy(self);
    }

    fn isWorkerThread(self: *ThreadPool) bool {
        const current_id = std.Thread.getCurrentId();
        for (self.worker_thread_ids) |tid| {
            if (tid == current_id) return true;
        }
        return false;
    }

    fn acquireBatchSlot(self: *ThreadPool) ?*BatchSlot {
        for (&self.batch_slots) |*slot| {
            if (slot.active.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                return slot;
            }
        }
        return null;
    }

    fn releaseBatchSlot(slot: *BatchSlot) void {
        slot.active.store(false, .release);
    }

    /// Execute CLAP threadpool tasks (plugin internal parallelism)
    pub fn execute(
        self: *ThreadPool,
        plugin: *const clap.Plugin,
        exec_fn: *const fn (*const clap.Plugin, u32) callconv(.c) void,
        task_count: u32,
    ) void {
        const zone = tracy.ZoneN(@src(), "ThreadPool.execute");
        defer zone.End();

        if (task_count == 0) return;

        const slot = self.acquireBatchSlot() orelse {
            // No slots available (max nesting depth), run synchronously
            const sync_zone = tracy.ZoneN(@src(), "execute sync fallback (no slots)");
            defer sync_zone.End();
            for (0..task_count) |i| {
                exec_fn(plugin, @intCast(i));
            }
            return;
        };
        defer releaseBatchSlot(slot);

        slot.plugin = plugin;
        slot.exec_fn = exec_fn;
        slot.generic_fn = null;
        slot.context = null;
        slot.task_count.store(task_count, .release);
        slot.next_task.store(0, .release);
        slot.tasks_remaining.store(task_count, .release);

        // Wake workers
        _ = self.generation.fetchAdd(1, .release);
        std.Thread.Futex.wake(&self.generation, @intCast(self.workers.len));

        // Caller participates
        while (true) {
            const idx = slot.next_task.fetchAdd(1, .acq_rel);
            if (idx >= task_count) break;
            exec_fn(plugin, idx);
            const prev = slot.tasks_remaining.fetchSub(1, .acq_rel);
            if (prev == 1) {
                std.Thread.Futex.wake(&slot.tasks_remaining, 1);
            }
        }

        // Wait for completion
        while (true) {
            const remaining = slot.tasks_remaining.load(.acquire);
            if (remaining == 0) break;
            std.Thread.Futex.wait(&slot.tasks_remaining, remaining);
        }
    }

    /// Execute generic parallel tasks (track-level parallelism)
    pub fn executeMany(
        self: *ThreadPool,
        task_count: u32,
        context: *anyopaque,
        exec_fn: *const fn (*anyopaque, u32) void,
    ) void {
        const zone = tracy.ZoneN(@src(), "ThreadPool.executeMany");
        defer zone.End();

        if (task_count == 0) return;

        const slot = self.acquireBatchSlot() orelse {
            // No slots, run synchronously
            for (0..task_count) |i| {
                exec_fn(context, @intCast(i));
            }
            return;
        };
        defer releaseBatchSlot(slot);

        slot.context = context;
        slot.generic_fn = exec_fn;
        slot.exec_fn = null;
        slot.plugin = null;
        slot.task_count.store(task_count, .release);
        slot.next_task.store(0, .release);
        slot.tasks_remaining.store(task_count, .release);

        // Wake workers
        _ = self.generation.fetchAdd(1, .release);
        std.Thread.Futex.wake(&self.generation, @intCast(self.workers.len));

        // Caller participates
        while (true) {
            const idx = slot.next_task.fetchAdd(1, .acq_rel);
            if (idx >= task_count) break;
            exec_fn(context, idx);
            const prev = slot.tasks_remaining.fetchSub(1, .acq_rel);
            if (prev == 1) {
                std.Thread.Futex.wake(&slot.tasks_remaining, 1);
            }
        }

        // Wait for completion
        while (true) {
            const remaining = slot.tasks_remaining.load(.acquire);
            if (remaining == 0) break;
            std.Thread.Futex.wait(&slot.tasks_remaining, remaining);
        }
    }

    fn workerMain(pool: *ThreadPool, tid: *std.Thread.Id) void {
        tid.* = std.Thread.getCurrentId();
        main.is_audio_thread = true; // Workers are always audio threads
        var last_gen = pool.generation.load(.acquire);

        while (!pool.shutdown.load(.acquire)) {
            std.Thread.Futex.wait(&pool.generation, last_gen);

            if (pool.shutdown.load(.acquire)) break;

            const current_gen = pool.generation.load(.acquire);
            if (current_gen == last_gen) continue;
            last_gen = current_gen;

            // Check all active batch slots for work
            for (&pool.batch_slots) |*slot| {
                if (!slot.active.load(.acquire)) continue;

                const total = slot.task_count.load(.acquire);

                // Try to grab work from this slot
                while (true) {
                    const idx = slot.next_task.fetchAdd(1, .acq_rel);
                    if (idx >= total) break;

                    // Execute based on slot type
                    if (slot.exec_fn) |exec_fn| {
                        if (slot.plugin) |plugin| {
                            const zone = tracy.ZoneN(@src(), "Worker CLAP task");
                            defer zone.End();
                            exec_fn(plugin, idx);
                        }
                    } else if (slot.generic_fn) |generic_fn| {
                        if (slot.context) |context| {
                            const zone = tracy.ZoneN(@src(), "Worker generic task");
                            defer zone.End();
                            generic_fn(context, idx);
                        }
                    }

                    const prev = slot.tasks_remaining.fetchSub(1, .acq_rel);
                    if (prev == 1) {
                        std.Thread.Futex.wake(&slot.tasks_remaining, 1);
                    }
                }
            }
        }
    }
};
