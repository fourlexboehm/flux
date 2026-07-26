#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "native_drop.h"
#include <string.h>

#define MAX_PENDING 32
#define MAX_PATH 1024

static char pending_paths[MAX_PENDING][MAX_PATH];
static int pending_count = 0;
static int pending_lens[MAX_PENDING];
static NSView *drop_view = nil;
static Class original_view_class = Nil;
static Class drop_view_class = Nil;

static NSDragOperation dragging_entered(id self, SEL command, id<NSDraggingInfo> sender) {
    (void)self;
    (void)command;
    NSPasteboard *pb = [sender draggingPasteboard];
    NSArray *classes = @[[NSURL class]];
    NSArray *urls = [pb readObjectsForClasses:classes options:@{
        NSPasteboardURLReadingFileURLsOnlyKey: @YES
    }];
    return urls.count > 0 ? NSDragOperationCopy : NSDragOperationNone;
}

static BOOL perform_drag_operation(id self, SEL command, id<NSDraggingInfo> sender) {
    (void)self;
    (void)command;
    NSPasteboard *pb = [sender draggingPasteboard];
    NSArray *classes = @[[NSURL class]];
    NSArray *urls = [pb readObjectsForClasses:classes options:@{
        NSPasteboardURLReadingFileURLsOnlyKey: @YES
    }];
    for (NSURL *url in urls) {
        if (pending_count >= MAX_PENDING) break;
        const char *path = url.path.UTF8String;
        int len = (int)strlen(path);
        if (len >= MAX_PATH) len = MAX_PATH - 1;
        memcpy(pending_paths[pending_count], path, len);
        pending_paths[pending_count][len] = '\0';
        pending_lens[pending_count] = len;
        pending_count++;
    }
    return urls.count > 0;
}

static BOOL wants_periodic_dragging_updates(id self, SEL command) {
    (void)self;
    (void)command;
    return NO;
}

void flux_native_drop_init(void* ns_view) {
    if (drop_view != nil || ns_view == NULL) return;

    // Install the destination methods on this view only. An overlay view changes
    // hit-testing and prevents the Metal/ImGui backend from receiving mouse input.
    drop_view = (__bridge NSView*)ns_view;
    original_view_class = object_getClass(drop_view);
    drop_view_class = objc_allocateClassPair(original_view_class, "FluxDropDestinationView", 0);
    if (drop_view_class == Nil) {
        drop_view = nil;
        original_view_class = Nil;
        return;
    }
    class_addMethod(drop_view_class, @selector(draggingEntered:), (IMP)dragging_entered, "Q@:@");
    class_addMethod(drop_view_class, @selector(performDragOperation:), (IMP)perform_drag_operation, "B@:@");
    class_addMethod(drop_view_class, @selector(wantsPeriodicDraggingUpdates), (IMP)wants_periodic_dragging_updates, "B@:");
    objc_registerClassPair(drop_view_class);
    object_setClass(drop_view, drop_view_class);
    [drop_view registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
}

int flux_native_drop_poll(char* buf, int buf_size) {
    if (pending_count == 0) return 0;
    int len = pending_lens[0];
    if (buf_size < len + 1) return 0;
    memcpy(buf, pending_paths[0], len);
    buf[len] = '\0';
    for (int i = 1; i < pending_count; i++) {
        memcpy(pending_paths[i - 1], pending_paths[i], MAX_PATH);
        pending_lens[i - 1] = pending_lens[i];
    }
    pending_count--;
    return len;
}

void flux_native_drop_shutdown(void) {
    if (drop_view != nil) {
        [drop_view unregisterDraggedTypes];
        object_setClass(drop_view, original_view_class);
    }
    drop_view = nil;
    original_view_class = Nil;
    // Registered Objective-C classes cannot be disposed safely here; reuse is
    // irrelevant because the application owns a single main window.
    drop_view_class = Nil;
    pending_count = 0;
}
