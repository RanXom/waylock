const Lock = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const log = std.log;
const mem = std.mem;
const posix = std.posix;
const system = std.posix.system;
const process = std.process;
const fatal = process.fatal;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const ext = wayland.client.ext;

const xkb = @import("xkbcommon");

const auth = @import("auth.zig");

const cairo = @import("cairo.zig");
const Output = @import("Output.zig");
const Renderer = @import("Renderer.zig");
const Seat = @import("Seat.zig");
const PasswordBuffer = @import("PasswordBuffer.zig");
const Theme = @import("Theme.zig");

const max_dots = 128;

pub const UiState = enum {
    idle,
    input,
    fail,
};

const FadeDirection = enum {
    none,
    in,
    out,
};

pub const Options = struct {
    fork_on_lock: bool,
    ready_fd: ?posix.fd_t = null,
    ignore_empty_password: bool,
    config_path: ?[]const u8 = null,
    pam_service: []const u8 = "swaylock",
    init_color: u24 = 0x002b36,
    input_color: u24 = 0x6c71c4,
    fail_color: u24 = 0xdc322f,
};

io: Io,
gpa: mem.Allocator,

state: enum {
    /// The session lock object has not yet been created.
    initializing,
    /// The session lock object has been created but the locked event has not been received.
    locking,
    /// The compositor has sent the locked event indicating that the session is locked.
    locked,
    /// Gracefully exiting and cleaning up resources. This could happen because the compositor
    /// did not grant waylock's request to lock the screen or because the user or compositor
    /// has unlocked the session.
    exiting,
} = .initializing,

ui_state: UiState = .idle,
ui_current_color: Theme.Rgba = Theme.default_outline,
ui_from_color: Theme.Rgba = Theme.default_outline,
ui_to_color: Theme.Rgba = Theme.default_outline,
ui_current_width: f64 = 1.0,
ui_from_width: f64 = 1.0,
ui_to_width: f64 = 1.0,
ui_anim_start: i64 = 0,
ui_anim_active: bool = false,

dots: [max_dots]f32 = @splat(0.0),
dot_targets: [max_dots]f32 = @splat(0.0),
dot_count: usize = 0,
password_dots: usize = 0,
last_tick: i64 = 0,

screen_fade: f64 = 1.0,
ui_alpha: f64 = 0.0,
fade_direction: FadeDirection = .none,
fade_start: i64 = 0,
fade_duration_ms: i64 = 250,
fade_from_screen: f64 = 1.0,
fade_from_ui: f64 = 0.0,
pending_unlock: bool = false,
fade_out_done_at: i64 = 0,

fork_on_lock: bool,
ready_fd: ?posix.fd_t,
ignore_empty_password: bool,

theme: Theme,
background: ?*cairo.cairo_surface_t = null,

pollfds: [2]posix.pollfd,

display: *wl.Display,
compositor: ?*wl.Compositor = null,
session_lock_manager: ?*ext.SessionLockManagerV1 = null,
session_lock: ?*ext.SessionLockV1 = null,
viewporter: ?*wp.Viewporter = null,
shm: ?*wl.Shm = null,

seats: wl.list.Head(Seat, .link),
outputs: wl.list.Head(Output, .link),

xkb_context: *xkb.Context,
password: PasswordBuffer,
auth_connection: auth.Connection,

pub fn run(io: Io, gpa: mem.Allocator, options: Options) void {
    var lock: Lock = .{
        .io = io,
        .gpa = gpa,
        .fork_on_lock = options.fork_on_lock,
        .ready_fd = options.ready_fd,
        .ignore_empty_password = options.ignore_empty_password,
        .theme = Theme.load(io, gpa, options.config_path),
        .pollfds = undefined,
        .display = wl.Display.connect(null) catch |err| {
            fatal("failed to connect to a wayland compositor: {s}", .{@errorName(err)});
        },
        .seats = undefined,
        .outputs = undefined,
        .xkb_context = xkb.Context.new(.no_flags) orelse fatal_oom(),
        .password = PasswordBuffer.init(),
        .auth_connection = auth.fork_child(io, options.pam_service),
    };
    defer lock.deinit();

    if (!lock.theme.loaded) {
        lock.theme.background_color = rgbToRgba(options.init_color);
        lock.theme.primary_color = rgbToRgba(options.input_color);
        lock.theme.error_color = rgbToRgba(options.fail_color);
    }

    lock.initUi();
    lock.loadBackground();
    lock.last_tick = lock.nowMs();
    lock.fade_duration_ms = lock.theme.fade_ms;

    lock.seats.init();
    lock.outputs.init();

    const poll_wayland = 0;
    const poll_auth = 1;

    lock.pollfds[poll_wayland] = .{
        .fd = lock.display.getFd(),
        .events = posix.POLL.IN,
        .revents = 0,
    };
    lock.pollfds[poll_auth] = .{
        .fd = lock.auth_connection.read_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    };

    const registry = lock.display.getRegistry() catch fatal_oom();
    defer registry.destroy();
    registry.setListener(*Lock, registry_listener, &lock);

    {
        const errno = lock.display.roundtrip();
        if (errno != .SUCCESS) {
            fatal("initial roundtrip failed: {s}", .{@tagName(errno)});
        }
    }

    if (lock.compositor == null) fatal_not_advertised(wl.Compositor);
    if (lock.session_lock_manager == null) fatal_not_advertised(ext.SessionLockManagerV1);
    if (lock.viewporter == null) fatal_not_advertised(wp.Viewporter);
    if (lock.shm == null) fatal_not_advertised(wl.Shm);

    lock.session_lock = lock.session_lock_manager.?.lock() catch fatal_oom();
    lock.session_lock.?.setListener(*Lock, session_lock_listener, &lock);

    lock.session_lock_manager.?.destroy();
    lock.session_lock_manager = null;

    // From this point onwards we may no longer handle OOM by exiting.
    assert(lock.state == .initializing);
    lock.state = .locking;

    {
        var it = lock.outputs.safeIterator(.forward);
        while (it.next()) |output| {
            output.create_surface() catch {
                log.err("out of memory", .{});
                output.destroy();
                continue;
            };
        }
    }

    while (lock.state != .exiting) {
        lock.flush_wayland_and_prepare_read();

        const timeout: i32 = if (lock.animating()) 16 else -1;
        _ = posix.poll(&lock.pollfds, timeout) catch |err| {
            fatal("poll() failed: {s}", .{@errorName(err)});
        };

        if (lock.pollfds[poll_wayland].revents & posix.POLL.IN != 0) {
            const errno = lock.display.readEvents();
            if (errno != .SUCCESS) {
                fatal("error reading wayland events: {s}", .{@tagName(errno)});
            }
        } else {
            lock.display.cancelRead();
        }

        if (lock.pollfds[poll_auth].revents & posix.POLL.IN != 0) {
            var byte: [1]u8 = undefined;
            var reader = lock.auth_connection.reader(lock.io);
            reader.interface.readSliceAll(&byte) catch |err| {
                fatal("failed to read response from child authentication process: {s}", .{@errorName(err)});
            };
            switch (byte[0]) {
                @intFromBool(true) => {
                    lock.startFadeOut();
                },
                @intFromBool(false) => {
                    lock.setUiState(.fail);
                    lock.updateDots(0);
                },
                else => {
                    fatal("unexpected response received from child authentication process: {d}", .{byte[0]});
                },
            }
        }

        if (lock.tick()) lock.redraw();
    }

    // Calling flush_wayland_and_prepare_read() is not sufficient here as we
    // don't want to exit cleanly until the server processes our request to
    // unlock the session. The only way to guarantee this has occurred is
    // through a roundtrip using the wl_display.sync request.
    const errno = lock.display.roundtrip();
    if (errno != .SUCCESS) {
        fatal("final roundtrip failed: E{s}", .{@tagName(errno)});
    }
}

/// This function does the following:
///  1. Dispatch buffered wayland events to their listener callbacks.
///  2. Prepare the wayland connection for reading.
///  3. Send all buffered wayland requests to the server.
/// After this function has been called, either wl.Display.readEvents() or
/// wl.Display.cancelRead() read must be called.
fn flush_wayland_and_prepare_read(lock: *Lock) void {
    while (!lock.display.prepareRead()) {
        const errno = lock.display.dispatchPending();
        if (errno != .SUCCESS) {
            fatal("failed to dispatch pending wayland events: E{s}", .{@tagName(errno)});
        }
    }

    while (true) {
        const errno = lock.display.flush();
        switch (errno) {
            .SUCCESS => return,
            .PIPE => {
                // libwayland uses this error to indicate that the wayland server
                // closed its side of the wayland socket. We want to continue to
                // read any buffered messages from the server though as there is
                // likely a protocol error message we'd like libwayland to log.
                _ = lock.display.readEvents();
                fatal("connection to wayland server unexpectedly terminated", .{});
            },
            .AGAIN => {
                // The socket buffer is full, so wait for it to become writable again.
                var wayland_out = [_]posix.pollfd{.{
                    .fd = lock.display.getFd(),
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = posix.poll(&wayland_out, -1) catch |err| {
                    fatal("poll() failed: {s}", .{@errorName(err)});
                };
                // No need to check for POLLHUP/POLLERR here, just fall
                // through to the next flush() to handle them in one place.
            },
            else => {
                fatal("failed to flush wayland requests: E{s}", .{@tagName(errno)});
            },
        }
    }
}

/// Clean up resources just so we can better use tooling such as valgrind to check for leaks.
fn deinit(lock: *Lock) void {
    if (lock.compositor) |compositor| compositor.destroy();
    if (lock.viewporter) |viewporter| viewporter.destroy();

    assert(lock.session_lock_manager == null);
    assert(lock.session_lock == null);

    while (lock.seats.first()) |seat| seat.destroy();
    while (lock.outputs.first()) |output| output.destroy();

    if (lock.shm) |shm| shm.destroy();
    if (lock.background) |background| cairo.cairo_surface_destroy(background);
    lock.theme.deinit(lock.gpa);

    lock.display.disconnect();

    lock.xkb_context.unref();

    // There may be further input after submitting a valid password.
    lock.password.clear();

    lock.* = undefined;
}

fn registry_listener(registry: *wl.Registry, event: wl.Registry.Event, lock: *Lock) void {
    lock.registry_event(registry, event) catch |err| switch (err) {
        error.OutOfMemory => {
            log.err("out of memory", .{});
            return;
        },
    };
}

fn registry_event(lock: *Lock, registry: *wl.Registry, event: wl.Registry.Event) !void {
    switch (event) {
        .global => |ev| {
            if (mem.orderZ(u8, ev.interface, wl.Compositor.interface.name) == .eq) {
                // Version 4 required for wl_surface.damage_buffer
                if (ev.version < 4) {
                    fatal("advertised wl_compositor version too old, version 4 required", .{});
                }
                lock.compositor = try registry.bind(ev.name, wl.Compositor, 4);
            } else if (mem.orderZ(u8, ev.interface, ext.SessionLockManagerV1.interface.name) == .eq) {
                lock.session_lock_manager = try registry.bind(ev.name, ext.SessionLockManagerV1, 1);
            } else if (mem.orderZ(u8, ev.interface, wl.Output.interface.name) == .eq) {
                // Version 3 required for wl_output.release
                if (ev.version < 3) {
                    fatal("advertised wl_output version too old, version 3 required", .{});
                }
                const wl_output = try registry.bind(ev.name, wl.Output, 3);
                errdefer wl_output.release();

                const output = try lock.gpa.create(Output);
                errdefer output.destroy();

                output.* = .{
                    .lock = lock,
                    .name = ev.name,
                    .wl_output = wl_output,
                    .link = undefined,
                };
                lock.outputs.prepend(output);

                switch (lock.state) {
                    .initializing, .exiting => {},
                    .locking, .locked => try output.create_surface(),
                }
            } else if (mem.orderZ(u8, ev.interface, wl.Seat.interface.name) == .eq) {
                // Version 5 required for wl_seat.release
                if (ev.version < 5) {
                    fatal("advertised wl_seat version too old, version 5 required.", .{});
                }
                const wl_seat = try registry.bind(ev.name, wl.Seat, 5);
                errdefer wl_seat.release();

                try Seat.create(lock, ev.name, wl_seat);
            } else if (mem.orderZ(u8, ev.interface, wp.Viewporter.interface.name) == .eq) {
                lock.viewporter = try registry.bind(ev.name, wp.Viewporter, 1);
            } else if (mem.orderZ(u8, ev.interface, wl.Shm.interface.name) == .eq) {
                lock.shm = try registry.bind(ev.name, wl.Shm, 1);
            }
        },
        .global_remove => |ev| {
            {
                var it = lock.outputs.safeIterator(.forward);
                while (it.next()) |output| {
                    if (output.name == ev.name) {
                        output.destroy();
                        break;
                    }
                }
            }
            {
                var it = lock.seats.safeIterator(.forward);
                while (it.next()) |seat| {
                    if (seat.name == ev.name) {
                        seat.destroy();
                        break;
                    }
                }
            }
        },
    }
}

fn session_lock_listener(_: *ext.SessionLockV1, event: ext.SessionLockV1.Event, lock: *Lock) void {
    switch (event) {
        .locked => {
            assert(lock.state == .locking);
            lock.state = .locked;
            lock.startFadeIn();
            if (lock.ready_fd) |ready_fd| {
                const file: Io.File = .{ .handle = ready_fd, .flags = .{ .nonblocking = false } };
                defer file.close(lock.io);
                file.writeStreamingAll(lock.io, "\n") catch |err| {
                    fatal("failed to send readiness notification: {s}", .{@errorName(err)});
                };
                lock.ready_fd = null;
            }
            if (lock.fork_on_lock) {
                fork_to_background();
                lock.password.protect_after_fork();
            }
        },
        .finished => {
            switch (lock.state) {
                .initializing => unreachable,
                .locking => {
                    log.err("the wayland compositor has denied our attempt to lock the session, " ++
                        "is another ext-session-lock client already running?", .{});
                    process.exit(1);
                },
                .locked => {
                    log.info("the wayland compositor has unlocked the session, exiting", .{});
                    process.exit(0);
                },
                .exiting => unreachable,
            }
        },
    }
}

pub fn submit_password(lock: *Lock) void {
    assert(lock.state == .locked);

    if (lock.pending_unlock) return;

    if (lock.ignore_empty_password and lock.password.buffer.len == 0) {
        log.info("ignoring submission of empty password", .{});
        return;
    }

    lock.send_password_to_auth() catch |err| {
        fatal("failed to send password to child authentication process: {s}", .{@errorName(err)});
    };

    lock.updateDots(0);
}

pub fn clearPassword(lock: *Lock) void {
    if (lock.pending_unlock) return;
    lock.password.clear();
    lock.updateDots(0);
    lock.setUiState(.idle);
}

pub fn passwordChanged(lock: *Lock) void {
    if (lock.pending_unlock) return;
    const count = std.unicode.utf8CountCodepoints(lock.password.buffer) catch 0;
    lock.updateDots(count);
    lock.setUiState(if (lock.password.buffer.len == 0) .idle else .input);
}

fn send_password_to_auth(lock: *Lock) !void {
    defer lock.password.clear();
    var writer = lock.auth_connection.writer(lock.io);
    const len_bytes: [4]u8 = @bitCast(@as(u32, @intCast(lock.password.buffer.len)));
    try writer.interface.writeAll(&len_bytes);
    try writer.interface.writeAll(lock.password.buffer);
}

fn startFadeIn(lock: *Lock) void {
    if (lock.fade_duration_ms <= 0) {
        lock.screen_fade = 0.0;
        lock.ui_alpha = 1.0;
        lock.redraw();
        return;
    }

    lock.fade_direction = .in;
    lock.fade_start = lock.nowMs();
    lock.fade_from_screen = lock.screen_fade;
    lock.fade_from_ui = lock.ui_alpha;
}

fn startFadeOut(lock: *Lock) void {
    if (lock.pending_unlock) return;

    lock.pending_unlock = true;
    lock.fade_out_done_at = 0;

    if (lock.fade_duration_ms <= 0) {
        lock.screen_fade = 1.0;
        lock.ui_alpha = 0.0;
        lock.fade_direction = .none;
        lock.fade_out_done_at = lock.nowMs();
        lock.redraw();
        return;
    }

    lock.fade_direction = .out;
    lock.fade_start = lock.nowMs();
    lock.fade_from_screen = lock.screen_fade;
    lock.fade_from_ui = lock.ui_alpha;
}

fn finishUnlock(lock: *Lock) void {
    lock.pending_unlock = false;
    if (lock.session_lock) |session_lock| {
        session_lock.unlockAndDestroy();
        lock.session_lock = null;
    }
    lock.state = .exiting;
}

fn initUi(lock: *Lock) void {
    lock.ui_current_color = lock.theme.idleBorder();
    lock.ui_from_color = lock.ui_current_color;
    lock.ui_to_color = lock.ui_current_color;
    lock.ui_current_width = 1.0;
    lock.ui_from_width = 1.0;
    lock.ui_to_width = 1.0;
}

fn loadBackground(lock: *Lock) void {
    const path = lock.theme.background_image orelse return;

    const path_z = lock.gpa.dupeSentinel(u8, path, 0) catch return;
    defer lock.gpa.free(path_z);

    const surface = cairo.cairo_image_surface_create_from_png(path_z.ptr) orelse {
        log.warn("failed to load lock background '{s}'", .{path});
        return;
    };
    if (cairo.cairo_surface_status(surface) != cairo.STATUS_SUCCESS) {
        log.warn("failed to load lock background '{s}'", .{path});
        cairo.cairo_surface_destroy(surface);
        return;
    }
    lock.background = surface;
}

fn setUiState(lock: *Lock, state: UiState) void {
    if (lock.ui_state == state) return;

    const color = switch (state) {
        .idle => lock.theme.idleBorder(),
        .input => lock.theme.primary_color,
        .fail => lock.theme.error_color,
    };
    const width: f64 = switch (state) {
        .idle => 1.0,
        .input => 2.0,
        .fail => 4.0,
    };

    lock.ui_state = state;
    lock.ui_from_color = lock.ui_current_color;
    lock.ui_to_color = color;
    lock.ui_from_width = lock.ui_current_width;
    lock.ui_to_width = width;
    lock.ui_anim_start = lock.nowMs();
    lock.ui_anim_active = true;
}

fn updateDots(lock: *Lock, count: usize) void {
    const n = @min(count, max_dots);
    for (0..max_dots) |i| {
        lock.dot_targets[i] = if (i < n) 1.0 else 0.0;
    }

    if (n > lock.dot_count) {
        for (lock.dot_count..n) |i| lock.dots[i] = 0.0;
        lock.dot_count = n;
    }

    lock.password_dots = n;
}

fn tick(lock: *Lock) bool {
    const now = lock.nowMs();
    var dirty = false;

    if (lock.fade_direction != .none) {
        const duration = lock.fade_duration_ms;
        const elapsed = now - lock.fade_start;
        const t: f64 = if (duration <= 0 or elapsed >= duration)
            1.0
        else
            @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(duration));
        const eased = t * t * (3.0 - 2.0 * t);

        switch (lock.fade_direction) {
            .in => {
                lock.screen_fade = lock.fade_from_screen + (0.0 - lock.fade_from_screen) * eased;
                lock.ui_alpha = lock.fade_from_ui + (1.0 - lock.fade_from_ui) * eased;
            },
            .out => {
                lock.screen_fade = lock.fade_from_screen + (1.0 - lock.fade_from_screen) * eased;
                lock.ui_alpha = lock.fade_from_ui + (0.0 - lock.fade_from_ui) * eased;
            },
            .none => {},
        }

        if (t >= 1.0) {
            lock.fade_direction = .none;
            if (lock.pending_unlock) lock.fade_out_done_at = now;
        }
        dirty = true;
    }

    // Keep the final faded-out frame on screen briefly before asking the
    // compositor to unlock, so the transition does not pop.
    if (lock.pending_unlock and
        lock.fade_direction == .none and
        lock.fade_out_done_at != 0 and
        now >= lock.fade_out_done_at + 80)
    {
        lock.finishUnlock();
        return false;
    }

    if (lock.ui_anim_active) {
        const elapsed = now - lock.ui_anim_start;
        const duration: i64 = 180;
        const t: f64 = if (elapsed >= duration)
            1.0
        else
            @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(duration));
        const eased = t * t * (3.0 - 2.0 * t);

        lock.ui_current_color = Theme.Rgba.lerp(lock.ui_from_color, lock.ui_to_color, eased);
        lock.ui_current_width = lock.ui_from_width + (lock.ui_to_width - lock.ui_from_width) * eased;
        if (t >= 1.0) lock.ui_anim_active = false;
        dirty = true;
    }

    const dt_ms: i64 = @max(0, @min(now - lock.last_tick, 50));
    lock.last_tick = now;

    if (dt_ms > 0) {
        const step: f32 = @floatCast(@as(f64, @floatFromInt(dt_ms)) / 150.0);
        for (0..max_dots) |i| {
            const target = lock.dot_targets[i];
            if (lock.dots[i] < target) {
                lock.dots[i] = @min(target, lock.dots[i] + step);
                dirty = true;
            } else if (lock.dots[i] > target) {
                lock.dots[i] = @max(target, lock.dots[i] - step);
                dirty = true;
            }
        }
    } else {
        for (0..max_dots) |i| {
            if (lock.dots[i] != lock.dot_targets[i]) dirty = true;
        }
    }

    while (lock.dot_count > 0 and
        lock.dots[lock.dot_count - 1] <= 0.001 and
        lock.dot_targets[lock.dot_count - 1] <= 0.001)
    {
        lock.dot_count -= 1;
    }

    return dirty;
}

fn animating(lock: *Lock) bool {
    if (lock.pending_unlock) return true;
    if (lock.fade_direction != .none) return true;
    if (lock.ui_anim_active) return true;
    for (0..max_dots) |i| {
        if (lock.dots[i] != lock.dot_targets[i]) return true;
    }
    return false;
}

fn nowMs(lock: *Lock) i64 {
    return Io.Clock.Timestamp.now(lock.io, .awake).raw.toMilliseconds();
}

fn redraw(lock: *Lock) void {
    var it = lock.outputs.iterator(.forward);
    while (it.next()) |output| output.redraw();
}

pub fn render(lock: *Lock, cr: *cairo.cairo_t, width: f64, height: f64) void {
    Renderer.render(&lock.theme, lock.background, cr, .{
        .width = width,
        .height = height,
        .border = lock.ui_current_color,
        .border_width = lock.ui_current_width,
        .dots = &lock.dots,
        .dot_count = lock.dot_count,
        .ui_alpha = lock.ui_alpha,
        .screen_fade = lock.screen_fade,
    });
}

fn rgbToRgba(rgb: u24) Theme.Rgba {
    return .{
        .r = @as(f64, @floatFromInt((rgb >> 16) & 0xff)) / 255.0,
        .g = @as(f64, @floatFromInt((rgb >> 8) & 0xff)) / 255.0,
        .b = @as(f64, @floatFromInt(rgb & 0xff)) / 255.0,
        .a = 1.0,
    };
}

fn fatal_oom() noreturn {
    fatal("out of memory during initialization", .{});
}

fn fatal_not_advertised(comptime Global: type) noreturn {
    fatal("{s} not advertised", .{Global.interface.name});
}

fn fork_to_background() void {
    const pid: system.pid_t = fork: {
        const rc = system.fork();
        switch (system.errno(rc)) {
            .SUCCESS => break :fork @intCast(rc),
            else => |err| fatal("fork failed: {}", .{err}),
        }
    };
    if (pid == 0) {
        // This can't fail as we are the child of a fork() and therefore not
        // a process group leader.
        _ = system.setsid();
        // Ensure the working directory is on the root filesystem to avoid potentially
        // blocking some other filesystem from being unmounted.
        switch (system.errno(system.chdir("/"))) {
            .SUCCESS => {},
            else => |err| {
                // While this is a nice thing to do, it is not critical to the locking functionality
                // and it is better to allow potentially unlocking the session rather than aborting
                // and leaving the session locked if this fails.
                log.warn("failed to change working directory to / on fork: {}", .{err});
            },
        }
    } else {
        // Terminate the parent process with a clean exit code.
        process.exit(0);
    }
}
