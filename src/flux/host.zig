const std = @import("std");
const clap = @import("clap-bindings");

const audio_engine = @import("audio/audio_engine.zig");
const audio_graph = @import("audio/audio_graph.zig");
const clap_ids = @import("clap_ids.zig");
const dawproject_runtime = @import("dawproject/runtime.zig");
const plugin_call_context = @import("plugin/call_context.zig");
const plugins = @import("plugin/plugins.zig");
const plugin_runtime = @import("plugin/plugin_runtime.zig");
const session_constants = @import("ui/session_view/constants.zig");
const thread_context = @import("thread_context.zig");
const ui_state = @import("ui/state.zig");

const track_count = session_constants.max_tracks;
const TrackPlugin = plugin_runtime.TrackPlugin;
const max_gui_timers = 64;
const max_gui_fds = 64;

const GuiTimer = struct {
    plugin: *const clap.Plugin,
    timer_id: clap.Id,
    period_ms: u32,
    next_fire_ns: u64,
    active: bool = false,
};

const GuiFd = struct {
    plugin: *const clap.Plugin,
    fd: c_int,
    flags: clap.ext.posix_fd_support.Flags,
    active: bool = false,
};

pub const Host = struct {
    clap_host: clap.Host,
    jobs: ?*audio_graph.JobQueue = null,
    jobs_fanout: u32 = 0,
    shared_state: ?*audio_engine.SharedState = null,
    main_thread_id: std.Thread.Id = undefined,
    callback_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Undo state
    ui_state: ?*ui_state.State = null,
    allocator: ?std.mem.Allocator = null,
    track_plugins_ptr: ?*[track_count]TrackPlugin = null,
    track_fx_ptr: ?*[track_count][ui_state.max_fx_slots]TrackPlugin = null,
    catalog_ptr: ?*const plugins.PluginCatalog = null,
    undo_change_in_progress: bool = false,
    undo_track_index: ?usize = null, // Track that started the change
    undo_pre_state: ?[]u8 = null, // State captured at begin_change
    gui_timers: [max_gui_timers]GuiTimer = [_]GuiTimer{.{ .plugin = undefined, .timer_id = .invalid_id, .period_ms = 0, .next_fire_ns = 0 }} ** max_gui_timers,
    next_gui_timer_id: u32 = 1,
    gui_fds: [max_gui_fds]GuiFd = [_]GuiFd{.{ .plugin = undefined, .fd = -1, .flags = .{ ._ = 0 } }} ** max_gui_fds,

    const thread_pool_ext = clap.ext.thread_pool.Host{
        .requestExec = _requestExec,
    };

    const thread_check_ext = clap.ext.thread_check.Host{
        .isMainThread = _isMainThread,
        .isAudioThread = _isAudioThread,
    };

    const gui_ext = clap.ext.gui.Host{
        .resizeHintsChanged = _guiResizeHintsChanged,
        .requestResize = _guiRequestResize,
        .requestShow = _guiRequestShow,
        .requestHide = _guiRequestHide,
        .closed = _guiClosed,
    };

    const undo_ext = clap.ext.undo.Host{
        .begin_change = _undoBeginChange,
        .cancel_change = _undoCancelChange,
        .change_made = _undoChangeMade,
        .request_undo = _undoRequestUndo,
        .request_redo = _undoRequestRedo,
        .set_wants_context_updates = _undoSetWantsContextUpdates,
    };

    const params_ext = clap.ext.params.Host{
        .rescan = _paramsRescan,
        .clear = _paramsClear,
        .requestFlush = _paramsRequestFlush,
    };

    const preset_load_ext = clap.ext.preset_load.Host{
        .onError = _presetLoadOnError,
        .loaded = _presetLoadLoaded,
    };

    const timer_support_ext = clap.ext.timer_support.Host{
        .registerTimer = _timerRegister,
        .unregisterTimer = _timerUnregister,
    };

    const posix_fd_support_ext = clap.ext.posix_fd_support.Host{
        .registerFd = _posixFdRegister,
        .modifyFd = _posixFdModify,
        .unregiserFd = _posixFdUnregister,
    };

    pub fn init() Host {
        return .{
            .clap_host = .{
                .clap_version = clap.version,
                .host_data = undefined,
                .name = "flux",
                .vendor = "gearmulator",
                .url = null,
                .version = "0.1",
                .getExtension = _getExtension,
                .requestRestart = _requestRestart,
                .requestProcess = _requestProcess,
                .requestCallback = _requestCallback,
            },
            .main_thread_id = std.Thread.getCurrentId(),
        };
    }

    fn _getExtension(_: *const clap.Host, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.thread_pool.id)) {
            return &thread_pool_ext;
        }
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.thread_check.id)) {
            return &thread_check_ext;
        }
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.gui.id)) {
            return &gui_ext;
        }
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.undo.id)) {
            return &undo_ext;
        }
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.params.id)) {
            return &params_ext;
        }
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.preset_load.id) or
            std.mem.eql(u8, std.mem.span(id), clap_ids.preset_load_compat_id))
        {
            return &preset_load_ext;
        }
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.timer_support.id)) {
            return &timer_support_ext;
        }
        if (std.mem.eql(u8, std.mem.span(id), clap.ext.posix_fd_support.id)) {
            return &posix_fd_support_ext;
        }
        return null;
    }

    fn _isMainThread(host: *const clap.Host) callconv(.c) bool {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        return std.Thread.getCurrentId() == self.main_thread_id;
    }

    fn _isAudioThread(_: *const clap.Host) callconv(.c) bool {
        return thread_context.is_audio_thread;
    }

    fn _requestExec(host: *const clap.Host, task_count: u32) callconv(.c) bool {
        if (task_count == 0) return true;

        const self: *Host = @ptrCast(@alignCast(host.host_data));

        const plugin = audio_graph.current_processing_plugin orelse return false;

        const ext_raw = plugin.getExtension(plugin, clap.ext.thread_pool.id) orelse return false;
        const ext: *const clap.ext.thread_pool.Plugin = @ptrCast(@alignCast(ext_raw));

        // Allow nesting, but cap recursion to avoid pathological behavior.
        // If we hit the cap, fall back to synchronous execution on this thread.
        const max_depth: u32 = 4;
        if (thread_context.clap_threadpool_depth >= max_depth) {
            for (0..task_count) |i| ext.exec(plugin, @intCast(i));
            return true;
        }

        if (self.jobs) |job_queue| {
            thread_context.clap_threadpool_depth += 1;
            defer thread_context.clap_threadpool_depth -= 1;

            const base_fanout: u32 = if (self.jobs_fanout > 0) self.jobs_fanout else 1;
            // When called from within a worker/help loop, keep some headroom to reduce oversubscription.
            const desired_fanout: u32 = if (thread_context.in_jobs_worker) @max(1, base_fanout / 2) else base_fanout;
            const job_count: u32 = @min(task_count, desired_fanout);

            const Shared = struct {
                plugin: *const clap.Plugin,
                exec_fn: *const fn (*const clap.Plugin, u32) callconv(.c) void,
                task_count: u32,
                next_task: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
            };

            var shared = Shared{
                .plugin = plugin,
                .exec_fn = ext.exec,
                .task_count = task_count,
                .next_task = std.atomic.Value(u32).init(0),
            };

            const RootJob = struct {
                pub fn exec(_: *@This()) void {}
            };
            const root = job_queue.allocate(RootJob{});

            const WorkerJob = struct {
                shared: *Shared,
                pub fn exec(job: *@This()) void {
                    thread_context.is_audio_thread = true;
                    thread_context.in_jobs_worker = true;
                    defer thread_context.in_jobs_worker = false;

                    while (true) {
                        const idx = job.shared.next_task.fetchAdd(1, .acq_rel);
                        if (idx >= job.shared.task_count) break;
                        job.shared.exec_fn(job.shared.plugin, idx);
                    }
                }
            };

            for (0..job_count) |_| {
                const worker = job_queue.allocate(WorkerJob{ .shared = &shared });
                job_queue.finishWith(worker, root);
                job_queue.schedule(worker);
            }

            job_queue.schedule(root);
            job_queue.wait(root);
            return true;
        }
        return false;
    }

    fn _requestRestart(_: *const clap.Host) callconv(.c) void {}
    fn _requestProcess(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        if (self.shared_state) |shared| {
            shared.process_requested.store(true, .release);
        }
    }

    fn _requestCallback(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        self.callback_requested.store(true, .release);
    }

    fn _guiResizeHintsChanged(_: *const clap.Host) callconv(.c) void {}

    fn _guiRequestResize(_: *const clap.Host, _: u32, _: u32) callconv(.c) bool {
        return true;
    }

    fn _guiRequestShow(_: *const clap.Host) callconv(.c) bool {
        return true;
    }

    fn _guiRequestHide(_: *const clap.Host) callconv(.c) bool {
        return true;
    }

    fn _guiClosed(_: *const clap.Host, _: bool) callconv(.c) void {}

    pub fn callPluginOnMainThread(self: *Host, plugin: *const clap.Plugin) void {
        _ = self;
        const previous = plugin_call_context.enter(plugin);
        defer plugin_call_context.restore(previous);
        plugin.onMainThread(plugin);
    }

    pub fn pumpMainThreadCallbacks(self: *Host) void {
        if (!self.callback_requested.swap(false, .acq_rel)) return;
        const shared = self.shared_state orelse return;
        const snapshot = shared.snapshot();
        for (snapshot.track_plugins) |plugin| {
            if (plugin) |p| {
                self.callPluginOnMainThread(p);
            }
        }
        for (snapshot.track_fx_plugins) |track_fx| {
            for (track_fx) |plugin| {
                if (plugin) |p| {
                    self.callPluginOnMainThread(p);
                }
            }
        }
    }

    pub fn pumpPluginGuiEvents(self: *Host, io: std.Io) void {
        self.pumpPluginTimers(io);
        self.pumpPluginFds();
    }

    fn _timerRegister(host: *const clap.Host, period_ms: u32, timer_id: *clap.Id) callconv(.c) bool {
        if (thread_context.is_audio_thread) return false;
        const plugin = plugin_call_context.current() orelse return false;
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        const now_ns = nowNs(std.Io.Threaded.global_single_threaded.io());

        for (&self.gui_timers) |*timer| {
            if (!timer.active) {
                const id: clap.Id = @enumFromInt(self.next_gui_timer_id);
                self.next_gui_timer_id +%= 1;
                if (self.next_gui_timer_id == @intFromEnum(clap.Id.invalid_id)) {
                    self.next_gui_timer_id = 1;
                }
                timer.* = .{
                    .plugin = plugin,
                    .timer_id = id,
                    .period_ms = @max(period_ms, 1),
                    .next_fire_ns = now_ns + msToNs(@max(period_ms, 1)),
                    .active = true,
                };
                timer_id.* = id;
                return true;
            }
        }
        return false;
    }

    fn _timerUnregister(host: *const clap.Host, timer_id: clap.Id) callconv(.c) bool {
        if (thread_context.is_audio_thread) return false;
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        for (&self.gui_timers) |*timer| {
            if (timer.active and timer.timer_id == timer_id) {
                timer.active = false;
                return true;
            }
        }
        return false;
    }

    fn _posixFdRegister(host: *const clap.Host, fd: c_int, flags: clap.ext.posix_fd_support.Flags) callconv(.c) bool {
        if (thread_context.is_audio_thread) return false;
        const plugin = plugin_call_context.current() orelse return false;
        const self: *Host = @ptrCast(@alignCast(host.host_data));

        for (&self.gui_fds) |*entry| {
            if (entry.active and entry.fd == fd) return false;
        }
        for (&self.gui_fds) |*entry| {
            if (!entry.active) {
                entry.* = .{
                    .plugin = plugin,
                    .fd = fd,
                    .flags = flags,
                    .active = true,
                };
                return true;
            }
        }
        return false;
    }

    fn _posixFdModify(host: *const clap.Host, fd: c_int, flags: clap.ext.posix_fd_support.Flags) callconv(.c) bool {
        if (thread_context.is_audio_thread) return false;
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        for (&self.gui_fds) |*entry| {
            if (entry.active and entry.fd == fd) {
                entry.flags = flags;
                return true;
            }
        }
        return false;
    }

    fn _posixFdUnregister(host: *const clap.Host, fd: c_int) callconv(.c) bool {
        if (thread_context.is_audio_thread) return false;
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        for (&self.gui_fds) |*entry| {
            if (entry.active and entry.fd == fd) {
                entry.active = false;
                return true;
            }
        }
        return false;
    }

    fn pumpPluginTimers(self: *Host, io: std.Io) void {
        const now_ns = nowNs(io);
        for (&self.gui_timers) |*timer| {
            if (!timer.active) continue;
            if (!self.pluginIsLoaded(timer.plugin)) {
                timer.active = false;
                continue;
            }
            if (now_ns < timer.next_fire_ns) continue;

            const ext_raw = timer.plugin.getExtension(timer.plugin, clap.ext.timer_support.id) orelse {
                timer.active = false;
                continue;
            };
            const ext: *const clap.ext.timer_support.Plugin = @ptrCast(@alignCast(ext_raw));
            {
                const previous = plugin_call_context.enter(timer.plugin);
                defer plugin_call_context.restore(previous);
                ext.onTimer(timer.plugin, timer.timer_id);
            }

            const period_ns = msToNs(timer.period_ms);
            timer.next_fire_ns = now_ns + period_ns;
        }
    }

    fn pumpPluginFds(self: *Host) void {
        if (@import("builtin").os.tag != .linux) return;

        var poll_fds: [max_gui_fds]std.posix.pollfd = undefined;
        var sources: [max_gui_fds]*GuiFd = undefined;
        var count: usize = 0;
        for (&self.gui_fds) |*entry| {
            if (!entry.active) continue;
            if (!self.pluginIsLoaded(entry.plugin)) {
                entry.active = false;
                continue;
            }
            poll_fds[count] = .{
                .fd = entry.fd,
                .events = posixEventsFromFlags(entry.flags),
                .revents = 0,
            };
            sources[count] = entry;
            count += 1;
        }
        if (count == 0) return;

        const ready_count = std.posix.poll(poll_fds[0..count], 0) catch return;
        if (ready_count == 0) return;

        for (poll_fds[0..count], sources[0..count]) |poll_fd, entry| {
            if (poll_fd.revents == 0) continue;
            const flags = flagsFromPosixEvents(poll_fd.revents);
            const ext_raw = entry.plugin.getExtension(entry.plugin, clap.ext.posix_fd_support.id) orelse {
                entry.active = false;
                continue;
            };
            const ext: *const clap.ext.posix_fd_support.Plugin = @ptrCast(@alignCast(ext_raw));
            {
                const previous = plugin_call_context.enter(entry.plugin);
                defer plugin_call_context.restore(previous);
                ext.onFd(entry.plugin, entry.fd, flags);
            }
        }
    }

    fn pluginIsLoaded(self: *Host, plugin: *const clap.Plugin) bool {
        if (self.track_plugins_ptr) |track_plugins| {
            for (track_plugins) |track| {
                if (track.getPlugin() == plugin) return true;
            }
        }
        if (self.track_fx_ptr) |track_fx| {
            for (track_fx) |track_slots| {
                for (track_slots) |slot| {
                    if (slot.getPlugin() == plugin) return true;
                }
            }
        }
        return false;
    }

    fn nowNs(io: std.Io) u64 {
        const now = std.Io.Clock.awake.now(io);
        const ns = now.toNanoseconds();
        return if (ns > 0) @intCast(ns) else 0;
    }

    fn msToNs(ms: u32) u64 {
        return @as(u64, ms) * std.time.ns_per_ms;
    }

    fn posixEventsFromFlags(flags: clap.ext.posix_fd_support.Flags) @FieldType(std.posix.pollfd, "events") {
        var events: @FieldType(std.posix.pollfd, "events") = 0;
        if (flags.read) events |= std.posix.POLL.IN;
        if (flags.write) events |= std.posix.POLL.OUT;
        if (flags.@"error") events |= std.posix.POLL.ERR;
        return events;
    }

    fn flagsFromPosixEvents(events: @FieldType(std.posix.pollfd, "revents")) clap.ext.posix_fd_support.Flags {
        return .{
            .read = (events & std.posix.POLL.IN) != 0,
            .write = (events & std.posix.POLL.OUT) != 0,
            .@"error" = (events & std.posix.POLL.ERR) != 0,
        };
    }

    // --- Undo extension callbacks ---

    /// Find which track a plugin belongs to
    fn findTrackForPlugin(self: *Host, caller_plugin: *const clap.Plugin) ?usize {
        const track_plugins = self.track_plugins_ptr orelse return null;
        for (track_plugins, 0..) |track, idx| {
            if (track.handle) |handle| {
                if (handle.plugin == caller_plugin) {
                    return idx;
                }
            }
        }
        if (self.track_fx_ptr) |track_fx| {
            for (track_fx, 0..) |track_slots, idx| {
                for (track_slots) |slot| {
                    if (slot.handle) |handle| {
                        if (handle.plugin == caller_plugin) {
                            return idx;
                        }
                    }
                }
            }
        }
        return null;
    }

    /// Get the CLAP plugin for a given track (external or builtin)
    fn getPluginForTrack(self: *Host, state: *ui_state.State, track_idx: usize) ?*const clap.Plugin {
        _ = state;
        if (track_idx >= track_count) return null;

        // All plugins (builtin and external) are now in TrackPlugin
        if (self.track_plugins_ptr) |track_plugins| {
            return track_plugins[track_idx].getPlugin();
        }
        return null;
    }

    fn _undoBeginChange(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        if (self.undo_change_in_progress) {
            std.log.warn("Plugin called begin_change while change already in progress", .{});
            return;
        }

        // Determine which track is making this call (use selected track with open GUI)
        const state = self.ui_state orelse return;
        const track_idx = state.selectedTrack();
        const allocator = self.allocator orelse return;

        // Get the plugin for this track (external or builtin)
        const plugin = self.getPluginForTrack(state, track_idx) orelse return;

        // Capture the current state before the change
        if (dawproject_runtime.capturePluginStateForUndo(allocator, plugin)) |pre_state| {
            self.undo_pre_state = pre_state;
            self.undo_track_index = track_idx;
            self.undo_change_in_progress = true;
        }
    }

    fn _undoCancelChange(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        const allocator = self.allocator orelse return;

        // Discard captured state
        if (self.undo_pre_state) |pre_state| {
            allocator.free(pre_state);
        }
        self.undo_pre_state = null;
        self.undo_track_index = null;
        self.undo_change_in_progress = false;
    }

    fn _undoChangeMade(
        host: *const clap.Host,
        name: [*:0]const u8,
        delta: ?*const anyopaque,
        delta_size: usize,
        delta_can_undo: bool,
    ) callconv(.c) void {
        _ = delta;
        _ = delta_size;
        _ = delta_can_undo;

        const self: *Host = @ptrCast(@alignCast(host.host_data));
        const state = self.ui_state orelse return;
        const allocator = self.allocator orelse return;

        // Determine track index - use tracked one from begin_change or selected track
        const track_idx = self.undo_track_index orelse state.selectedTrack();

        // Get the pre-change state (either from begin_change or capture now)
        const old_state = if (self.undo_pre_state) |pre| pre else blk: {
            // No begin_change was called - this is an instant change
            // We need to capture state, but we're already past the change...
            // For instant changes without begin_change, we can't provide undo
            // because we don't have the old state. Log and skip.
            std.log.debug("Plugin change_made without begin_change: {s}", .{name});
            break :blk null;
        };

        if (old_state == null) {
            // Can't create undo entry without old state
            self.undo_change_in_progress = false;
            self.undo_track_index = null;
            return;
        }

        // Get the plugin for this track (external or builtin)
        const plugin = self.getPluginForTrack(state, track_idx) orelse {
            allocator.free(old_state.?);
            self.undo_change_in_progress = false;
            self.undo_track_index = null;
            return;
        };

        // Capture the new state after the change
        if (dawproject_runtime.capturePluginStateForUndo(allocator, plugin)) |new_state| {
            // Push to undo history
            state.undo_history.push(.{
                .plugin_state = .{
                    .track_index = track_idx,
                    .old_state = old_state.?,
                    .new_state = new_state,
                },
            });
            std.log.debug("Plugin undo entry created: {s}", .{name});
        } else {
            // Failed to capture new state, free old state
            allocator.free(old_state.?);
        }

        // Reset change tracking
        self.undo_pre_state = null;
        self.undo_track_index = null;
        self.undo_change_in_progress = false;
    }

    fn _undoRequestUndo(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        const state = self.ui_state orelse return;
        _ = state.performUndo();
    }

    fn _undoRequestRedo(host: *const clap.Host) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(host.host_data));
        const state = self.ui_state orelse return;
        _ = state.performRedo();
    }

    fn _undoSetWantsContextUpdates(_: *const clap.Host, _: bool) callconv(.c) void {
        // TODO: Implement context updates if plugins request them
        // This would involve calling plugin's set_can_undo/set_can_redo
        // when the undo state changes
    }

    // --- Params extension callbacks ---

    fn _paramsRescan(_: *const clap.Host, _: clap.ext.params.Host.RescanFlags) callconv(.c) void {
        // Plugin is notifying us that parameter values/info changed.
        // For now this is a no-op; the host UI doesn't currently display
        // plugin parameter values. In the future this could trigger UI refresh.
    }

    fn _paramsClear(_: *const clap.Host, _: clap.Id, _: clap.ext.params.Host.ClearFlags) callconv(.c) void {
        // Plugin is requesting we clear automation/modulation for a parameter.
        // Not implemented - flux doesn't have parameter automation yet.
    }

    fn _paramsRequestFlush(_: *const clap.Host) callconv(.c) void {
        // Plugin is requesting a parameter flush outside of process().
        // Not implemented - we always process parameters during process().
    }

    fn _presetLoadOnError(
        _: *const clap.Host,
        _: clap.preset_discovery.Location.Kind,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
        os_error: i32,
        msg: [*:0]const u8,
    ) callconv(.c) void {
        std.log.warn("Preset load error (os_error={d}): {s}", .{ os_error, std.mem.span(msg) });
    }

    fn _presetLoadLoaded(
        _: *const clap.Host,
        _: clap.preset_discovery.Location.Kind,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
    ) callconv(.c) void {
        // Selection is tracked in UI state; nothing to do here yet.
    }
};
