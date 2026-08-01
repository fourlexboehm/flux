//! Stub Signalsmith Stretch ABI for hosts that don't link the C++ wrapper
//! (e.g. DVUI flux-host). Bakes that need stretch fail gracefully via null handles.

#include "wrapper.h"
#include <stddef.h>

signalsmith_stretch_t *signalsmith_stretch_create(int channel_count, size_t block_length, size_t interval) {
    (void)channel_count;
    (void)block_length;
    (void)interval;
    return NULL;
}

signalsmith_stretch_t *signalsmith_stretch_create_preset_default(int channel_count, float sample_rate) {
    (void)channel_count;
    (void)sample_rate;
    return NULL;
}

signalsmith_stretch_t *signalsmith_stretch_create_preset_cheaper(int channel_count, float sample_rate) {
    (void)channel_count;
    (void)sample_rate;
    return NULL;
}

void signalsmith_stretch_destroy(signalsmith_stretch_t *handle) { (void)handle; }
void signalsmith_stretch_reset(signalsmith_stretch_t *handle) { (void)handle; }
size_t signalsmith_stretch_input_latency(signalsmith_stretch_t *handle) {
    (void)handle;
    return 0;
}
size_t signalsmith_stretch_output_latency(signalsmith_stretch_t *handle) {
    (void)handle;
    return 0;
}
void signalsmith_stretch_seek(signalsmith_stretch_t *handle, float *input, size_t input_length, double playback_rate) {
    (void)handle;
    (void)input;
    (void)input_length;
    (void)playback_rate;
}
void signalsmith_stretch_set_transpose_factor(signalsmith_stretch_t *handle, float multiplier, float tonality_limit) {
    (void)handle;
    (void)multiplier;
    (void)tonality_limit;
}
void signalsmith_stretch_set_transpose_factor_semitones(signalsmith_stretch_t *handle, float multiplier, float tonality_limit) {
    (void)handle;
    (void)multiplier;
    (void)tonality_limit;
}
void signalsmith_stretch_set_formant_factor(signalsmith_stretch_t *handle, float multiplier, int compensate_pitch) {
    (void)handle;
    (void)multiplier;
    (void)compensate_pitch;
}
void signalsmith_stretch_set_formant_factor_semitones(signalsmith_stretch_t *handle, float semitones, int compensate_pitch) {
    (void)handle;
    (void)semitones;
    (void)compensate_pitch;
}
void signalsmith_stretch_set_formant_base(signalsmith_stretch_t *handle, float frequency) {
    (void)handle;
    (void)frequency;
}
void signalsmith_stretch_process(signalsmith_stretch_t *handle, float *input, size_t input_length, float *output, size_t output_length) {
    (void)handle;
    (void)input;
    (void)input_length;
    (void)output;
    (void)output_length;
}
bool signalsmith_stretch_exact(signalsmith_stretch_t *handle, float *input, size_t input_length, float *output, size_t output_length) {
    (void)handle;
    (void)input;
    (void)input_length;
    (void)output;
    (void)output_length;
    return false;
}
void signalsmith_stretch_flush(signalsmith_stretch_t *handle, float *output, size_t output_length) {
    (void)handle;
    (void)output;
    (void)output_length;
}
