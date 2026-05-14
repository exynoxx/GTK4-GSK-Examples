#!/usr/bin/env -S gjs -m
/**
 * GSK demo 04 — GJS port of demo 01.
 *
 * Run:  gjs -m main.js
 *
 * Demonstrated nodes:
 *   LinearGradientNode   – full-widget background
 *   RoundedClipNode      – card shape + circle clip
 *   ColorNode            – card fill, circle fill, rotated rect
 *   BorderNode           – semi-transparent card edge
 *   OutsetShadowNode     – card drop shadow
 *   OpacityNode          – pulsing circle fade
 *   TransformNode        – spinning rectangle
 *   BlurNode             – frosted pill in the top-right corner
 *   ContainerNode        – scene compositor
 *
 * GJS-vs-Vala API differences worth noting:
 *   • Widget subclassing: GObject.registerClass + vfunc_* overrides
 *   • GBoxed structs (Graphene.Rect, Gsk.RoundedRect) created with new + init()
 *   • Ditto Gsk.ColorStop — plain JS objects { offset, color } do NOT work;
 *     you must use new Gsk.ColorStop() and assign fields individually
 *   • Gdk.RGBA: new Gdk.RGBA(), then set .red/.green/.blue/.alpha
 *   • ApplicationFlags lives in Gio, not GLib
 *   • Gsk.Transform methods return new instances (functional / immutable style)
 *   • Tick callback must return GLib.SOURCE_CONTINUE to keep firing
 */

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import Gtk from 'gi://Gtk?version=4.0';
import Gdk from 'gi://Gdk?version=4.0';
import Gsk from 'gi://Gsk';
import Graphene from 'gi://Graphene';

// ---------------------------------------------------------------------------
// Geometry / colour helpers — keep snapshot() readable
// ---------------------------------------------------------------------------

function rect(x, y, w, h) {
    const r = new Graphene.Rect();
    r.init(x, y, w, h);
    return r;
}

function pt(x, y) {
    const p = new Graphene.Point();
    p.init(x, y);
    return p;
}

function rgba(r, g, b, a) {
    const c = new Gdk.RGBA();
    c.red = r; c.green = g; c.blue = b; c.alpha = a;
    return c;
}

function rrect(bounds, radius) {
    const rr = new Gsk.RoundedRect();
    rr.init_from_rect(bounds, radius);
    return rr;
}

// GJS requires proper Gsk.ColorStop instances — plain JS objects are rejected.
function stop(offset, r, g, b, a) {
    const s = new Gsk.ColorStop();
    s.offset = offset;
    s.color = rgba(r, g, b, a);
    return s;
}

// ---------------------------------------------------------------------------
// Custom widget — builds the GSK render-node tree each frame
// ---------------------------------------------------------------------------

const GskCanvas = GObject.registerClass(
    { GTypeName: 'GskCanvas' },
    class GskCanvas extends Gtk.Widget {

        _init(params = {}) {
            super._init(params);
            this.set_size_request(640, 480);
            this._tick = 0;
            this._tickId = 0;
        }

        vfunc_realize() {
            super.vfunc_realize();
            this._tickId = this.add_tick_callback((_widget, clock) => {
                this._tick = (clock.get_frame_time() % 4_000_000) / 4_000_000;
                this.queue_draw();
                return GLib.SOURCE_CONTINUE;
            });
        }

        vfunc_unrealize() {
            if (this._tickId !== 0) {
                this.remove_tick_callback(this._tickId);
                this._tickId = 0;
            }
            super.vfunc_unrealize();
        }

        // -------------------------------------------------------------------
        // vfunc_snapshot — builds the whole scene as a render-node tree
        // -------------------------------------------------------------------

        vfunc_snapshot(snap) {
            const w = this.get_width();
            const h = this.get_height();
            const t = this._tick; // 0..1, wraps every 4 s

            // 1. Full-widget linear gradient background ---------------------
            const bgNode = new Gsk.LinearGradientNode(
                rect(0, 0, w, h),
                pt(0, 0), pt(w, h),
                [
                    stop(0.0, 0.07, 0.07, 0.12, 1),
                    stop(1.0, 0.14, 0.10, 0.22, 1),
                ]
            );

            // 2. Card: outset shadow + rounded fill + semi-white border -----
            const cx = w / 2;
            const cy = h / 2;
            const cardBounds = rect(cx - 140, cy - 80, 280, 160);
            const cardRR = rrect(cardBounds, 14);

            const shadowNode = new Gsk.OutsetShadowNode(
                cardRR, rgba(0, 0, 0, 0.55), 0, 6, 0, 18
            );

            const cardFill = new Gsk.ColorNode(rgba(0.18, 0.16, 0.26, 1), cardBounds);

            const edgeColor = rgba(1, 1, 1, 0.12);
            const cardBorder = new Gsk.BorderNode(
                cardRR,
                [1, 1, 1, 1],
                [edgeColor, edgeColor, edgeColor, edgeColor]
            );

            const cardClipped = new Gsk.RoundedClipNode(
                new Gsk.ContainerNode([cardFill, cardBorder]),
                cardRR
            );

            // 3. Pulsing circle (OpacityNode) --------------------------------
            const pulse = Math.sin(t * 2 * Math.PI) * 0.5 + 0.5;
            const cr = 36;
            const circleBounds = rect(cx - cr, cy - cr, cr * 2, cr * 2);

            const circleOpacity = new Gsk.OpacityNode(
                new Gsk.RoundedClipNode(
                    new Gsk.ColorNode(rgba(0.40, 0.75, 1, 1), circleBounds),
                    rrect(circleBounds, cr)
                ),
                0.35 + pulse * 0.65
            );

            // 4. Rotating coloured rectangle (TransformNode) -----------------
            const rotFill = new Gsk.ColorNode(rgba(1, 0.5, 0.2, 0.9), rect(-30, -12, 60, 24));
            const rotNode = new Gsk.TransformNode(
                rotFill,
                new Gsk.Transform().translate(pt(cx, cy)).rotate(t * 360)
            );

            // 5. Blurred pill in the top-right corner (BlurNode) ------------
            const pillFill = new Gsk.ColorNode(rgba(1, 1, 1, 0.08), rect(w - 140, 18, 110, 36));
            const pillBlur = new Gsk.BlurNode(pillFill, 8);

            // 6. Compose the full scene -------------------------------------
            snap.append_node(
                new Gsk.ContainerNode([
                    bgNode,
                    shadowNode,
                    cardClipped,
                    circleOpacity,
                    rotNode,
                    pillBlur,
                ])
            );
        }
    }
);

// ---------------------------------------------------------------------------
// Application
// ---------------------------------------------------------------------------

const app = new Gtk.Application({
    application_id: 'org.example.GskDemoGjs',
    flags: Gio.ApplicationFlags.DEFAULT_FLAGS,
});

app.connect('activate', () => {
    const win = new Gtk.ApplicationWindow({ application: app });
    win.set_title('GSK Render Node Demo (GJS)');
    win.resizable = true;
    win.set_child(new GskCanvas());
    win.present();
});

app.run([]);
