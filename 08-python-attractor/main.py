#!/usr/bin/env python3
"""
GSK demo 08 (Python / PyGObject): 3-D strange attractor.

Integrates the Aizawa attractor on the CPU each frame and renders the last
several thousand state points as a long, colour-graded trail rebuilt every
frame from a `Gsk.PathBuilder`. Showcases the parts of the GSK render-node
API that are most useful for live data visualisation — paths, strokes,
gradient paints, and Pango layouts composed into the scene.

Demonstrated nodes / techniques:
    LinearGradientNode      vertical sky background
    ColorNode               static stars + glow head + paint source
    PathBuilder/StrokeNode  trail polyline, chunked per colour
    RoundedClipNode         title chip silhouette
    OutsetShadowNode        title chip drop shadow
    TransformNode           positioning the Pango title
    append_layout()         Pango text into the GSK tree
    add_tick_callback       per-frame integration + auto-rotation

The Aizawa system (a, b, c, d, e, f constants) settles into a bounded
twisted attractor; we project its trajectory with a simple Y-then-X
rotation plus perspective division.  No noise libraries, no NumPy — just
the standard `math` module, so the code stays trivially portable.

Run:
    python3 main.py
"""

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gsk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Graphene", "1.0")
gi.require_version("Pango", "1.0")

from gi.repository import Gdk, GLib, Gsk, Gtk, Graphene, Pango

import math
import sys


# ── Aizawa attractor ────────────────────────────────────────────────────────

A, B, C, D, E, F = 0.95, 0.7, 0.6, 3.5, 0.25, 0.1
DT = 0.01
STEPS_PER_FRAME = 12
TRAIL_LEN = 2400
CHUNK = 200


def integrate(x, y, z):
    """One explicit-Euler step of the Aizawa attractor."""
    dx = (z - B) * x - D * y
    dy = D * x + (z - B) * y
    dz = (C + A * z
          - z ** 3 / 3.0
          - (x * x + y * y) * (1.0 + E * z)
          + F * z * x ** 3)
    return x + dx * DT, y + dy * DT, z + dz * DT


# ── Tiny helpers ────────────────────────────────────────────────────────────

def make_rect(x, y, w, h):
    r = Graphene.Rect()
    r.init(x, y, w, h)
    return r


def make_pt(x, y):
    p = Graphene.Point()
    p.init(x, y)
    return p


def rgba(r, g, b, a=1.0):
    c = Gdk.RGBA()
    c.red, c.green, c.blue, c.alpha = r, g, b, a
    return c


def stop(offset, color):
    cs = Gsk.ColorStop()
    cs.offset = offset
    cs.color = color
    return cs


def hsv(h, s, v, a=1.0):
    """HSV [0, 360) × [0, 1]² → Gdk.RGBA."""
    h = h % 360.0
    sec = int(h // 60) % 6
    f = (h / 60.0) - (h // 60)
    p = v * (1.0 - s)
    q = v * (1.0 - f * s)
    t = v * (1.0 - (1.0 - f) * s)
    r, g, b = [(v, t, p), (q, v, p), (p, v, t),
               (p, q, v), (t, p, v), (v, p, q)][sec]
    return rgba(r, g, b, a)


# ── AttractorCanvas ─────────────────────────────────────────────────────────

class AttractorCanvas(Gtk.Widget):
    __gtype_name__ = "AttractorCanvas"

    def __init__(self):
        super().__init__()
        self.set_hexpand(True)
        self.set_vexpand(True)
        self.set_size_request(960, 640)

        # Pre-spin the integrator so we open on the steady-state shape.
        x, y, z = 0.1, 0.0, 0.0
        for _ in range(3000):
            x, y, z = integrate(x, y, z)
        self._state = (x, y, z)

        # Ring buffers (Python lists; ~6 µs per write — plenty fast).
        self._trail_x = [0.0] * TRAIL_LEN
        self._trail_y = [0.0] * TRAIL_LEN
        self._trail_z = [0.0] * TRAIL_LEN
        self._head = 0
        self._filled = 0

        self._rot_y = 0.0
        self._rot_x = 0.32
        self._frame_us = 0

        self._title = None  # Pango.Layout, lazily created in realize()

        self.add_tick_callback(self._on_tick)

    # ── frame clock ────────────────────────────────────────────────────────

    def _on_tick(self, _widget, clock):
        self._frame_us = clock.get_frame_time()

        x, y, z = self._state
        for _ in range(STEPS_PER_FRAME):
            x, y, z = integrate(x, y, z)
            self._trail_x[self._head] = x
            self._trail_y[self._head] = y
            self._trail_z[self._head] = z
            self._head = (self._head + 1) % TRAIL_LEN
            if self._filled < TRAIL_LEN:
                self._filled += 1
        self._state = (x, y, z)

        self._rot_y += 0.006
        self.queue_draw()
        return GLib.SOURCE_CONTINUE

    # ── snapshot ────────────────────────────────────────────────────────────

    def do_snapshot(self, snap):
        w = self.get_width()
        h = self.get_height()
        if w < 2 or h < 2:
            return
        wf, hf = float(w), float(h)
        cx, cy = wf * 0.5, hf * 0.55

        # 1. Vertical gradient sky
        sky = [
            stop(0.0, rgba(0.04, 0.03, 0.12)),
            stop(1.0, rgba(0.01, 0.01, 0.04)),
        ]
        snap.append_node(Gsk.LinearGradientNode.new(
            make_rect(0, 0, wf, hf),
            make_pt(0, 0), make_pt(0, hf),
            sky,
        ))

        # 2. Deterministic starfield
        for i in range(140):
            nx = ((i * 9301 + 49297) % 233280) / 233280.0
            ny = ((i * 13007 + 4127) % 233280) / 233280.0
            sz = 0.35 + ((i * 17) % 100) / 200.0
            snap.append_node(Gsk.ColorNode.new(
                rgba(sz, sz, sz + 0.1, sz),
                make_rect(nx * wf, ny * hf, 1.4, 1.4),
            ))

        # 3. Pre-compute projection trig
        cy_rot, sy_rot = math.cos(self._rot_y), math.sin(self._rot_y)
        cx_rot, sx_rot = math.cos(self._rot_x), math.sin(self._rot_x)
        scale = min(wf, hf) * 0.18 * 5.0

        def project(x, y, z):
            x1 = x * cy_rot + z * sy_rot
            z1 = -x * sy_rot + z * cy_rot
            y2 = y * cx_rot - z1 * sx_rot
            z2 = y * sx_rot + z1 * cx_rot
            d = max(0.6, 5.0 + z2)
            return cx + x1 * scale / d, cy + y2 * scale / d

        # 4. Trail — split into colour-graded chunks for a continuous gradient
        n = self._filled
        if n >= 2:
            base_hue = (self._frame_us / 50000.0) % 360.0
            written = 0
            chunk_pts = []
            for i in range(n):
                idx = (self._head - n + i) % TRAIL_LEN
                chunk_pts.append(project(
                    self._trail_x[idx],
                    self._trail_y[idx],
                    self._trail_z[idx],
                ))
                written += 1
                if written >= CHUNK or i == n - 1:
                    if len(chunk_pts) >= 2:
                        pb = Gsk.PathBuilder.new()
                        pb.move_to(*chunk_pts[0])
                        for px, py in chunk_pts[1:]:
                            pb.line_to(px, py)
                        path = pb.to_path()

                        s = Gsk.Stroke.new(1.5)
                        s.set_line_cap(Gsk.LineCap.ROUND)
                        s.set_line_join(Gsk.LineJoin.ROUND)

                        progress = i / max(1, n - 1)
                        col = hsv(base_hue + progress * 120.0,
                                  0.7, 1.0,
                                  0.15 + progress * 0.75)
                        paint = Gsk.ColorNode.new(col,
                                                  make_rect(0, 0, wf, hf))
                        snap.append_node(Gsk.StrokeNode.new(paint, path, s))
                    # Continue with last point so chunks join seamlessly
                    chunk_pts = [chunk_pts[-1]]
                    written = 0

            # 5. Bright head marker
            head_idx = (self._head - 1) % TRAIL_LEN
            hx, hy = project(
                self._trail_x[head_idx],
                self._trail_y[head_idx],
                self._trail_z[head_idx],
            )
            r = 4.0
            snap.append_node(Gsk.ColorNode.new(
                rgba(1.0, 0.95, 0.85, 1.0),
                make_rect(hx - r, hy - r, r * 2, r * 2),
            ))

        # 6. Title chip — Pango text inside a rounded card
        self._snapshot_title(snap, wf)

    # ── Pango title ─────────────────────────────────────────────────────────

    def _snapshot_title(self, snap, wf):
        if self._title is None:
            self._title = self.create_pango_layout("Aizawa attractor")
            self._title.set_font_description(
                Pango.FontDescription.from_string("Cantarell Bold 15"))

        tw, th = self._title.get_pixel_size()
        x = (wf - tw) * 0.5
        y = 22.0

        chip_rect = make_rect(x - 14, y - 6, tw + 28, th + 12)
        chip = Gsk.RoundedRect()
        chip.init_from_rect(chip_rect, 11.0)

        snap.append_outset_shadow(chip, rgba(0, 0, 0, 0.55), 0, 4, 0, 14)
        snap.push_rounded_clip(chip)
        snap.append_color(rgba(0.05, 0.04, 0.13, 0.88), chip_rect)
        snap.append_border(
            chip,
            [1, 1, 1, 1],
            [rgba(1, 1, 1, 0.18)] * 4,
        )
        snap.pop()  # rounded clip

        sub = Gtk.Snapshot()
        sub.append_layout(self._title, rgba(0.92, 0.95, 1.0, 0.95))
        node = sub.to_node()
        if node is not None:
            snap.append_node(Gsk.TransformNode.new(
                node, Gsk.Transform.new().translate(make_pt(x, y))))


# ── Application ─────────────────────────────────────────────────────────────

def main(argv):
    app = Gtk.Application(application_id="org.example.GskPyAttractor")

    def on_activate(app):
        win = Gtk.ApplicationWindow(application=app)
        win.set_title("GSK Demo 08 — Aizawa attractor (Python)")
        win.set_default_size(960, 640)
        win.set_child(AttractorCanvas())
        win.present()

    app.connect("activate", on_activate)
    return app.run(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
