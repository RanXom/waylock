const Theme = @This();

const std = @import("std");
const Io = std.Io;
const log = std.log;
const mem = std.mem;

const cairo = @import("cairo.zig");

pub const Rgba = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1.0,

    pub fn lerp(from: Rgba, to: Rgba, t: f64) Rgba {
        return .{
            .r = from.r + (to.r - from.r) * t,
            .g = from.g + (to.g - from.g) * t,
            .b = from.b + (to.b - from.b) * t,
            .a = from.a + (to.a - from.a) * t,
        };
    }

    pub fn withAlpha(color: Rgba, alpha: f64) Rgba {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = alpha };
    }
};

pub const Anchor = enum {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,

    pub fn fractions(anchor: Anchor) struct { x: f64, y: f64 } {
        return .{
            .x = switch (anchor) {
                .top_left, .center_left, .bottom_left => 0.0,
                .top_center, .center, .bottom_center => 0.5,
                .top_right, .center_right, .bottom_right => 1.0,
            },
            .y = switch (anchor) {
                .top_left, .top_center, .top_right => 0.0,
                .center_left, .center, .center_right => 0.5,
                .bottom_left, .bottom_center, .bottom_right => 1.0,
            },
        };
    }
};

pub const WidgetKind = enum {
    text,
    image,
};

pub const Widget = struct {
    name: ?[]u8 = null,
    kind: WidgetKind = .text,

    text: ?[:0]u8 = null,
    image_path: ?[:0]u8 = null,
    image: ?*cairo.cairo_surface_t = null,

    anchor: Anchor = .center,
    x: f64 = 0.0,
    y: f64 = 0.0,

    font_family: ?[:0]u8 = null,
    font_size: ?f64 = null,
    bold: bool = false,
    color: ?Rgba = null,
    opacity: f64 = 1.0,

    width: ?f64 = null,
    height: ?f64 = null,
};

const max_widgets = 32;

pub const default_background = Rgba{ .r = 0.11, .g = 0.11, .b = 0.15 };
pub const default_surface = Rgba{ .r = 0.17, .g = 0.17, .b = 0.22 };
pub const default_text = Rgba{ .r = 0.90, .g = 0.90, .b = 0.94 };
pub const default_primary = Rgba{ .r = 0.55, .g = 0.72, .b = 1.0 };
pub const default_error = Rgba{ .r = 0.95, .g = 0.35, .b = 0.42 };
pub const default_outline = Rgba{ .r = 0.55, .g = 0.55, .b = 0.62 };

loaded: bool = false,
background_image: ?[]u8 = null,
background_color: Rgba = default_background,
surface_color: Rgba = default_surface,
surface_opacity: f64 = 0.80,
text_color: Rgba = default_text,
primary_color: Rgba = default_primary,
error_color: Rgba = default_error,
outline_color: Rgba = default_outline,

box_width: f64 = 240.0,
box_height: f64 = 42.0,
border_radius: f64 = 0.0,
box_anchor: Anchor = .center,
box_x: f64 = 0.0,
box_y: f64 = 0.0,

dot_spacing: f64 = 9.0,
dot_radius: f64 = 2.4,

font_family: ?[:0]u8 = null,
font_size: f64 = 16.0,
fade_ms: i64 = 250,
compositor_fade: ?bool = null,

widgets: [max_widgets]Widget = undefined,
widget_count: usize = 0,

pub fn load(io: Io, gpa: mem.Allocator, path: ?[]const u8) Theme {
    var theme: Theme = .{};
    const config_path = path orelse return theme;

    const data = Io.Dir.cwd().readFileAlloc(io, config_path, gpa, .limited(64 * 1024)) catch |err| {
        log.warn("failed to read theme '{s}': {s}", .{ config_path, @errorName(err) });
        return theme;
    };
    defer gpa.free(data);
    theme.loaded = true;

    var current_widget: ?usize = null;
    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const end = mem.indexOfScalar(u8, line, ']') orelse continue;
            const section = mem.trim(u8, line[1..end], " \t\r");
            if (mem.startsWith(u8, section, "widget.")) {
                const name = mem.trim(u8, section["widget.".len..], " \t\r");
                current_widget = theme.getOrCreateWidget(gpa, name);
            } else {
                current_widget = null;
            }
            continue;
        }

        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = mem.trim(u8, line[0..eq], " \t\r");
        const value = mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (key.len == 0 or value.len == 0) continue;

        if (current_widget) |index| {
            theme.parseWidgetKey(gpa, &theme.widgets[index], key, value);
        } else {
            theme.parseGlobalKey(gpa, key, value);
        }
    }

    theme.loadWidgetImages();
    return theme;
}

pub fn deinit(theme: *Theme, gpa: mem.Allocator) void {
    if (theme.background_image) |path| gpa.free(path);
    theme.background_image = null;

    if (theme.font_family) |family| gpa.free(family);
    theme.font_family = null;

    for (theme.widgets[0..theme.widget_count]) |*widget| {
        if (widget.name) |name| gpa.free(name);
        if (widget.text) |text| gpa.free(text);
        if (widget.image_path) |path| gpa.free(path);
        if (widget.font_family) |family| gpa.free(family);
        if (widget.image) |image| cairo.cairo_surface_destroy(image);
        widget.* = .{};
    }
    theme.widget_count = 0;
}

pub fn idleBorder(theme: *const Theme) Rgba {
    return theme.outline_color.withAlpha(0.45);
}

fn parseGlobalKey(theme: *Theme, gpa: mem.Allocator, key: []const u8, value: []const u8) void {
    if (mem.eql(u8, key, "background_image")) {
        if (theme.background_image) |old| gpa.free(old);
        theme.background_image = gpa.dupe(u8, value) catch null;
    } else if (mem.eql(u8, key, "compositor_fade")) {
        if (std.ascii.eqlIgnoreCase(value, "auto")) {
            theme.compositor_fade = null;
        } else {
            theme.compositor_fade = parseBool(value) orelse theme.compositor_fade;
        }
    } else if (mem.eql(u8, key, "background_color")) {
        theme.background_color = parseColor(value, theme.background_color);
    } else if (mem.eql(u8, key, "surface_color")) {
        theme.surface_color = parseColor(value, theme.surface_color);
    } else if (mem.eql(u8, key, "surface_opacity")) {
        theme.surface_opacity = parseRange(value, theme.surface_opacity, 0.0, 1.0);
    } else if (mem.eql(u8, key, "text_color")) {
        theme.text_color = parseColor(value, theme.text_color);
    } else if (mem.eql(u8, key, "primary_color")) {
        theme.primary_color = parseColor(value, theme.primary_color);
    } else if (mem.eql(u8, key, "error_color")) {
        theme.error_color = parseColor(value, theme.error_color);
    } else if (mem.eql(u8, key, "outline_color")) {
        theme.outline_color = parseColor(value, theme.outline_color);
    } else if (mem.eql(u8, key, "box_width")) {
        theme.box_width = parseRange(value, theme.box_width, 40.0, 2000.0);
    } else if (mem.eql(u8, key, "box_height")) {
        theme.box_height = parseRange(value, theme.box_height, 12.0, 400.0);
    } else if (mem.eql(u8, key, "border_radius")) {
        theme.border_radius = parseRange(value, theme.border_radius, 0.0, 100.0);
    } else if (mem.eql(u8, key, "box_anchor")) {
        theme.box_anchor = parseAnchor(value) orelse theme.box_anchor;
    } else if (mem.eql(u8, key, "box_x")) {
        theme.box_x = parseRange(value, theme.box_x, -100000.0, 100000.0);
    } else if (mem.eql(u8, key, "box_y")) {
        theme.box_y = parseRange(value, theme.box_y, -100000.0, 100000.0);
    } else if (mem.eql(u8, key, "dot_spacing")) {
        theme.dot_spacing = parseRange(value, theme.dot_spacing, 2.0, 40.0);
    } else if (mem.eql(u8, key, "dot_radius")) {
        theme.dot_radius = parseRange(value, theme.dot_radius, 0.5, 12.0);
    } else if (mem.eql(u8, key, "font_family")) {
        if (theme.font_family) |old| gpa.free(old);
        theme.font_family = gpa.dupeSentinel(u8, value, 0) catch null;
    } else if (mem.eql(u8, key, "font_size")) {
        theme.font_size = parseRange(value, theme.font_size, 6.0, 200.0);
    } else if (mem.eql(u8, key, "fade_ms")) {
        theme.fade_ms = parseMs(value, theme.fade_ms);
    } else {
        log.warn("unknown theme key '{s}'", .{key});
    }
}

fn parseWidgetKey(theme: *Theme, gpa: mem.Allocator, widget: *Widget, key: []const u8, value: []const u8) void {
    if (mem.eql(u8, key, "type")) {
        widget.kind = parseWidgetKind(value) orelse widget.kind;
    } else if (mem.eql(u8, key, "text")) {
        if (widget.text) |old| gpa.free(old);
        widget.text = gpa.dupeSentinel(u8, value, 0) catch null;
    } else if (mem.eql(u8, key, "image")) {
        if (widget.image_path) |old| gpa.free(old);
        widget.image_path = gpa.dupeSentinel(u8, value, 0) catch null;
    } else if (mem.eql(u8, key, "anchor")) {
        widget.anchor = parseAnchor(value) orelse widget.anchor;
    } else if (mem.eql(u8, key, "x")) {
        widget.x = parseRange(value, widget.x, -100000.0, 100000.0);
    } else if (mem.eql(u8, key, "y")) {
        widget.y = parseRange(value, widget.y, -100000.0, 100000.0);
    } else if (mem.eql(u8, key, "font_family")) {
        if (widget.font_family) |old| gpa.free(old);
        widget.font_family = gpa.dupeSentinel(u8, value, 0) catch null;
    } else if (mem.eql(u8, key, "font_size")) {
        widget.font_size = parseRange(value, theme.font_size, 6.0, 200.0);
    } else if (mem.eql(u8, key, "bold")) {
        widget.bold = parseBool(value) orelse widget.bold;
    } else if (mem.eql(u8, key, "color")) {
        widget.color = parseColor(value, theme.text_color);
    } else if (mem.eql(u8, key, "opacity")) {
        widget.opacity = parseRange(value, widget.opacity, 0.0, 1.0);
    } else if (mem.eql(u8, key, "width")) {
        if (parseOptionalRange(value, 1.0, 10000.0)) |width| widget.width = width;
    } else if (mem.eql(u8, key, "height")) {
        if (parseOptionalRange(value, 1.0, 10000.0)) |height| widget.height = height;
    } else {
        log.warn("unknown widget '{s}' key '{s}'", .{ widget.name orelse "?", key });
    }
}

fn getOrCreateWidget(theme: *Theme, gpa: mem.Allocator, name: []const u8) ?usize {
    if (name.len == 0) return null;

    for (theme.widgets[0..theme.widget_count], 0..) |*widget, index| {
        if (widget.name) |existing| {
            if (mem.eql(u8, existing, name)) return index;
        }
    }

    if (theme.widget_count >= max_widgets) {
        log.warn("ignoring widget '{s}': too many widgets", .{name});
        return null;
    }

    const name_copy = gpa.dupe(u8, name) catch {
        log.warn("ignoring widget '{s}': out of memory", .{name});
        return null;
    };
    const index = theme.widget_count;
    theme.widgets[index] = .{ .name = name_copy };
    theme.widget_count += 1;
    return index;
}

fn loadWidgetImages(theme: *Theme) void {
    for (theme.widgets[0..theme.widget_count]) |*widget| {
        if (widget.kind != .image) continue;
        const path = widget.image_path orelse {
            log.warn("image widget '{s}' has no image path", .{widget.name orelse "?"});
            continue;
        };

        const surface = cairo.cairo_image_surface_create_from_png(path.ptr) orelse {
            log.warn("failed to load widget image '{s}'", .{path});
            continue;
        };
        if (cairo.cairo_surface_status(surface) != cairo.STATUS_SUCCESS) {
            log.warn("failed to load widget image '{s}'", .{path});
            cairo.cairo_surface_destroy(surface);
            continue;
        }
        widget.image = surface;
    }
}

fn parseColor(raw: []const u8, fallback: Rgba) Rgba {
    var value = mem.trim(u8, raw, " \t\r\"'");
    if (mem.startsWith(u8, value, "0x")) {
        value = value[2..];
    } else if (mem.startsWith(u8, value, "#")) {
        value = value[1..];
    }

    if (value.len != 6 and value.len != 8) return fallback;

    const r = std.fmt.parseInt(u8, value[0..2], 16) catch return fallback;
    const g = std.fmt.parseInt(u8, value[2..4], 16) catch return fallback;
    const b = std.fmt.parseInt(u8, value[4..6], 16) catch return fallback;
    const a: u8 = if (value.len == 8)
        std.fmt.parseInt(u8, value[6..8], 16) catch 255
    else
        255;

    return .{
        .r = @as(f64, @floatFromInt(r)) / 255.0,
        .g = @as(f64, @floatFromInt(g)) / 255.0,
        .b = @as(f64, @floatFromInt(b)) / 255.0,
        .a = @as(f64, @floatFromInt(a)) / 255.0,
    };
}

fn parseRange(raw: []const u8, fallback: f64, min: f64, max: f64) f64 {
    const value = std.fmt.parseFloat(f64, raw) catch return fallback;
    if (value < min or value > max) return fallback;
    return value;
}

fn parseOptionalRange(raw: []const u8, min: f64, max: f64) ?f64 {
    const value = std.fmt.parseFloat(f64, raw) catch return null;
    if (value < min or value > max) return null;
    return value;
}

fn parseMs(raw: []const u8, fallback: i64) i64 {
    const value = std.fmt.parseInt(i64, raw, 10) catch return fallback;
    if (value < 0 or value > 5000) return fallback;
    return value;
}

fn parseBool(raw: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        mem.eql(u8, raw, "1"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no") or
        mem.eql(u8, raw, "0"))
    {
        return false;
    }
    return null;
}

fn parseWidgetKind(raw: []const u8) ?WidgetKind {
    if (std.ascii.eqlIgnoreCase(raw, "text")) return .text;
    if (std.ascii.eqlIgnoreCase(raw, "image")) return .image;
    return null;
}

fn parseAnchor(raw: []const u8) ?Anchor {
    var buffer: [32]u8 = undefined;
    if (raw.len == 0 or raw.len > buffer.len) return null;

    for (raw, 0..) |char, i| {
        buffer[i] = switch (char) {
            '-', ' ', '_' => '_',
            else => std.ascii.toLower(char),
        };
    }
    const value = buffer[0..raw.len];

    const table = .{
        .{ "top_left", Anchor.top_left },
        .{ "top_center", Anchor.top_center },
        .{ "top_right", Anchor.top_right },
        .{ "center_left", Anchor.center_left },
        .{ "center", Anchor.center },
        .{ "center_right", Anchor.center_right },
        .{ "bottom_left", Anchor.bottom_left },
        .{ "bottom_center", Anchor.bottom_center },
        .{ "bottom_right", Anchor.bottom_right },
    };
    inline for (table) |entry| {
        if (mem.eql(u8, value, entry[0])) return entry[1];
    }
    return null;
}
