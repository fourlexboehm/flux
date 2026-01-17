const std = @import("std");
const clap = @import("clap-bindings");

pub const ThreadPool = struct {
    workers: []std.Thread,
    allocator: std.mem.Allocator,
    shutdown: std.atomic.Value(bool),

    // Per-request state
    exec_fn: std.atomic.Value(?*const fn (*const clap.Plugin, u32) callconv(.c) void),
    plugin: std.atomic.Value(?*const clap.Plugin),
    next_task: std.atomic.Value(u32),
    task_count: std.atomic.Value(u32),
    tasks_remaining: std.atomic.Value(u32),
    // Generation counter - workers futex-wait on this
    generation: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !*ThreadPool {
        const pool = try allocator.create(ThreadPool);
        pool.* = ThreadPool{
            .workers = &.{},
            .allocator = allocator,
            .shutdown = std.atomic.Value(bool).init(false),
            .exec_fn = std.atomic.Value(?*const fn (*const clap.Plugin, u32) callconv(.c) void).init(null),
            .plugin = std.atomic.Value(?*const clap.Plugin).init(null),
            .next_task = std.atomic.Value(u32).init(0),
            .task_count = std.atomic.Value(u32).init(0),
            .tasks_remaining = std.atomic.Value(u32).init(0),
            .generation = std.atomic.Value(u32).init(0),
        };

        const worker_count = if (num_workers > 1) num_workers - 1 else 0;
        if (worker_count > 0) {
            pool.workers = try allocator.alloc(std.Thread, worker_count);
            for (pool.workers, 0..) |*worker, i| {
                worker.* = std.Thread.spawn(.{}, workerMain, .{pool}) catch |err| {
                    pool.shutdown.store(true, .release);
                    std.Thread.Futex.wake(&pool.generation, @intCast(i));
                    for (pool.workers[0..i]) |*w| {
                        w.join();
                    }
                    allocator.free(pool.workers);
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
        }
        self.allocator.destroy(self);
    }

    pub fn execute(
        self: *ThreadPool,
        plugin: *const clap.Plugin,
        exec_fn: *const fn (*const clap.Plugin, u32) callconv(.c) void,
        task_count: u32,
    ) void {
        if (task_count == 0) return;

        // Set up the work
        self.plugin.store(plugin, .release);
        self.exec_fn.store(exec_fn, .release);
        self.task_count.store(task_count, .release);
        self.next_task.store(0, .release);
        self.tasks_remaining.store(task_count, .release);

        // Bump generation and wake all workers
        _ = self.generation.fetchAdd(1, .release);
        std.Thread.Futex.wake(&self.generation, @intCast(self.workers.len));

        // Calling thread also participates in work
        while (true) {
            const idx = self.next_task.fetchAdd(1, .acq_rel);
            if (idx >= task_count) break;
            exec_fn(plugin, idx);
            const prev = self.tasks_remaining.fetchSub(1, .acq_rel);
            if (prev == 1) {
                std.Thread.Futex.wake(&self.tasks_remaining, 1);
            }
        }

        // Wait for all tasks to complete
        while (true) {
            const remaining = self.tasks_remaining.load(.acquire);
            if (remaining == 0) break;
            std.Thread.Futex.wait(&self.tasks_remaining, remaining);
        }
    }

    fn workerMain(pool: *ThreadPool) void {
        var last_gen = pool.generation.load(.acquire);

        while (!pool.shutdown.load(.acquire)) {
            std.Thread.Futex.wait(&pool.generation, last_gen);

            if (pool.shutdown.load(.acquire)) break;

            const current_gen = pool.generation.load(.acquire);
            if (current_gen == last_gen) continue;
            last_gen = current_gen;

            const exec_fn = pool.exec_fn.load(.acquire) orelse continue;
            const plugin = pool.plugin.load(.acquire) orelse continue;
            const total = pool.task_count.load(.acquire);

            while (true) {
                const idx = pool.next_task.fetchAdd(1, .acq_rel);
                if (idx >= total) break;
                exec_fn(plugin, idx);
                const prev = pool.tasks_remaining.fetchSub(1, .acq_rel);
                if (prev == 1) {
                    std.Thread.Futex.wake(&pool.tasks_remaining, 1);
                }
            }
        }
    }
};
