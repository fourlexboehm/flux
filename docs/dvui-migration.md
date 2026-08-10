# DVUI migration notes

Flux’s host shell moved from zgui (`src/ui_zgui/`, `src/app/host.zig`) to DVUI
(`src/ui/`). Domain data lives under `document/`; chrome under `ui/state.zig`;
CLAP loading under `ui/plugin_host.zig`; audio under `ui/audio_runtime.zig`.

## Restored host features (pre-DVUI parity)

| Feature | Old location | New location |
|--------|--------------|--------------|
| Graph `JobQueue` + adaptive sleep | `audio_device`, `bench` | `ui/audio_runtime` |
| `FLUX_SINGLE_THREAD` / parallel threshold / worker sleep | `bench.configureRuntimeTuning` | `audio_runtime.configureRuntimeTuning` |
| `jobs_fanout` + `FLUX_AUDIO_ARM_FANOUT_SCALE` | `app/host` + `bench` | `plugin_host.jobs_fanout` via tuning |
| CLAP `thread_pool` | `app/host` | `ui/plugin_host` (shares JobQueue) |
| `requestProcess` / `requestCallback` | `app/host` | `plugin_host` → shared + all-plugin pump |
| `params` / `latency` / `timer_support` / `posix_fd` | `app/host` | `plugin_host` |
| CLAP `undo` + state blobs | `app/host` → UI undo | `plugin_host` → `document.Store.undo_history` |
| CLAP undo context updates | stub TODO | `set_wants_context_updates` + per-tick `PluginContext` push |
| Buffer-size re-activate | `audio_device.applyBufferFramesChange` | `audio_runtime` + `plugin_host.reconfigureMaxFrames` |
| MIDI control surface | `midi/controller_mapping`, `smart_params` | same modules; document cmds + chrome |
| Kernel / headless bench | `app/bench.zig` + main env | `audio/kernel_bench` + `ui/bench` early exit |

## Env vars

| Variable | Effect |
|----------|--------|
| `FLUX_SINGLE_THREAD=1` | Disable JobQueue (serial synth process) |
| `FLUX_AUDIO_PARALLEL_THRESHOLD` | Min concurrent synths before parallel (default 3) |
| `FLUX_AUDIO_ARM_FANOUT_SCALE` | Scale thread_pool fan-out (default 0.75 on ARM, 1.0 else) |
| `FLUX_AUDIO_WORKER_MIN_SLEEP_NS` | Worker idle sleep floor (default 10000) |
| `FLUX_AUDIO_WORKER_MAX_SLEEP_NS` | Worker idle sleep ceiling (default 2000000) |
| `FLUX_DEV_DEVICE=<clap-id>` | Preload a catalog plugin on track 1 |
| `FLUX_KERNEL_BENCH=1` | Early-exit SIMD add-mul microbench (no window/device) |
| `FLUX_KERNEL_BENCH_TRACKS` / `_FRAMES` / `_BLOCKS` | Kernel bench sizing (defaults 64 / 64 / 20000) |
| `FLUX_HEADLESS_BENCH=1` | Early-exit device stress (transport + buffer resize + host pumps) |
| `FLUX_BENCH_DURATION_S` | Headless duration seconds (default 180, min 10) |
| `FLUX_BENCH_SCENARIO` | Headless scenario label (logged only) |

Also: `zig build rt-bench` runs the full RT microbench suite (includes kernel + graph/plugin stages).

## Layering rules

- **`document/`** — durable session/arrangement/MIDI/mixer undo. No DVUI.
- **`ui/state.zig`** — draw chrome only (no clap/session domain ownership).
- **`ui/plugin_host.zig`** — CLAP catalog, load, host extensions, MIDI hardware.
- **`ui/audio_runtime.zig`** — device + engine + JobQueue + tuning.
- **`ui/bench.zig`** — headless/kernel entrypoints for the flux binary (no window).
- **`midi/*`** — hardware input + control-surface mapping into document/RT.

## Remaining / optional

- Media content-hash suffix on import (see root `TODO.md`).
