# Flux

Flux is a minimal DAW and CLAP host built in Zig. It focuses on clip launching, MIDI sequencing, and a tight embedded instrument workflow. ZSynth ships as a first-class build target inside this repo.

## Status

Flux is early-stage and experimental. Expect breaking changes while the audio graph, clip system, and plugin hosting mature.

## Build

- Build everything: `zig build`
- Run Flux: `./zig-out/bin/flux` or `zig build run-flux`

Flux loads the built-in ZSynth CLAP plugin from `zig-out/lib/ZSynth.clap/Contents/MacOS/ZSynth` on macOS or
`zig-out/lib/zsynth.clap` on Linux.

## ZSynth

ZSynth lives in `zsynth/` and builds as a CLAP target.

- ZSynth docs: `zsynth/README.md`

## Repo Layout

- `src/flux`: Flux app source
- `zsynth/`: ZSynth plugin + support files
- `assets/`: shared assets (fonts, etc.)

