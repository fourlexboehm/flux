## DVUI migration — restore deleted host features (priority)

UI shell + `document/` refactors stay. Everything below was working pre-DVUI (`app/host.zig`, `audio_device.zig`, `midi/*`, `app/bench.zig` tuning) and must come back on the new path (`ui/plugin_host`, `ui/audio_runtime`, `document/*`).

### Audio / JobQueue
- [x] Graph `JobQueue` start/stop + `engine.jobs` (`ui/audio_runtime`)
- [x] Adaptive worker idle sleep from DSP load (callback)
- [x] `FLUX_SINGLE_THREAD` / `FLUX_AUDIO_PARALLEL_THRESHOLD`
- [x] Wire same queue into CLAP host **thread_pool** (`requestExec` / voice fan-out)
- [x] `jobs_fanout` + `FLUX_AUDIO_ARM_FANOUT_SCALE` (was `bench.configureRuntimeTuning`)
- [x] Apply `FLUX_AUDIO_WORKER_MIN_SLEEP_NS` / `MAX` via `setWorkerSleepBounds` at startup

### CLAP host extensions (were on `app/host.zig`, now stubs/missing on `plugin_host`)
- [x] `thread_pool` — schedule plugin voice tasks on JobQueue
- [x] `requestProcess` → `shared.process_requested`
- [x] `requestCallback` + main-thread pump for **all** loaded plugins (not only open GUIs)
- [x] `params` host (`rescan` / `clear` / `requestFlush` — at least flush path usable)
- [x] `latency` host (`changed` — even if soft)
- [x] `timer_support` + per-frame pump
- [x] `posix_fd_support` + poll pump (Linux)
- [x] `undo` host (`begin_change` / `cancel_change` / `change_made` / `request_undo`/`redo`)
  - full-state blobs via `capturePluginStateForUndo`
  - push `plugin_state` onto document undo history
  - apply restore on Ctrl+Z (cmd_undo applies via `plugin_host.applyPluginStateBlob`)
  - `set_wants_context_updates` → subscribe slots; pump `PluginContext` can_undo/can_redo/names

### Device / buffer
- [x] Buffer-size change: stop device → wait idle → **deactivate/activate** all plugins at new max frames → reopen (old `audio_device.applyBufferFramesChange`)

### MIDI control surface
- [x] Restore `midi/controller_mapping.zig` (Axiom-class CC: transport, mute, faders, knobs)
- [x] Restore `midi/smart_params.zig` (ranked param pages for knobs)
- [x] Chrome state for controller / smart param tables
- [x] Drain CC events each frame → mapping → `audio_runtime.pushControllerParamWrite` + session/document mute/volume/launch

### Runtime / tooling (lower priority than host correctness)
- [x] Headless / kernel bench entrypoints
  - `FLUX_KERNEL_BENCH=1` → `audio/kernel_bench.zig` (early exit from `main`, also in `rt-bench`)
  - `FLUX_HEADLESS_BENCH=1` → `ui/bench.zig` device stress via `audio_runtime` + host pumps (no window)
- [x] `docs/dvui-migration.md` (README points at it)

---

## Media

- Optionally compute a strong content hash while import/load already reads source bytes, store it on `SampleAsset`, and add a short hash suffix to Flux-owned media filenames. This avoids collision reads during later saves.
