/**
 * GSK demo 09: integrating a custom GSK-drawn widget with the rest of the
 * GTK 4 / GLib ecosystem.
 *
 * One custom `Gtk.Widget` (DesktopCanvas) paints a small "system overview"
 * page entirely through `snapshot()`, pulling its content from across the
 * stack:
 *
 *   Gio.AppInfo            list installed applications
 *   Gtk.IconTheme          resolve GLib.Icon → Gtk.IconPaintable
 *   Gdk.Paintable          icon rendering into a Gtk.Snapshot
 *   Pango.Layout           all typography (title, clock, app labels, …)
 *   Gdk.Display + Gdk.Monitor   primary monitor + refresh rate
 *   Gio.NetworkMonitor     reactive network availability + connectivity
 *   GLib.DateTime          locale-aware time and date
 *   GLib.Environment       hostname, real name, username
 *
 * Stock GTK widgets coexist with the canvas in the same window: a
 * `Gtk.SearchEntry` above the canvas drives the app-grid filter, and the
 * canvas invokes `Gio.AppInfo.launch()` when a card is clicked.
 *
 * Demonstrated GSK nodes:
 *   LinearGradientNode  page background
 *   RoundedClipNode     card silhouettes (header, status, app cards)
 *   ColorNode           card fills + accent bars
 *   BorderNode          1 px hairlines
 *   OutsetShadowNode    soft drop shadows
 *   TransformNode       hover scale + sub-snapshot positioning
 *   append_layout()     Pango text composed into the node tree
 *   Gdk.Paintable.snapshot()  icon paintables drawn into the snapshot
 */

using Gtk;
using Gdk;
using GLib;

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

Gsk.RoundedRect make_rrect (float x, float y, float w, float h, float radius) {
    var rr = Gsk.RoundedRect ();
    rr.init_from_rect (make_rect (x, y, w, h), radius);
    return rr;
}

// ─── AppEntry ────────────────────────────────────────────────────────────────
//
// One row per installed application. Caches the icon paintable so we do
// the (relatively expensive) IconTheme lookup once at startup.

class AppEntry : Object {
    public GLib.AppInfo info;
    public Gtk.IconPaintable? icon;
    public string display_name;
    public string description;
    public string casefold;     // pre-lowered name for filtering

    public AppEntry (GLib.AppInfo ai, Gtk.IconTheme theme) {
        info = ai;
        display_name = ai.get_display_name () ?? ai.get_name ();
        description  = ai.get_description () ?? "";
        casefold     = display_name.down ();

        var gicon = ai.get_icon ();
        icon = (gicon != null)
            ? theme.lookup_by_gicon ((!) gicon, 40, 1,
                                     Gtk.TextDirection.NONE,
                                     Gtk.IconLookupFlags.PRELOAD)
            : theme.lookup_icon ("application-x-executable", null, 40, 1,
                                 Gtk.TextDirection.NONE,
                                 Gtk.IconLookupFlags.PRELOAD);
    }
}

// ─── DesktopCanvas ───────────────────────────────────────────────────────────

class DesktopCanvas : Gtk.Widget {

    // Layout constants (also drive hit-testing for hover + click).
    private const int HEADER_H    = 88;
    private const int STATUS_H    = 92;
    private const int SECTION_GAP = 12;
    private const int OUTER_PAD   = 18;
    private const int CARD_H      = 64;
    private const int CARD_GAP    = 10;
    private const int APP_COLS    = 4;
    private const int ICON_SIZE   = 40;

    // Data sources
    private GenericArray<AppEntry> apps_all     = new GenericArray<AppEntry> ();
    private GenericArray<AppEntry> apps_visible = new GenericArray<AppEntry> ();
    private string filter_text = "";

    // Live state
    private DateTime now;
    private NetworkMonitor netmon;

    // Pango layouts (created once in realize)
    private Pango.Layout? lay_greet  = null;
    private Pango.Layout? lay_time   = null;
    private Pango.Layout? lay_date   = null;
    private Pango.Layout? lay_status_h = null;   // small all-caps heading
    private Pango.Layout? lay_status_v = null;   // primary value text
    private Pango.Layout? lay_app_name = null;

    // Hover / click state
    private double mouse_x = -1;
    private double mouse_y = -1;
    private uint   tick_id = 0;

    construct {
        set_hexpand (true);
        set_vexpand (true);
        set_size_request (940, 660);

        now = new DateTime.now_local ();

        load_apps ();
        recompute_visible ();

        netmon = NetworkMonitor.get_default ();
        netmon.network_changed.connect ((_) => { queue_draw (); });

        var motion = new Gtk.EventControllerMotion ();
        motion.motion.connect ((x, y) => {
            mouse_x = x; mouse_y = y; queue_draw ();
        });
        motion.leave.connect (() => {
            mouse_x = -1; mouse_y = -1; queue_draw ();
        });
        add_controller (motion);

        var click = new Gtk.GestureClick ();
        click.set_button (Gdk.BUTTON_PRIMARY);
        click.released.connect ((_n, x, y) => { on_click (x, y); });
        add_controller (click);
    }

    public override void realize () {
        base.realize ();
        lay_greet     = make_layout ("Cantarell Bold 22");
        lay_time      = make_layout ("Cantarell Light 26");
        lay_date      = make_layout ("Cantarell 11");
        lay_status_h  = make_layout ("Cantarell Bold 8");
        lay_status_v  = make_layout ("Cantarell 12");
        lay_app_name  = make_layout ("Cantarell 10");

        // Once-per-second tick for the clock; cheaper than the frame clock
        // because the rest of the page is static.
        tick_id = Timeout.add_seconds (1, () => {
            now = new DateTime.now_local ();
            queue_draw ();
            return Source.CONTINUE;
        });
    }

    public override void unrealize () {
        if (tick_id != 0) { Source.remove (tick_id); tick_id = 0; }
        base.unrealize ();
    }

    private Pango.Layout make_layout (string desc) {
        var l = create_pango_layout ("");
        l.set_font_description (Pango.FontDescription.from_string (desc));
        return l;
    }

    // ── Data ───────────────────────────────────────────────────────────────

    private void load_apps () {
        var display = Gdk.Display.get_default ();
        var theme = (display != null)
            ? Gtk.IconTheme.get_for_display ((!) display)
            : new Gtk.IconTheme ();

        foreach (var ai in GLib.AppInfo.get_all ()) {
            if (!ai.should_show ()) continue;
            apps_all.add (new AppEntry (ai, theme));
        }
        apps_all.sort ((a, b) => GLib.strcmp (a.casefold, b.casefold));
    }

    public void set_filter (string text) {
        filter_text = text.down ().strip ();
        recompute_visible ();
        queue_draw ();
    }

    private void recompute_visible () {
        apps_visible = new GenericArray<AppEntry> ();
        foreach (var e in apps_all) {
            if (filter_text == "" || e.casefold.contains (filter_text)) {
                apps_visible.add (e);
            }
        }
    }

    // ── Hit-testing ────────────────────────────────────────────────────────

    private int card_index_at (double x, double y, out Graphene.Rect rect) {
        rect = make_rect (0, 0, 0, 0);
        float w = (float) get_width ();
        float grid_top = HEADER_H + SECTION_GAP + STATUS_H + SECTION_GAP;
        if (y < grid_top) return -1;

        float usable_w = w - 2.0f * OUTER_PAD;
        float col_w = (usable_w - (APP_COLS - 1) * CARD_GAP) / APP_COLS;
        float row_h = CARD_H + CARD_GAP;

        float local_y = (float) y - grid_top;
        int row = (int) (local_y / row_h);
        float row_top = grid_top + row * row_h;
        if ((float) y > row_top + CARD_H) return -1;   // in the gap

        float local_x = (float) x - OUTER_PAD;
        if (local_x < 0 || local_x > usable_w) return -1;
        int col = (int) (local_x / (col_w + CARD_GAP));
        float col_x = OUTER_PAD + col * (col_w + CARD_GAP);
        if ((float) x > col_x + col_w) return -1;       // in the gap

        int idx = row * APP_COLS + col;
        if (idx >= (int) apps_visible.length) return -1;
        rect = make_rect (col_x, row_top, col_w, CARD_H);
        return idx;
    }

    private void on_click (double x, double y) {
        Graphene.Rect _r;
        int idx = card_index_at (x, y, out _r);
        if (idx < 0) return;
        var e = apps_visible[idx];
        try {
            e.info.launch (null, null);
        } catch (Error err) {
            stderr.printf ("gsk-demo: launch failed for %s: %s\n",
                           e.display_name, err.message);
        }
    }

    // ── Snapshot ───────────────────────────────────────────────────────────

    public override void snapshot (Gtk.Snapshot snap) {
        float w = (float) get_width ();
        float h = (float) get_height ();
        if (w < 2 || h < 2) return;

        // Background
        Gsk.ColorStop[] bg = {
            { 0.0f, { 0.07f, 0.07f, 0.11f, 1.0f } },
            { 1.0f, { 0.04f, 0.04f, 0.08f, 1.0f } },
        };
        snap.append_node (new Gsk.LinearGradientNode (
            make_rect (0, 0, w, h),
            make_pt (0, 0), make_pt (0, h),
            bg));

        draw_header (snap, w);
        draw_status (snap, w);
        draw_grid   (snap, w, h);
    }

    // ── Header card (greeting + clock) ─────────────────────────────────────

    private void draw_header (Gtk.Snapshot snap, float w) {
        var rect = make_rect (OUTER_PAD, OUTER_PAD,
                              w - 2 * OUTER_PAD, HEADER_H);
        var rr   = make_rrect (rect.origin.x, rect.origin.y,
                               rect.size.width, rect.size.height, 14.0f);

        snap.append_outset_shadow (rr, { 0f, 0f, 0f, 0.45f }, 0, 4, 0, 16);
        snap.push_rounded_clip (rr);
        snap.append_color ({ 0.11f, 0.12f, 0.18f, 1.0f }, rect);

        string user = Environment.get_real_name ();
        if (user == null || user == "Unknown" || user == "") {
            user = Environment.get_user_name ();
        }
        ((!) lay_greet).set_text ("Welcome, " + user, -1);
        append_layout_at (snap, (!) lay_greet,
                          rect.origin.x + 22,
                          rect.origin.y + 16,
                          { 0.94f, 0.96f, 1.0f, 1.0f });

        ((!) lay_date).set_text (now.format ("%A, %d %B %Y") ?? "", -1);
        append_layout_at (snap, (!) lay_date,
                          rect.origin.x + 22,
                          rect.origin.y + 52,
                          { 1f, 1f, 1f, 0.55f });

        // Clock on the right
        ((!) lay_time).set_text (now.format ("%H:%M:%S") ?? "", -1);
        int tw, th;
        ((!) lay_time).get_pixel_size (out tw, out th);
        append_layout_at (snap, (!) lay_time,
                          rect.origin.x + rect.size.width - 22 - tw,
                          rect.origin.y + 18,
                          { 0.55f, 0.85f, 1.0f, 1.0f });

        // App count under the clock
        string app_count = "%u installed · %u shown"
            .printf (apps_all.length, apps_visible.length);
        ((!) lay_date).set_text (app_count, -1);
        int cw, ch;
        ((!) lay_date).get_pixel_size (out cw, out ch);
        append_layout_at (snap, (!) lay_date,
                          rect.origin.x + rect.size.width - 22 - cw,
                          rect.origin.y + 54,
                          { 1f, 1f, 1f, 0.55f });

        // Hairline border
        Gdk.RGBA bc = { 1f, 1f, 1f, 0.08f };
        snap.append_border (rr, { 1, 1, 1, 1 }, { bc, bc, bc, bc });
        snap.pop ();   // rounded clip
    }

    // ── Status row (hostname / display / network) ──────────────────────────

    private void draw_status (Gtk.Snapshot snap, float w) {
        float y = OUTER_PAD + HEADER_H + SECTION_GAP;
        float usable = w - 2 * OUTER_PAD;
        float gap = 12;
        float col = (usable - 2 * gap) / 3;

        // 1. Hostname / user
        string real_name = Environment.get_real_name ();
        string user_name = Environment.get_user_name ();
        string host_sub = (real_name != null && real_name != "Unknown"
                           && real_name != "" && real_name != user_name)
            ? "%s · %s".printf (real_name, user_name)
            : user_name;
        draw_status_card (snap,
            make_rect (OUTER_PAD, y, col, STATUS_H),
            "HOST",
            Environment.get_host_name (),
            host_sub,
            { 0.40f, 0.78f, 0.45f, 1.0f });

        // 2. Display
        string display_v = "unknown";
        string display_sub = "";
        var display = Gdk.Display.get_default ();
        if (display != null) {
            var monitors = ((!) display).get_monitors ();
            uint n = monitors.get_n_items ();
            if (n > 0) {
                var m = (Gdk.Monitor) monitors.get_item (0);
                var g = m.geometry;
                int s = m.scale_factor; //dont use for now
                display_v = "%d × %d".printf (g.width, g.height);
                int hz = m.refresh_rate;
                display_sub = (hz > 0)
                    ? "@ %d Hz · %u monitor%s".printf (hz / 1000, n,
                                                       n == 1 ? "" : "s")
                    : "%u monitor%s".printf (n, n == 1 ? "" : "s");
            }
        }
        draw_status_card (snap,
            make_rect (OUTER_PAD + col + gap, y, col, STATUS_H),
            "DISPLAY", display_v, display_sub,
            { 0.36f, 0.55f, 0.94f, 1.0f });

        // 3. Network
        bool online = netmon.network_available;
        string conn = "";
        switch (netmon.connectivity) {
            case NetworkConnectivity.LOCAL:   conn = "local only"; break;
            case NetworkConnectivity.LIMITED: conn = "limited";    break;
            case NetworkConnectivity.PORTAL:  conn = "captive portal"; break;
            case NetworkConnectivity.FULL:    conn = "full connectivity"; break;
        }
        draw_status_card (snap,
            make_rect (OUTER_PAD + 2 * (col + gap), y, col, STATUS_H),
            "NETWORK",
            online ? "Online" : "Offline",
            online ? conn : "no route to internet",
            online ? Gdk.RGBA () { red = 0.40f, green = 0.78f, blue = 0.45f, alpha = 1 }
                   : Gdk.RGBA () { red = 0.88f, green = 0.35f, blue = 0.30f, alpha = 1 });
    }

    private void draw_status_card (Gtk.Snapshot snap, Graphene.Rect rect,
                                   string heading, string value,
                                   string subline, Gdk.RGBA accent) {
        var rr = make_rrect (rect.origin.x, rect.origin.y,
                             rect.size.width, rect.size.height, 12.0f);
        snap.push_rounded_clip (rr);
        snap.append_color ({ 0.10f, 0.11f, 0.16f, 1.0f }, rect);
        snap.append_color (accent,
            make_rect (rect.origin.x, rect.origin.y, 3, rect.size.height));

        ((!) lay_status_h).set_text (heading, -1);
        append_layout_at (snap, (!) lay_status_h,
                          rect.origin.x + 16, rect.origin.y + 14,
                          { 1f, 1f, 1f, 0.5f });

        ((!) lay_status_v).set_text (value, -1);
        append_layout_at (snap, (!) lay_status_v,
                          rect.origin.x + 16, rect.origin.y + 32,
                          { 0.94f, 0.96f, 1.0f, 1.0f });

        ((!) lay_date).set_text (subline, -1);
        append_layout_at (snap, (!) lay_date,
                          rect.origin.x + 16, rect.origin.y + 58,
                          { 1f, 1f, 1f, 0.5f });

        Gdk.RGBA bc = { 1f, 1f, 1f, 0.08f };
        snap.append_border (rr, { 1, 1, 1, 1 }, { bc, bc, bc, bc });
        snap.pop ();
    }

    // ── App grid ───────────────────────────────────────────────────────────

    private void draw_grid (Gtk.Snapshot snap, float w, float h) {
        float top = OUTER_PAD + HEADER_H + SECTION_GAP + STATUS_H + SECTION_GAP;
        float usable = w - 2 * OUTER_PAD;
        float col_w = (usable - (APP_COLS - 1) * CARD_GAP) / APP_COLS;

        Graphene.Rect hover_rect;
        int hover_idx = (mouse_x >= 0)
            ? card_index_at (mouse_x, mouse_y, out hover_rect)
            : -1;

        int n = (int) apps_visible.length;
        int max_rows = (int) ((h - top - OUTER_PAD + CARD_GAP)
                              / (CARD_H + CARD_GAP));
        int max_cards = max_rows * APP_COLS;
        int show = (n < max_cards) ? n : max_cards;

        for (int i = 0; i < show; i++) {
            int row = i / APP_COLS;
            int col = i % APP_COLS;
            float cx = OUTER_PAD + col * (col_w + CARD_GAP);
            float cy = top + row * (CARD_H + CARD_GAP);
            draw_app_card (snap, apps_visible[i],
                           make_rect (cx, cy, col_w, CARD_H),
                           i == hover_idx);
        }

        // Empty state
        if (n == 0) {
            ((!) lay_status_v).set_text ("No apps match your filter.", -1);
            append_layout_at (snap, (!) lay_status_v,
                              OUTER_PAD + 4, top + 12,
                              { 1f, 1f, 1f, 0.55f });
        }
    }

    private void draw_app_card (Gtk.Snapshot snap, AppEntry e,
                                Graphene.Rect rect, bool hovered) {
        // Hover scale: 1.0 → 1.03, pivot at card centre.
        if (hovered) {
            float cx = rect.origin.x + rect.size.width  * 0.5f;
            float cy = rect.origin.y + rect.size.height * 0.5f;
            snap.save ();
            snap.translate (make_pt (cx, cy));
            snap.scale (1.03f, 1.03f);
            snap.translate (make_pt (-cx, -cy));
        }

        var rr = make_rrect (rect.origin.x, rect.origin.y,
                             rect.size.width, rect.size.height, 10.0f);
        if (hovered) {
            snap.append_outset_shadow (rr, { 0f, 0f, 0f, 0.5f }, 0, 4, 0, 14);
        }
        snap.push_rounded_clip (rr);

        snap.append_color (
            hovered ? Gdk.RGBA () { red = 0.14f, green = 0.16f, blue = 0.23f, alpha = 1 }
                    : Gdk.RGBA () { red = 0.10f, green = 0.11f, blue = 0.16f, alpha = 1 },
            rect);

        // Icon — render the Gdk.Paintable into a sub-snapshot, then position
        // it via a save/translate frame.
        if (e.icon != null) {
            snap.save ();
            snap.translate (make_pt (rect.origin.x + 12,
                                     rect.origin.y +
                                     (rect.size.height - ICON_SIZE) * 0.5f));
            ((Gdk.Paintable) (!) e.icon).snapshot (snap,
                                                    (double) ICON_SIZE,
                                                    (double) ICON_SIZE);
            snap.restore ();
        }

        // Name
        ((!) lay_app_name).set_text (e.display_name, -1);
        ((!) lay_app_name).set_width (
            (int) ((rect.size.width - ICON_SIZE - 28) * Pango.SCALE));
        ((!) lay_app_name).set_ellipsize (Pango.EllipsizeMode.END);
        append_layout_at (snap, (!) lay_app_name,
                          rect.origin.x + 12 + ICON_SIZE + 10,
                          rect.origin.y + 12,
                          { 0.94f, 0.96f, 1.0f, 1.0f });

        // Description (truncated)
        if (e.description != "") {
            ((!) lay_date).set_text (e.description, -1);
            ((!) lay_date).set_width (
                (int) ((rect.size.width - ICON_SIZE - 28) * Pango.SCALE));
            ((!) lay_date).set_ellipsize (Pango.EllipsizeMode.END);
            append_layout_at (snap, (!) lay_date,
                              rect.origin.x + 12 + ICON_SIZE + 10,
                              rect.origin.y + 30,
                              { 1f, 1f, 1f, 0.55f });
        }

        Gdk.RGBA bc = { 1f, 1f, 1f, 0.07f };
        snap.append_border (rr, { 1, 1, 1, 1 }, { bc, bc, bc, bc });
        snap.pop ();   // rounded clip

        if (hovered) snap.restore ();
    }

    // ── Layout helper: append a Pango layout at (x, y) in the snapshot ─────

    private void append_layout_at (Gtk.Snapshot snap, Pango.Layout layout,
                                   float x, float y, Gdk.RGBA color) {
        snap.save ();
        snap.translate (make_pt (x, y));
        snap.append_layout (layout, color);
        snap.restore ();
    }
}

// ─── Application ─────────────────────────────────────────────────────────────

int main (string[] args) {
    var app = new Gtk.Application ("org.example.GskEcosystem",
                                   GLib.ApplicationFlags.DEFAULT_FLAGS);

    app.activate.connect (() => {
        var canvas = new DesktopCanvas ();

        var search = new Gtk.SearchEntry ();
        search.set_placeholder_text ("Filter applications…");
        search.set_margin_top (12);
        search.set_margin_start (18);
        search.set_margin_end (18);
        search.set_margin_bottom (4);
        search.search_changed.connect (() => {
            canvas.set_filter (search.get_text ());
        });

        var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        vbox.append (search);
        vbox.append (canvas);

        var win = new Gtk.ApplicationWindow (app);
        win.set_title ("GSK Demo 09 — GTK ecosystem integration");
        win.set_default_size (980, 760);
        win.set_child (vbox);
        win.present ();
    });

    return app.run (args);
}
