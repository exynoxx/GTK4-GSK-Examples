/**
 * GSK demo 04: mixing stock GTK widgets with custom GSK-drawn widgets.
 *
 * Three kinds of widget coexist in one window — no special API required:
 *
 *   WaveCanvas   Custom Gtk.Widget that overrides snapshot() and draws
 *                animated waveforms entirely with GSK node types:
 *                LinearGradientNode, ColorNode, StrokeNode (via PathBuilder).
 *
 *   InfoBadge    Second custom Gtk.Widget positioned via Gtk.Overlay.
 *                Draws itself as a frosted pill (OutsetShadowNode,
 *                RoundedClipNode, BorderNode, TransformNode).
 *
 *   Sidebar      Entirely stock GTK4 widgets: Gtk.Scale, Gtk.Switch,
 *                Gtk.DropDown, Gtk.Button, Gtk.Label, Gtk.Box.
 *                Wired to WaveCanvas fields via value-changed / notify signals.
 *
 * Mixing works because all three are plain Gtk.Widget subclasses.  GTK's
 * widget tree handles layout, hit-testing, and compositing for all of them.
 */

// ---------------------------------------------------------------------------
// Shared geometry helpers
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
// Waveform kind (maps 1-to-1 onto the DropDown index)
// ---------------------------------------------------------------------------

enum WaveForm { SINE, SQUARE, SAWTOOTH }

// ---------------------------------------------------------------------------
// WaveCanvas — custom widget; all drawing done via the GSK node API
// ---------------------------------------------------------------------------

class WaveCanvas : Gtk.Widget {

    // Parameters written directly by sidebar signal handlers
    public int      wave_count = 3;
    public double   speed      = 1.0;
    public double   amplitude  = 0.35;   // fraction of canvas half-height
    public double   hue        = 0.0;    // 0..360°
    public bool     hue_cycle  = true;
    public WaveForm waveform   = WaveForm.SINE;

    private uint  tick_id  = 0;
    private int64 start_us = 0;
    private int64 frame_us = 0;

    // FPS meter — read by InfoBadge
    private double _fps       = 0.0;
    private int    _fps_count = 0;
    private int64  _fps_last  = 0;
    public  double fps        { get { return _fps; } }

    construct {
        set_hexpand (true);
        set_vexpand (true);
    }

    ~WaveCanvas () {
        if (tick_id != 0) remove_tick_callback (tick_id);
    }

    public override void realize () {
        base.realize ();
        start_us = frame_us = _fps_last = get_frame_clock ().get_frame_time ();
        tick_id = add_tick_callback ((w, clock) => {
            frame_us = clock.get_frame_time ();
            _fps_count++;
            double elapsed = (frame_us - _fps_last) / 1e6;
            if (elapsed >= 0.5) {
                _fps       = _fps_count / elapsed;
                _fps_count = 0;
                _fps_last  = frame_us;
            }
            queue_draw ();
            return Source.CONTINUE;
        });
    }

    public override void unrealize () {
        if (tick_id != 0) { remove_tick_callback (tick_id); tick_id = 0; }
        base.unrealize ();
    }

    public override void snapshot (Gtk.Snapshot snap) {
        float w = (float) get_width ();
        float h = (float) get_height ();
        if (w < 1 || h < 1) return;

        double t   = (frame_us - start_us) / 1e6 * speed;
        float  cy  = h * 0.5f;
        float  amp = (float) amplitude * cy;

        // Dark gradient background
        Gsk.ColorStop[] bg = {
            { 0.0f, { 0.06f, 0.04f, 0.14f, 1.0f } },
            { 1.0f, { 0.02f, 0.02f, 0.07f, 1.0f } },
        };
        snap.append_node (new Gsk.LinearGradientNode (
            make_rect (0, 0, w, h), make_pt (0, 0), make_pt (0, h), bg));

        // Subtle horizontal grid
        for (int gi = 1; gi < 4; gi++) {
            float gy = h * (float) gi / 4.0f;
            snap.append_node (new Gsk.ColorNode (
                { 1f, 1f, 1f, 0.04f }, make_rect (0, gy - 0.5f, w, 1.0f)));
        }

        // Waves — one StrokeNode per wave
        for (int i = 0; i < wave_count; i++) {
            double phase_off = i * (2.0 * Math.PI / wave_count);
            double freq      = 1.5 + i * 0.4;
            double hue_off   = i * (360.0 / wave_count);

            double h_val = Math.fmod (hue + hue_off + (hue_cycle ? t * 30.0 : 0.0), 360.0);
            if (h_val < 0) h_val += 360.0;
            Gdk.RGBA col = hsv (h_val, 0.85, 1.0);

            var b = new Gsk.PathBuilder ();
            int steps = (int) w;
            for (int xi = 0; xi <= steps; xi++) {
                float  px    = (float) xi;
                double angle = phase_off + freq * (px / w) * 6.0 * Math.PI + t * 2.0 * Math.PI;
                double raw;
                switch (waveform) {
                    case WaveForm.SQUARE:
                        raw = Math.sin (angle) >= 0.0 ? 1.0 : -1.0;
                        break;
                    case WaveForm.SAWTOOTH:
                        double saw = Math.fmod (angle / (2.0 * Math.PI), 1.0);
                        if (saw < 0) saw += 1.0;
                        raw = 2.0 * saw - 1.0;
                        break;
                    default:
                        raw = Math.sin (angle);
                        break;
                }
                float py = cy - (float)(raw * amp);
                if (xi == 0) b.move_to (px, py);
                else          b.line_to (px, py);
            }

            var stroke = new Gsk.Stroke (2.0f + (float) i * 0.35f);
            stroke.set_line_cap  (Gsk.LineCap.ROUND);
            stroke.set_line_join (Gsk.LineJoin.ROUND);

            // StrokeNode uses a ColorNode as its paint source
            var paint = new Gsk.ColorNode (col, make_rect (0, 0, w, h));
            snap.append_node (new Gsk.StrokeNode (paint, b.to_path (), stroke));
        }
    }

    // Standard HSV → linear-light RGB (no gamma; fine for glow-style graphics)
    private Gdk.RGBA hsv (double h, double s, double v) {
        double h6 = h / 60.0;
        int    sec = (int) h6 % 6;
        double f   = h6 - (int) h6;
        double p   = v * (1.0 - s);
        double q   = v * (1.0 - f * s);
        double tv  = v * (1.0 - (1.0 - f) * s);
        double r, g, b;
        switch (sec) {
            case 0:  r = v;  g = tv; b = p;  break;
            case 1:  r = q;  g = v;  b = p;  break;
            case 2:  r = p;  g = v;  b = tv; break;
            case 3:  r = p;  g = q;  b = v;  break;
            case 4:  r = tv; g = p;  b = v;  break;
            default: r = v;  g = p;  b = q;  break;
        }
        return { (float) r, (float) g, (float) b, 1.0f };
    }
}

// ---------------------------------------------------------------------------
// InfoBadge — second custom GSK widget; floated over the canvas via Overlay
// ---------------------------------------------------------------------------

class InfoBadge : Gtk.Widget {

    private unowned WaveCanvas canvas;
    private uint tick_id = 0;

    public InfoBadge (WaveCanvas c) {
        canvas = c;
        set_halign (Gtk.Align.END);
        set_valign (Gtk.Align.START);
        set_margin_top (14);
        set_margin_end (14);
        set_size_request (180, 36);
        set_can_target (false);   // pass input events through to the canvas
    }

    ~InfoBadge () {
        if (tick_id != 0) remove_tick_callback (tick_id);
    }

    public override void realize () {
        base.realize ();
        tick_id = add_tick_callback ((w, _clock) => { queue_draw (); return Source.CONTINUE; });
    }

    public override void unrealize () {
        if (tick_id != 0) { remove_tick_callback (tick_id); tick_id = 0; }
        base.unrealize ();
    }

    public override void snapshot (Gtk.Snapshot snap) {
        float w = (float) get_width ();
        float h = (float) get_height ();
        var r  = make_rect (0, 0, w, h);
        var rr = Gsk.RoundedRect ();
        rr.init_from_rect (r, h * 0.5f);

        // Frosted pill — same node vocabulary as the canvas background
        snap.append_node (
            new Gsk.OutsetShadowNode (rr, { 0f, 0f, 0f, 0.50f }, 0, 3, 0, 12));
        snap.append_node (
            new Gsk.RoundedClipNode (
                new Gsk.ColorNode ({ 0.05f, 0.04f, 0.13f, 0.88f }, r), rr));
        float[] bw  = { 1f, 1f, 1f, 1f };
        Gdk.RGBA[] bc = {
            { 1f, 1f, 1f, 0.16f }, { 1f, 1f, 1f, 0.16f },
            { 1f, 1f, 1f, 0.16f }, { 1f, 1f, 1f, 0.16f },
        };
        snap.append_node (new Gsk.BorderNode (rr, bw, bc));

        // Text — Pango layout created fresh each frame (badge is small)
        string wf_name;
        switch (canvas.waveform) {
            case WaveForm.SQUARE:   wf_name = "square";   break;
            case WaveForm.SAWTOOTH: wf_name = "sawtooth"; break;
            default:                wf_name = "sine";     break;
        }
        string text = "%d %s  ·  %.0f fps".printf (
            canvas.wave_count, wf_name, canvas.fps);
        var lay = create_pango_layout (text);
        lay.set_font_description (Pango.FontDescription.from_string ("Cantarell 10"));
        int tw, th;
        lay.get_pixel_size (out tw, out th);
        var sub = new Gtk.Snapshot ();
        sub.append_layout (lay, { 1f, 1f, 1f, 0.80f });
        var node = sub.to_node ();
        if (node != null) {
            snap.append_node (new Gsk.TransformNode (
                node, new Gsk.Transform ().translate (
                    make_pt ((w - (float) tw) * 0.5f,
                             (h - (float) th) * 0.5f))));
        }
    }
}

// ---------------------------------------------------------------------------
// Application — builds the window, sidebar (stock GTK), and canvas overlay
// ---------------------------------------------------------------------------

int main (string[] args) {
    var app = new Gtk.Application ("org.example.GskMixed",
                                   GLib.ApplicationFlags.DEFAULT_FLAGS);
    app.activate.connect (() => {

        // ---- CSS: dark sidebar skin ----------------------------------------
        var css = new Gtk.CssProvider ();
        css.load_from_string ("""
            .sidebar {
                background-color: #0f0d1b;
                border-right: 1px solid rgba(255,255,255,0.07);
                padding: 18px 14px 18px 14px;
            }
            .sidebar label {
                color: rgba(255,255,255,0.78);
            }
            .section-label {
                font-size: 8pt;
                font-weight: bold;
                color: rgba(255,255,255,0.32);
                margin-top: 16px;
                margin-bottom: 2px;
            }
        """);
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (), css,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        // ---- Canvas + overlay badge ----------------------------------------
        var canvas = new WaveCanvas ();
        var badge  = new InfoBadge (canvas);

        var overlay = new Gtk.Overlay ();
        overlay.set_child (canvas);
        overlay.add_overlay (badge);

        // ---- Sidebar: stock GTK widgets ------------------------------------
        var sidebar = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        sidebar.set_size_request (220, -1);
        sidebar.add_css_class ("sidebar");

        // Convenience: append a section heading
        // (local helper lambda — Vala allows closures here)

        // — WAVEFORMS ———————————————————————————————————————
        var lbl_s1 = new Gtk.Label ("WAVEFORMS");
        lbl_s1.add_css_class ("section-label");
        lbl_s1.set_halign (Gtk.Align.START);
        sidebar.append (lbl_s1);

        // Waves (1–8)
        var lbl_count = new Gtk.Label ("Waves");
        lbl_count.set_halign (Gtk.Align.START);
        var sc_count = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 1, 8, 1);
        sc_count.set_value (canvas.wave_count);
        sc_count.set_draw_value (true);
        sc_count.set_hexpand (true);
        sidebar.append (lbl_count);
        sidebar.append (sc_count);
        sc_count.value_changed.connect (() => {
            canvas.wave_count = (int) sc_count.get_value ();
        });

        // Speed (0.1–4.0)
        var lbl_speed = new Gtk.Label ("Speed");
        lbl_speed.set_halign (Gtk.Align.START);
        var sc_speed = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 0.1, 4.0, 0.1);
        sc_speed.set_value (canvas.speed);
        sc_speed.set_draw_value (true);
        sc_speed.set_hexpand (true);
        sidebar.append (lbl_speed);
        sidebar.append (sc_speed);
        sc_speed.value_changed.connect (() => { canvas.speed = sc_speed.get_value (); });

        // Amplitude (0.05–0.90)
        var lbl_amp = new Gtk.Label ("Amplitude");
        lbl_amp.set_halign (Gtk.Align.START);
        var sc_amp = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 0.05, 0.90, 0.05);
        sc_amp.set_value (canvas.amplitude);
        sc_amp.set_draw_value (true);
        sc_amp.set_hexpand (true);
        sidebar.append (lbl_amp);
        sidebar.append (sc_amp);
        sc_amp.value_changed.connect (() => { canvas.amplitude = sc_amp.get_value (); });

        // — APPEARANCE ——————————————————————————————————————
        var lbl_s2 = new Gtk.Label ("APPEARANCE");
        lbl_s2.add_css_class ("section-label");
        lbl_s2.set_halign (Gtk.Align.START);
        sidebar.append (lbl_s2);

        // Base hue (0–360)
        var lbl_hue = new Gtk.Label ("Base hue");
        lbl_hue.set_halign (Gtk.Align.START);
        var sc_hue = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 0.0, 360.0, 1.0);
        sc_hue.set_value (canvas.hue);
        sc_hue.set_draw_value (true);
        sc_hue.set_hexpand (true);
        sidebar.append (lbl_hue);
        sidebar.append (sc_hue);
        sc_hue.value_changed.connect (() => { canvas.hue = sc_hue.get_value (); });

        // Colour-cycle switch row
        var row_cycle = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var lbl_cycle = new Gtk.Label ("Colour cycle");
        lbl_cycle.set_halign (Gtk.Align.START);
        lbl_cycle.set_hexpand (true);
        var sw_cycle = new Gtk.Switch ();
        sw_cycle.set_active (canvas.hue_cycle);
        sw_cycle.set_valign (Gtk.Align.CENTER);
        row_cycle.append (lbl_cycle);
        row_cycle.append (sw_cycle);
        sidebar.append (row_cycle);
        sw_cycle.notify["active"].connect (() => {
            canvas.hue_cycle = sw_cycle.get_active ();
        });

        // Waveform dropdown
        var lbl_wf = new Gtk.Label ("Waveform");
        lbl_wf.set_halign (Gtk.Align.START);
        string[] wf_names = { "Sine", "Square", "Sawtooth" };
        var wf_model = new Gtk.StringList (wf_names);
        var dd_wf = new Gtk.DropDown (wf_model, null);
        dd_wf.set_selected ((uint) canvas.waveform);
        dd_wf.set_hexpand (true);
        sidebar.append (lbl_wf);
        sidebar.append (dd_wf);
        dd_wf.notify["selected"].connect (() => {
            canvas.waveform = (WaveForm) dd_wf.get_selected ();
        });

        // Randomize — updates both canvas fields and the slider positions
        var btn_rand = new Gtk.Button.with_label ("Randomize");
        btn_rand.set_margin_top (20);
        sidebar.append (btn_rand);
        btn_rand.clicked.connect (() => {
            var rng  = new Rand ();
            int    nc = rng.int_range (1, 9);
            double sp = rng.next_double () * 3.5 + 0.2;
            double am = rng.next_double () * 0.65 + 0.15;
            double hu = rng.next_double () * 360.0;
            WaveForm wf = (WaveForm) rng.int_range (0, 3);
            canvas.wave_count = nc;
            canvas.speed      = sp;
            canvas.amplitude  = am;
            canvas.hue        = hu;
            canvas.waveform   = wf;
            // Sync sliders so the UI reflects the new values
            sc_count.set_value (nc);
            sc_speed.set_value (sp);
            sc_amp.set_value   (am);
            sc_hue.set_value   (hu);
            dd_wf.set_selected ((uint) wf);
        });

        // ---- Root layout: sidebar | overlay --------------------------------
        var hbox = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        hbox.append (sidebar);
        hbox.append (overlay);

        var win = new Gtk.ApplicationWindow (app);
        win.title = "GSK Mixed — Demo 04";
        win.set_default_size (1060, 640);
        win.set_child (hbox);
        win.present ();
    });

    return app.run (args);
}
