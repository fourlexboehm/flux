//! Host NSWindow for CLAP cocoa GUI parenting (DVUI path).
//! Compiled with -fobjc-arc.

#import "macos_plugin_window.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

bool flux_plugin_window_create(FluxPluginWindow *out, uint32_t width, uint32_t height, const char *title) {
    if (!out) return false;
    out->ns_window = NULL;
    out->ns_view = NULL;

    @autoreleasepool {
        const CGFloat w = width > 0 ? (CGFloat)width : 800.0;
        const CGFloat h = height > 0 ? (CGFloat)height : 500.0;
        NSRect rect = NSMakeRect(0, 0, w, h);
        NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:rect
                                                       styleMask:style
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        if (!window) return false;
        [window setReleasedWhenClosed:NO];

        NSString *ns_title = title ? [NSString stringWithUTF8String:title] : @"Plugin";
        if (ns_title) [window setTitle:ns_title];

        // Capture main window before ordering plugin front.
        NSWindow *main_window = [NSApp mainWindow];

        NSView *view = [[NSView alloc] initWithFrame:rect];
        if (!view) return false;
        [window setContentView:view];
        [window makeKeyAndOrderFront:nil];

        if (main_window) {
            [main_window addChildWindow:window ordered:NSWindowAbove];
        }

        // Bridge to void*: +1 retain so Zig ownership is explicit under ARC.
        out->ns_window = (__bridge_retained void *)window;
        out->ns_view = (__bridge_retained void *)view;
        return true;
    }
}

void flux_plugin_window_destroy(FluxPluginWindow *win) {
    if (!win) return;
    @autoreleasepool {
        if (win->ns_window) {
            NSWindow *window = (__bridge_transfer NSWindow *)win->ns_window;
            NSWindow *main_window = [NSApp mainWindow];
            if (main_window) {
                [main_window removeChildWindow:window];
            }
            [window setIsVisible:NO];
            [window orderOut:nil];
            // window released by bridge_transfer at end of scope
            win->ns_window = NULL;
        }
        if (win->ns_view) {
            NSView *view = (__bridge_transfer NSView *)win->ns_view;
            (void)view;
            win->ns_view = NULL;
        }
    }
}

void flux_plugin_window_hide(FluxPluginWindow *win) {
    if (!win || !win->ns_window) return;
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win->ns_window;
        [window setIsVisible:NO];
        [window orderOut:nil];
    }
}

bool flux_keyboard_physical_down(uint16_t mac_keycode) {
    // HID system state reflects the physical keyboard regardless of key window.
    // That is what lets the computer piano keep routing when a plugin child
    // NSWindow (or plugin-owned floating window) has focus.
    return (bool)CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, (CGKeyCode)mac_keycode);
}
