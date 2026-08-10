# Flux

Flux is a minimal DAW and CLAP host built in Zig. It started as a fork of, and was originally designed around, ZSynth (https://github.com/jrachele/zsynth). It focuses on a session view workflow (Ableton/Bitwig-style clip launching), MIDI sequencing, and a tight embedded instrument workflow.

The UI is [DVUI](https://github.com/david-vanderson/dvui) on SDL3 — a single native binary, no ImGui/zgui layer.

Core features:
- Session view clip launcher with MIDI and audio clips
- Arrangement view with clip drag/resize, zoom, and a per-track mixer strip
- Piano roll editor with automation lanes and its own MIDI undo history
- High-performance concurrent audio engine with a job-based graph
- CLAP plugin hosting (external `.clap` bundles + in-process built-ins)
- Built-in instruments (ZSynth, ZMinimoog, ZPortaFM) and stock FX (EQ, compressor, gate, limiter) with DVUI editors embedded in the device rack
- DAWproject (`.dawproject`) as the primary project format for compatibility
- Undo/redo history for editing operations

## Status

Flux is early-stage and experimental. Expect breaking changes while the session workflow, audio graph, and plugin hosting mature.

Migration notes and remaining parity work: `docs/dvui-migration.md`.

## Build

- Build everything: `zig build`
- Run Flux: `zig build run-flux` (or `./zig-out/bin/flux`)
- macOS app bundle: `zig build bundle-flux-app` / `zig build run-flux-app`
- Unit tests: `zig build test`
- Smoke-load every installed system CLAP: `zig build test-clap-load`

There is one root `build.zig` graph; the DVUI/SDL3 module, XML, audio, CLAP, MIDI, stretch, and native libraries all attach to the `flux` executable there. `zig-pkg/` is package-manager output and must not be edited.

The built-in instruments and FX are compiled into `flux` and instantiated in-process — there are no `ZSynth.clap`-style bundles to build or install any more. Only third-party plugins are loaded from disk via `DynLib` (standard CLAP search paths).

Keyboard basics: Space play · Tab session/arrangement · Shift+Tab device/clip panel · B browser.

## Built-in instruments

| Instrument | Source | CLAP id |
|------------|--------|---------|
| ZSynth | `src/builtins/instruments/zsynth/` | `com.juge.zsynth` |
| ZMinimoog | `src/builtins/instruments/zminimoog/` | `com.fourlex.zminimoog` |
| ZPortaFM | `src/builtins/instruments/zportafm/` | `com.fourlex.zportafm` |

They are registered in `src/builtins/instruments/registry.zig` and loaded by `src/plugin/builtin_load.zig`. Their DSP is UI-free; the host draws their editors from `src/ui/panels/editors/`.

- ZSynth docs: `zsynth/README.md`

## Repo Layout

See `docs/code-style.md` for the 1000-line source file limit and split conventions.

- `src/main.zig`: app entry (DVUI host)
- `src/ui/`: host UI — views, panels, device rack, built-in editors
- `src/document/`: UI-neutral document store + commands (session, arrangement, clips, MIDI history)
- `src/audio/`: audio engine, graph, and DSP support
- `src/plugin/`: CLAP hosting primitives (`DynLib` handles, built-in load, param flush, floating/parented GUIs)
- `src/builtins/`: in-process instruments and stock FX
- `src/project/`: DAWproject read/write
- `shared/`: CLAP entry/extension scaffolding shared by the built-in plugins
- `assets/`: shared assets (fonts, etc.)
