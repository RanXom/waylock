const Renderer = @This();

const std = @import("std");

const cairo = @import("cairo.zig");
const Theme = @import("Theme.zig");

pub const Params = struct {
    width: f64,
    height: f64,
    border: Theme.Rgba,
    border_width: f64,
    dots: []const f32,
    dot_count: usize,
};

pub fn render(
    theme: *const Theme,
    background: ?*cairo.cairo_surface_t,
    cr: *cairo.cairo_t,
    params: Params,
) void {
    drawBackground(theme, background, cr, params.width, params.height);

    const box_w = theme.box_width;
    const box_h = theme.box_height;
    const x = (params.width - box_w) / 2.0;
    const y = (params.height - box_h) / 2.0;

    // Outer hairline, matching the theme reference's faint double border.
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_set_source_rgba(cr, theme.text_color.r, theme.text_color.g, theme.text_color.b, 0.25);
    roundedRect(cr, x - 2.0, y - 2.0, box_w + 4.0, box_h + 4.0, theme.border_radius);
    cairo.cairo_stroke(cr);

    // Translucent field.
    cairo.cairo_set_source_rgba(
        cr,
        theme.surface_color.r,
        theme.surface_color.g,
        theme.surface_color.b,
        theme.surface_opacity,
    );
    roundedRect(cr, x, y, box_w, box_h, theme.border_radius);
    cairo.cairo_fill(cr);

    // Animated state border.
    if (params.border_width > 0.01) {
        const bw = params.border_width;
        const inset = bw / 2.0;
        cairo.cairo_set_line_width(cr, bw);
        cairo.cairo_set_source_rgba(cr, params.border.r, params.border.g, params.border.b, params.border.a);
        roundedRect(
            cr,
            x + inset,
            y + inset,
            box_w - bw,
            box_h - bw,
            @max(0.0, theme.border_radius - inset),
        );
        cairo.cairo_stroke(cr);
    }

    drawDots(theme, cr, params, x, y, box_w, box_h);
}

fn drawBackground(
    theme: *const Theme,
    background: ?*cairo.cairo_surface_t,
    cr: *cairo.cairo_t,
    width: f64,
    height: f64,
) void {
    cairo.cairo_set_operator(cr, cairo.OPERATOR_SOURCE);

    if (background) |image| {
        const image_w = cairo.cairo_image_surface_get_width(image);
        const image_h = cairo.cairo_image_surface_get_height(image);
        if (image_w > 0 and image_h > 0) {
            const iw: f64 = @floatFromInt(image_w);
            const ih: f64 = @floatFromInt(image_h);
            const scale = @max(width / iw, height / ih);

            cairo.cairo_save(cr);
            cairo.cairo_translate(cr, (width - iw * scale) / 2.0, (height - ih * scale) / 2.0);
            cairo.cairo_scale(cr, scale, scale);
            cairo.cairo_set_source_surface(cr, image, 0.0, 0.0);
            if (cairo.cairo_get_source(cr)) |pattern| {
                cairo.cairo_pattern_set_filter(pattern, cairo.FILTER_BILINEAR);
            }
            cairo.cairo_paint(cr);
            cairo.cairo_restore(cr);

            cairo.cairo_set_operator(cr, cairo.OPERATOR_OVER);
            return;
        }
    }

    cairo.cairo_set_source_rgba(
        cr,
        theme.background_color.r,
        theme.background_color.g,
        theme.background_color.b,
        1.0,
    );
    cairo.cairo_paint(cr);
    cairo.cairo_set_operator(cr, cairo.OPERATOR_OVER);
}

fn drawDots(
    theme: *const Theme,
    cr: *cairo.cairo_t,
    params: Params,
    x: f64,
    y: f64,
    box_w: f64,
    box_h: f64,
) void {
    const n = @min(params.dot_count, params.dots.len);
    if (n == 0) return;

    var spacing = theme.dot_spacing;
    if (n > 1) {
        const fit = (box_w - 12.0) / @as(f64, @floatFromInt(n - 1));
        if (fit < spacing) spacing = @max(2.0, fit);
    }

    var radius = @min(theme.dot_radius, spacing * 0.27);
    radius = @max(1.3, radius);

    const x0 = x + box_w / 2.0 - @as(f64, @floatFromInt(n - 1)) * spacing / 2.0;
    const cy = y + box_h / 2.0;

    for (0..n) |i| {
        const alpha: f64 = @floatCast(params.dots[i]);
        if (alpha <= 0.001) continue;
        cairo.cairo_set_source_rgba(
            cr,
            theme.text_color.r,
            theme.text_color.g,
            theme.text_color.b,
            theme.text_color.a * alpha,
        );
        cairo.cairo_arc(cr, x0 + @as(f64, @floatFromInt(i)) * spacing, cy, radius, 0.0, 2.0 * std.math.pi);
        cairo.cairo_fill(cr);
    }
}

fn roundedRect(cr: *cairo.cairo_t, x: f64, y: f64, width: f64, height: f64, radius: f64) void {
    if (radius <= 0.0) {
        cairo.cairo_rectangle(cr, x, y, width, height);
        return;
    }

    const r = @min(radius, @min(width, height) / 2.0);
    cairo.cairo_new_sub_path(cr);
    cairo.cairo_arc(cr, x + width - r, y + r, r, -std.math.pi / 2.0, 0.0);
    cairo.cairo_arc(cr, x + width - r, y + height - r, r, 0.0, std.math.pi / 2.0);
    cairo.cairo_arc(cr, x + r, y + height - r, r, std.math.pi / 2.0, std.math.pi);
    cairo.cairo_arc(cr, x + r, y + r, r, std.math.pi, 3.0 * std.math.pi / 2.0);
    cairo.cairo_close_path(cr);
}
