const builtin = @import("builtin");
const objc = if (builtin.os.tag == .macos) @import("objc") else struct {};

pub const AppWindow = if (builtin.os.tag == .macos) struct {
    app: *objc.app_kit.Application,
    window: *objc.app_kit.Window,
    view: *objc.app_kit.View,
    device: *objc.metal.Device,
    layer: *objc.quartz_core.MetalLayer,
    command_queue: *objc.metal.CommandQueue,
    scale_factor: f32,

    pub fn init(title: [:0]const u8, width: f64, height: f64) !AppWindow {
        const app = objc.app_kit.Application.sharedApplication();
        _ = app.setActivationPolicy(objc.app_kit.ApplicationActivationPolicyRegular);
        app.activateIgnoringOtherApps(true);

        const rect = objc.app_kit.Rect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = width, .height = height },
        };
        const style = objc.app_kit.WindowStyleMaskTitled |
            objc.app_kit.WindowStyleMaskClosable |
            objc.app_kit.WindowStyleMaskResizable |
            objc.app_kit.WindowStyleMaskMiniaturizable;
        const window = objc.app_kit.Window.alloc().initWithContentRect_styleMask_backing_defer_screen(
            rect,
            style,
            objc.app_kit.BackingStoreBuffered,
            false,
            null,
        );
        window.setReleasedWhenClosed(false);
        const title_str = objc.foundation.String.stringWithUTF8String(title);
        window.setTitle(title_str);
        window.center();

        const view = objc.app_kit.View.alloc().initWithFrame(rect);
        view.setWantsLayer(true);
        window.setContentView(view);
        window.makeKeyAndOrderFront(null);

        const device = objc.metal.createSystemDefaultDevice().?;
        const layer = objc.quartz_core.MetalLayer.allocInit();
        layer.setDevice(device);
        layer.setPixelFormat(objc.metal.PixelFormatBGRA8Unorm);
        layer.setFramebufferOnly(true);
        view.setLayer(layer.as(objc.quartz_core.Layer));

        const command_queue = device.newCommandQueue().?;
        const scale_factor: f32 = @floatCast(window.backingScaleFactor());

        return .{
            .app = app,
            .window = window,
            .view = view,
            .device = device,
            .layer = layer,
            .command_queue = command_queue,
            .scale_factor = scale_factor,
        };
    }

    pub fn deinit(self: *AppWindow) void {
        self.command_queue.release();
        self.layer.release();
        self.device.release();
        self.view.release();
        self.window.release();
    }
} else struct {};
