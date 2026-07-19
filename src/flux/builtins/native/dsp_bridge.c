#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "miniaudio.h"
#include "sndfilter/compressor.h"

#define FLUX_EQ_STATE_BYTES 8192
#define FLUX_COMP_STATE_BYTES 16384
#define FLUX_EQ_BANDS 8
#define FLUX_BIQUAD_HEAP_BYTES 64

typedef struct {
    ma_biquad filters[FLUX_EQ_BANDS * 2];
    union {
        long double alignment;
        unsigned char bytes[FLUX_BIQUAD_HEAP_BYTES];
    } heaps[FLUX_EQ_BANDS * 2];
    uint32_t initialized;
} flux_eq_state;

typedef struct {
    sf_compressor_state_st compressor;
    int initialized;
} flux_dynamics_state;

_Static_assert(sizeof(flux_eq_state) <= FLUX_EQ_STATE_BYTES, "increase EQ state storage");
_Static_assert(_Alignof(flux_eq_state) <= 16, "increase EQ state alignment");
_Static_assert(sizeof(flux_dynamics_state) <= FLUX_COMP_STATE_BYTES, "increase compressor state storage");
_Static_assert(_Alignof(flux_dynamics_state) <= 16, "increase compressor state alignment");

void flux_eq_init(void *memory)
{
    memset(memory, 0, FLUX_EQ_STATE_BYTES);
}

void flux_eq_reset(void *memory)
{
    flux_eq_state *state = memory;
    for (uint32_t i = 0; i < FLUX_EQ_BANDS * 2; ++i) {
        if (state->initialized & (1u << i))
            ma_biquad_clear_cache(&state->filters[i]);
    }
}

int flux_eq_configure(void *memory, uint32_t band,
    double b0, double b1, double b2, double a0, double a1, double a2)
{
    if (band >= FLUX_EQ_BANDS)
        return 0;
    flux_eq_state *state = memory;
    ma_biquad_config config = ma_biquad_config_init(
        ma_format_f32, 1, b0, b1, b2, a0, a1, a2);

    for (uint32_t channel = 0; channel < 2; ++channel) {
        const uint32_t i = band * 2 + channel;
        ma_result result;
        if (state->initialized & (1u << i)) {
            result = ma_biquad_reinit(&config, &state->filters[i]);
        } else {
            size_t heap_size = 0;
            result = ma_biquad_get_heap_size(&config, &heap_size);
            if (result != MA_SUCCESS || heap_size > FLUX_BIQUAD_HEAP_BYTES)
                return 0;
            result = ma_biquad_init_preallocated(&config, state->heaps[i].bytes, &state->filters[i]);
            if (result == MA_SUCCESS)
                state->initialized |= 1u << i;
        }
        if (result != MA_SUCCESS)
            return 0;
    }
    return 1;
}

void flux_eq_process_band(void *memory, uint32_t band, float *left, float *right, uint32_t frames)
{
    if (band >= FLUX_EQ_BANDS)
        return;
    flux_eq_state *state = memory;
    const uint32_t li = band * 2;
    const uint32_t ri = li + 1;
    if ((state->initialized & (1u << li)) == 0 || (state->initialized & (1u << ri)) == 0)
        return;
    ma_biquad_process_pcm_frames(&state->filters[li], left, left, frames);
    ma_biquad_process_pcm_frames(&state->filters[ri], right, right, frames);
}

static float db_to_linear(float db)
{
    return powf(10.0f, db * 0.05f);
}

void flux_dynamics_reset(void *memory)
{
    memset(memory, 0, FLUX_COMP_STATE_BYTES);
}

static void configure_compressor(flux_dynamics_state *state, uint32_t sample_rate,
    float input_gain_db, float threshold_db, float knee_db, float ratio,
    float attack_s, float release_s, float output_gain_db, int auto_makeup)
{
    float detectoravg = state->compressor.detectoravg;
    float compgain = state->compressor.compgain;
    float maxcompdiffdb = state->compressor.maxcompdiffdb;
    float metergain = state->compressor.metergain;
    sf_sample_st delayed = state->compressor.delaybuf[0];

    sf_advancecomp(&state->compressor, (int)sample_rate, input_gain_db, threshold_db,
        knee_db, ratio, attack_s, release_s, 0.0f, 0.09f, 0.16f, 0.42f, 0.98f,
        output_gain_db, 1.0f);
    if (!auto_makeup)
        state->compressor.mastergain = db_to_linear(output_gain_db);

    if (state->initialized) {
        state->compressor.detectoravg = detectoravg;
        state->compressor.compgain = compgain;
        state->compressor.maxcompdiffdb = maxcompdiffdb;
        state->compressor.metergain = metergain;
        state->compressor.delaybuf[0] = delayed;
    }
    state->initialized = 1;
}

void flux_compressor_configure(void *memory, uint32_t sample_rate, float input_gain_db,
    float threshold_db, float ratio, float attack_s, float release_s,
    float output_gain_db, int auto_makeup)
{
    configure_compressor(memory, sample_rate, input_gain_db, threshold_db, 6.0f,
        ratio, attack_s, release_s, output_gain_db, auto_makeup);
}

void flux_limiter_configure(void *memory, uint32_t sample_rate, float input_gain_db,
    float threshold_db, float attack_s, float release_s, float output_gain_db)
{
    configure_compressor(memory, sample_rate, input_gain_db, threshold_db, 0.0f,
        1000.0f, attack_s, release_s, output_gain_db, 0);
}

static void process_planar(sf_compressor_state_st *state, float *left, float *right, uint32_t frames)
{
    sf_sample_st block[64];
    uint32_t offset = 0;
    while (offset < frames) {
        uint32_t count = frames - offset;
        if (count > 64)
            count = 64;
        for (uint32_t i = 0; i < count; ++i) {
            block[i].L = left[offset + i];
            block[i].R = right[offset + i];
        }
        sf_compressor_process(state, (int)count, block, block);
        for (uint32_t i = 0; i < count; ++i) {
            left[offset + i] = block[i].L;
            right[offset + i] = block[i].R;
        }
        offset += count;
    }
}

void flux_compressor_process(void *memory, float *left, float *right, uint32_t frames)
{
    flux_dynamics_state *state = memory;
    process_planar(&state->compressor, left, right, frames);
}

void flux_limiter_process(void *memory, float *left, float *right, uint32_t frames,
    float ceiling_db)
{
    flux_dynamics_state *state = memory;
    process_planar(&state->compressor, left, right, frames);
    const float ceiling = db_to_linear(ceiling_db);
    for (uint32_t i = 0; i < frames; ++i) {
        left[i] = fmaxf(-ceiling, fminf(ceiling, left[i]));
        right[i] = fmaxf(-ceiling, fminf(ceiling, right[i]));
    }
}
