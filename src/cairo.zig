// Minimal Cairo bindings for the parts used by the renderer.
//
// Zig 0.17 removed @cImport, so the small surface area we need is declared
// by hand instead of translating cairo.h.

pub const cairo_t = opaque {};
pub const cairo_surface_t = opaque {};
pub const cairo_pattern_t = opaque {};

pub const FORMAT_ARGB32: c_int = 0;
pub const STATUS_SUCCESS: c_int = 0;
pub const OPERATOR_SOURCE: c_int = 1;
pub const OPERATOR_OVER: c_int = 2;
pub const FILTER_BILINEAR: c_int = 4;

pub const FONT_SLANT_NORMAL: c_int = 0;
pub const FONT_WEIGHT_NORMAL: c_int = 0;
pub const FONT_WEIGHT_BOLD: c_int = 1;

pub const TextExtents = extern struct {
    x_bearing: f64,
    y_bearing: f64,
    width: f64,
    height: f64,
    x_advance: f64,
    y_advance: f64,
};

pub extern fn cairo_create(target: *cairo_surface_t) ?*cairo_t;
pub extern fn cairo_destroy(cr: *cairo_t) void;

pub extern fn cairo_save(cr: *cairo_t) void;
pub extern fn cairo_restore(cr: *cairo_t) void;
pub extern fn cairo_translate(cr: *cairo_t, tx: f64, ty: f64) void;
pub extern fn cairo_scale(cr: *cairo_t, sx: f64, sy: f64) void;

pub extern fn cairo_set_operator(cr: *cairo_t, op: c_int) void;
pub extern fn cairo_set_source_rgba(cr: *cairo_t, red: f64, green: f64, blue: f64, alpha: f64) void;
pub extern fn cairo_set_source_surface(cr: *cairo_t, surface: *cairo_surface_t, x: f64, y: f64) void;
pub extern fn cairo_get_source(cr: *cairo_t) ?*cairo_pattern_t;
pub extern fn cairo_pattern_set_filter(pattern: *cairo_pattern_t, filter: c_int) void;
pub extern fn cairo_paint(cr: *cairo_t) void;
pub extern fn cairo_paint_with_alpha(cr: *cairo_t, alpha: f64) void;

pub extern fn cairo_move_to(cr: *cairo_t, x: f64, y: f64) void;
pub extern fn cairo_select_font_face(cr: *cairo_t, family: [*:0]const u8, slant: c_int, weight: c_int) void;
pub extern fn cairo_set_font_size(cr: *cairo_t, size: f64) void;
pub extern fn cairo_show_text(cr: *cairo_t, utf8: [*:0]const u8) void;
pub extern fn cairo_text_extents(cr: *cairo_t, utf8: [*:0]const u8, extents: *TextExtents) void;

pub extern fn cairo_set_line_width(cr: *cairo_t, width: f64) void;
pub extern fn cairo_rectangle(cr: *cairo_t, x: f64, y: f64, width: f64, height: f64) void;
pub extern fn cairo_new_sub_path(cr: *cairo_t) void;
pub extern fn cairo_arc(cr: *cairo_t, xc: f64, yc: f64, radius: f64, angle1: f64, angle2: f64) void;
pub extern fn cairo_close_path(cr: *cairo_t) void;
pub extern fn cairo_fill(cr: *cairo_t) void;
pub extern fn cairo_stroke(cr: *cairo_t) void;

pub extern fn cairo_image_surface_create_for_data(
    data: [*]u8,
    format: c_int,
    width: c_int,
    height: c_int,
    stride: c_int,
) ?*cairo_surface_t;
pub extern fn cairo_image_surface_create_from_png(filename: [*:0]const u8) ?*cairo_surface_t;
pub extern fn cairo_image_surface_get_width(surface: *cairo_surface_t) c_int;
pub extern fn cairo_image_surface_get_height(surface: *cairo_surface_t) c_int;
pub extern fn cairo_surface_status(surface: *cairo_surface_t) c_int;
pub extern fn cairo_surface_flush(surface: *cairo_surface_t) void;
pub extern fn cairo_surface_destroy(surface: *cairo_surface_t) void;
