const Theme = @This();

const std = @import("std");
const Io = std.Io;
const log = std.log;
const mem = std.mem;

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

box_width: f64 = 170.0,
box_height: f64 = 30.0,
border_radius: f64 = 0.0,
dot_spacing: f64 = 9.0,
dot_radius: f64 = 2.4,

pub fn load(io: Io, gpa: mem.Allocator, path: ?[]const u8) Theme {
    var theme: Theme = .{};
    const config_path = path orelse return theme;

    const data = Io.Dir.cwd().readFileAlloc(io, config_path, gpa, .limited(64 * 1024)) catch |err| {
        log.warn("failed to read theme '{s}': {s}", .{ config_path, @errorName(err) });
        return theme;
    };
    defer gpa.free(data);
    theme.loaded = true;

    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = mem.trim(u8, line[0..eq], " \t\r");
        const value = mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (key.len == 0 or value.len == 0) continue;

        if (mem.eql(u8, key, "background_image")) {
            if (theme.background_image) |old| gpa.free(old);
            theme.background_image = gpa.dupe(u8, value) catch null;
        } else if (mem.eql(u8, key, "background_color")) {
            theme.background_color = parseColor(value, theme.background_color);
        } else if (mem.eql(u8, key, "surface_color")) {
            theme.surface_color = parseColor(value, theme.surface_color);
        } else if (mem.eql(u8, key, "surface_opacity")) {
            theme.surface_opacity = parseOpacity(value, theme.surface_opacity);
        } else if (mem.eql(u8, key, "text_color")) {
            theme.text_color = parseColor(value, theme.text_color);
        } else if (mem.eql(u8, key, "primary_color")) {
            theme.primary_color = parseColor(value, theme.primary_color);
        } else if (mem.eql(u8, key, "error_color")) {
            theme.error_color = parseColor(value, theme.error_color);
        } else if (mem.eql(u8, key, "outline_color")) {
            theme.outline_color = parseColor(value, theme.outline_color);
        } else if (mem.eql(u8, key, "box_width")) {
            theme.box_width = parseSize(value, theme.box_width, 40.0, 2000.0);
        } else if (mem.eql(u8, key, "box_height")) {
            theme.box_height = parseSize(value, theme.box_height, 12.0, 400.0);
        } else if (mem.eql(u8, key, "border_radius")) {
            theme.border_radius = parseSize(value, theme.border_radius, 0.0, 100.0);
        } else if (mem.eql(u8, key, "dot_spacing")) {
            theme.dot_spacing = parseSize(value, theme.dot_spacing, 2.0, 40.0);
        } else if (mem.eql(u8, key, "dot_radius")) {
            theme.dot_radius = parseSize(value, theme.dot_radius, 0.5, 12.0);
        }
    }

    return theme;
}

pub fn deinit(theme: *Theme, gpa: mem.Allocator) void {
    if (theme.background_image) |path| gpa.free(path);
    theme.background_image = null;
}

pub fn idleBorder(theme: *const Theme) Rgba {
    return theme.outline_color.withAlpha(0.45);
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

fn parseOpacity(raw: []const u8, fallback: f64) f64 {
    const value = std.fmt.parseFloat(f64, raw) catch return fallback;
    if (value < 0.0 or value > 1.0) return fallback;
    return value;
}

fn parseSize(raw: []const u8, fallback: f64, min: f64, max: f64) f64 {
    const value = std.fmt.parseFloat(f64, raw) catch return fallback;
    if (value < min or value > max) return fallback;
    return value;
}
