Minimal ZDAW Plan + TODOs

Audio Graph (Core)
- Define node graph types: NodeId, Node, Port, Connection, Graph
- Implement DSP node interfaces: process(), prepare(sample_rate, max_frames)
- Implement graph executor (topological sort, render order)
- Add mix node, gain node, and master output node
- Add clip note source node (per-track or per-clip)
- Add ZSynth instrument node (embedded engine instance)
- Route track -> mixer -> master -> device callback

Sequencer + Clips
- Convert clip notes into note events with time positions
- Playback clock: bpm, transport, playhead, loop by clip length
- Per-track active clip: only one clip plays per track
- Trigger logic: play button triggers clip, stop button halts clip
- Visual playhead aligned to audio engine time
- Clip length editing (already in UI), wire to playback

Audio Device + Timing
- Move device callback from zero-fill to graph render
- Handle buffer size, sample rate changes
- Create lock-free ring/event queue for UI -> audio thread updates
- Add basic voice stealing or note-off handling

CLAP + External Plugins
- Keep CLAP ABI for external DAWs (zsynth)
- For zdaw: use embedded ZSynth engine directly
- Later: add external CLAP/VST chain nodes for tracks

UI + UX
- Show track mixer (volume/mute/solo)
- Add per-track play/stop states and clip launch feedback
- Show clip length as overlay on clip button
- Add global stop and per-track stop controls
- Display transport time + bar/beat

Testing + Debug
- Add offline render test: fixed notes -> known waveform stats
- Add simple graph integrity checks (no cycles, valid ports)
- Log performance timings for graph render
