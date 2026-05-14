/**
 * GSK demo: a custom widget that builds render node trees directly.
 *
 * Demonstrated nodes:
 *   - LinearGradientNode  (background)
 *   - RoundedClipNode     (card shape)
 *   - ColorNode           (card fill)
 *   - BorderNode          (card border)
 *   - OutsetShadowNode    (card drop shadow)
 *   - OpacityNode         (pulsing circle)
 *   - TransformNode       (rotating rectangle)
 *   - BlurNode            (blurred backdrop pill)
 *   - ContainerNode       (compositing)
 */

class GskCanvas : Gtk.Widget {
    // Animation state
    private float tick = 0.0f;
    private uint tick_id = 0;

    construct {
        set_size_request (640, 480);
    }

    ~GskCanvas () {
        if (tick_id != 0) {
            remove_tick_callback (tick_id);
        }
    }

    public override void realize () {
        base.realize ();

        // Drive animation via the frame clock.
        tick_id = add_tick_callback ((widget, clock) => {
            tick = (float)(clock.get_frame_time () % 4000000) / 4000000.0f;
            widget.queue_draw ();
            return Source.CONTINUE;
        });
    }

    // -----------------------------------------------------------------------
    // snapshot() — builds the whole scene as a GSK render-node tree
    // -----------------------------------------------------------------------

    public override void snapshot (Gtk.Snapshot snap) {
        float w = (float) get_width ();
        float h = (float) get_height ();

        // 1. Full-widget linear gradient background -------------------------
        var bg_bounds = Graphene.Rect ();
        bg_bounds.init (0, 0, w, h);

        var grad_start = Graphene.Point ();
        grad_start.init (0, 0);
        var grad_end   = Graphene.Point ();
        grad_end.init (w, h);

        Gsk.ColorStop[] stops = {
            { 0.0f, { 0.07f, 0.07f, 0.12f, 1.0f } },
            { 1.0f, { 0.14f, 0.10f, 0.22f, 1.0f } },
        };

        var bg_node = new Gsk.LinearGradientNode (bg_bounds, grad_start, grad_end, stops);

        // 2. Card with drop shadow, fill, border, and rounded clip ----------
        float cx = w / 2.0f;
        float cy = h / 2.0f;
        float card_w = 280.0f;
        float card_h = 160.0f;

        var card_rect = Graphene.Rect ();
        card_rect.init (cx - card_w / 2, cy - card_h / 2, card_w, card_h);

        // Rounded rect used for both clip and border
        var rounded = Gsk.RoundedRect ();
        var corner  = Graphene.Size ();
        corner.init (14.0f, 14.0f);
        rounded.init_from_rect (card_rect, 14.0f);

        // Outset shadow (behind card)
        var card_fill_node = new Gsk.ColorNode (
            { 0.18f, 0.16f, 0.26f, 1.0f },
            card_rect
        );
        var shadow_node = new Gsk.OutsetShadowNode (rounded, { 0.0f, 0.0f, 0.0f, 0.55f },
                                                    0.0f, 6.0f, 0.0f, 18.0f);

        // Border (1 px, semi-white)
        float[] border_widths = { 1.0f, 1.0f, 1.0f, 1.0f };
        Gdk.RGBA[] border_colors = {
            { 1.0f, 1.0f, 1.0f, 0.12f },
            { 1.0f, 1.0f, 1.0f, 0.12f },
            { 1.0f, 1.0f, 1.0f, 0.12f },
            { 1.0f, 1.0f, 1.0f, 0.12f },
        };
        var border_node = new Gsk.BorderNode (rounded, border_widths, border_colors);

        // Clip fill + border inside rounded rect
        Gsk.RenderNode[] card_inner = { card_fill_node, border_node };
        var card_container = new Gsk.ContainerNode (card_inner);
        var card_clipped   = new Gsk.RoundedClipNode (card_container, rounded);

        // 3. Pulsing circle with opacity ------------------------------------
        float pulse = (float)(Math.sin (tick * 2 * Math.PI)) * 0.5f + 0.5f;
        float circle_r  = 36.0f;
        float circle_cx = cx;
        float circle_cy = cy;

        var circle_rect = Graphene.Rect ();
        circle_rect.init (circle_cx - circle_r, circle_cy - circle_r,
                          circle_r * 2, circle_r * 2);

        var circle_rounded = Gsk.RoundedRect ();
        circle_rounded.init_from_rect (circle_rect, circle_r);

        var circle_fill = new Gsk.ColorNode (
            { 0.40f, 0.75f, 1.00f, 1.0f },
            circle_rect
        );
        var circle_clipped = new Gsk.RoundedClipNode (circle_fill, circle_rounded);
        var circle_opacity = new Gsk.OpacityNode (circle_clipped, 0.35f + pulse * 0.65f);

        // 4. Rotating coloured rectangle ------------------------------------
        float angle_deg = tick * 360.0f;

        var rot_rect = Graphene.Rect ();
        rot_rect.init (-30.0f, -12.0f, 60.0f, 24.0f);

        var rot_fill = new Gsk.ColorNode ({ 1.0f, 0.50f, 0.20f, 0.9f }, rot_rect);

        var transform = new Gsk.Transform ()
            .translate (Graphene.Point () { x = cx, y = cy })
            .rotate (angle_deg);

        var rot_node = new Gsk.TransformNode (rot_fill, transform);

        // 5. Blurred pill in the top-right corner ---------------------------
        var pill_rect = Graphene.Rect ();
        pill_rect.init (w - 140.0f, 18.0f, 110.0f, 36.0f);

        var pill_fill = new Gsk.ColorNode ({ 1.0f, 1.0f, 1.0f, 0.08f }, pill_rect);
        var pill_blur = new Gsk.BlurNode (pill_fill, 8.0f);

        // 6. Compose everything with a ContainerNode ------------------------
        Gsk.RenderNode[] scene = {
            bg_node,
            shadow_node,
            card_clipped,
            circle_opacity,
            rot_node,
            pill_blur,
        };
        var root = new Gsk.ContainerNode (scene);

        snap.append_node (root);
    }
}

int main (string[] args) {
    var app = new Gtk.Application ("org.example.GskDemo",
                                   GLib.ApplicationFlags.DEFAULT_FLAGS);

    app.activate.connect (() => {
        var win = new Gtk.ApplicationWindow (app);
        win.title = "GSK Render Node Demo";
        win.resizable = true;

        var canvas = new GskCanvas ();
        win.set_child (canvas);
        win.present ();
    });

    return app.run (args);
}
