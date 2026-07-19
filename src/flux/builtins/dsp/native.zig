pub const eq_state_bytes = 8192;
pub const comp_state_bytes = 16384;

pub const EqState = [eq_state_bytes]u8;
pub const CompState = [comp_state_bytes]u8;

pub extern fn flux_eq_init(state: *align(16) EqState) void;
pub extern fn flux_eq_reset(state: *align(16) EqState) void;
pub extern fn flux_eq_configure(
    state: *align(16) EqState,
    band: u32,
    b0: f64,
    b1: f64,
    b2: f64,
    a0: f64,
    a1: f64,
    a2: f64,
) c_int;
pub extern fn flux_eq_process_band(
    state: *align(16) EqState,
    band: u32,
    left: [*]f32,
    right: [*]f32,
    frames: u32,
) void;

pub extern fn flux_compressor_configure(
    state: *align(16) CompState,
    sample_rate: u32,
    input_gain_db: f32,
    threshold_db: f32,
    ratio: f32,
    attack_s: f32,
    release_s: f32,
    output_gain_db: f32,
    auto_makeup: c_int,
) void;
pub extern fn flux_dynamics_reset(state: *align(16) CompState) void;
pub extern fn flux_compressor_process(
    state: *align(16) CompState,
    left: [*]f32,
    right: [*]f32,
    frames: u32,
) void;
pub extern fn flux_limiter_configure(
    state: *align(16) CompState,
    sample_rate: u32,
    input_gain_db: f32,
    threshold_db: f32,
    attack_s: f32,
    release_s: f32,
    output_gain_db: f32,
) void;
pub extern fn flux_limiter_process(
    state: *align(16) CompState,
    left: [*]f32,
    right: [*]f32,
    frames: u32,
    ceiling_db: f32,
) void;
