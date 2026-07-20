#ifndef FLUX_NATIVE_DROP_H
#define FLUX_NATIVE_DROP_H

#ifdef __cplusplus
extern "C" {
#endif

void flux_native_drop_init(void* ns_view);
int flux_native_drop_poll(char* buf, int buf_size);
void flux_native_drop_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
