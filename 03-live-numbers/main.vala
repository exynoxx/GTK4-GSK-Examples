/**
 * GSK demo 03: live-numbers dashboard — neon gauges & animated metrics.
 *
 * New nodes demonstrated (not in 01/02):
 *   - ConicGradientNode      (rainbow-sweep arc gauge fills)
 *   - RadialGradientNode     (glow halos behind gauges and KPI tiles)
 *   - StrokeNode             (stroked arc rings, sparklines — GTK ≥ 4.14)
 *   - RepeatingLinearGradientNode  (diagonal scan-line backdrop)
 *
 */

// ---------------------------------------------------------------------------
// Layout constants
// ---------------------------------------------------------------------------

const float WIN_W      = 1280.0f;
const float WIN_H      = 800.0f;
const float OUTER_PAD  = 16.0f;
const float TILE_GAP   = 12.0f;
const float HEADER_H   = 48.0f;
const int   GRID_COLS  = 6;
const int   GRID_ROWS  = 4;
const float CARD_R     = 12.0f;

// ---------------------------------------------------------------------------
// Geometry helpers
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

Gsk.RoundedRect rrect_from (Graphene.Rect r, float radius) {
    var rr = Gsk.RoundedRect ();
    rr.init_from_rect (r, radius);
    return rr;
}

float fclamp (float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// ---------------------------------------------------------------------------
// Mock-data model
// ---------------------------------------------------------------------------

class Metric : Object {
    public float current;
    public float target;
    public float lo;
    public float hi;
    public float[] history;
    public int    hist_head;
    public int64  next_target_us;

    public Metric (float lo, float hi, float initial_ratio, int64 phase_us) {
        this.lo = lo;
        this.hi = hi;
        float init = lo + initial_ratio * (hi - lo);
        this.current = init;
        this.target  = init;
        this.history = new float[60];
        for (int i = 0; i < 60; i++) history[i] = current;
        this.hist_head = 0;
        this.next_target_us = phase_us;
    }

    public float ratio () {
        if (hi == lo) return 0.0f;
        return fclamp ((current - lo) / (hi - lo), 0.0f, 1.0f);
    }
}

// ---------------------------------------------------------------------------
// Dashboard widget
// ---------------------------------------------------------------------------

class DashboardCanvas : Gtk.Widget {

    // ---- animation state ----
    private uint  tick_id         = 0;
    private int64 last_frame_us   = 0;
    private int64 last_sample_us  = 0;
    private int64 tick_us         = 0;
    private Rand  rng;

    // ---- metrics ----
    private Metric headline;
    private Metric kpi_a;
    private Metric kpi_b;
    private Metric arc_a;
    private Metric arc_b;
    private Metric speedo;
    private Metric spark_wide;
    private Metric[] donut;
    private Metric[] bars;
    private Metric[] progress_bars;
    private Metric[,] heat;

    // ---- pre-built static paths ----
    private Gsk.Path arrow_up;
    private Gsk.Path arrow_down;

    // ---- Pango layout pool (created ONCE in realize, reused via set_text) ----
    private Pango.Layout? lay_36b  = null;   // Cantarell Bold 36
    private Pango.Layout? lay_22b  = null;   // Cantarell Bold 22
    private Pango.Layout? lay_20b  = null;   // Cantarell Bold 20
    private Pango.Layout? lay_18b  = null;   // Cantarell Bold 18
    private Pango.Layout? lay_16b  = null;   // Cantarell Bold 16
    private Pango.Layout? lay_10b  = null;   // Cantarell Bold 10
    private Pango.Layout? lay_9b   = null;   // Cantarell Bold 9
    private Pango.Layout? lay_8b   = null;   // Cantarell Bold 8
    private Pango.Layout? lay_11r  = null;   // Cantarell 11
    private Pango.Layout? lay_10r  = null;   // Cantarell 10
    private Pango.Layout? lay_9r   = null;   // Cantarell 9

    // ---- size-dependent cache ----
    private float last_w = 0;
    private float last_h = 0;
    // Immutable sub-trees that never change once the size is known:
    private Gsk.RenderNode? node_bg_scan  = null;  // background + scanlines
    private Gsk.RenderNode? node_header_static = null;  // separator + subtitle
    private Gsk.RenderNode?[] node_cards  = new Gsk.RenderNode?[12];
    // Tile title label nodes per tile
    private Gsk.RenderNode?[] node_tile_labels = new Gsk.RenderNode?[12];
    // Cached arc track paths (vary with cx/cy/rad, i.e. with window size)
    private Gsk.Path? p_arc_track  = null;  // 270° ring for arc gauge
    private float     p_arc_cx = 0;
    private float     p_arc_cy = 0;
    private float     p_arc_rad = 0;
    private Gsk.Path? p_spd_track  = null;  // 180° arc for speedometer
    private float     p_spd_cx = 0;
    private float     p_spd_cy = 0;
    private float     p_spd_rad = 0;
    // Cached tile rects
    private float tile_w = 0;
    private float tile_h = 0;
    private float grid_x0 = 0;
    private float grid_y0 = 0;

    // -----------------------------------------------------------------------
    construct {
        set_size_request ((int) WIN_W, (int) WIN_H);
        rng = new Rand.with_seed (7);

        headline     = new Metric (8000,  65000, 0.45f, 0);
        kpi_a        = new Metric (-20,    40,   0.55f, 400000);
        kpi_b        = new Metric ( 20,   320,   0.30f, 900000);
        arc_a        = new Metric (  0,     1,   0.62f, 1300000);
        arc_b        = new Metric (  0,     1,   0.38f, 1800000);
        speedo       = new Metric (  0,     1,   0.50f, 2200000);
        spark_wide   = new Metric (  0,     1,   0.40f, 100000);

        donut = new Metric[5];
        for (int i = 0; i < 5; i++)
            donut[i] = new Metric (0.05f, 0.50f, (float) i / 5.0f, i * 550000);

        bars = new Metric[12];
        for (int i = 0; i < 12; i++)
            bars[i] = new Metric (0.05f, 1.0f, (float) i / 12.0f, i * 200000);

        progress_bars = new Metric[4];
        for (int i = 0; i < 4; i++)
            progress_bars[i] = new Metric (0.05f, 0.95f, (float) i / 4.0f, i * 750000);

        heat = new Metric[5, 5];
        for (int y = 0; y < 5; y++)
            for (int x = 0; x < 5; x++)
                heat[y, x] = new Metric (0.0f, 1.0f, (y * 5 + x) / 25.0f, (y * 5 + x) * 280000);

        arrow_up   = build_arrow (true);
        arrow_down = build_arrow (false);
    }

    ~DashboardCanvas () {
        if (tick_id != 0) remove_tick_callback (tick_id);
    }

    // -----------------------------------------------------------------------
    // realize / unrealize
    // -----------------------------------------------------------------------

    public override void realize () {
        base.realize ();

        // Build Pango layout pool ONCE — cheapest possible text rendering
        lay_36b = make_layout ("Cantarell Bold 36");
        lay_22b = make_layout ("Cantarell Bold 22");
        lay_20b = make_layout ("Cantarell Bold 20");
        lay_18b = make_layout ("Cantarell Bold 18");
        lay_16b = make_layout ("Cantarell Bold 16");
        lay_10b = make_layout ("Cantarell Bold 10");
        lay_9b  = make_layout ("Cantarell Bold 9");
        lay_8b  = make_layout ("Cantarell Bold 8");
        lay_11r = make_layout ("Cantarell 11");
        lay_10r = make_layout ("Cantarell 10");
        lay_9r  = make_layout ("Cantarell 9");

        last_frame_us  = get_frame_clock ().get_frame_time ();
        last_sample_us = last_frame_us;

        tick_id = add_tick_callback ((widget, clock) => {
            tick_us = clock.get_frame_time ();
            float dt = (float) ((tick_us - last_frame_us) / 1000000.0);
            if (dt > 0.1f) dt = 0.1f;
            last_frame_us = tick_us;

            advance (headline,   tick_us, dt);
            advance (kpi_a,      tick_us, dt);
            advance (kpi_b,      tick_us, dt);
            advance (arc_a,      tick_us, dt);
            advance (arc_b,      tick_us, dt);
            advance (speedo,     tick_us, dt);
            advance (spark_wide, tick_us, dt);
            foreach (var m in donut)         advance (m, tick_us, dt);
            foreach (var m in bars)          advance (m, tick_us, dt);
            foreach (var m in progress_bars) advance (m, tick_us, dt);
            for (int y = 0; y < 5; y++)
                for (int x = 0; x < 5; x++)
                    advance (heat[y, x], tick_us, dt);

            if (tick_us - last_sample_us >= 100000) {
                last_sample_us = tick_us;
                push_sample (headline);
                push_sample (kpi_a);
                push_sample (kpi_b);
                push_sample (spark_wide);
            }

            widget.queue_draw ();
            return Source.CONTINUE;
        });
    }

    public override void unrealize () {
        if (tick_id != 0) { remove_tick_callback (tick_id); tick_id = 0; }
        base.unrealize ();
    }

    private Pango.Layout make_layout (string desc) {
        var lay = create_pango_layout ("");
        lay.set_font_description (Pango.FontDescription.from_string (desc));
        return lay;
    }

    // -----------------------------------------------------------------------
    // Data helpers
    // -----------------------------------------------------------------------

    private void advance (Metric m, int64 now, float dt) {
        if (now >= m.next_target_us) {
            m.target = (float) (rng.next_double () * (m.hi - m.lo) + m.lo);
            m.next_target_us = now + (int64) ((2.0 + rng.next_double () * 3.5) * 1000000);
        }
        float k = 1.0f - (float) Math.exp (-2.8 * dt);
        m.current += (m.target - m.current) * k;
    }

    private void push_sample (Metric m) {
        m.history[m.hist_head] = m.current;
        m.hist_head = (m.hist_head + 1) % m.history.length;
    }

    // -----------------------------------------------------------------------
    // Text helpers — use the layout pool, no allocation overhead
    // -----------------------------------------------------------------------

    // Render text at (x,y) using pre-created layout
    private Gsk.RenderNode? lt_at (Pango.Layout lay, string text,
                                    Gdk.RGBA color, float x, float y) {
        lay.set_text (text, -1);
        var sub = new Gtk.Snapshot ();
        sub.append_layout (lay, color);
        var node = sub.to_node ();
        if (node == null) return null;
        return new Gsk.TransformNode (
            node, new Gsk.Transform ().translate (make_pt (x, y)));
    }

    // Render text centred on cx, top at y
    private Gsk.RenderNode? lt_cx (Pango.Layout lay, string text,
                                    Gdk.RGBA color, float cx, float y) {
        lay.set_text (text, -1);
        int tw, th;
        lay.get_pixel_size (out tw, out th);
        var sub = new Gtk.Snapshot ();
        sub.append_layout (lay, color);
        var node = sub.to_node ();
        if (node == null) return null;
        return new Gsk.TransformNode (
            node, new Gsk.Transform ().translate (
                make_pt (cx - (float) tw * 0.5f, y)));
    }

    // -----------------------------------------------------------------------
    // Size-dependent cache rebuild (called once per window size change)
    // -----------------------------------------------------------------------

    private void rebuild_size_caches (float w, float h) {
        // Recompute grid
        float grid_w = w - 2.0f * OUTER_PAD;
        float grid_h = h - HEADER_H - OUTER_PAD;
        tile_w  = (grid_w - (GRID_COLS - 1) * TILE_GAP) / (float) GRID_COLS;
        tile_h  = (grid_h - (GRID_ROWS - 1) * TILE_GAP) / (float) GRID_ROWS;
        grid_x0 = OUTER_PAD;
        grid_y0 = HEADER_H;

        // 1. Background + scanlines
        Gsk.ColorStop[] bg_stops = {
            { 0.0f, { 0.06f, 0.05f, 0.14f, 1.0f } },
            { 1.0f, { 0.02f, 0.02f, 0.06f, 1.0f } },
        };
        var bg = new Gsk.RadialGradientNode (
            make_rect (0, 0, w, h),
            make_pt (w * 0.5f, h * 0.3f),
            w * 0.7f, h * 0.7f,
            0.0f, 1.0f, bg_stops);

        Gsk.ColorStop[] sl_stops = {
            { 0.00f, { 1f, 1f, 1f, 0.000f } },
            { 0.48f, { 1f, 1f, 1f, 0.000f } },
            { 0.50f, { 1f, 1f, 1f, 0.028f } },
            { 0.52f, { 1f, 1f, 1f, 0.000f } },
            { 1.00f, { 1f, 1f, 1f, 0.000f } },
        };
        var scanlines = new Gsk.RepeatingLinearGradientNode (
            make_rect (0, 0, w, h),
            make_pt (0, 0), make_pt (4, 4), sl_stops);
        node_bg_scan = new Gsk.ContainerNode (
            new Gsk.RenderNode[] { bg, scanlines });

        // 2. Header static chrome (separator + subtitle)
        Gsk.RenderNode[] hkids = {};
        hkids += new Gsk.ColorNode ({ 1f, 1f, 1f, 0.06f },
                                    make_rect (0, HEADER_H - 1, w, 1));
        var hs = lt_at (lay_11r,
                        "System Monitor  ·  Mock Data",
                        { 1f, 1f, 1f, 0.30f }, w - 248.0f, 15.0f);
        if (hs != null) hkids += hs;
        node_header_static = new Gsk.ContainerNode (hkids);

        // 3. Card chrome (12 tiles)
        for (int i = 0; i < 12; i++)
            node_cards[i] = build_card (tile_rect (i), card_fill (i));

        // 4. Static tile labels (do NOT change with data)
        string[] titles = {
            "TOTAL REQUESTS / s",  // 0 headline — this one overlaps dynamic data, skip
            "REVENUE",             // 1
            "LATENCY",             // 2
            "THROUGHPUT",          // 3 speedo
            "CPU",                 // 4 arc_a
            "MEM",                 // 5 arc_b
            "DISTRIBUTION",        // 6 donut
            "TRENDS",              // 7 sparkline
            "HOURLY TRAFFIC",      // 8 bars
            "",                    // 9 progress (no single title)
            "HEAT MAP",            // 10
            "SERVICES",            // 11
        };
        for (int i = 0; i < 12; i++) {
            if (titles[i].length == 0) { node_tile_labels[i] = null; continue; }
            var r = tile_rect (i);
            float tcx = r.get_x () + r.get_width () * 0.5f;
            float ty  = r.get_y () + 10.0f;
            // Exceptions: headline label is centered lower
            if (i == 0) {
                ty = r.get_y () + r.get_height () * 0.5f + 18.0f;
                node_tile_labels[i] = lt_cx (lay_10r, titles[i],
                                             { 1f, 1f, 1f, 0.38f }, tcx, ty);
            } else {
                node_tile_labels[i] = lt_cx (lay_9b, titles[i],
                                             { 1f, 1f, 1f, 0.38f }, tcx, ty);
            }
        }

        // 5. Track arc paths (tied to tile geometry)
        // Arc gauge a (tile 4)
        {
            var r  = tile_rect (4);
            float cx  = r.get_x () + r.get_width () * 0.5f;
            float cy  = r.get_y () + r.get_height () * 0.5f + 4.0f;
            float rad = float.min (r.get_width (), r.get_height ()) * 0.32f;
            p_arc_cx = cx; p_arc_cy = cy; p_arc_rad = rad;
            p_arc_track = build_arc (-90.0f, 270.0f, cx, cy, rad);
        }
        // Speedometer (tile 3)
        {
            var r  = tile_rect (3);
            float cx  = r.get_x () + r.get_width () * 0.5f;
            float cy  = r.get_y () + r.get_height () * 0.70f;
            float rad = float.min (r.get_width () * 0.44f, r.get_height () * 0.55f);
            p_spd_cx = cx; p_spd_cy = cy; p_spd_rad = rad;
            p_spd_track = build_arc (180.0f, 180.0f, cx, cy, rad);
        }
    }

    // Tile index → Graphene.Rect (uses cached grid params)
    private Graphene.Rect tile_rect (int idx) {
        // Tile layout: 12 tiles, spans matching the grid plan
        int[,] layout = {
        //  col  row  cspan  rspan
            { 0,  0,   2,    1 },   // 0 headline
            { 2,  0,   1,    1 },   // 1 kpi_a
            { 3,  0,   1,    1 },   // 2 kpi_b
            { 4,  0,   2,    2 },   // 3 speedo
            { 0,  1,   1,    1 },   // 4 arc_a
            { 1,  1,   1,    1 },   // 5 arc_b
            { 2,  1,   2,    2 },   // 6 donut
            { 0,  2,   2,    1 },   // 7 sparkline
            { 0,  3,   3,    1 },   // 8 bars
            { 3,  3,   2,    1 },   // 9 progress
            { 4,  2,   2,    1 },   // 10 heatmap
            { 5,  3,   1,    1 },   // 11 pills
        };
        int c  = layout[idx, 0];
        int r  = layout[idx, 1];
        int cs = layout[idx, 2];
        int rs = layout[idx, 3];
        float x  = grid_x0 + (float) c  * (tile_w + TILE_GAP);
        float y  = grid_y0 + (float) r  * (tile_h + TILE_GAP);
        float ww = (float) cs * tile_w + (float) (cs - 1) * TILE_GAP;
        float hh = (float) rs * tile_h + (float) (rs - 1) * TILE_GAP;
        return make_rect (x, y, ww, hh);
    }

    private Gdk.RGBA card_fill (int idx) {
        // All cards share the same translucent fill
        return { 0.06f, 0.05f, 0.13f, 0.90f };
    }

    // Build card chrome: shadow + rounded clip fill + border
    private Gsk.RenderNode build_card (Graphene.Rect r, Gdk.RGBA fill) {
        var rr     = rrect_from (r, CARD_R);
        var shadow = new Gsk.OutsetShadowNode (rr, { 0f, 0f, 0f, 0.48f }, 0f, 4f, 0f, 16f);
        var face   = new Gsk.RoundedClipNode (new Gsk.ColorNode (fill, r), rr);
        float[] bw  = { 1f, 1f, 1f, 1f };
        Gdk.RGBA[] bc = {
            { 1f, 1f, 1f, 0.10f }, { 1f, 1f, 1f, 0.10f },
            { 1f, 1f, 1f, 0.10f }, { 1f, 1f, 1f, 0.10f },
        };
        return new Gsk.ContainerNode (
            new Gsk.RenderNode[] { shadow, face, new Gsk.BorderNode (rr, bw, bc) });
    }

    // -----------------------------------------------------------------------
    // Arc path builder (class method — no free-function shadowing issue)
    // -----------------------------------------------------------------------

    private Gsk.Path build_arc (float a0, float sweep, float cx, float cy, float r) {
        var b = new Gsk.PathBuilder ();
        if (sweep > -0.5f && sweep < 0.5f) {
            double a = a0 * Math.PI / 180.0;
            float sx = cx + r * (float) Math.cos (a);
            float sy = cy + r * (float) Math.sin (a);
            b.move_to (sx, sy); b.line_to (sx, sy);
            return b.to_path ();
        }
        bool cw = sweep > 0.0f;
        double a_rad = a0 * Math.PI / 180.0;
        b.move_to (cx + r * (float) Math.cos (a_rad),
                   cy + r * (float) Math.sin (a_rad));
        float remaining = sweep;
        float a_cur = a0;
        while ((cw && remaining > 0.01f) || (!cw && remaining < -0.01f)) {
            float step = cw ? float.min (remaining, 179.0f)
                            : float.max (remaining, -179.0f);
            float a_end = a_cur + step;
            double a_end_rad = a_end * Math.PI / 180.0;
            b.svg_arc_to (r, r, 0.0f, false, cw,
                          cx + r * (float) Math.cos (a_end_rad),
                          cy + r * (float) Math.sin (a_end_rad));
            a_cur = a_end;
            remaining -= step;
        }
        return b.to_path ();
    }

    private Gsk.Path build_arrow (bool up) {
        var b = new Gsk.PathBuilder ();
        if (up) {
            b.move_to ( 0.0f, -6.0f); b.line_to ( 6.0f,  2.0f); b.line_to ( 2.0f,  2.0f);
            b.line_to ( 2.0f,  6.0f); b.line_to (-2.0f,  6.0f); b.line_to (-2.0f,  2.0f);
            b.line_to (-6.0f,  2.0f);
        } else {
            b.move_to ( 0.0f,  6.0f); b.line_to ( 6.0f, -2.0f); b.line_to ( 2.0f, -2.0f);
            b.line_to ( 2.0f, -6.0f); b.line_to (-2.0f, -6.0f); b.line_to (-2.0f, -2.0f);
            b.line_to (-6.0f, -2.0f);
        }
        b.close ();
        return b.to_path ();
    }

    // -----------------------------------------------------------------------
    // Sparkline helper
    // -----------------------------------------------------------------------

    private Gsk.RenderNode? build_sparkline (Metric m,
                                              float x0, float y0,
                                              float w, float h,
                                              Gdk.RGBA color) {
        float[] hist = m.history;
        int len = hist.length;
        float data_lo = hist[0]; float data_hi = hist[0];
        for (int i = 1; i < len; i++) {
            if (hist[i] < data_lo) data_lo = hist[i];
            if (hist[i] > data_hi) data_hi = hist[i];
        }
        float span = data_hi - data_lo;
        if (span < 0.001f) span = 0.001f;
        var b = new Gsk.PathBuilder ();
        float step = w / (float) (len - 1);
        int head = m.hist_head;
        for (int i = 0; i < len; i++) {
            float val = hist[(head + i) % len];
            float px = x0 + (float) i * step;
            float py = y0 + h - (val - data_lo) / span * h;
            if (i == 0) b.move_to (px, py); else b.line_to (px, py);
        }
        var stroke = new Gsk.Stroke (1.5f);
        stroke.set_line_cap  (Gsk.LineCap.ROUND);
        stroke.set_line_join (Gsk.LineJoin.ROUND);
        var paint = new Gsk.ColorNode (color, make_rect (x0, y0, w, h + 2));
        return new Gsk.StrokeNode (paint, b.to_path (), stroke);
    }

    // -----------------------------------------------------------------------
    // snapshot — root scene
    // -----------------------------------------------------------------------

    public override void snapshot (Gtk.Snapshot snap) {
        float w = (float) get_width ();
        float h = (float) get_height ();
        if (w < 1 || h < 1) return;

        // Rebuild size-dependent caches only when the window size changes
        if (w != last_w || h != last_h) {
            last_w = w; last_h = h;
            rebuild_size_caches (w, h);
        }

        Gsk.RenderNode[] scene = {};
        scene += node_bg_scan;

        // Header
        scene += build_header_dynamic ();
        if (node_header_static != null) scene += node_header_static;

        // Tiles
        scene += tile_headline    (0);
        scene += tile_kpi         (1, kpi_a, "$",   { 0.1f, 0.9f, 0.5f, 1f });
        scene += tile_kpi         (2, kpi_b, " ms", { 1.0f, 0.6f, 0.1f, 1f });
        scene += tile_speedo      (3);
        scene += tile_arc_gauge   (4, arc_a, { 1.0f, 0.2f, 0.8f, 1f }, { 0.5f, 0.1f, 1.0f, 1f });
        scene += tile_arc_gauge   (5, arc_b, { 0.1f, 0.9f, 1.0f, 1f }, { 0.1f, 0.4f, 1.0f, 1f });
        scene += tile_donut       (6);
        scene += tile_sparkline   (7);
        scene += tile_bars        (8);
        scene += tile_progress    (9);
        scene += tile_heatmap     (10);
        scene += tile_pills       (11);

        snap.append_node (new Gsk.ContainerNode (scene));
    }

    // -----------------------------------------------------------------------
    // Header — only the animated parts rebuilt each frame
    // -----------------------------------------------------------------------

    private Gsk.RenderNode build_header_dynamic () {
        Gsk.RenderNode[] kids = {};

        // Title (static text — but cheap with cached layout)
        var t = lt_at (lay_16b, "LIVE NUMBERS", { 1f, 1f, 1f, 0.90f }, OUTER_PAD, 12.0f);
        if (t != null) kids += t;

        // Pulsing LIVE pill
        float pulse = (float) (Math.sin (tick_us * 2.5e-6) * 0.4 + 0.6);
        float pill_w = 54.0f; float pill_h = 20.0f;
        float pill_x = OUTER_PAD + 186.0f; float pill_y = 14.0f;
        var pr  = make_rect (pill_x, pill_y, pill_w, pill_h);
        var prr = rrect_from (pr, pill_h * 0.5f);
        var pfill  = new Gsk.RoundedClipNode (
            new Gsk.ColorNode ({ 1.0f, 0.2f, 0.3f, 0.90f }, pr), prr);
        var pglow  = new Gsk.OutsetShadowNode (prr, { 1.0f, 0.1f, 0.2f, 0.55f }, 0f, 0f, 0f, 8f);
        var pill   = new Gsk.OpacityNode (
            new Gsk.ContainerNode (new Gsk.RenderNode[] { pglow, pfill }), pulse);
        kids += pill;
        var lt = lt_cx (lay_9b, "LIVE", { 1f, 1f, 1f, 1f },
                        pill_x + pill_w * 0.5f, pill_y + 4.0f);
        if (lt != null) kids += lt;

        return new Gsk.ContainerNode (kids);
    }

    // -----------------------------------------------------------------------
    // Tile: headline big number
    // -----------------------------------------------------------------------

    private Gsk.RenderNode tile_headline (int idx) {
        var r  = tile_rect (idx);
        float cx = r.get_x () + r.get_width () * 0.5f;
        float cy = r.get_y () + r.get_height () * 0.5f;

        Gsk.ColorStop[] gs = {
            { 0.0f, { 0.4f, 0.1f, 0.9f, 0.32f } },
            { 1.0f, { 0.4f, 0.1f, 0.9f, 0.00f } },
        };
        var glow = new Gsk.RadialGradientNode (
            make_rect (r.get_x (), r.get_y (), r.get_width (), r.get_height ()),
            make_pt (cx, cy),
            r.get_width () * 0.5f, r.get_height () * 0.7f,
            0.0f, 1.0f, gs);

        var num = lt_cx (lay_36b, "%.0f".printf (headline.current),
                         { 0.9f, 0.5f, 1.0f, 1.0f }, cx, cy - 26.0f);

        Gsk.RenderNode[] kids = { node_cards[idx], glow };
        if (num != null) kids += num;
        if (node_tile_labels[idx] != null) kids += node_tile_labels[idx];
        return new Gsk.ContainerNode (kids);
    }

    // -----------------------------------------------------------------------
    // Tile: KPI with delta + sparkline
    // -----------------------------------------------------------------------

    private Gsk.RenderNode tile_kpi (int idx, Metric m, string unit, Gdk.RGBA accent) {
        var r  = tile_rect (idx);
        float cx  = r.get_x () + r.get_width () * 0.5f;
        float top = r.get_y () + 10.0f;

        var vt = lt_cx (lay_22b,
                        "%.1f%s".printf (m.current, unit),
                        { accent.red, accent.green, accent.blue, 1.0f },
                        cx, top + 16.0f);

        float delta = m.current - m.history[(m.hist_head + 59) % 60];
        bool up = delta >= 0;
        Gdk.RGBA arrow_col;
        if (up) { arrow_col = { 0.2f, 1.0f, 0.4f, 1.0f }; }
        else    { arrow_col = { 1.0f, 0.3f, 0.3f, 1.0f }; }
        float arrow_y = top + 50.0f;
        var arrow_paint = new Gsk.ColorNode (arrow_col,
            make_rect (cx - 8, arrow_y - 8, 16, 16));
        var arrow_fill  = new Gsk.FillNode (
            arrow_paint, up ? arrow_up : arrow_down, Gsk.FillRule.WINDING);
        var arrow_node  = new Gsk.TransformNode (
            arrow_fill, new Gsk.Transform ().translate (make_pt (cx, arrow_y)));

        float sp_x = r.get_x () + 10.0f;
        float sp_y = r.get_y () + r.get_height () - 34.0f;
        float sp_w = r.get_width () - 20.0f;
        float sp_h = 24.0f;
        var spk = build_sparkline (m, sp_x, sp_y, sp_w, sp_h, accent);

        Gsk.RenderNode[] kids = { node_cards[idx] };
        if (node_tile_labels[idx] != null) kids += node_tile_labels[idx];
        if (vt != null) kids += vt;
        kids += arrow_node;
        if (spk != null) kids += spk;
        return new Gsk.ContainerNode (kids);
    }

    // -----------------------------------------------------------------------
    // Tile: arc gauge
    // -----------------------------------------------------------------------

    private Gsk.RenderNode tile_arc_gauge (int idx, Metric m,
                                            Gdk.RGBA ca, Gdk.RGBA cb) {
        var r = tile_rect (idx);
        // Use shared geometry from cache (arc_a and arc_b share same tile size)
        float cx  = p_arc_cx;
        float cy  = p_arc_cy;
        float rad = p_arc_rad;
        // Offset cy/cx to match tile idx (tile 4 vs 5 have different x)
        {
            var ri = tile_rect (idx);
            cx = ri.get_x () + ri.get_width () * 0.5f;
            cy = ri.get_y () + ri.get_height () * 0.5f + 4.0f;
            rad = float.min (ri.get_width (), ri.get_height ()) * 0.32f;
        }
        float thick = 9.0f;
        float gb    = rad + thick + 2;
        var   gb_r  = make_rect (cx - gb, cy - gb, gb * 2, gb * 2);

        // Track ring (dim) — path rebuilt only when geometry changes, but it's fast
        // For arc gauges tile 4 and 5 share same track shape (just offset cx)
        var track_path = build_arc (-90.0f, 270.0f, cx, cy, rad);
        var track_stroke = new Gsk.Stroke (thick);
        track_stroke.set_line_cap (Gsk.LineCap.ROUND);
        var track = new Gsk.StrokeNode (
            new Gsk.ColorNode ({ 1f, 1f, 1f, 0.08f }, gb_r), track_path, track_stroke);

        // Active arc (conic-gradient child inside StrokeNode)
        float sweep = 270.0f * m.ratio ();
        Gsk.RenderNode? active_arc = null;
        if (sweep > 0.5f) {
            Gsk.ColorStop[] cs = {
                { 0.0f, { ca.red, ca.green, ca.blue, 1.0f } },
                { 0.5f, { cb.red, cb.green, cb.blue, 1.0f } },
                { 1.0f, { ca.red, ca.green, ca.blue, 1.0f } },
            };
            var conic      = new Gsk.ConicGradientNode (gb_r, make_pt (cx, cy), 0.0f, cs);
            var arc_stroke = new Gsk.Stroke (thick);
            arc_stroke.set_line_cap (Gsk.LineCap.ROUND);
            active_arc = new Gsk.StrokeNode (conic,
                                              build_arc (-90.0f, sweep, cx, cy, rad),
                                              arc_stroke);
        }

        // Radial glow
        Gsk.ColorStop[] gs = {
            { 0.0f, { ca.red, ca.green, ca.blue, 0.22f } },
            { 1.0f, { ca.red, ca.green, ca.blue, 0.00f } },
        };
        var glow = new Gsk.RadialGradientNode (
            make_rect (cx - rad, cy - rad, rad * 2, rad * 2),
            make_pt (cx, cy), rad, rad, 0.0f, 1.0f, gs);

        var pct = lt_cx (lay_18b,
                         "%d%%".printf ((int) (m.ratio () * 100.0f)),
                         { ca.red, ca.green, ca.blue, 1.0f },
                         cx, cy - 12.0f);

        Gsk.RenderNode[] kids = { node_cards[idx], glow, track };
        if (active_arc != null) kids += active_arc;
        if (pct != null) kids += pct;
        if (node_tile_labels[idx] != null) kids += node_tile_labels[idx];
        return new Gsk.ContainerNode (kids);
    }

    // -----------------------------------------------------------------------
    // Tile: speedometer
    // -----------------------------------------------------------------------

    private Gsk.RenderNode tile_speedo (int idx) {
        var   r   = tile_rect (idx);
        float cx  = p_spd_cx;
        float cy  = p_spd_cy;
        float rad = p_spd_rad;
        float thick = 10.0f;
        float gb    = rad + thick + 2;
        var   gb_r  = make_rect (cx - gb, cy - gb, gb * 2, gb * 2);

        // Track (cached path)
        var track_stroke = new Gsk.Stroke (thick);
        track_stroke.set_line_cap (Gsk.LineCap.ROUND);
        var track = new Gsk.StrokeNode (
            new Gsk.ColorNode ({ 1f, 1f, 1f, 0.08f }, gb_r),
            p_spd_track, track_stroke);

        // Active arc
        float sweep = 180.0f * speedo.ratio ();
        Gsk.RenderNode? active_arc = null;
        if (sweep > 0.5f) {
            Gsk.ColorStop[] cs = {
                { 0.0f, { 0.2f, 0.9f, 0.4f, 1.0f } },
                { 0.5f, { 1.0f, 0.9f, 0.1f, 1.0f } },
                { 1.0f, { 1.0f, 0.3f, 0.1f, 1.0f } },
            };
            var conic      = new Gsk.ConicGradientNode (gb_r, make_pt (cx, cy), 180.0f, cs);
            var arc_stroke = new Gsk.Stroke (thick);
            arc_stroke.set_line_cap (Gsk.LineCap.ROUND);
            active_arc = new Gsk.StrokeNode (conic,
                                              build_arc (180.0f, sweep, cx, cy, rad),
                                              arc_stroke);
        }

        // Needle
        float needle_angle = 180.0f + speedo.ratio () * 180.0f;
        float needle_len   = rad - 8.0f;
        // Needle tip is at +x so rotate(angle) points it toward the arc position.
        // A small tail (-6) extends behind the pivot for visual balance.
        var needle_rect    = make_rect (-6.0f, -1.5f, needle_len + 6.0f, 3.0f);
        var needle_rr      = rrect_from (needle_rect, 2.0f);
        var needle_clipped = new Gsk.RoundedClipNode (
            new Gsk.ColorNode ({ 1f, 1f, 1f, 0.90f }, needle_rect), needle_rr);
        var needle = new Gsk.TransformNode (needle_clipped,
            new Gsk.Transform ().translate (make_pt (cx, cy)).rotate (needle_angle));

        // Pivot dot
        float dot_r = 5.0f;
        var dot_rect = make_rect (cx - dot_r, cy - dot_r, dot_r * 2, dot_r * 2);
        var pivot    = new Gsk.RoundedClipNode (
            new Gsk.ColorNode ({ 1f, 1f, 1f, 1.0f }, dot_rect), rrect_from (dot_rect, dot_r));

        var val_txt = lt_cx (lay_20b,
                             "%.0f%%".printf (speedo.ratio () * 100.0f),
                             { 1f, 0.9f, 0.3f, 1.0f },
                             cx, cy + 10.0f);

        Gsk.RenderNode[] kids = { node_cards[idx], track };
        if (active_arc != null) kids += active_arc;
        kids += needle;
        kids += pivot;
        if (val_txt != null) kids += val_txt;
        if (node_tile_labels[idx] != null) kids += node_tile_labels[idx];
        return new Gsk.ContainerNode (kids);
    }

    // -----------------------------------------------------------------------
    // Tile: donut chart
    // -----------------------------------------------------------------------

    private Gsk.RenderNode tile_donut (int idx) {
        var r  = tile_rect (idx);
        // Keep the ring in the left ~55 % so it doesn't overlap the legend column.
        float leg_x_boundary = r.get_x () + r.get_width () * 0.55f;
        float max_rad = (leg_x_boundary - r.get_x ()) * 0.45f;
        float cx  = r.get_x () + r.get_width () * 0.27f;
        float cy  = r.get_y () + r.get_height () * 0.52f;
        float rad = float.min (max_rad, r.get_height () * 0.36f);

        Gdk.RGBA[] seg_colors = {
            { 1.0f, 0.2f, 0.7f, 1.0f }, { 0.1f, 0.9f, 1.0f, 1.0f },
            { 0.4f, 1.0f, 0.3f, 1.0f }, { 1.0f, 0.7f, 0.1f, 1.0f },
            { 0.7f, 0.3f, 1.0f, 1.0f },
        };
        string[] seg_labels = { "SVC A", "SVC B", "SVC C", "SVC D", "SVC E" };

        float total = 0.0f;
        for (int i = 0; i < donut.length; i++) total += donut[i].current;
        if (total < 0.001f) total = 0.001f;

        float gb = rad + 13;
        float a  = -90.0f;
        var   stroke_params = new Gsk.Stroke (11.0f);
        stroke_params.set_line_cap (Gsk.LineCap.BUTT);

        Gsk.RenderNode[] kids = { node_cards[idx] };
        for (int i = 0; i < donut.length; i++) {
            float sweep = (donut[i].current / total) * 358.0f;
            if (sweep < 1.0f) { a += sweep; continue; }
            var paint = new Gsk.ColorNode (seg_colors[i],
                                           make_rect (cx - gb, cy - gb, gb * 2, gb * 2));
            kids += new Gsk.StrokeNode (paint, build_arc (a, sweep, cx, cy, rad), stroke_params);
            a += sweep + 0.5f;
        }

        // Legend
        float leg_x = leg_x_boundary + 4.0f;
        float leg_y = r.get_y () + 18.0f;
        float row_h = (r.get_height () - 30.0f) / (float) donut.length;
        for (int i = 0; i < donut.length; i++) {
            float ry  = leg_y + (float) i * row_h;
            var   c   = seg_colors[i];
            var dot_r = make_rect (leg_x, ry + 3.0f, 8.0f, 8.0f);
            kids += new Gsk.RoundedClipNode (
                new Gsk.ColorNode (c, dot_r), rrect_from (dot_r, 4.0f));
            var tl = lt_at (lay_9r,
                            "%s  %.0f%%".printf (seg_labels[i], donut[i].current / total * 100.0f),
                            { 1f, 1f, 1f, 0.65f }, leg_x + 12.0f, ry);
            if (tl != null) kids += tl;
        }
        if (node_tile_labels[idx] != null) kids += node_tile_labels[idx];
        return new Gsk.ContainerNode (kids);
    }

    // -----------------------------------------------------------------------
    // Tile: wide sparkline
    // -----------------------------------------------------------------------

    private Gsk.RenderNode tile_sparkline (int idx) {
        var r  = tile_rect (idx);
        float pad  = 14.0f;
        float sp_x = r.get_x () + pad;
        float sp_y = r.get_y () + 24.0f;
        float sp_w = r.get_width () - 2.0f * pad;
        float sp_h = r.get_height () - 38.0f;

        Gsk.ColorStop[] stripe_stops = {
            { 0.00f, { 1f, 1f, 1f, 0.000f } },
            { 0.48f, { 1f, 1f, 1f, 0.000f } },
            { 0.50f, { 1f, 1f, 1f, 0.038f } },
            { 0.52f, { 1f, 1f, 1f, 0.000f } },
            { 1.00f, { 1f, 1f, 1f, 0.000f } },
        };
        var chart_r = make_rect (sp_x, sp_y, sp_w, sp_h);
        var stripe = new Gsk.RoundedClipNode (
            new Gsk.RepeatingLinearGradientNode (
                chart_r, make_pt (sp_x, sp_y), make_pt (sp_x, sp_y + 12.0f), stripe_stops),
            rrect_from (chart_r, 4.0f));

        Gsk.RenderNode[] kids = { node_cards[idx], stripe };
        var spk1 = build_sparkline (spark_wide, sp_x, sp_y, sp_w, sp_h,
                                    { 0.1f, 0.9f, 1.0f, 1.0f });
        if (spk1 != null) kids += spk1;

        // Second line: normalised kpi_a (saves temp override — just scale inline)
        float klo = kpi_a.lo; float khi = kpi_a.hi;
        float kspan = khi - klo; if (kspan < 0.001f) kspan = 0.001f;
        float[] khist_norm = new float[kpi_a.history.length];
        for (int i = 0; i < khist_norm.length; i++)
            khist_norm[i] = (kpi_a.history[i] - klo) / kspan;
        Metric kpi_norm = new Metric (0, 1, 0, 0);
        kpi_norm.history  = khist_norm;
        kpi_norm.hist_head = kpi_a.hist_head;
        var spk2 = build_sparkline (kpi_norm, sp_x, sp_y, sp_w, sp_h,
                                    { 1.0f, 0.2f, 0.8f, 0.40f });
        if (spk2 != null) kids += spk2;

        if (node_tile_labels[idx] != null) kids += node_tile_labels[idx];
        return new Gsk.ContainerNode (kids);
    }

    // -----------------------------------------------------------------------
    // Tile: vertical bar chart
    // -----------------------------------------------------------------------

    private Gsk.RenderNode tile_bars (int idx) {
        var r  = tile_rect (idx);
        float pad   = 12.0f;
        float cx0   = r.get_x () + pad;
        float cy0   = r.get_y () + r.get_height () - pad - 2.0f;
        float av_w  = (r.get_width () - 2.0f * pad) / (float) bars.length;
        float bw    = av_w - 4.0f;
        float max_h = r.get_height () - 28.0f;

        Gdk.RGBA[] bar_colors = {
            { 1.0f, 0.2f, 0.8f, 1f }, { 0.9f, 0.2f, 1.0f, 1f },
            { 0.5f, 0.2f, 1.0f, 1f }, { 0.1f, 0.5f, 1.0f, 1f },
            { 0.1f, 0.9f, 1.0f, 1f }, { 0.1f, 1.0f, 0.6f, 1f },
            { 0.3f, 1.0f, 0.2f, 1f }, { 0.9f, 1.0f, 0.1f, 1f },
            { 1.0f, 0.7f, 0.1f, 1f }, { 1.0f, 0.4f, 0.1f, 1f },
            { 1.0f, 0.2f, 0.3f, 1f }, { 1.0f, 0.2f, 0.6f, 1f },
        };

        Gsk.RenderNode[] kids = { node_cards[idx] };
        for (int i = 0; i < bars.length; i++) {
            float bh = bars[i].ratio () * max_h;
            if (bh < 2.0f) continue;
            float bx  = cx0 + (float) i * av_w;
            float by  = cy0 - bh;
            var   bc  = bar_colors[i % bar_colors.length];
            Gsk.ColorStop[] bar_stops = {
                { 0.0f, { bc.red, bc.green, bc.blue, 1.0f } },
                { 1.0f, { bc.red * 0.3f, bc.green * 0.3f, bc.blue * 0.3f, 0.7f } },
            };
            var bar_rect = make_rect (bx, by, bw, bh);
            kids += new Gsk.RoundedClipNode (
                new Gsk.LinearGradientNode (bar_rect,
                    make_pt (bx, by), make_pt (bx, by + bh), bar_stops),
                rrect_from (bar_rect, 3.0f));
        }
        if (node_tile_labels[idx] != null) kids += node_tile_labels[idx];
        return new Gsk.ContainerNode (kids);
    }

    // -----------------------------------------------------------------------
    // Tile: horizontal progress bars
    // -----------------------------------------------------------------------

    private Gsk.RenderNode tile_progress (int idx) {
        var r = tile_rect (idx);
        float pad   = 12.0f;
        float bar_h = 8.0f;
        string[] prog_labels = { "DISK", "NET", "SWAP", "GPU" };
        Gdk.RGBA[] prog_cols = {
            { 1.0f, 0.4f, 0.1f, 1f }, { 0.1f, 0.8f, 1.0f, 1f },
            { 0.8f, 0.3f, 1.0f, 1f }, { 0.2f, 1.0f, 0.4f, 1f },
        };

        float row_h = (r.get_height () - 24.0f) / (float) progress_bars.length;
        float bar_w = r.get_width () - 2.0f * pad - 36.0f;
        float bar_x = r.get_x () + pad + 36.0f;

        Gsk.RenderNode[] kids = { node_cards[idx] };
        for (int i = 0; i < progress_bars.length; i++) {
            float row_y  = r.get_y () + 20.0f + (float) i * row_h;
            float bar_cy = row_y + row_h * 0.5f;
            float track_y = bar_cy - bar_h * 0.5f;

            var track_r  = make_rect (bar_x, track_y, bar_w, bar_h);
            kids += new Gsk.RoundedClipNode (
                new Gsk.ColorNode ({ 1f, 1f, 1f, 0.08f }, track_r),
                rrect_from (track_r, bar_h * 0.5f));

            float fw = bar_w * progress_bars[i].ratio ();
            if (fw > 2.0f) {
                var pc = prog_cols[i];
                Gsk.ColorStop[] fill_stops = {
                    { 0.0f, { pc.red * 0.6f, pc.green * 0.6f, pc.blue * 0.6f, 1.0f } },
                    { 1.0f, { pc.red, pc.green, pc.blue, 1.0f } },
                };
                var fill_r = make_rect (bar_x, track_y, fw, bar_h);
                kids += new Gsk.RoundedClipNode (
                    new Gsk.LinearGradientNode (fill_r,
                        make_pt (bar_x, 0), make_pt (bar_x + fw, 0), fill_stops),
                    rrect_from (fill_r, bar_h * 0.5f));

                Gsk.ColorStop[] gls = {
                    { 0.0f, { pc.red, pc.green, pc.blue, 0.45f } },
                    { 1.0f, { pc.red, pc.green, pc.blue, 0.00f } },
                };
                kids += new Gsk.RadialGradientNode (
                    make_rect (bar_x + fw - 12, bar_cy - 10, 24, 20),
                    make_pt (bar_x + fw, bar_cy),
                    12.0f, 10.0f, 0.0f, 1.0f, gls);
            }

            var lbl = lt_at (lay_9b, prog_labels[i], { 1f, 1f, 1f, 0.45f },
                             r.get_x () + pad, bar_cy - 6.0f);
            var pct = lt_at (lay_9r,
                             "%.0f%%".printf (progress_bars[i].ratio () * 100.0f),
                             { 1f, 1f, 1f, 0.55f },
                             bar_x + bar_w + 4.0f, bar_cy - 6.0f);
            if (lbl != null) kids += lbl;
            if (pct != null) kids += pct;
        }
        return new Gsk.ContainerNode (kids);
    }

    // -----------------------------------------------------------------------
    // Tile: heatmap 5×5
    // -----------------------------------------------------------------------

    private Gsk.RenderNode tile_heatmap (int idx) {
        var r  = tile_rect (idx);
        float pad    = 14.0f;
        float grid_w = r.get_width () - 2.0f * pad;
        float grid_h = r.get_height () - 30.0f;
        float cell_w = grid_w / 5.0f;
        float cell_h = grid_h / 5.0f;
        float x0     = r.get_x () + pad;
        float y0     = r.get_y () + 22.0f;
        float gap    = 3.0f;

        Gsk.RenderNode[] kids = { node_cards[idx] };
        for (int cy = 0; cy < 5; cy++) {
            for (int cx = 0; cx < 5; cx++) {
                float v = heat[cy, cx].ratio ();
                float r_c, g_c, b_c;
                if (v < 0.5f) {
                    float t = v * 2.0f;
                    r_c = 0.6f - t * 0.5f; g_c = 0.1f + t * 0.8f; b_c = 1.0f;
                } else {
                    float t = (v - 0.5f) * 2.0f;
                    r_c = 0.1f + t * 0.9f; g_c = 0.9f; b_c = 1.0f - t * 0.7f;
                }
                float cell_x = x0 + (float) cx * cell_w + gap * 0.5f;
                float cell_y = y0 + (float) cy * cell_h + gap * 0.5f;
                float cw = cell_w - gap; float ch = cell_h - gap;
                var cell_r = make_rect (cell_x, cell_y, cw, ch);
                kids += new Gsk.RoundedClipNode (
                    new Gsk.ColorNode ({ r_c, g_c, b_c, 0.85f }, cell_r),
                    rrect_from (cell_r, 3.0f));
            }
        }
        if (node_tile_labels[idx] != null) kids += node_tile_labels[idx];
        return new Gsk.ContainerNode (kids);
    }

    // -----------------------------------------------------------------------
    // Tile: status pills
    // -----------------------------------------------------------------------

    private Gsk.RenderNode tile_pills (int idx) {
        var r = tile_rect (idx);
        float pad = 10.0f;
        string[] pill_labels = { "API", "DB", "CDN", "AUTH" };
        string[] pill_status = { "OK", "OK", "SLOW", "OK" };
        Gdk.RGBA[] on_colors = {
            { 0.2f, 1.0f, 0.4f, 1f }, { 0.2f, 1.0f, 0.4f, 1f },
            { 1.0f, 0.7f, 0.1f, 1f }, { 0.2f, 1.0f, 0.4f, 1f },
        };

        float row_h  = (r.get_height () - 28.0f) / (float) pill_labels.length;
        float pill_w = r.get_width () - 2.0f * pad;
        float pill_h = row_h - 6.0f;

        Gsk.RenderNode[] kids = { node_cards[idx] };
        for (int i = 0; i < pill_labels.length; i++) {
            float py  = r.get_y () + 24.0f + (float) i * row_h;
            var   col = on_colors[i];
            float phase  = (float) ((tick_us + (int64)(i * 400000)) / 1200000.0 * Math.PI * 2);
            float pulse  = (float) (Math.sin (phase) * 0.3 + 0.7);

            var pr  = make_rect (r.get_x () + pad, py, pill_w, pill_h);
            var prr = rrect_from (pr, pill_h * 0.5f);
            kids += new Gsk.RoundedClipNode (
                new Gsk.ColorNode ({ col.red, col.green, col.blue, 0.12f }, pr), prr);
            float[] bw  = { 1f, 1f, 1f, 1f };
            Gdk.RGBA[] bc = {
                { col.red, col.green, col.blue, 0.40f },
                { col.red, col.green, col.blue, 0.40f },
                { col.red, col.green, col.blue, 0.40f },
                { col.red, col.green, col.blue, 0.40f },
            };
            kids += new Gsk.BorderNode (prr, bw, bc);

            float dot_cx = r.get_x () + pad + pill_h * 0.5f + 1.0f;
            float dot_cy = py + pill_h * 0.5f;
            float dot_r  = 4.0f;
            var dot_rect = make_rect (dot_cx - dot_r, dot_cy - dot_r, dot_r * 2, dot_r * 2);
            kids += new Gsk.OpacityNode (
                new Gsk.RoundedClipNode (
                    new Gsk.ColorNode (col, dot_rect), rrect_from (dot_rect, dot_r)),
                pulse);

            var lbl = lt_at (lay_9b,
                             "%s  %s".printf (pill_labels[i], pill_status[i]),
                             { 1f, 1f, 1f, 0.75f },
                             dot_cx + dot_r + 6.0f, py + pill_h * 0.5f - 6.0f);
            if (lbl != null) kids += lbl;
        }
        if (node_tile_labels[idx] != null) kids += node_tile_labels[idx];
        return new Gsk.ContainerNode (kids);
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main (string[] args) {
    var app = new Gtk.Application ("org.example.GskLiveNumbers",
                                   GLib.ApplicationFlags.DEFAULT_FLAGS);

    app.activate.connect (() => {
        var canvas = new DashboardCanvas ();
        var win = new Gtk.ApplicationWindow (app);
        win.title = "GSK Live Numbers — Demo 03";
        win.set_default_size ((int) WIN_W, (int) WIN_H);
        win.resizable = true;
        win.set_child (canvas);
        win.present ();
    });

    return app.run (args);
}
