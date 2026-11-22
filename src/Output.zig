const Output = @This();

const std = @import("std");
const log = std.log;
const math = std.math;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const ext = wayland.client.ext;

const cairo = @import("cairo.zig");

const Lock = @import("Lock.zig");

const ShmBuffer = struct {
    output: *Output,
    wl_buffer: *wl.Buffer,
    data: []align(std.heap.page_size_min) u8,
    surface: *cairo.cairo_surface_t,
    busy: bool = false,
};

lock: *Lock,
name: u32,
wl_output: *wl.Output,
surface: ?*wl.Surface = null,
viewport: ?*wp.Viewport = null,
lock_surface: ?*ext.SessionLockSurfaceV1 = null,

configured: bool = false,
// These fields are not used before the first configure is received.
width: u31 = undefined,
height: u31 = undefined,

buffers: [2]?*ShmBuffer = .{ null, null },

link: wl.list.Link,

pub fn create_surface(output: *Output) !void {
    const surface = try output.lock.compositor.?.createSurface();
    output.surface = surface;

    const lock_surface = try output.lock.session_lock.?.getLockSurface(surface, output.wl_output);
    lock_surface.setListener(*Output, lock_surface_listener, output);
    output.lock_surface = lock_surface;

    output.viewport = try output.lock.viewporter.?.getViewport(surface);
}

pub fn destroy(output: *Output) void {
    output.destroyBuffers();
    output.wl_output.release();
    if (output.viewport) |viewport| viewport.destroy();
    if (output.lock_surface) |lock_surface| lock_surface.destroy();
    if (output.surface) |surface| surface.destroy();

    output.link.remove();
    output.lock.gpa.destroy(output);
}

fn lock_surface_listener(
    _: *ext.SessionLockSurfaceV1,
    event: ext.SessionLockSurfaceV1.Event,
    output: *Output,
) void {
    switch (event) {
        .configure => |ev| {
            const width: u31 = @min(math.maxInt(u31), ev.width);
            const height: u31 = @min(math.maxInt(u31), ev.height);
            const size_changed = !output.configured or output.width != width or output.height != height;

            output.configured = true;
            output.width = width;
            output.height = height;

            if (size_changed or output.buffers[0] == null) {
                output.destroyBuffers();
                output.createBuffers();
            }

            output.lock_surface.?.ackConfigure(ev.serial);
            output.redraw();
        },
    }
}

fn createBuffers(output: *Output) void {
    const shm = output.lock.shm orelse {
        log.err("wl_shm was not advertised", .{});
        return;
    };

    const width: u32 = output.width;
    const height: u32 = output.height;
    const stride: u32 = width * 4;
    const size: usize = @as(usize, stride) * height;

    for (&output.buffers) |*slot| {
        slot.* = createShmBuffer(output, shm, width, height, stride, size) catch |err| {
            log.err("failed to create shared memory buffer: {s}", .{@errorName(err)});
            return;
        };
    }
}

fn createShmBuffer(
    output: *Output,
    shm: *wl.Shm,
    width: u32,
    height: u32,
    stride: u32,
    size: usize,
) !*ShmBuffer {
    const fd = try std.posix.memfd_create("waylock-shm", std.os.linux.MFD.CLOEXEC);
    defer _ = std.c.close(fd);

    if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.TruncateFailed;

    const data = try std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(data);

    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();

    const wl_buffer = try pool.createBuffer(
        0,
        @intCast(width),
        @intCast(height),
        @intCast(stride),
        .argb8888,
    );
    errdefer wl_buffer.destroy();

    const surface = cairo.cairo_image_surface_create_for_data(
        data.ptr,
        cairo.FORMAT_ARGB32,
        @intCast(width),
        @intCast(height),
        @intCast(stride),
    ) orelse return error.CairoSurfaceFailed;
    if (cairo.cairo_surface_status(surface) != cairo.STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surface);
        return error.CairoSurfaceFailed;
    }
    errdefer cairo.cairo_surface_destroy(surface);

    const buffer = try output.lock.gpa.create(ShmBuffer);
    buffer.* = .{
        .output = output,
        .wl_buffer = wl_buffer,
        .data = data,
        .surface = surface,
    };
    wl_buffer.setListener(*ShmBuffer, buffer_listener, buffer);
    return buffer;
}

fn buffer_listener(_: *wl.Buffer, event: wl.Buffer.Event, buffer: *ShmBuffer) void {
    switch (event) {
        .release => buffer.busy = false,
    }
}

fn destroyBuffers(output: *Output) void {
    for (&output.buffers) |*slot| {
        const buffer = slot.* orelse continue;
        slot.* = null;

        buffer.wl_buffer.destroy();
        cairo.cairo_surface_destroy(buffer.surface);
        std.posix.munmap(buffer.data);
        output.lock.gpa.destroy(buffer);
    }
}

fn pickBuffer(output: *Output) ?*ShmBuffer {
    for (&output.buffers) |*slot| {
        if (slot.*) |buffer| {
            if (!buffer.busy) return buffer;
        }
    }
    return null;
}

pub fn redraw(output: *Output) void {
    if (!output.configured) return;

    const buffer = output.pickBuffer() orelse return;
    const cr = cairo.cairo_create(buffer.surface) orelse return;
    defer cairo.cairo_destroy(cr);

    output.lock.render(cr, @floatFromInt(output.width), @floatFromInt(output.height));
    cairo.cairo_surface_flush(buffer.surface);

    buffer.busy = true;
    output.surface.?.attach(buffer.wl_buffer, 0, 0);
    output.surface.?.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
    output.viewport.?.setDestination(output.width, output.height);
    output.surface.?.commit();
}
