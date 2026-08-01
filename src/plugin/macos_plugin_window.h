//! Minimal NSWindow host for CLAP cocoa setParent (no mach-objc / Zig 0.17).
//! Used by the DVUI host when plugins only support non-floating GUIs.

#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FluxPluginWindow {
    void *ns_window; // NSWindow *
    void *ns_view;   // NSView * (content view for clap setParent)
} FluxPluginWindow;

/// Create a titled, closable, resizable NSWindow with an empty NSView content.
/// `title` is UTF-8. Returns false on failure (out is zeroed).
bool flux_plugin_window_create(FluxPluginWindow *out, uint32_t width, uint32_t height, const char *title);

/// Destroy window/view (safe if already null).
void flux_plugin_window_destroy(FluxPluginWindow *win);

/// Hide without destroying.
void flux_plugin_window_hide(FluxPluginWindow *win);

#ifdef __cplusplus
}
#endif
