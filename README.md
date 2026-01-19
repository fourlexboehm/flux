# Flux

Flux is a minimal DAW and CLAP host built in Zig. It started as a fork of, and was originally designed around, ZSynth (https://github.com/jrachele/zsynth). It focuses on a session view workflow (Ableton/Bitwig-style clip launching), MIDI sequencing, and a tight embedded instrument workflow. There is no arrangement view and no audio clips by design.

Core features:
- Session view clip launcher with MIDI clips
- High-performance concurrent audio engine with a job-based graph
- CLAP plugin hosting (including the built-in ZSynth instrument)
- DAWproject (`.dawproject`) as the primary project format for compatibility
- Undo/redo history for editing operations

## Status

Flux is early-stage and experimental. Expect breaking changes while the session workflow, audio graph, and plugin hosting mature.

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
