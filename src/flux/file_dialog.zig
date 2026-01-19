//! Native file dialog support for macOS and Linux
//! Uses NSSavePanel/NSOpenPanel on macOS and zenity on Linux

const builtin = @import("builtin");
const std = @import("std");

pub const FileDialogError = error{
    DialogCancelled,
    DialogFailed,
    OutOfMemory,
    Unsupported,
};

pub const FileType = struct {
    name: []const u8,
    extensions: []const []const u8,
};

/// Show a native "Open File" dialog
/// Returns the selected file path or null if cancelled
pub fn openFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    title: []const u8,
    file_types: []const FileType,
) FileDialogError!?[]const u8 {
    switch (builtin.os.tag) {
        .macos => return openFileMacOS(allocator, title, file_types),
        .linux => return openFileLinux(allocator, io, title, file_types),
        else => return FileDialogError.Unsupported,
    }
}

/// Show a native "Save File" dialog
/// Returns the selected file path or null if cancelled
pub fn saveFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    title: []const u8,
    default_name: []const u8,
    file_types: []const FileType,
) FileDialogError!?[]const u8 {
    switch (builtin.os.tag) {
        .macos => return saveFileMacOS(allocator, title, default_name, file_types),
        .linux => return saveFileLinux(allocator, io, title, default_name, file_types),
        else => return FileDialogError.Unsupported,
    }
}

// ============================================================================
// macOS Implementation using Objective-C runtime
// ============================================================================

fn openFileMacOS(
    allocator: std.mem.Allocator,
    title: []const u8,
    file_types: []const FileType,
) FileDialogError!?[]const u8 {
    if (builtin.os.tag != .macos) return FileDialogError.Unsupported;

    const objc = @import("objc");

    // Get NSOpenPanel class and create instance via class method
    const panel = OpenPanel.openPanel();

    // Set title
    const title_z = allocator.dupeZ(u8, title) catch return FileDialogError.OutOfMemory;
    defer allocator.free(title_z);
    const title_str = objc.foundation.String.stringWithUTF8String(title_z.ptr);
    panel.setTitle(title_str);

    // Set allowed file types (using deprecated but working API)
    if (file_types.len > 0) {
        if (createExtensionArray(allocator, file_types)) |exts_array| {
            panel.setAllowedFileTypes(exts_array);
        } else |_| {}
    }

    // Run modal
    const result = panel.runModal();

    // NSModalResponseOK = 1
    if (result != 1) return null;

    // Get URL and path
    const url = panel.URL() orelse return null;
    const path_ns = url.path() orelse return null;
    const path_ptr = path_ns.UTF8String();
    const path_slice = std.mem.span(path_ptr);

    return allocator.dupe(u8, path_slice) catch return FileDialogError.OutOfMemory;
}

fn saveFileMacOS(
    allocator: std.mem.Allocator,
    title: []const u8,
    default_name: []const u8,
    file_types: []const FileType,
) FileDialogError!?[]const u8 {
    if (builtin.os.tag != .macos) return FileDialogError.Unsupported;

    const objc = @import("objc");

    // Get NSSavePanel class and create instance
    const panel = SavePanel.savePanel();

    // Set title
    const title_z = allocator.dupeZ(u8, title) catch return FileDialogError.OutOfMemory;
    defer allocator.free(title_z);
    const title_str = objc.foundation.String.stringWithUTF8String(title_z.ptr);
    panel.setTitle(title_str);

    // Set default filename
    const name_z = allocator.dupeZ(u8, default_name) catch return FileDialogError.OutOfMemory;
    defer allocator.free(name_z);
    const name_str = objc.foundation.String.stringWithUTF8String(name_z.ptr);
    panel.setNameFieldStringValue(name_str);

    // Set allowed file types
    if (file_types.len > 0) {
        if (createExtensionArray(allocator, file_types)) |exts_array| {
            panel.setAllowedFileTypes(exts_array);
        } else |_| {}
    }

    // Run modal
    const result = panel.runModal();

    if (result != 1) return null;

    // Get URL and path
    const url = panel.URL() orelse return null;
    const path_ns = url.path() orelse return null;
    const path_ptr = path_ns.UTF8String();
    const path_slice = std.mem.span(path_ptr);

    return allocator.dupe(u8, path_slice) catch return FileDialogError.OutOfMemory;
}

// Create array of extension strings
fn createExtensionArray(allocator: std.mem.Allocator, file_types: []const FileType) !*NSArray {
    if (builtin.os.tag != .macos) return error.Unsupported;

    const objc = @import("objc");

    // Create mutable array
    const mut_array = NSMutableArray.array();

    for (file_types) |ft| {
        for (ft.extensions) |ext| {
            const ext_z = try allocator.dupeZ(u8, ext);
            defer allocator.free(ext_z);
            const ext_str = objc.foundation.String.stringWithUTF8String(ext_z.ptr);
            mut_array.addObject(@ptrCast(ext_str));
        }
    }

    return @ptrCast(mut_array);
}

// Objective-C bindings for NSSavePanel
const SavePanel = opaque {
    const objc = @import("objc").objc;

    pub const InternalInfo = objc.ExternClass("NSSavePanel", @This(), objc.Id, &.{});

    // Class method to create panel
    pub fn savePanel() *@This() {
        return objc.msgSend(@This().InternalInfo.class(), "savePanel", *@This(), .{});
    }

    pub fn setTitle(self: *@This(), title: *@import("objc").foundation.String) void {
        return objc.msgSend(self, "setTitle:", void, .{title});
    }

    pub fn setNameFieldStringValue(self: *@This(), value: *@import("objc").foundation.String) void {
        return objc.msgSend(self, "setNameFieldStringValue:", void, .{value});
    }

    pub fn setAllowedFileTypes(self: *@This(), types: *NSArray) void {
        return objc.msgSend(self, "setAllowedFileTypes:", void, .{types});
    }

    pub fn runModal(self: *@This()) c_long {
        return objc.msgSend(self, "runModal", c_long, .{});
    }

    pub fn URL(self: *@This()) ?*NSURL {
        return objc.msgSend(self, "URL", ?*NSURL, .{});
    }
};

// Objective-C bindings for NSOpenPanel
const OpenPanel = opaque {
    const objc = @import("objc").objc;

    pub const InternalInfo = objc.ExternClass("NSOpenPanel", @This(), SavePanel, &.{});

    // Class method to create panel
    pub fn openPanel() *@This() {
        return objc.msgSend(@This().InternalInfo.class(), "openPanel", *@This(), .{});
    }

    pub fn setTitle(self: *@This(), title: *@import("objc").foundation.String) void {
        return objc.msgSend(self, "setTitle:", void, .{title});
    }

    pub fn setAllowedFileTypes(self: *@This(), types: *NSArray) void {
        return objc.msgSend(self, "setAllowedFileTypes:", void, .{types});
    }

    pub fn runModal(self: *@This()) c_long {
        return objc.msgSend(self, "runModal", c_long, .{});
    }

    pub fn URL(self: *@This()) ?*NSURL {
        return objc.msgSend(self, "URL", ?*NSURL, .{});
    }
};

// Minimal NSURL binding
const NSURL = opaque {
    const objc = @import("objc").objc;

    pub fn path(self: *@This()) ?*@import("objc").foundation.String {
        return objc.msgSend(self, "path", ?*@import("objc").foundation.String, .{});
    }
};

// NSArray bindings
const NSArray = opaque {};

const NSMutableArray = opaque {
    const objc = @import("objc").objc;

    pub const InternalInfo = objc.ExternClass("NSMutableArray", @This(), objc.Id, &.{});

    pub fn array() *@This() {
        return objc.msgSend(@This().InternalInfo.class(), "array", *@This(), .{});
    }

    pub fn addObject(self: *@This(), obj: *objc.Id) void {
        return objc.msgSend(self, "addObject:", void, .{obj});
    }
};

// ============================================================================
// Linux Implementation using zenity
// ============================================================================

fn openFileLinux(
    allocator: std.mem.Allocator,
    io: std.Io,
    title: []const u8,
    file_types: []const FileType,
) FileDialogError!?[]const u8 {
    if (builtin.os.tag != .linux) return FileDialogError.Unsupported;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        // Free allocated filter args (skip first 3 which are static)
        if (args_list.items.len > 3) {
            for (args_list.items[3..]) |item| {
                allocator.free(item);
            }
        }
        args_list.deinit(allocator);
    }

    args_list.append(allocator, "zenity") catch return FileDialogError.OutOfMemory;
    args_list.append(allocator, "--file-selection") catch return FileDialogError.OutOfMemory;

    const title_arg = std.fmt.allocPrint(allocator, "--title={s}", .{title}) catch return FileDialogError.OutOfMemory;
    args_list.append(allocator, title_arg) catch {
        allocator.free(title_arg);
        return FileDialogError.OutOfMemory;
    };

    // Add file filters
    for (file_types) |ft| {
        var filter_buf: std.ArrayList(u8) = .empty;
        defer filter_buf.deinit(allocator);

        filter_buf.appendSlice(allocator, "--file-filter=") catch return FileDialogError.OutOfMemory;
        filter_buf.appendSlice(allocator, ft.name) catch return FileDialogError.OutOfMemory;
        filter_buf.appendSlice(allocator, " |") catch return FileDialogError.OutOfMemory;

        for (ft.extensions, 0..) |ext, i| {
            if (i > 0) filter_buf.appendSlice(allocator, " ") catch return FileDialogError.OutOfMemory;
            filter_buf.appendSlice(allocator, "*.") catch return FileDialogError.OutOfMemory;
            filter_buf.appendSlice(allocator, ext) catch return FileDialogError.OutOfMemory;
        }

        const filter_arg = filter_buf.toOwnedSlice(allocator) catch return FileDialogError.OutOfMemory;
        args_list.append(allocator, filter_arg) catch {
            allocator.free(filter_arg);
            return FileDialogError.OutOfMemory;
        };
    }

    return runZenity(allocator, io, args_list.items);
}

fn saveFileLinux(
    allocator: std.mem.Allocator,
    io: std.Io,
    title: []const u8,
    default_name: []const u8,
    file_types: []const FileType,
) FileDialogError!?[]const u8 {
    if (builtin.os.tag != .linux) return FileDialogError.Unsupported;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        // Free allocated args (skip first 6 which are static or allocated separately)
        if (args_list.items.len > 6) {
            for (args_list.items[6..]) |item| {
                allocator.free(item);
            }
        }
        args_list.deinit(allocator);
    }

    args_list.append(allocator, "zenity") catch return FileDialogError.OutOfMemory;
    args_list.append(allocator, "--file-selection") catch return FileDialogError.OutOfMemory;
    args_list.append(allocator, "--save") catch return FileDialogError.OutOfMemory;
    args_list.append(allocator, "--confirm-overwrite") catch return FileDialogError.OutOfMemory;

    const title_arg = std.fmt.allocPrint(allocator, "--title={s}", .{title}) catch return FileDialogError.OutOfMemory;
    args_list.append(allocator, title_arg) catch {
        allocator.free(title_arg);
        return FileDialogError.OutOfMemory;
    };

    const filename_arg = std.fmt.allocPrint(allocator, "--filename={s}", .{default_name}) catch return FileDialogError.OutOfMemory;
    args_list.append(allocator, filename_arg) catch {
        allocator.free(filename_arg);
        return FileDialogError.OutOfMemory;
    };

    // Add file filters
    for (file_types) |ft| {
        var filter_buf: std.ArrayList(u8) = .empty;
        defer filter_buf.deinit(allocator);

        filter_buf.appendSlice(allocator, "--file-filter=") catch return FileDialogError.OutOfMemory;
        filter_buf.appendSlice(allocator, ft.name) catch return FileDialogError.OutOfMemory;
        filter_buf.appendSlice(allocator, " |") catch return FileDialogError.OutOfMemory;

        for (ft.extensions, 0..) |ext, i| {
            if (i > 0) filter_buf.appendSlice(allocator, " ") catch return FileDialogError.OutOfMemory;
            filter_buf.appendSlice(allocator, "*.") catch return FileDialogError.OutOfMemory;
            filter_buf.appendSlice(allocator, ext) catch return FileDialogError.OutOfMemory;
        }

        const filter_arg = filter_buf.toOwnedSlice(allocator) catch return FileDialogError.OutOfMemory;
        args_list.append(allocator, filter_arg) catch {
            allocator.free(filter_arg);
            return FileDialogError.OutOfMemory;
        };
    }

    return runZenity(allocator, io, args_list.items);
}

fn runZenity(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) FileDialogError!?[]const u8 {
    if (builtin.os.tag != .linux) return FileDialogError.Unsupported;

    var child = std.process.spawn(io, .{
        .argv = args,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return FileDialogError.DialogFailed;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    // Read stdout
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child.stdout.?.read(io, &buf) catch break;
        if (n == 0) break;
        output.appendSlice(allocator, buf[0..n]) catch return FileDialogError.OutOfMemory;
    }

    const term = child.wait(io) catch return FileDialogError.DialogFailed;

    // zenity returns 0 on OK, 1 on Cancel
    if (term.code != 0) return null;

    // Trim trailing newline
    var result = output.items;
    while (result.len > 0 and (result[result.len - 1] == '\n' or result[result.len - 1] == '\r')) {
        result = result[0 .. result.len - 1];
    }

    if (result.len == 0) return null;

    return allocator.dupe(u8, result) catch return FileDialogError.OutOfMemory;
}
