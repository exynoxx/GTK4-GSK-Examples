/**
 * GSK demo 07: notification banners on a Wayland layer-shell surface.
 *
 * Showcases that `gtk4-layer-shell` plus a custom `Gtk.Widget.snapshot()`
 * is all you need to build floating, compositor-managed notification
 * popups — no DBus, no shell integration. The window itself is a normal
 * `Gtk.Window` whose surface role has been switched to `layer-shell`
 * before it is mapped.
 *
 * Layer-shell setup (see `make_layer_window`):
 *   - Layer = TOP                       (above regular windows)
 *   - Anchor = TOP | RIGHT              (window sizes to natural content
 *                                        height and grows downward)
 *   - KeyboardMode = NONE               (banners never steal focus)
 *   - No exclusive zone                 (windows beneath are not resized)
 *
 * GSK nodes / techniques per banner:
 *   - RoundedClipNode    rounded card silhouette
 *   - ColorNode          card fill + left accent stripe (urgency hint)
 *   - BorderNode         1 px hairline border
 *   - OutsetShadowNode   soft drop shadow
 *   - push_opacity()     fade-in / fade-out
 *   - translate()        slide-in from the right, slide-out to the right
 *   - base.snapshot()    composes the Pango-rendered child labels on top
 *
 * The binary is a single-instance `Gtk.Application`. The first invocation
 * shows the layer-shell surface with a welcome banner explaining how to
 * fire more notifications; subsequent invocations route through the
 * existing process and add another banner:
 *
 *     ./build/gsk-demo                                  # start the server
 *     ./build/gsk-demo "Title" "Body"                   # add a banner
 *     ./build/gsk-demo "Title" "Body" icon-name urgency
 *
 * `urgency` is one of low | normal | critical and controls the colour of
 * the left accent stripe. See `fire-notification.sh` for a convenience
 * wrapper.
 */

// ─── Geometry helpers ────────────────────────────────────────────────────────

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

// ─── Tunables ────────────────────────────────────────────────────────────────

const int BANNER_WIDTH    = 340;
const int BANNER_RADIUS   = 12;
const int BANNER_PADDING  = 14;
const int ACCENT_WIDTH    = 4;
const int STACK_GAP       = 10;
const int SCREEN_MARGIN   = 16;

const int ENTER_MS        = 220;
const int LEAVE_MS        = 320;
const int EXPIRE_MS       = 5000;

// ─── Sample notification payload ─────────────────────────────────────────────

struct Sample {
    public string   title;
    public string   body;
    public string   icon;        // freedesktop icon name; "" for none
    public Gdk.RGBA accent;      // left-edge stripe colour
}

Gdk.RGBA accent_for_urgency (string urgency) {
    switch (urgency) {
        case "low":      return { 0.36f, 0.55f, 0.94f, 1.0f };   // blue
        case "critical": return { 0.88f, 0.35f, 0.30f, 1.0f };   // red
        default:         return { 0.98f, 0.66f, 0.20f, 1.0f };   // orange
    }
}

// ─── NotifBanner ─────────────────────────────────────────────────────────────
//
// One card. Lays its labels out with stock GTK widgets, draws the card
// chrome (background, border, shadow, accent stripe) with GSK render nodes,
// and animates entry/exit by pushing an opacity + translate frame.

class NotifBanner : Gtk.Box {

    public signal void leave_finished ();

    private Gdk.RGBA accent;
    private uint     expire_id  = 0;

    // Animation state
    private uint   tick_id      = 0;
    private bool   entering     = false;
    private bool   leaving      = false;
    private int64  anim_started = 0;
    private double anim_t       = 0.0;   // 0..1 within current phase

    public NotifBanner (Sample s) {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        accent = s.accent;

        set_size_request (BANNER_WIDTH, -1);
        set_halign (Gtk.Align.END);

        // Inner row provides the *card-interior* padding. Margins on the
        // banner itself would just push it around inside the stack — what we
        // want is the GSK-drawn chrome (full banner bounds) plus inset
        // content. Using an inner row keeps the chrome edge-to-edge.
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        row.margin_start  = BANNER_PADDING + ACCENT_WIDTH + 4;
        row.margin_end    = BANNER_PADDING;
        row.margin_top    = BANNER_PADDING;
        row.margin_bottom = BANNER_PADDING;
        append (row);

        if (s.icon != "") {
            var img = new Gtk.Image.from_icon_name (s.icon);
            img.pixel_size = 32;
            img.set_valign (Gtk.Align.START);
            row.append (img);
        }

        var col = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        col.set_hexpand (true);

        var title = new Gtk.Label (s.title);
        title.set_xalign (0);
        title.set_halign (Gtk.Align.START);
        title.set_wrap (true);
        title.set_wrap_mode (Pango.WrapMode.WORD_CHAR);
        // max_width_chars forces wrapping. Without it the label's natural
        // request is its longest single-line size, and the banner would
        // stretch past BANNER_WIDTH on long titles/bodies.
        title.set_max_width_chars (30);
        title.set_width_chars     (30);
        title.add_css_class ("notif-title");
        col.append (title);

        if (s.body != "") {
            var body = new Gtk.Label (s.body);
            body.set_xalign (0);
            body.set_halign (Gtk.Align.START);
            body.set_wrap (true);
            body.set_wrap_mode (Pango.WrapMode.WORD_CHAR);
            body.set_max_width_chars (30);
            body.set_width_chars     (30);
            body.add_css_class ("notif-body");
            col.append (body);
        }

        row.append (col);

        // Click anywhere → dismiss.
        var click = new Gtk.GestureClick ();
        click.set_button (Gdk.BUTTON_PRIMARY);
        click.released.connect (() => { begin_leave (); });
        add_controller (click);
    }

    public override void realize () {
        base.realize ();
        begin_enter ();
        expire_id = Timeout.add (EXPIRE_MS, () => {
            expire_id = 0;
            begin_leave ();
            return Source.REMOVE;
        });
    }

    public override void unrealize () {
        if (tick_id   != 0) { remove_tick_callback (tick_id); tick_id = 0; }
        if (expire_id != 0) { Source.remove (expire_id);      expire_id = 0; }
        base.unrealize ();
    }

    private void begin_enter () {
        entering = true;
        anim_t = 0.0;
        start_tick (ENTER_MS, () => {
            entering = false;
        });
    }

    public void begin_leave () {
        if (leaving) return;
        if (tick_id   != 0) { remove_tick_callback (tick_id); tick_id   = 0; }
        if (expire_id != 0) { Source.remove (expire_id);      expire_id = 0; }
        entering = false;
        leaving  = true;
        anim_t   = 0.0;
        set_sensitive (false);
        start_tick (LEAVE_MS, () => {
            leave_finished ();
        });
    }

    private delegate void OnDone ();

    private void start_tick (int duration_ms, owned OnDone on_done) {
        anim_started = (get_frame_clock () != null)
                       ? ((!) get_frame_clock ()).get_frame_time ()
                       : (int64) get_monotonic_time ();
        tick_id = add_tick_callback ((widget, clock) => {
            double elapsed = (clock.get_frame_time () - anim_started) / 1000.0;
            double t = elapsed / (double) duration_ms;
            if (t >= 1.0) {
                anim_t = 1.0;
                queue_draw ();
                tick_id = 0;
                on_done ();
                return Source.REMOVE;
            }
            anim_t = t;
            queue_draw ();
            return Source.CONTINUE;
        });
    }

    private static double ease_out_cubic (double t) {
        double inv = 1.0 - t;
        return 1.0 - inv * inv * inv;
    }

    public override void snapshot (Gtk.Snapshot s) {
        float w = (float) get_width ();
        float h = (float) get_height ();
        if (w <= 0 || h <= 0) return;

        // Resolve current opacity + slide offset from animation phase.
        double opacity = 1.0;
        float  dx      = 0.0f;
        if (entering) {
            double e = ease_out_cubic (anim_t);
            opacity = e;
            dx = (float) ((1.0 - e) * (w + 24.0));
        } else if (leaving) {
            double e = ease_out_cubic (anim_t);
            opacity = 1.0 - e;
            dx = (float) (e * (w + 24.0));
        }

        s.save ();
        s.push_opacity (opacity);
        if (dx != 0.0f) s.translate (make_pt (dx, 0.0f));

        // ── Card chrome ──────────────────────────────────────────────────────
        var rect = make_rect (0, 0, w, h);
        var rr   = Gsk.RoundedRect ();
        rr.init_from_rect (rect, (float) BANNER_RADIUS);

        // Drop shadow drawn before the clip so it spreads outside the card.
        s.append_outset_shadow (rr, { 0f, 0f, 0f, 0.45f }, 0f, 4f, 0f, 14f);

        // Everything else clipped to the rounded silhouette.
        s.push_rounded_clip (rr);

        s.append_color ({ 0.08f, 0.09f, 0.13f, 0.96f }, rect);
        s.append_color (accent, make_rect (0, 0, (float) ACCENT_WIDTH, h));

        float[] bw = { 1f, 1f, 1f, 1f };
        Gdk.RGBA bc_col = { 1f, 1f, 1f, 0.12f };
        Gdk.RGBA[] bc = { bc_col, bc_col, bc_col, bc_col };
        s.append_border (rr, bw, bc);

        // Child widgets (icon + labels) on top of the card chrome.
        base.snapshot (s);

        s.pop ();   // rounded clip
        s.pop ();   // opacity
        s.restore ();
    }
}

// ─── Layer-shell host window ─────────────────────────────────────────────────

Gtk.Window make_layer_window (Gtk.Application app, out Gtk.Box stack) {
    var win = new Gtk.Window ();
    win.set_application (app);

    GtkLayerShell.init_for_window (win);
    GtkLayerShell.set_namespace     (win, "gsk-demo-notifications");
    GtkLayerShell.set_layer         (win, GtkLayerShell.Layer.TOP);
    GtkLayerShell.set_keyboard_mode (win, GtkLayerShell.KeyboardMode.NONE);
    GtkLayerShell.set_anchor (win, GtkLayerShell.Edge.TOP,   true);
    GtkLayerShell.set_anchor (win, GtkLayerShell.Edge.RIGHT, true);
    GtkLayerShell.set_margin (win, GtkLayerShell.Edge.TOP,   SCREEN_MARGIN);
    GtkLayerShell.set_margin (win, GtkLayerShell.Edge.RIGHT, SCREEN_MARGIN);

    win.decorated = false;
    win.resizable = false;
    win.add_css_class ("notif-root");

    stack = new Gtk.Box (Gtk.Orientation.VERTICAL, STACK_GAP);
    stack.set_halign (Gtk.Align.END);
    stack.set_valign (Gtk.Align.START);
    win.set_child (stack);

    return win;
}

// ─── Application ─────────────────────────────────────────────────────────────
//
// Single-instance Gtk.Application. The primary instance owns the
// layer-shell window; subsequent process invocations route their argv
// through GApplication.command_line and produce a new banner.

class NotifApp : Gtk.Application {

    private Gtk.Window? window = null;
    private Gtk.Box?    stack  = null;

    public NotifApp () {
        Object (application_id: "org.example.GskLayerNotifications",
                flags: ApplicationFlags.HANDLES_COMMAND_LINE);
    }

    public override int command_line (ApplicationCommandLine cl) {
        if (!ensure_window ()) {
            cl.printerr ("gsk-demo: gtk4-layer-shell is not supported on this "
                       + "compositor. Run under a wlroots-based compositor "
                       + "(Sway, Hyprland, river, ...).\n");
            return 1;
        }

        string[] args = cl.get_arguments ();

        if (args.length >= 3) {
            // ./gsk-demo TITLE BODY [ICON] [URGENCY]
            Sample s = {
                args[1],
                args[2],
                args.length > 3 ? args[3] : "",
                accent_for_urgency (args.length > 4 ? args[4] : "normal")
            };
            spawn_banner (s);
        } else if (args.length == 2) {
            cl.printerr ("gsk-demo: need at least TITLE and BODY "
                       + "(got TITLE only)\n");
            return 2;
        } else if (!cl.is_remote) {
            // First, local invocation with no notification args: introduce
            // the demo with a single welcome banner.
            spawn_banner ({
                "Layer-shell notifications",
                "Run ./fire-notification.sh \"Title\" \"Body\" to send more.",
                "dialog-information-symbolic",
                accent_for_urgency ("low")
            });
        }

        return 0;
    }

    private bool ensure_window () {
        if (window != null) return true;
        if (!GtkLayerShell.is_supported ()) return false;

        install_css ();
        window = make_layer_window (this, out stack);
        ((!) window).present ();
        return true;
    }

    private void install_css () {
        var css = new Gtk.CssProvider ();
        css.load_from_string ("""
            .notif-root  { background-color: transparent; }
            .notif-title { font-weight: bold; color: #ececec; }
            .notif-body  { color: #b0b0b0; }
        """);
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (), css,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
    }

    private void spawn_banner (Sample s) {
        if (stack == null) return;
        var banner = new NotifBanner (s);
        banner.leave_finished.connect (() => { ((!) stack).remove (banner); });
        ((!) stack).append (banner);
    }
}

int main (string[] args) {
    return new NotifApp ().run (args);
}
