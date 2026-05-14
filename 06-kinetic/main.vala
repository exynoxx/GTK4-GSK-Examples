/**
 * GSK demo 06: Kinetic Constellation — a motion-techniques showcase.
 *
 * Nodes / techniques demonstrated:
 *   ConicGradientNode   — rotating sky background
 *   RadialGradientNode  — pulsing core glow + satellite halos
 *   LinearGradientNode  — racetrack lane backgrounds
 *   StrokeNode          — aurora ribbons (bezier paths)
 *   FillNode            — 3-D octahedron faces (back-face culled, depth sorted)
 *   OutsetShadowNode    — core outer bloom + title glow
 *   OpacityNode         — satellite trail fade + burst fade
 *   TransformNode       — comet trail pieces + easing dots
 *   BlurNode            — soft radial bloom on the core
 *   ColorNode           — stars, trail dots, burst particles
 *   ContainerNode       — scene composition
 *   append_layout       — title + lane labels via Pango
 *
 * Motion techniques:
 *   Hue rotation        — continuous ambient background shift
 *   Parallax            — starfield depth × mouse offset
 *   Sinusoidal paths    — aurora ribbon control-point wobble
 *   Elliptical orbits   — Kepler-style satellite positions
 *   Ring-buffer trails  — per-satellite past-position opacity decay
 *   Manual 3-D          — vertex rotation matrices, perspective divide, depth sort
 *   Easing curves       — linear, ease-in³, ease-out³, ease-in-out³, elastic, bounce
 *   Spring physics      — mouse comet (k=80, c=14, under-damped)
 *   Particle system     — gravity + lifetime fade, emitted on click
 */

// ── 3-D math ─────────────────────────────────────────────────────────────────

struct Vec3 { public float x; public float y; public float z; }

Vec3 v3_rotx (Vec3 v, float a) {
    float s = (float) Math.sin (a), c = (float) Math.cos (a);
    Vec3 r = { v.x, v.y * c - v.z * s, v.y * s + v.z * c };
    return r;
}
Vec3 v3_roty (Vec3 v, float a) {
    float s = (float) Math.sin (a), c = (float) Math.cos (a);
    Vec3 r = { v.x * c + v.z * s, v.y, -v.x * s + v.z * c };
    return r;
}
Vec3 v3_rotz (Vec3 v, float a) {
    float s = (float) Math.sin (a), c = (float) Math.cos (a);
    Vec3 r = { v.x * c - v.y * s, v.x * s + v.y * c, v.z };
    return r;
}

// Centroid z of a triangle face (for depth sorting)
float face_z (Vec3 a, Vec3 b, Vec3 c) {
    return (a.z + b.z + c.z) / 3.0f;
}

// Perspective project to screen — focal 500 px
Graphene.Point proj (Vec3 v, float cx, float cy, float scale) {
    float d = 500.0f + v.z * scale;
    if (d < 1.0f) d = 1.0f;
    var p = Graphene.Point ();
    p.init (cx + v.x * scale * 500.0f / d,
            cy + v.y * scale * 500.0f / d);
    return p;
}

// ── Geometry helpers ──────────────────────────────────────────────────────────

Graphene.Rect make_rect (float x, float y, float w, float h) {
    var r = Graphene.Rect (); r.init (x, y, w, h); return r;
}
Graphene.Point make_pt (float x, float y) {
    var p = Graphene.Point (); p.init (x, y); return p;
}
Gsk.RoundedRect make_rrect (float x, float y, float w, float h, float radius) {
    var rr = Gsk.RoundedRect (); rr.init_from_rect (make_rect (x, y, w, h), radius); return rr;
}

// ── Colour helpers ────────────────────────────────────────────────────────────

Gdk.RGBA hsv (float h, float s, float v, float a = 1.0f) {
    float h6 = h / 60.0f;
    int   sec = (int) h6 % 6;
    float f   = h6 - (float)(int) h6;
    float p   = v * (1.0f - s);
    float q   = v * (1.0f - f * s);
    float tv  = v * (1.0f - (1.0f - f) * s);
    float r, g, b;
    switch (sec) {
        case 0:  r = v;  g = tv; b = p;  break;
        case 1:  r = q;  g = v;  b = p;  break;
        case 2:  r = p;  g = v;  b = tv; break;
        case 3:  r = p;  g = q;  b = v;  break;
        case 4:  r = tv; g = p;  b = v;  break;
        default: r = v;  g = p;  b = q;  break;
    }
    return { r, g, b, a };
}

// ── Easing functions (t in [0,1] → [0,1]) ────────────────────────────────────

float ease_linear        (float t) { return t; }
float ease_in_cubic      (float t) { return t * t * t; }
float ease_out_cubic     (float t) { float u = 1.0f - t; return 1.0f - u * u * u; }
float ease_in_out_cubic  (float t) {
    return t < 0.5f ? 4.0f * t * t * t
                    : 1.0f - (float) Math.pow (-2.0 * t + 2.0, 3.0) * 0.5f;
}
float ease_out_elastic   (float t) {
    if (t <= 0.0f) return 0.0f;
    if (t >= 1.0f) return 1.0f;
    float c4 = (float)(2.0 * Math.PI / 3.0);
    return (float) Math.pow (2.0, -10.0 * t) * (float) Math.sin ((t * 10.0f - 0.75f) * c4) + 1.0f;
}
float ease_out_bounce    (float t) {
    float n1 = 7.5625f, d1 = 2.75f;
    if (t < 1.0f / d1)        return n1 * t * t;
    else if (t < 2.0f / d1)   { t -= 1.5f / d1;   return n1 * t * t + 0.75f; }
    else if (t < 2.5f / d1)   { t -= 2.25f / d1;  return n1 * t * t + 0.9375f; }
    else                       { t -= 2.625f / d1; return n1 * t * t + 0.984375f; }
}

// ── State structs ─────────────────────────────────────────────────────────────

class Satellite : Object {
    public float  orbit_rx;
    public float  orbit_ry;
    public float  period;
    public float  phase;
    public float  hue;
    public float  size;
    public float[] trail_x;
    public float[] trail_y;
    public int    trail_head;
    public const int TRAIL = 10;

    public Satellite (float rx, float ry, float p, float ph, float h, float s) {
        orbit_rx = rx; orbit_ry = ry; period = p; phase = ph; hue = h; size = s;
        trail_x = new float[TRAIL];
        trail_y = new float[TRAIL];
        trail_head = 0;
    }

    public void push_trail (float x, float y) {
        trail_x[trail_head] = x;
        trail_y[trail_head] = y;
        trail_head = (trail_head + 1) % TRAIL;
    }

    public void get_trail (int age, out float x, out float y) {
        int idx = ((trail_head - 1 - age) % TRAIL + TRAIL) % TRAIL;
        x = trail_x[idx]; y = trail_y[idx];
    }
}

struct BurstParticle {
    public float x;
    public float y;
    public float vx;
    public float vy;
    public float life;
    public float max_life;
    public float hue;
    public float size;
}

// ── KineticCanvas ─────────────────────────────────────────────────────────────

class KineticCanvas : Gtk.Widget {

    // Frame clock
    private uint  tick_id   = 0;
    private int64 tick_us   = 0;
    private int64 last_us   = 0;

    // Mouse + spring comet
    private float mouse_x = 640.0f;
    private float mouse_y = 400.0f;
    private float comet_x = 640.0f;
    private float comet_y = 400.0f;
    private float comet_vx = 0.0f;
    private float comet_vy = 0.0f;
    private float[] comet_trail_x;
    private float[] comet_trail_y;
    private int   comet_head = 0;
    private const int COMET_TRAIL = 14;

    // Scene objects
    private Satellite[] satellites;
    private float[]  star_x;
    private float[]  star_y;
    private float[]  star_sz;
    private float[]  star_depth;
    private const int N_STARS = 140;

    // Burst particles (fixed ring buffer)
    private BurstParticle[] bursts;
    private int burst_count = 0;
    private const int MAX_BURSTS = 512;

    // Ribbon parameters (base_y_frac, amp_frac, speed, phase, hue, width)
    private float[,] ribbon_params;
    private const int N_RIBBONS = 4;

    // Pango layouts
    private Pango.Layout? lay_title    = null;
    private Pango.Layout? lay_sub      = null;
    private Pango.Layout? lay_ease_lbl = null;

    construct {
        set_hexpand (true);
        set_vexpand (true);
        set_size_request (1280, 800);
        set_focusable (true);

        comet_trail_x = new float[COMET_TRAIL];
        comet_trail_y = new float[COMET_TRAIL];

        bursts = new BurstParticle[MAX_BURSTS];

        var rng = new Rand.with_seed (42);

        // Satellites: orbit_rx, orbit_ry, period_s, phase_rad, hue_deg, body_size
        satellites = new Satellite[] {
            new Satellite (160, 80,  4.2f, 0.0f,   195, 8),
            new Satellite (220, 100, 6.5f, 1.1f,   45,  6),
            new Satellite (290, 130, 9.0f, 2.4f,   280, 10),
            new Satellite (100, 60,  2.8f, 0.7f,   120, 5),
            new Satellite (350, 155, 13.0f,3.8f,   30,  7),
        };

        // Starfield
        star_x     = new float[N_STARS];
        star_y     = new float[N_STARS];
        star_sz    = new float[N_STARS];
        star_depth = new float[N_STARS];
        for (int i = 0; i < N_STARS; i++) {
            star_x[i]     = (float)(rng.next_double () * 1280.0);
            star_y[i]     = (float)(rng.next_double () * 800.0);
            star_sz[i]    = (float)(rng.next_double () * 2.0 + 0.5);
            star_depth[i] = (float)(rng.next_double () * 0.8 + 0.2);
        }

        // Ribbon params [N_RIBBONS, 6]: base_y_frac, amp_frac, speed, phase, hue, width
        ribbon_params = new float[N_RIBBONS, 6] {
            { 0.28f, 0.12f, 0.40f, 0.0f,  185.0f, 8.0f },
            { 0.38f, 0.10f, 0.55f, 1.3f,  260.0f, 6.0f },
            { 0.50f, 0.08f, 0.35f, 2.6f,  320.0f, 5.0f },
            { 0.62f, 0.11f, 0.48f, 4.0f,  80.0f,  7.0f },
        };

        // Gesture: mouse motion
        var motion = new Gtk.EventControllerMotion ();
        motion.motion.connect ((x, y) => {
            mouse_x = (float) x;
            mouse_y = (float) y;
        });
        add_controller (motion);

        // Gesture: click → emit burst
        var click = new Gtk.GestureClick ();
        click.pressed.connect ((n, x, y) => {
            emit_burst ((float) x, (float) y);
        });
        add_controller (click);
    }

    ~KineticCanvas () {
        if (tick_id != 0) remove_tick_callback (tick_id);
    }

    public override void realize () {
        base.realize ();

        lay_title    = make_layout ("Cantarell Bold 28");
        lay_sub      = make_layout ("Cantarell 11");
        lay_ease_lbl = make_layout ("Cantarell Bold 9");

        // Seed comet at centre
        float init_cx = (float) get_width () * 0.5f;
        float init_cy = (float) get_height () * 0.5f;
        comet_x = init_cx; comet_y = init_cy;
        for (int i = 0; i < COMET_TRAIL; i++) {
            comet_trail_x[i] = init_cx;
            comet_trail_y[i] = init_cy;
        }

        last_us = get_frame_clock ().get_frame_time ();

        tick_id = add_tick_callback ((widget, clock) => {
            tick_us = clock.get_frame_time ();
            float dt = (float)((tick_us - last_us) / 1000000.0);
            if (dt > 0.1f) dt = 0.1f;
            last_us = tick_us;

            float t = (float)(tick_us / 1000000.0);
            float w = (float) get_width ();
            float h = (float) get_height ();
            float cx = w * 0.5f;
            float cy = h * 0.52f;

            // Advance satellites + push trail
            foreach (var sat in satellites) {
                float angle = t / sat.period * 2.0f * (float) Math.PI + sat.phase;
                float sx = cx + sat.orbit_rx * (float) Math.cos (angle);
                float sy = cy + sat.orbit_ry * (float) Math.sin (angle);
                sat.push_trail (sx, sy);
            }

            // Spring comet: F = -k*(pos - mouse) - c*vel
            float k = 80.0f, c = 14.0f;
            comet_vx += (-k * (comet_x - mouse_x) - c * comet_vx) * dt;
            comet_vy += (-k * (comet_y - mouse_y) - c * comet_vy) * dt;
            comet_x  += comet_vx * dt;
            comet_y  += comet_vy * dt;
            comet_trail_x[comet_head] = comet_x;
            comet_trail_y[comet_head] = comet_y;
            comet_head = (comet_head + 1) % COMET_TRAIL;

            // Advance bursts: gravity + age
            int live = 0;
            for (int i = 0; i < burst_count; i++) {
                bursts[i].vy   += 420.0f * dt;
                bursts[i].x    += bursts[i].vx * dt;
                bursts[i].y    += bursts[i].vy * dt;
                bursts[i].life -= dt;
                if (bursts[i].life > 0.0f) {
                    if (live != i) bursts[live] = bursts[i];
                    live++;
                }
            }
            burst_count = live;

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

    private void emit_burst (float bx, float by) {
        var rng = new Rand ();
        int n = 28;
        for (int i = 0; i < n && burst_count < MAX_BURSTS; i++) {
            float angle = (float)(rng.next_double () * 2.0 * Math.PI);
            float speed = (float)(rng.next_double () * 280.0 + 60.0);
            bursts[burst_count].x        = bx;
            bursts[burst_count].y        = by;
            bursts[burst_count].vx       = (float) Math.cos (angle) * speed;
            bursts[burst_count].vy       = (float) Math.sin (angle) * speed - 80.0f;
            bursts[burst_count].life     = (float)(rng.next_double () * 0.9 + 0.4);
            bursts[burst_count].max_life = bursts[burst_count].life;
            bursts[burst_count].hue      = (float)(rng.next_double () * 360.0);
            bursts[burst_count].size     = (float)(rng.next_double () * 5.0 + 2.0);
            burst_count++;
        }
    }

    // ── snapshot ──────────────────────────────────────────────────────────────

    public override void snapshot (Gtk.Snapshot snap) {
        float w = (float) get_width ();
        float h = (float) get_height ();
        if (w < 1 || h < 1) return;

        float t  = (float)(tick_us / 1000000.0);
        float cx = w * 0.5f;
        float cy = h * 0.52f;

        // ── Layer 0: rotating conic gradient sky ──────────────────────────────
        {
            float rot = (float)Math.fmod (t * 4.0, 360.0);  // 90 s full cycle
            float h0 = (float)Math.fmod (210.0 + t * 3.0, 360.0);
            float h1 = (float)Math.fmod (h0 + 60.0, 360.0);
            float h2 = (float)Math.fmod (h0 + 140.0, 360.0);
            float h3 = (float)Math.fmod (h0 + 240.0, 360.0);
            Gsk.ColorStop[] sky = {
                { 0.00f, hsv (h0, 0.85f, 0.10f) },
                { 0.25f, hsv (h1, 0.90f, 0.08f) },
                { 0.50f, hsv (h2, 0.80f, 0.06f) },
                { 0.75f, hsv (h3, 0.88f, 0.09f) },
                { 1.00f, hsv (h0, 0.85f, 0.10f) },
            };
            snap.append_node (new Gsk.ConicGradientNode (
                make_rect (0, 0, w, h), make_pt (cx, cy), rot, sky));
        }

        // ── Layer 1: aurora ribbons ───────────────────────────────────────────
        for (int ri = 0; ri < N_RIBBONS; ri++) {
            float base_y   = ribbon_params[ri, 0] * h;
            float amp      = ribbon_params[ri, 1] * h;
            float spd      = ribbon_params[ri, 2];
            float ph       = ribbon_params[ri, 3];
            float hue_r    = ribbon_params[ri, 4];
            float lw       = ribbon_params[ri, 5];

            var pb = new Gsk.PathBuilder ();
            float step = w / 6.0f;
            float y0 = base_y + amp * (float) Math.sin (t * spd + ph);
            pb.move_to (0, y0);
            for (int si = 1; si <= 6; si++) {
                float px   = si * step;
                float py   = base_y + amp * (float) Math.sin (t * spd + ph + si * 1.1f);
                float cpx1 = px - step * 0.6f;
                float cpy1 = base_y + amp * (float) Math.sin (t * spd + ph + (si - 0.6f) * 1.1f);
                float cpx2 = px - step * 0.2f;
                float cpy2 = py;
                pb.cubic_to (cpx1, cpy1, cpx2, cpy2, px, py);
            }

            var stroke = new Gsk.Stroke (lw);
            stroke.set_line_cap (Gsk.LineCap.ROUND);
            stroke.set_line_join (Gsk.LineJoin.ROUND);

            // Gradient as paint source (linear across width)
            Gsk.ColorStop[] rs = {
                { 0.0f, hsv (hue_r, 0.7f, 0.9f, 0.0f) },
                { 0.2f, hsv (hue_r, 0.7f, 1.0f, 0.55f) },
                { 0.8f, hsv ((float)Math.fmod (hue_r + 40, 360), 0.75f, 1.0f, 0.55f) },
                { 1.0f, hsv (hue_r, 0.7f, 0.9f, 0.0f) },
            };
            var paint = new Gsk.LinearGradientNode (
                make_rect (0, 0, w, h), make_pt (0, base_y), make_pt (w, base_y), rs);
            snap.append_node (new Gsk.StrokeNode (paint, pb.to_path (), stroke));
        }

        // ── Layer 2: parallax starfield ───────────────────────────────────────
        {
            float mouse_dx = mouse_x - cx;
            float mouse_dy = mouse_y - cy;
            for (int i = 0; i < N_STARS; i++) {
                float px = star_x[i] - mouse_dx * star_depth[i] * 0.03f;
                float py = star_y[i] - mouse_dy * star_depth[i] * 0.03f;
                // Wrap to window bounds
                px = (float) Math.fmod (px + w, w);
                py = (float) Math.fmod (py + h, h);
                float sz = star_sz[i];
                float bri = 0.4f + star_depth[i] * 0.6f;
                snap.append_node (new Gsk.ColorNode (
                    { bri, bri, bri + 0.1f, bri },
                    make_rect (px - sz * 0.5f, py - sz * 0.5f, sz, sz)));
            }
        }

        // ── Layer 3: central pulsing core ─────────────────────────────────────
        {
            float pulse = 0.5f + 0.5f * (float) Math.sin (t * 2.5f);
            float r0    = 22.0f + pulse * 8.0f;
            float r1    = 70.0f + pulse * 20.0f;
            float r2    = 130.0f + pulse * 15.0f;

            // Outer diffuse halo (blur)
            Gsk.ColorStop[] halo = {
                { 0.0f, { 0.50f, 0.70f, 1.00f, 0.18f } },
                { 1.0f, { 0.00f, 0.00f, 0.00f, 0.00f } },
            };
            var halo_node = new Gsk.RadialGradientNode (
                make_rect (cx - r2, cy - r2, r2 * 2, r2 * 2),
                make_pt (cx, cy), r2, r2, 0.0f, 1.0f, halo);
            snap.append_node (new Gsk.BlurNode (halo_node, 18.0f));

            // Shadow ring (OutsetShadow)
            var core_rr = make_rrect (cx - r0, cy - r0, r0 * 2, r0 * 2, r0);
            snap.append_node (new Gsk.OutsetShadowNode (
                core_rr, { 0.4f, 0.7f, 1.0f, 0.7f + pulse * 0.25f },
                0, 0, 8.0f + pulse * 12.0f, 30.0f));

            // Inner core radial gradient
            Gsk.ColorStop[] core = {
                { 0.0f, { 0.85f, 0.95f, 1.00f, 1.0f } },
                { 0.4f, { 0.40f, 0.65f, 1.00f, 1.0f } },
                { 1.0f, { 0.10f, 0.25f, 0.70f, 1.0f } },
            };
            snap.append_node (new Gsk.RadialGradientNode (
                make_rect (cx - r0, cy - r0, r0 * 2, r0 * 2),
                make_pt (cx, cy), r0, r0, 0.0f, 1.0f, core));

            // Mid-range energy ring
            Gsk.ColorStop[] ring = {
                { 0.0f, { 0.30f, 0.55f, 1.00f, 0.00f } },
                { 0.7f, { 0.30f, 0.55f, 1.00f, 0.12f } },
                { 1.0f, { 0.30f, 0.55f, 1.00f, 0.00f } },
            };
            snap.append_node (new Gsk.RadialGradientNode (
                make_rect (cx - r1, cy - r1, r1 * 2, r1 * 2),
                make_pt (cx, cy), r1, r1, 0.0f, 1.0f, ring));
        }

        // ── Layer 4: orbital satellites + trails ──────────────────────────────
        foreach (var sat in satellites) {
            float sx, sy;
            sat.get_trail (0, out sx, out sy);

            // Trail: age 1..TRAIL-1, opacity decreasing
            for (int age = Satellite.TRAIL - 1; age >= 1; age--) {
                float tx, ty;
                sat.get_trail (age, out tx, out ty);
                float frac  = 1.0f - (float) age / Satellite.TRAIL;
                float alpha = frac * frac * 0.7f;
                float tsz   = sat.size * frac * 0.9f;
                if (tsz < 0.5f) continue;

                Gsk.ColorStop[] tgs = {
                    { 0.0f, hsv (sat.hue, 0.8f, 1.0f, alpha) },
                    { 1.0f, hsv (sat.hue, 0.8f, 0.5f, 0.0f) },
                };
                var tnode = new Gsk.RadialGradientNode (
                    make_rect (tx - tsz, ty - tsz, tsz * 2, tsz * 2),
                    make_pt (tx, ty), tsz, tsz, 0.0f, 1.0f, tgs);
                snap.append_node (new Gsk.OpacityNode (tnode, alpha));
            }

            // Satellite body glow
            float glow_r = sat.size * 2.5f;
            Gsk.ColorStop[] bgs = {
                { 0.0f, hsv (sat.hue, 0.7f, 1.0f, 0.3f) },
                { 1.0f, hsv (sat.hue, 0.7f, 1.0f, 0.0f) },
            };
            snap.append_node (new Gsk.RadialGradientNode (
                make_rect (sx - glow_r, sy - glow_r, glow_r * 2, glow_r * 2),
                make_pt (sx, sy), glow_r, glow_r, 0.0f, 1.0f, bgs));

            // Satellite core
            Gsk.ColorStop[] bcs = {
                { 0.0f, hsv (sat.hue, 0.2f, 1.0f, 1.0f) },
                { 1.0f, hsv (sat.hue, 0.9f, 0.8f, 1.0f) },
            };
            float bsz = sat.size;
            snap.append_node (new Gsk.RadialGradientNode (
                make_rect (sx - bsz, sy - bsz, bsz * 2, bsz * 2),
                make_pt (sx, sy), bsz, bsz, 0.0f, 1.0f, bcs));
        }

        // ── Layer 5: 3-D rotating octahedron (top-right area) ─────────────────
        {
            float ocx = w * 0.80f, ocy = h * 0.28f;
            float scale = 65.0f;
            float ax = t * 0.7f, ay = t * 1.1f, az = t * 0.4f;

            // Octahedron vertices (unit)
            Vec3[] verts = {
                {  0,  -1,  0 },   // 0 top
                {  0,   1,  0 },   // 1 bottom
                {  0,   0,  1 },   // 2 front
                {  0,   0, -1 },   // 3 back
                { -1,   0,  0 },   // 4 left
                {  1,   0,  0 },   // 5 right
            };

            // Rotate all vertices
            for (int i = 0; i < verts.length; i++) {
                verts[i] = v3_rotx (verts[i], ax);
                verts[i] = v3_roty (verts[i], ay);
                verts[i] = v3_rotz (verts[i], az);
            }

            // 8 faces (CCW winding looking outward)
            int[,] faces = {
                { 0, 2, 5 }, { 0, 5, 3 }, { 0, 3, 4 }, { 0, 4, 2 },
                { 1, 5, 2 }, { 1, 3, 5 }, { 1, 4, 3 }, { 1, 2, 4 },
            };
            float[] face_hues = {
                195, 220, 260, 300, 30, 60, 120, 165
            };

            // Depth sort (painter's algorithm: farthest first)
            int[] order = { 0, 1, 2, 3, 4, 5, 6, 7 };
            for (int i = 0; i < 8; i++)
                for (int j = i + 1; j < 8; j++) {
                    float zi = face_z (verts[faces[order[i],0]],
                                       verts[faces[order[i],1]],
                                       verts[faces[order[i],2]]);
                    float zj = face_z (verts[faces[order[j],0]],
                                       verts[faces[order[j],1]],
                                       verts[faces[order[j],2]]);
                    if (zi > zj) { int tmp = order[i]; order[i] = order[j]; order[j] = tmp; }
                }

            // Draw faces back-to-front
            for (int fi = 0; fi < 8; fi++) {
                int f = order[fi];
                Vec3 va = verts[faces[f, 0]];
                Vec3 vb = verts[faces[f, 1]];
                Vec3 vc = verts[faces[f, 2]];

                // Back-face cull via z-component of cross product (view dir = (0,0,1))
                float nz = (vb.x - va.x) * (vc.y - va.y) - (vb.y - va.y) * (vc.x - va.x);
                if (nz < 0) continue;

                Graphene.Point pa = proj (va, ocx, ocy, scale);
                Graphene.Point pb = proj (vb, ocx, ocy, scale);
                Graphene.Point pc = proj (vc, ocx, ocy, scale);

                var pb2 = new Gsk.PathBuilder ();
                pb2.move_to (pa.x, pa.y);
                pb2.line_to (pb.x, pb.y);
                pb2.line_to (pc.x, pc.y);
                pb2.close ();
                var face_path = pb2.to_path ();

                // Depth-based brightness
                float fz   = face_z (va, vb, vc);
                float bri  = 0.55f + fz * 0.45f;
                float alpha = 0.80f + fz * 0.18f;

                float fh = face_hues[f];
                var paint = new Gsk.ColorNode (hsv (fh, 0.75f, bri, alpha),
                    make_rect (ocx - scale - 10, ocy - scale - 10,
                               scale * 2 + 20, scale * 2 + 20));
                snap.append_node (new Gsk.FillNode (paint, face_path, Gsk.FillRule.WINDING));

                // Edge outline
                var estroke = new Gsk.Stroke (0.8f);
                var epaint  = new Gsk.ColorNode (
                    { 1.0f, 1.0f, 1.0f, 0.25f },
                    make_rect (ocx - scale - 10, ocy - scale - 10,
                               scale * 2 + 20, scale * 2 + 20));
                snap.append_node (new Gsk.StrokeNode (epaint, face_path, estroke));
            }

            // Floating label below octahedron
            if (lay_sub != null) {
                lay_sub.set_text ("3-D projection", -1);
                int tw, th; lay_sub.get_pixel_size (out tw, out th);
                var sub = new Gtk.Snapshot ();
                sub.append_layout (lay_sub, { 1f, 1f, 1f, 0.35f });
                var node = sub.to_node ();
                if (node != null) {
                    snap.append_node (new Gsk.TransformNode (node,
                        new Gsk.Transform ().translate (
                            make_pt (ocx - (float)tw * 0.5f, ocy + scale + 14))));
                }
            }
        }

        // ── Layer 6: easing racetrack (bottom strip) ──────────────────────────
        {
            float lane_h    = 26.0f;
            float lbl_w     = 115.0f;
            float strip_top = h - 8.0f - 6.0f * (lane_h + 4.0f);
            float track_x   = lbl_w + 10.0f;
            float track_w   = w * 0.46f - track_x;

            // Track background
            Gsk.ColorStop[] tbg = {
                { 0.0f, { 0.06f, 0.05f, 0.14f, 0.85f } },
                { 1.0f, { 0.03f, 0.02f, 0.08f, 0.85f } },
            };
            snap.append_node (new Gsk.LinearGradientNode (
                make_rect (0, strip_top - 8, lbl_w + track_w + 20, lane_h * 6 + 4 * 6 + 20),
                make_pt (0, strip_top), make_pt (0, strip_top + 200), tbg));

            // 4-second loop
            float loop_t = (float)((tick_us % 4000000) / 4000000.0);

            string[] lbl_names = {
                "linear", "ease-in³", "ease-out³",
                "ease-in-out³", "elastic", "bounce"
            };
            float[] lane_hues = { 60, 120, 195, 260, 300, 30 };

            for (int li = 0; li < 6; li++) {
                float ly = strip_top + li * (lane_h + 4.0f);

                float eased;
                switch (li) {
                    case 0: eased = ease_linear       (loop_t); break;
                    case 1: eased = ease_in_cubic      (loop_t); break;
                    case 2: eased = ease_out_cubic     (loop_t); break;
                    case 3: eased = ease_in_out_cubic  (loop_t); break;
                    case 4: eased = ease_out_elastic   (loop_t); break;
                    default:eased = ease_out_bounce    (loop_t); break;
                }

                // Lane track line
                float mid_y = ly + lane_h * 0.5f;
                snap.append_node (new Gsk.ColorNode (
                    { 1f, 1f, 1f, 0.07f },
                    make_rect (track_x, mid_y - 0.5f, track_w, 1.0f)));

                // Start + end markers
                snap.append_node (new Gsk.ColorNode (
                    { 1f, 1f, 1f, 0.20f },
                    make_rect (track_x, ly, 1.5f, lane_h)));
                snap.append_node (new Gsk.ColorNode (
                    { 1f, 1f, 1f, 0.20f },
                    make_rect (track_x + track_w - 1.5f, ly, 1.5f, lane_h)));

                // Dot position
                float dot_x  = track_x + eased * (track_w - 10.0f) + 5.0f;
                float dot_r  = 6.0f;
                Gdk.RGBA dcol = hsv (lane_hues[li], 0.8f, 1.0f, 1.0f);

                // Glow behind dot
                Gsk.ColorStop[] dg = {
                    { 0.0f, hsv (lane_hues[li], 0.6f, 1.0f, 0.5f) },
                    { 1.0f, hsv (lane_hues[li], 0.6f, 1.0f, 0.0f) },
                };
                float gr = dot_r * 2.5f;
                snap.append_node (new Gsk.RadialGradientNode (
                    make_rect (dot_x - gr, mid_y - gr, gr * 2, gr * 2),
                    make_pt (dot_x, mid_y), gr, gr, 0.0f, 1.0f, dg));

                // Dot
                snap.append_node (new Gsk.ColorNode (dcol,
                    make_rect (dot_x - dot_r, mid_y - dot_r, dot_r * 2, dot_r * 2)));

                // Label
                if (lay_ease_lbl != null) {
                    lay_ease_lbl.set_text (lbl_names[li], -1);
                    int tw, th; lay_ease_lbl.get_pixel_size (out tw, out th);
                    var sub = new Gtk.Snapshot ();
                    sub.append_layout (lay_ease_lbl,
                        { dcol.red, dcol.green, dcol.blue, 0.75f });
                    var node = sub.to_node ();
                    if (node != null) {
                        snap.append_node (new Gsk.TransformNode (node,
                            new Gsk.Transform ().translate (
                                make_pt (lbl_w - (float) tw - 6.0f,
                                         mid_y - (float) th * 0.5f))));
                    }
                }
            }
        }

        // ── Layer 7: spring comet + trail ─────────────────────────────────────
        {
            for (int age = COMET_TRAIL - 1; age >= 0; age--) {
                int idx   = ((comet_head - 1 - age) % COMET_TRAIL + COMET_TRAIL) % COMET_TRAIL;
                float tx  = comet_trail_x[idx];
                float ty  = comet_trail_y[idx];
                float frac = 1.0f - (float) age / COMET_TRAIL;
                float r   = 3.0f + frac * 5.0f;
                float a   = frac * frac * 0.85f;
                float ch  = (float)Math.fmod (t * 60.0 + age * 15.0, 360.0);

                Gsk.ColorStop[] cg = {
                    { 0.0f, hsv (ch, 0.5f, 1.0f, a) },
                    { 1.0f, hsv (ch, 0.5f, 1.0f, 0.0f) },
                };
                snap.append_node (new Gsk.RadialGradientNode (
                    make_rect (tx - r, ty - r, r * 2, r * 2),
                    make_pt (tx, ty), r, r, 0.0f, 1.0f, cg));
            }

            // Comet head
            float hr = 8.0f;
            float ch = (float)Math.fmod (t * 60.0, 360.0);
            Gsk.ColorStop[] hg = {
                { 0.0f, hsv (ch, 0.1f, 1.0f, 1.0f) },
                { 1.0f, hsv (ch, 0.8f, 1.0f, 0.0f) },
            };
            snap.append_node (new Gsk.RadialGradientNode (
                make_rect (comet_x - hr, comet_y - hr, hr * 2, hr * 2),
                make_pt (comet_x, comet_y), hr, hr, 0.0f, 1.0f, hg));
        }

        // ── Layer 8: click burst particles ────────────────────────────────────
        for (int i = 0; i < burst_count; i++) {
            float alpha = bursts[i].life / bursts[i].max_life;
            alpha = alpha * alpha;
            float bsz = bursts[i].size * alpha;
            if (bsz < 0.5f) continue;
            Gdk.RGBA bcol = hsv (bursts[i].hue, 0.9f, 1.0f, alpha);
            snap.append_node (new Gsk.ColorNode (bcol,
                make_rect (bursts[i].x - bsz * 0.5f,
                           bursts[i].y - bsz * 0.5f,
                           bsz, bsz)));
        }

        // ── Layer 9: title overlay ────────────────────────────────────────────
        if (lay_title != null) {
            lay_title.set_text ("Kinetic Constellation", -1);
            int tw, th; lay_title.get_pixel_size (out tw, out th);
            float tx = (w - (float) tw) * 0.5f;
            float ty = 18.0f;

            // Glow shadow behind title
            var title_rr = make_rrect (tx - 12, ty - 6, (float)tw + 24, (float)th + 12, 8);
            snap.append_node (new Gsk.OutsetShadowNode (
                title_rr, { 0.5f, 0.75f, 1.0f, 0.55f }, 0, 0, 4, 20));

            var sub = new Gtk.Snapshot ();
            sub.append_layout (lay_title, { 0.85f, 0.95f, 1.0f, 0.92f });
            var node = sub.to_node ();
            if (node != null) {
                snap.append_node (new Gsk.TransformNode (node,
                    new Gsk.Transform ().translate (make_pt (tx, ty))));
            }
        }

        if (lay_sub != null) {
            lay_sub.set_text ("click anywhere to burst  ·  move mouse to steer the comet", -1);
            int tw, th; lay_sub.get_pixel_size (out tw, out th);
            var sub2 = new Gtk.Snapshot ();
            sub2.append_layout (lay_sub, { 1f, 1f, 1f, 0.28f });
            var node2 = sub2.to_node ();
            if (node2 != null) {
                snap.append_node (new Gsk.TransformNode (node2,
                    new Gsk.Transform ().translate (
                        make_pt ((w - (float)tw) * 0.5f, 60.0f))));
            }
        }
    }
}

// ── Application ───────────────────────────────────────────────────────────────

int main (string[] args) {
    var app = new Gtk.Application ("org.example.GskKinetic",
                                   GLib.ApplicationFlags.DEFAULT_FLAGS);
    app.activate.connect (() => {
        var canvas = new KineticCanvas ();

        var win = new Gtk.ApplicationWindow (app);
        win.title = "GSK Kinetic Constellation";
        win.set_default_size (1280, 800);
        win.set_child (canvas);
        win.present ();
    });
    return app.run (args);
}
