/**
 * GSK demo 02 — EmptyState
 *
 * Builds the "no video loaded" screen render-node subtree and maintains
 * hit_open_pill for VideoPlayerCanvas gesture dispatch.
 */

class EmptyState : Object {

    // Hit rect written by build_node(), read by VideoPlayerCanvas
    public Graphene.Rect hit_open_pill = Graphene.Rect ();

    // Builds the empty-state node tree and updates hit_open_pill as a side effect.
    // owner is required solely to create Pango layouts.
    public Gsk.RenderNode build_node (float w, float h, Gtk.Widget owner) {
        var bounds = make_rect (0, 0, w, h);

        // Dark gradient backdrop
        Gsk.ColorStop[] stops = {
            { 0.0f, { 0.07f, 0.07f, 0.10f, 1.0f } },
            { 1.0f, { 0.14f, 0.10f, 0.20f, 1.0f } },
        };
        var bg = new Gsk.LinearGradientNode (bounds, make_pt (0, 0), make_pt (w, h), stops);

        // ---- "Open File" pill ----
        float pill_w  = 140.0f;
        float pill_h  = 44.0f;
        float pill_cx = w / 2.0f;
        float pill_cy = h / 2.0f;
        var pill_rect  = make_rect (pill_cx - pill_w / 2.0f,
                                    pill_cy - pill_h / 2.0f,
                                    pill_w, pill_h);
        var pill_rrect = Gsk.RoundedRect ();
        pill_rrect.init_from_rect (pill_rect, pill_h / 2.0f);

        hit_open_pill = pill_rect;

        var pill_shadow  = new Gsk.OutsetShadowNode (
            pill_rrect, { 0f, 0f, 0f, 0.40f }, 0f, 4f, 0f, 14f);
        var pill_fill    = new Gsk.ColorNode ({ 1f, 1f, 1f, 0.10f }, pill_rect);
        var pill_clipped = new Gsk.RoundedClipNode (pill_fill, pill_rrect);
        float[] pw = { 1f, 1f, 1f, 1f };
        Gdk.RGBA[] pc = {
            { 1f, 1f, 1f, 0.25f }, { 1f, 1f, 1f, 0.25f },
            { 1f, 1f, 1f, 0.25f }, { 1f, 1f, 1f, 0.25f }
        };
        var pill_border = new Gsk.BorderNode (pill_rrect, pw, pc);

        var ol = owner.create_pango_layout ("Open File");
        ol.set_font_description (Pango.FontDescription.from_string ("Sans 13"));
        int olw, olh;
        ol.get_pixel_size (out olw, out olh);
        var open_sub = new Gtk.Snapshot ();
        open_sub.append_layout (ol, { 1f, 1f, 1f, 1f });
        var open_label = open_sub.to_node ();

        Gsk.RenderNode[] pill_nodes = { pill_shadow, pill_clipped, pill_border };
        if (open_label != null) {
            var ot = new Gsk.Transform ().translate (
                make_pt (pill_cx - (float) olw / 2.0f,
                         pill_cy - (float) olh / 2.0f));
            pill_nodes += new Gsk.TransformNode (open_label, ot);
        }
        var pill_node = new Gsk.ContainerNode (pill_nodes);

        // ---- "or drop a video here" hint, below the pill ----
        var hl = owner.create_pango_layout ("or drop a video here");
        hl.set_font_description (Pango.FontDescription.from_string ("Sans 11"));
        int hlw, hlh;
        hl.get_pixel_size (out hlw, out hlh);
        var hint_sub = new Gtk.Snapshot ();
        hint_sub.append_layout (hl, { 1f, 1f, 1f, 1f });
        var hint_label = hint_sub.to_node ();

        Gsk.RenderNode[] scene = { bg, pill_node };
        if (hint_label != null) {
            float hint_y = pill_cy + pill_h / 2.0f + 20.0f;
            var ht = new Gsk.Transform ().translate (
                make_pt (w / 2.0f - (float) hlw / 2.0f, hint_y));
            scene += new Gsk.OpacityNode (
                new Gsk.TransformNode (hint_label, ht), 0.65f);
        }

        return new Gsk.ContainerNode (scene);
    }
}
