/**
 * GSK demo 02 — ControlsBar
 *
 * Builds the frosted-glass control bar render-node subtree and maintains
 * the hit rects that VideoPlayerCanvas uses for gesture dispatch.
 */

// ---------------------------------------------------------------------------
// Layout constants
// ---------------------------------------------------------------------------

const float BAR_HEIGHT  = 64.0f;
const float BAR_MARGIN  = 24.0f;
const float BAR_RADIUS  = 18.0f;
const float BLUR_RADIUS = 20.0f;

const float PLAY_ZONE_W = 52.0f;
const float ICON_HALF   = 11.0f;   // icons are designed in ±ICON_HALF space
const float SLIDER_H    = 4.0f;
const float THUMB_R     = 7.0f;
const float VOL_W       = 72.0f;

// ---------------------------------------------------------------------------
// Shared geometry helpers — module-level so EmptyState and VideoPlayerCanvas
// can use them without redefinition.
// ---------------------------------------------------------------------------

Graphene.Rect make_rect (float x, float y, float w, float h) {
    var r = Graphene.Rect ();
    r.init (x, y, w, h);
    return r;
}

Graphene.Point make_pt (float x, float y) {
    var p = Graphene.Point ();
    p.init (x, y);
    return p;
}

// ---------------------------------------------------------------------------
// Icon path builders — each path is centred at the origin, ±ICON_HALF
// ---------------------------------------------------------------------------

Gsk.Path build_play_path () {
    var b = new Gsk.PathBuilder ();
    b.move_to (-8.0f, -10.0f);
    b.line_to ( 10.0f,  0.0f);
    b.line_to ( -8.0f, 10.0f);
    b.close ();
    return b.to_path ();
}

Gsk.Path build_pause_path () {
    var b = new Gsk.PathBuilder ();
    b.move_to (-9.0f, -10.0f); b.line_to (-3.0f, -10.0f);
    b.line_to (-3.0f,  10.0f); b.line_to (-9.0f,  10.0f); b.close ();
    b.move_to ( 3.0f, -10.0f); b.line_to ( 9.0f, -10.0f);
    b.line_to ( 9.0f,  10.0f); b.line_to ( 3.0f,  10.0f); b.close ();
    return b.to_path ();
}

Gsk.Path build_speaker_path (bool muted) {
    var b = new Gsk.PathBuilder ();
    // Speaker cone body
    b.move_to (-9.0f,  -4.5f);
    b.line_to (-3.0f,  -4.5f);
    b.line_to ( 3.0f, -10.0f);
    b.line_to ( 3.0f,  10.0f);
    b.line_to (-3.0f,   4.5f);
    b.line_to (-9.0f,   4.5f);
    b.close ();

    if (!muted) {
        // Sound wave 1: thin wedge arc, x ≈ 5..7
        b.move_to (5.0f, -4.5f);
        b.svg_arc_to (5.5f, 5.5f, 0, false, true,  5.0f,  4.5f);
        b.line_to (7.0f, 3.5f);
        b.svg_arc_to (7.5f, 7.5f, 0, false, false, 7.0f, -3.5f);
        b.close ();
        // Sound wave 2: larger wedge arc, x ≈ 7..10
        b.move_to (7.5f, -7.5f);
        b.svg_arc_to (9.5f, 9.5f, 0, false, true,  7.5f,  7.5f);
        b.line_to (9.5f,  6.0f);
        b.svg_arc_to (11.0f, 11.0f, 0, false, false, 9.5f, -6.0f);
        b.close ();
    } else {
        // Diagonal slash through the speaker (parallelogram)
        b.move_to ( 5.0f, -11.0f);
        b.line_to (11.0f,  -5.0f);
        b.line_to (-5.0f,  11.0f);
        b.line_to (-11.0f,  5.0f);
        b.close ();
    }
    return b.to_path ();
}

Gsk.Path build_fullscreen_path () {
    var b = new Gsk.PathBuilder ();
    // Four corner L-shapes pointing outward — each is a 6-point closed polygon
    // Top-left
    b.move_to (-12.0f,  -7.0f); b.line_to (-12.0f, -12.0f); b.line_to ( -7.0f, -12.0f);
    b.line_to ( -7.0f,  -9.0f); b.line_to ( -9.0f,  -9.0f); b.line_to ( -9.0f,  -7.0f);
    b.close ();
    // Top-right
    b.move_to (  7.0f, -12.0f); b.line_to ( 12.0f, -12.0f); b.line_to ( 12.0f,  -7.0f);
    b.line_to (  9.0f,  -7.0f); b.line_to (  9.0f,  -9.0f); b.line_to (  7.0f,  -9.0f);
    b.close ();
    // Bottom-left
    b.move_to (-12.0f,   7.0f); b.line_to (-12.0f,  12.0f); b.line_to ( -7.0f,  12.0f);
    b.line_to ( -7.0f,   9.0f); b.line_to ( -9.0f,   9.0f); b.line_to ( -9.0f,   7.0f);
    b.close ();
    // Bottom-right
    b.move_to ( 12.0f,   7.0f); b.line_to ( 12.0f,  12.0f); b.line_to (  7.0f,  12.0f);
    b.line_to (  7.0f,   9.0f); b.line_to (  9.0f,   9.0f); b.line_to (  9.0f,   7.0f);
    b.close ();
    return b.to_path ();
}

// ---------------------------------------------------------------------------
// ControlsBar
// ---------------------------------------------------------------------------

class ControlsBar : Object {

    // Hit rects written by build_node(), read by VideoPlayerCanvas gesture handlers
    public Graphene.Rect hit_play       = Graphene.Rect ();
    public Graphene.Rect hit_mute       = Graphene.Rect ();
    public Graphene.Rect hit_fullscreen = Graphene.Rect ();
    public Graphene.Rect hit_progress   = Graphene.Rect ();
    public Graphene.Rect hit_volume     = Graphene.Rect ();
    public float progress_track_x = 0;
    public float progress_track_w = 0;
    public float volume_track_x   = 0;
    public float volume_track_w   = 0;

    // Cached icon paths (built once at construction)
    private Gsk.Path play_path;
    private Gsk.Path pause_path;
    private Gsk.Path speaker_path;
    private Gsk.Path speaker_muted_path;
    private Gsk.Path fullscreen_path;

    construct {
        play_path          = build_play_path ();
        pause_path         = build_pause_path ();
        speaker_path       = build_speaker_path (false);
        speaker_muted_path = build_speaker_path (true);
        fullscreen_path    = build_fullscreen_path ();
    }

    // Builds the full control bar node tree and updates all hit rects as a
    // side effect.  owner is required solely to create Pango layouts.
    public Gsk.RenderNode build_node (float w, float h, Graphene.Rect vr,
                                       Gtk.MediaStream media, Gtk.Widget owner) {
        float bar_w  = w - 2.0f * BAR_MARGIN;
        float bar_x  = BAR_MARGIN;
        float bar_y  = h - BAR_HEIGHT - BAR_MARGIN;
        float bar_cy = bar_y + BAR_HEIGHT / 2.0f;
        var   bar_rect  = make_rect (bar_x, bar_y, bar_w, BAR_HEIGHT);
        var   bar_rrect = Gsk.RoundedRect ();
        bar_rrect.init_from_rect (bar_rect, BAR_RADIUS);

        // ---- Frosted-glass backdrop ----

        var drop_shadow = new Gsk.OutsetShadowNode (
            bar_rrect, { 0f, 0f, 0f, 0.45f }, 0f, 8f, 0f, 24f);

        // VIDEO #2 — same media snapshotted again into a sub-snapshot.
        // A TransformNode places it at (vr.x, vr.y) in widget space so the
        // blurred copy aligns with the raw pixels visible under the bar.
        var sub2 = new Gtk.Snapshot ();
        media.snapshot (sub2, vr.get_width (), vr.get_height ());
        var vid2 = sub2.to_node ();

        Gsk.RenderNode glass_fill;
        if (vid2 != null) {
            var t_align = new Gsk.Transform ()
                .translate (make_pt (vr.get_x (), vr.get_y ()));
            var aligned = new Gsk.TransformNode (vid2, t_align);
            var blurred = new Gsk.BlurNode (aligned, BLUR_RADIUS);
            var tint    = new Gsk.ColorNode ({ 1f, 1f, 1f, 0.12f }, bar_rect);
            Gsk.RenderNode[] g = { blurred, tint };
            glass_fill = new Gsk.ContainerNode (g);
        } else {
            glass_fill = new Gsk.ColorNode ({ 0.08f, 0.08f, 0.08f, 0.85f }, bar_rect);
        }
        var glass_clipped = new Gsk.RoundedClipNode (glass_fill, bar_rrect);

        float[] bw = { 1f, 1f, 1f, 1f };
        Gdk.RGBA[] bc = {
            { 1f, 1f, 1f, 0.18f }, { 1f, 1f, 1f, 0.18f },
            { 1f, 1f, 1f, 0.18f }, { 1f, 1f, 1f, 0.18f }
        };
        var bar_border = new Gsk.BorderNode (bar_rrect, bw, bc);

        // ---- Play / pause icon ----
        float play_cx = bar_x + PLAY_ZONE_W / 2.0f;
        hit_play = make_rect (bar_x, bar_y, PLAY_ZONE_W, BAR_HEIGHT);
        var play_icon = build_icon_node (
            media.get_playing () ? pause_path : play_path,
            play_cx, bar_cy);

        // ---- Fullscreen icon (far right) ----
        float pad   = 10.0f;
        float fs_cx = bar_x + bar_w - pad - ICON_HALF;
        hit_fullscreen = make_rect (fs_cx - ICON_HALF, bar_y, ICON_HALF * 2.0f, BAR_HEIGHT);
        var fs_icon = build_icon_node (fullscreen_path, fs_cx, bar_cy);

        // ---- Volume slider ----
        float vol_right = fs_cx - ICON_HALF - pad;
        float vol_left  = vol_right - VOL_W;
        volume_track_x  = vol_left;
        volume_track_w  = VOL_W;
        double vol_ratio = media.get_muted () ? 0.0 : media.get_volume ();
        if (vol_ratio < 0.0) vol_ratio = 0.0;
        if (vol_ratio > 1.0) vol_ratio = 1.0;
        float vol_thumb_x;
        var vol_nodes = build_slider_nodes (vol_left, bar_cy, VOL_W, vol_ratio,
                                            out vol_thumb_x);
        hit_volume = make_rect (vol_left - THUMB_R, bar_y,
                                VOL_W + THUMB_R * 2.0f, BAR_HEIGHT);

        // ---- Mute icon ----
        float mute_cx = vol_left - pad - ICON_HALF;
        hit_mute = make_rect (mute_cx - ICON_HALF, bar_y,
                              ICON_HALF * 2.0f + pad, BAR_HEIGHT);
        var mute_icon = build_icon_node (
            media.get_muted () ? speaker_muted_path : speaker_path,
            mute_cx, bar_cy);

        // ---- Timestamp — one layout used for both measurement and rendering ----
        int64 ts  = media.get_timestamp ();
        int64 dur = media.get_duration ();
        string ts_str = format_time (ts) + " / " + format_time (dur);

        var ts_layout = owner.create_pango_layout (ts_str);
        ts_layout.set_font_description (Pango.FontDescription.from_string ("Monospace 11"));
        int tw, th;
        ts_layout.get_pixel_size (out tw, out th);

        float time_right = mute_cx - ICON_HALF - pad;
        float time_left  = time_right - (float) tw;
        float time_top   = bar_cy - (float) th / 2.0f;
        Gsk.RenderNode? time_node = render_layout (ts_layout, time_left, time_top);

        // ---- Progress bar ----
        float prog_left  = bar_x + PLAY_ZONE_W + pad;
        float prog_right = time_left - pad;
        float prog_w     = prog_right - prog_left;
        if (prog_w < 4.0f) prog_w = 4.0f;
        progress_track_x = prog_left;
        progress_track_w = prog_w;

        double prog_ratio = (dur > 0) ? (double) ts / (double) dur : 0.0;
        if (prog_ratio < 0.0) prog_ratio = 0.0;
        if (prog_ratio > 1.0) prog_ratio = 1.0;
        float prog_thumb_x;
        var prog_nodes = build_slider_nodes (prog_left, bar_cy, prog_w, prog_ratio,
                                             out prog_thumb_x);
        hit_progress = make_rect (prog_left - THUMB_R, bar_y,
                                  prog_w + THUMB_R * 2.0f, BAR_HEIGHT);

        // ---- Compose ----
        Gsk.RenderNode[] items = {};
        items += drop_shadow;
        items += glass_clipped;
        items += bar_border;
        items += play_icon;
        foreach (var n in prog_nodes)  items += n;
        if (time_node != null)         items += time_node;
        items += mute_icon;
        foreach (var n in vol_nodes)   items += n;
        items += fs_icon;

        return new Gsk.ContainerNode (items);
    }

    // Build a [track, fill, thumb] trio of render nodes for a horizontal slider.
    private Gsk.RenderNode[] build_slider_nodes (
            float left_x, float cy, float slider_w, double ratio,
            out float thumb_x_out) {
        float ty       = cy - SLIDER_H / 2.0f;
        float fw       = (float)(ratio * slider_w);
        float thumb_cx = left_x + fw;
        thumb_x_out    = thumb_cx;

        var track_r = make_rect (left_x, ty, slider_w, SLIDER_H);
        var fill_r  = make_rect (left_x, ty, fw,        SLIDER_H);
        var thr     = make_rect (thumb_cx - THUMB_R, cy - THUMB_R,
                                 THUMB_R * 2.0f, THUMB_R * 2.0f);
        var thr_rr  = Gsk.RoundedRect ();
        thr_rr.init_from_rect (thr, THUMB_R);
        var thumb = new Gsk.RoundedClipNode (
            new Gsk.ColorNode ({ 1f, 1f, 1f, 1f }, thr), thr_rr);

        Gsk.RenderNode[] nodes = {
            new Gsk.ColorNode ({ 1f, 1f, 1f, 0.25f }, track_r),
            new Gsk.ColorNode ({ 1f, 1f, 1f, 0.95f }, fill_r),
            thumb
        };
        return nodes;
    }

    // Icons are designed at the origin in ±ICON_HALF space; TransformNode places
    // them at (cx, cy). ColorNode is used as the FillNode paint source.
    private Gsk.RenderNode build_icon_node (Gsk.Path path, float cx, float cy) {
        var paint_bounds = make_rect (-ICON_HALF, -ICON_HALF,
                                      ICON_HALF * 2.0f, ICON_HALF * 2.0f);
        var paint = new Gsk.ColorNode ({ 1f, 1f, 1f, 1f }, paint_bounds);
        var fill  = new Gsk.FillNode (paint, path, Gsk.FillRule.WINDING);
        return new Gsk.TransformNode (
            fill, new Gsk.Transform ().translate (make_pt (cx, cy)));
    }

    // Wrap a pre-built Pango layout into a positioned TransformNode.
    private static Gsk.RenderNode? render_layout (Pango.Layout layout, float x, float y) {
        var sub  = new Gtk.Snapshot ();
        sub.append_layout (layout, { 1f, 1f, 1f, 1f });
        var node = sub.to_node ();
        if (node == null) return null;
        return new Gsk.TransformNode (
            node, new Gsk.Transform ().translate (make_pt (x, y)));
    }

    private static string format_time (int64 us) {
        if (us < 0) us = 0;
        int64 total_s = us / 1000000;
        int   hh      = (int)(total_s / 3600);
        int   mm      = (int)((total_s % 3600) / 60);
        int   ss      = (int)(total_s % 60);
        if (hh > 0)
            return "%d:%02d:%02d".printf (hh, mm, ss);
        return "%d:%02d".printf (mm, ss);
    }
}
