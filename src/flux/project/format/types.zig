// DAWproject Types (subset matching project.xsd)

pub const Unit = enum {
    linear,
    normalized,
    percent,
    decibel,
    hertz,
    semitones,
    seconds,
    beats,
    bpm,

    pub fn toString(self: Unit) []const u8 {
        return switch (self) {
            .linear => "linear",
            .normalized => "normalized",
            .percent => "percent",
            .decibel => "decibel",
            .hertz => "hertz",
            .semitones => "semitones",
            .seconds => "seconds",
            .beats => "beats",
            .bpm => "bpm",
        };
    }
};

pub const TimeUnit = enum {
    beats,
    seconds,

    pub fn toString(self: TimeUnit) []const u8 {
        return switch (self) {
            .beats => "beats",
            .seconds => "seconds",
        };
    }
};

pub const MixerRole = enum {
    regular,
    master,
    effect,
    submix,
    vca,

    pub fn toString(self: MixerRole) []const u8 {
        return switch (self) {
            .regular => "regular",
            .master => "master",
            .effect => "effect",
            .submix => "submix",
            .vca => "vca",
        };
    }
};

pub const DeviceRole = enum {
    instrument,
    noteFX,
    audioFX,
    analyzer,

    pub fn toString(self: DeviceRole) []const u8 {
        return switch (self) {
            .instrument => "instrument",
            .noteFX => "noteFX",
            .audioFX => "audioFX",
            .analyzer => "analyzer",
        };
    }
};

pub const ContentType = enum {
    audio,
    automation,
    notes,
    video,
    markers,
    tracks,

    pub fn toString(self: ContentType) []const u8 {
        return switch (self) {
            .audio => "audio",
            .automation => "automation",
            .notes => "notes",
            .video => "video",
            .markers => "markers",
            .tracks => "tracks",
        };
    }
};

/// Real-valued parameter (tempo, volume, pan, etc.)
pub const RealParameter = struct {
    id: []const u8,
    name: []const u8,
    value: f64,
    min: ?f64 = null,
    max: ?f64 = null,
    unit: Unit,
    /// Plugin-native param id (DAWproject `parameterID`, xs:int). Required by Bitwig
    /// for device Parameters — missing value causes NPE on import. Mixer/transport
    /// params leave this null. CLAP u32 ids are stored as i32 bit pattern.
    parameter_id: ?i32 = null,
};

/// Boolean parameter (mute, solo, enabled)
pub const BoolParameter = struct {
    id: []const u8,
    name: []const u8,
    value: bool,
    parameter_id: ?i32 = null,
};

/// Time signature parameter
pub const TimeSignatureParameter = struct {
    id: []const u8,
    name: []const u8 = "Time Signature",
    numerator: i32,
    denominator: i32,
};

/// File reference (for plugin state, audio files)
pub const FileReference = struct {
    path: []const u8,
    external: bool = false,
};

/// How the device is written in project.xml (DAWproject element).
pub const DeviceXmlKind = enum {
    clap,
    equalizer,
    compressor,
    noise_gate,
    limiter,

    pub fn xmlTag(self: DeviceXmlKind) []const u8 {
        return switch (self) {
            .clap => "ClapPlugin",
            .equalizer => "Equalizer",
            .compressor => "Compressor",
            .noise_gate => "NoiseGate",
            .limiter => "Limiter",
        };
    }
};

/// EQ band (DAWproject Equalizer/Band)
pub const EqBand = struct {
    band_type: []const u8, // highPass, lowPass, bell, ...
    order: ?i32 = null,
    freq: RealParameter,
    gain: ?RealParameter = null,
    q: ?RealParameter = null,
    enabled: ?BoolParameter = null,
};

/// Device (CLAP plugin or portable DAWproject builtin)
pub const ClapPlugin = struct {
    id: []const u8,
    name: []const u8,
    device_id: []const u8, // e.g. "org.surge-synth-team.surge-xt" or "com.flux.builtin.compressor"
    device_name: []const u8,
    device_role: DeviceRole,
    loaded: bool = true,
    xml_kind: DeviceXmlKind = .clap,
    parameters: []const RealParameter = &.{},
    enabled: ?BoolParameter = null,
    state: ?FileReference = null,
    /// Equalizer bands (when xml_kind == .equalizer)
    eq_bands: []const EqBand = &.{},
    /// Schema-named params for Compressor/NoiseGate/Limiter (optional; also mirrored in parameters)
    attack: ?RealParameter = null,
    release: ?RealParameter = null,
    threshold: ?RealParameter = null,
    ratio: ?RealParameter = null,
    input_gain: ?RealParameter = null,
    output_gain: ?RealParameter = null,
    auto_makeup: ?BoolParameter = null,
    range: ?RealParameter = null,
};

/// Channel with volume, pan, mute, devices
pub const Channel = struct {
    id: []const u8,
    audio_channels: i32 = 2,
    role: MixerRole = .regular,
    solo: bool = false,
    destination: ?[]const u8 = null, // ID reference to master channel
    volume: ?RealParameter = null,
    pan: ?RealParameter = null,
    mute: ?BoolParameter = null,
    devices: []const ClapPlugin = &.{},
};

/// Track containing a channel
pub const Track = struct {
    id: []const u8,
    name: []const u8,
    color: ?[]const u8 = null,
    /// Single primary type (legacy / simple cases). Prefer `content_types_attr` when set.
    content_type: ContentType = .notes,
    /// Space-separated DAWproject list (e.g. "audio notes") for hybrid tracks.
    /// When non-null, XML export writes this instead of `content_type`.
    content_types_attr: ?[]const u8 = null,
    loaded: bool = true,
    channel: ?Channel = null,
};

/// MIDI note
pub const Note = struct {
    time: f64, // in beats
    duration: f64,
    channel: i32 = 0,
    key: i32, // MIDI pitch 0-127
    vel: f64 = 0.8, // velocity 0.0-1.0
    rel: f64 = 0.8, // release velocity
};

/// Notes container
pub const Notes = struct {
    id: []const u8,
    notes: []const Note,
};

pub const AutomationPoint = struct {
    time: f64, // in beats
    value: f64,
};

pub const AutomationTarget = struct {
    parameter: ?[]const u8 = null,
    expression: ?[]const u8 = null,
    channel: ?i32 = null,
    key: ?i32 = null,
    controller: ?i32 = null,
};

pub const Points = struct {
    id: []const u8,
    target: AutomationTarget,
    unit: ?Unit = null,
    points: []const AutomationPoint,
};

/// Warp marker mapping outer timeline time ↔ content time
pub const WarpPoint = struct {
    time: f64, // outer (usually beats)
    content_time: f64, // inner (usually seconds for audio)
};

/// Audio media file reference (full file length in seconds)
pub const Audio = struct {
    id: []const u8 = "",
    file: FileReference,
    duration: f64, // full file length in seconds
    sample_rate: i32,
    channels: i32,
    algorithm: ?[]const u8 = null, // free-form vendor string; round-trip
};

/// Warps timeline: content (usually Audio) + piecewise-linear warp points
pub const Warps = struct {
    id: []const u8 = "",
    time_unit: ?TimeUnit = null, // outer unit
    content_time_unit: TimeUnit, // required by schema
    audio: ?Audio = null,
    warps: []const WarpPoint = &.{},
};

/// Clip containing notes, audio, nested clips, or other content
pub const Clip = struct {
    time: f64, // start time on parent timeline
    duration: f64,
    play_start: f64 = 0.0,
    play_stop: ?f64 = null,
    loop_start: ?f64 = null,
    loop_end: ?f64 = null,
    content_time_unit: ?TimeUnit = null,
    fade_time_unit: ?TimeUnit = null,
    fade_in_time: ?f64 = null,
    fade_out_time: ?f64 = null,
    enable: bool = true,
    name: ?[]const u8 = null,
    /// DAWproject Nameable color (#rrggbb)
    color: ?[]const u8 = null,
    lanes: ?Lanes = null,
    notes: ?Notes = null,
    points: []const Points = &.{},
    warps: ?Warps = null,
    audio: ?Audio = null,
    /// Nested Clips timeline (Bitwig-style audio events inside a clip)
    nested_clips: ?Clips = null,
};

/// Clips container
pub const Clips = struct {
    id: []const u8,
    clips: []const Clip,
};

/// Lanes (track lanes in arrangement)
pub const Lanes = struct {
    id: []const u8,
    track: ?[]const u8 = null, // ID reference
    time_unit: ?TimeUnit = null,
    clips: ?Clips = null,
    notes: ?Notes = null,
    points: []const Points = &.{},
    children: []const Lanes = &.{},
};

/// Arrangement (timeline)
pub const Arrangement = struct {
    id: []const u8,
    lanes: ?Lanes = null,
};

/// ClipSlot (for session view - one per track per scene)
pub const ClipSlot = struct {
    id: []const u8,
    track: []const u8, // IDREF to track
    has_stop: bool = true,
    clip: ?Clip = null,
};

/// Scene (for session view)
pub const Scene = struct {
    id: []const u8,
    name: []const u8,
    lanes_id: []const u8,
    clip_slots: []const ClipSlot = &.{},
};

/// Transport settings
pub const Transport = struct {
    tempo: ?RealParameter = null,
    time_signature: ?TimeSignatureParameter = null,
};

/// Application info
pub const Application = struct {
    name: []const u8,
    version: []const u8,
};

/// Root project structure
pub const Project = struct {
    version: []const u8 = "1.0",
    application: Application,
    transport: ?Transport = null,
    tracks: []const Track = &.{},
    master_track: ?Track = null,
    arrangement: ?Arrangement = null,
    scenes: []const Scene = &.{},
};
