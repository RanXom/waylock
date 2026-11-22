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
    /// 0 = fully transition image, 1 = fully lock screen.
    progress: f64,
    /// Desktop snapshot captured just before locking, if available.
    transition: ?*cairo.cairo_surface_t,
};

pub fn render(
    theme: *const Theme,
    background: ?*cairo.cairo_surface_t,
    cr: *cairo.cairo_t,
    params: Params,
) void {
    if (params.transition) |snapshot| {
        drawImageFill(snapshot, cr, params.width, params.height, 1.0);
        drawBackground(theme, background, cr, params.width, params.height, params.progress);
    } else {
        // Without a snapshot, fade only the UI over the blurred wallpaper.
        drawBackground(theme, background, cr, params.width, params.height, 1.0);
    }

    drawBox(theme, cr, params, params.progress);
    drawWidgets(theme, cr, params.width, params.height, params.progress);
}

fn drawBox(theme: *const Theme, cr: *cairo.cairo_t, params: Params, alpha: f64) void {
    if (alpha <= 0.001) return;

    const box_w = theme.box_width;
    const box_h = theme.box_height;
    const pos = anchoredPosition(
        theme.box_anchor,
        params.width,
        params.height,
        theme.box_x,
        theme.box_y,
        box_w,
        box_h,
    );
    const x = pos.x;
    const y = pos.y;

    // Outer hairline, matching the theme reference's faint double border.
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_set_source_rgba(cr, theme.text_color.r, theme.text_color.g, theme.text_color.b, 0.25 * alpha);
    roundedRect(cr, x - 2.0, y - 2.0, box_w + 4.0, box_h + 4.0, theme.border_radius);
    cairo.cairo_stroke(cr);

    // Translucent field.
    cairo.cairo_set_source_rgba(
        cr,
        theme.surface_color.r,
        theme.surface_color.g,
        theme.surface_color.b,
        theme.surface_opacity * alpha,
    );
    roundedRect(cr, x, y, box_w, box_h, theme.border_radius);
    cairo.cairo_fill(cr);

    // Animated state border.
    if (params.border_width > 0.01) {
        const bw = params.border_width;
        const inset = bw / 2.0;
        cairo.cairo_set_line_width(cr, bw);
        cairo.cairo_set_source_rgba(
            cr,
            params.border.r,
            params.border.g,
            params.border.b,
            params.border.a * alpha,
        );
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

    drawDots(theme, cr, params, x, y, box_w, box_h, alpha);
}

fn drawWidgets(theme: *const Theme, cr: *cairo.cairo_t, width: f64, height: f64, alpha: f64) void {
    for (theme.widgets[0..theme.widget_count]) |*widget| {
        const widget_alpha = widget.opacity * alpha;
        if (widget_alpha <= 0.001) continue;

        switch (widget.kind) {
            .text => drawTextWidget(theme, widget, cr, width, height, widget_alpha),
            .image => drawImageWidget(widget, cr, width, height, widget_alpha),
        }
    }
}

fn drawTextWidget(
    theme: *const Theme,
    widget: *const Theme.Widget,
    cr: *cairo.cairo_t,
    width: f64,
    height: f64,
    alpha: f64,
) void {
    const text = widget.text orelse return;
    const family = widget.font_family orelse theme.font_family orelse "sans";
    const size = widget.font_size orelse theme.font_size;

    cairo.cairo_select_font_face(
        cr,
        family.ptr,
        cairo.FONT_SLANT_NORMAL,
        if (widget.bold) cairo.FONT_WEIGHT_BOLD else cairo.FONT_WEIGHT_NORMAL,
    );
    cairo.cairo_set_font_size(cr, size);

    var extents: cairo.TextExtents = undefined;
    cairo.cairo_text_extents(cr, text.ptr, &extents);

    const pos = anchoredPosition(
        widget.anchor,
        width,
        height,
        widget.x,
        widget.y,
        extents.width,
        extents.height,
    );

    const color = widget.color orelse theme.text_color;
    cairo.cairo_set_source_rgba(cr, color.r, color.g, color.b, color.a * alpha);
    cairo.cairo_move_to(cr, pos.x - extents.x_bearing, pos.y - extents.y_bearing);
    cairo.cairo_show_text(cr, text.ptr);
}

fn drawImageWidget(
    widget: *const Theme.Widget,
    cr: *cairo.cairo_t,
    width: f64,
    height: f64,
    alpha: f64,
) void {
    const image = widget.image orelse return;

    const natural_w: f64 = @floatFromInt(cairo.cairo_image_surface_get_width(image));
    const natural_h: f64 = @floatFromInt(cairo.cairo_image_surface_get_height(image));
    if (natural_w <= 0.0 or natural_h <= 0.0) return;

    const draw_w = widget.width orelse natural_w;
    const draw_h = widget.height orelse natural_h;
    const pos = anchoredPosition(
        widget.anchor,
        width,
        height,
        widget.x,
        widget.y,
        draw_w,
        draw_h,
    );

    cairo.cairo_save(cr);
    cairo.cairo_translate(cr, pos.x, pos.y);
    if (draw_w != natural_w or draw_h != natural_h) {
        cairo.cairo_scale(cr, draw_w / natural_w, draw_h / natural_h);
    }
    cairo.cairo_set_source_surface(cr, image, 0.0, 0.0);
    if (cairo.cairo_get_source(cr)) |pattern| {
        cairo.cairo_pattern_set_filter(pattern, cairo.FILTER_BILINEAR);
    }
    cairo.cairo_paint_with_alpha(cr, alpha);
    cairo.cairo_restore(cr);
}

fn anchoredPosition(
    anchor: Theme.Anchor,
    screen_w: f64,
    screen_h: f64,
    x: f64,
    y: f64,
    element_w: f64,
    element_h: f64,
) struct { x: f64, y: f64 } {
    const fractions = anchor.fractions();
    return .{
        .x = screen_w * fractions.x + x - element_w * fractions.x,
        .y = screen_h * fractions.y + y - element_h * fractions.y,
    };
}

fn drawImageFill(
    surface: *cairo.cairo_surface_t,
    cr: *cairo.cairo_t,
    width: f64,
    height: f64,
    alpha: f64,
) void {
    const image_w = cairo.cairo_image_surface_get_width(surface);
    const image_h = cairo.cairo_image_surface_get_height(surface);
    if (image_w <= 0 or image_h <= 0) return;

    const iw: f64 = @floatFromInt(image_w);
    const ih: f64 = @floatFromInt(image_h);
    const scale = @max(width / iw, height / ih);

    cairo.cairo_save(cr);
    cairo.cairo_translate(cr, (width - iw * scale) / 2.0, (height - ih * scale) / 2.0);
    cairo.cairo_scale(cr, scale, scale);
    cairo.cairo_set_source_surface(cr, surface, 0.0, 0.0);
    if (cairo.cairo_get_source(cr)) |pattern| {
        cairo.cairo_pattern_set_filter(pattern, cairo.FILTER_BILINEAR);
    }
    cairo.cairo_paint_with_alpha(cr, alpha);
    cairo.cairo_restore(cr);
}

fn drawBackground(
    theme: *const Theme,
    background: ?*cairo.cairo_surface_t,
    cr: *cairo.cairo_t,
    width: f64,
    height: f64,
    alpha: f64,
) void {
    if (alpha <= 0.001) return;

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
            cairo.cairo_paint_with_alpha(cr, alpha);
            cairo.cairo_restore(cr);
            return;
        }
    }

    cairo.cairo_set_source_rgba(
        cr,
        theme.background_color.r,
        theme.background_color.g,
        theme.background_color.b,
        alpha,
    );
    cairo.cairo_paint(cr);
}

fn drawDots(
    theme: *const Theme,
    cr: *cairo.cairo_t,
    params: Params,
    x: f64,
    y: f64,
    box_w: f64,
    box_h: f64,
    alpha: f64,
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
        const dot_alpha: f64 = @floatCast(params.dots[i]);
        if (dot_alpha <= 0.001) continue;
        cairo.cairo_set_source_rgba(
            cr,
            theme.text_color.r,
            theme.text_color.g,
            theme.text_color.b,
            theme.text_color.a * dot_alpha * alpha,
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
