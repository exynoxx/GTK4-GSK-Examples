/**
 * GSK demo 02 — VideoPlayerCanvas
 *
 * Custom Gtk.Widget that owns media lifecycle, animation, and gesture
 * handling.  Rendering is delegated to ControlsBar and EmptyState.
 */

// ---------------------------------------------------------------------------
// Drag state
// ---------------------------------------------------------------------------

enum DragTarget { NONE, PROGRESS, VOLUME }

// ---------------------------------------------------------------------------
// VideoPlayerCanvas
// ---------------------------------------------------------------------------

class VideoPlayerCanvas : Gtk.Widget {

    // ----- Media state -----
    private Gtk.MediaStream? media      = null;
    private GLib.File?       cur_file   = null;
    private ulong[]          media_hids = {};

    // ----- Animation state -----
    private uint  tick_id             = 0;
    private int64 last_motion_time_us = 0;
    private int64 last_tick_us        = 0;   // for dt-based opacity lerp
    private float controls_opacity    = 1.0f;
    private float target_opacity      = 1.0f;

    // ----- Drag / interaction state -----
    private DragTarget drag_target          = DragTarget.NONE;
    private bool       was_playing_pre_drag = false;
    private double     drag_start_x         = 0;
    private int64      last_seek_us          = 0;

    // ----- Components -----
    private ControlsBar controls = new ControlsBar ();
    private EmptyState  empty    = new EmptyState ();

    // -------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------

    construct {
        focusable = true;
        set_size_request (960, 600);

        var click = new Gtk.GestureClick ();
        click.pressed.connect (on_click);
        add_controller (click);

        var drag = new Gtk.GestureDrag ();
        drag.drag_begin.connect  (on_drag_begin);
        drag.drag_update.connect (on_drag_update);
        drag.drag_end.connect    (on_drag_end);
        add_controller (drag);

        var motion = new Gtk.EventControllerMotion ();
        motion.motion.connect (on_motion);
        motion.enter.connect  ((x, y) => wake_controls ());
        add_controller (motion);

        var key = new Gtk.EventControllerKey ();
        key.key_pressed.connect (on_key_pressed);
        add_controller (key);
    }

    ~VideoPlayerCanvas () {
        if (tick_id != 0)
            remove_tick_callback (tick_id);
    }

    // -------------------------------------------------------------------
    // realize / unrealize
    // -------------------------------------------------------------------

    public override void realize () {
        base.realize ();

        if (media != null)
            realize_media ();

        tick_id = add_tick_callback ((widget, clock) => {
            int64 now = clock.get_frame_time ();
            // dt-based lerp so fade speed is frame-rate independent (~125 ms)
            float dt = last_tick_us > 0
                ? (float)(now - last_tick_us) / 1000000.0f
                : 0.016f;
            last_tick_us = now;

            // Auto-hide: fade controls out after 2.5 s of mouse inactivity
            // when playing and nothing is being dragged.
            if (media != null && media.get_playing ()
                    && drag_target == DragTarget.NONE
                    && last_motion_time_us > 0
                    && now - last_motion_time_us > 2500000) {
                target_opacity = 0.0f;
            } else {
                target_opacity = 1.0f;
            }

            float diff = target_opacity - controls_opacity;
            bool dirty = (diff > 0.001f || diff < -0.001f);
            if (dirty) {
                controls_opacity += diff * 8.0f * dt;
                if (controls_opacity < 0.0f) controls_opacity = 0.0f;
                if (controls_opacity > 1.0f) controls_opacity = 1.0f;
            }

            // Always redraw during playback so the progress bar advances
            if (media != null && media.get_playing ())
                dirty = true;

            if (dirty)
                widget.queue_draw ();

            return Source.CONTINUE;
        });
    }

    public override void unrealize () {
        if (media != null)
            unrealize_media ();
        if (tick_id != 0) {
            remove_tick_callback (tick_id);
            tick_id = 0;
        }
        base.unrealize ();
    }

    // -------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------

    public void load_file (GLib.File file) {
        disconnect_media_signals ();
        if (media != null && get_realized ())
            unrealize_media ();

        cur_file = file;
        media    = Gtk.MediaFile.for_file (file);

        if (get_realized ())
            realize_media ();

        // Redraw on any media property change and on new video frames
        media_hids += media.notify.connect ((pspec) => queue_draw ());
        media_hids += ((Gdk.Paintable) media).invalidate_contents.connect (() => queue_draw ());

        media.play_now ();

        controls_opacity    = 1.0f;
        target_opacity      = 1.0f;
        last_motion_time_us = GLib.get_monotonic_time ();

        queue_draw ();
    }

    // -------------------------------------------------------------------
    // Media surface lifecycle
    // -------------------------------------------------------------------

    private void realize_media () {
        var native = get_native ();
        if (native != null) {
            var surface = native.get_surface ();
            if (surface != null)
                media.realize (surface);
        }
    }

    private void unrealize_media () {
        var native = get_native ();
        if (native != null) {
            var surface = native.get_surface ();
            if (surface != null)
                media.unrealize (surface);
        }
    }

    private void disconnect_media_signals () {
        if (media == null) return;
        foreach (var id in media_hids)
            media.disconnect (id);
        media_hids = {};
    }

    // -------------------------------------------------------------------
    // Interaction helpers
    // -------------------------------------------------------------------

    private void wake_controls () {
        target_opacity      = 1.0f;
        last_motion_time_us = GLib.get_monotonic_time ();
        queue_draw ();
    }

    private void toggle_fullscreen () {
        var win = get_root () as Gtk.Window;
        if (win == null) return;
        if (win.is_fullscreen ()) win.unfullscreen ();
        else win.fullscreen ();
    }

    private void open_file_dialog () {
        var dlg = new Gtk.FileDialog ();
        dlg.title = "Open Video File";
        var win = get_root () as Gtk.Window;
        dlg.open.begin (win, null, (obj, res) => {
            try {
                var f = dlg.open.end (res);
                if (f != null) {
                    load_file (f);
                    var w = get_root () as Gtk.Window;
                    if (w != null) w.title = f.get_basename ();
                }
            } catch (GLib.Error e) {
                // user cancelled — nothing to do
            }
        });
    }

    // -------------------------------------------------------------------
    // Gesture handlers
    // -------------------------------------------------------------------

    private void on_click (int n_press, double x, double y) {
        wake_controls ();
        grab_focus ();

        if (media == null) {
            if (point_in_rect (x, y, empty.hit_open_pill))
                open_file_dialog ();
            return;
        }

        if (point_in_rect (x, y, controls.hit_play)) {
            if (media.get_playing ()) media.pause (); else media.play_now ();
        } else if (point_in_rect (x, y, controls.hit_mute)) {
            media.set_muted (!media.get_muted ());
            queue_draw ();
        } else if (point_in_rect (x, y, controls.hit_fullscreen)) {
            toggle_fullscreen ();
        } else if (point_in_rect (x, y, controls.hit_progress)) {
            seek_to_ratio ((x - controls.progress_track_x) / controls.progress_track_w);
        } else if (point_in_rect (x, y, controls.hit_volume)) {
            set_volume_ratio ((x - controls.volume_track_x) / controls.volume_track_w);
        }
    }

    private void on_drag_begin (double x, double y) {
        wake_controls ();
        drag_start_x        = x;
        was_playing_pre_drag = media != null && media.get_playing ();

        if (media == null) { drag_target = DragTarget.NONE; return; }

        if (point_in_rect (x, y, controls.hit_progress)) {
            drag_target = DragTarget.PROGRESS;
            // Pause during scrub to prevent audio glitches; resume on drag_end
            if (was_playing_pre_drag)
                media.pause ();
        } else if (point_in_rect (x, y, controls.hit_volume)) {
            drag_target = DragTarget.VOLUME;
        } else {
            drag_target = DragTarget.NONE;
        }
    }

    private void on_drag_update (double offset_x, double offset_y) {
        if (drag_target == DragTarget.NONE || media == null) return;
        wake_controls ();
        double cx = drag_start_x + offset_x;

        if (drag_target == DragTarget.PROGRESS) {
            int64 now_us = GLib.get_monotonic_time ();
            if (now_us - last_seek_us > 33000) {   // throttle to ~30 Hz
                seek_to_ratio ((cx - controls.progress_track_x) / controls.progress_track_w);
                last_seek_us = now_us;
            }
        } else {
            set_volume_ratio ((cx - controls.volume_track_x) / controls.volume_track_w);
        }
    }

    private void on_drag_end (double offset_x, double offset_y) {
        if (drag_target == DragTarget.PROGRESS && media != null) {
            double cx = drag_start_x + offset_x;
            seek_to_ratio ((cx - controls.progress_track_x) / controls.progress_track_w);
            if (was_playing_pre_drag)
                media.play_now ();
        }
        drag_target = DragTarget.NONE;
    }

    private void on_motion (double x, double y) {
        wake_controls ();

        bool on_control = media != null
            && (point_in_rect (x, y, controls.hit_play)
                || point_in_rect (x, y, controls.hit_mute)
                || point_in_rect (x, y, controls.hit_fullscreen)
                || point_in_rect (x, y, controls.hit_progress)
                || point_in_rect (x, y, controls.hit_volume));
        bool on_pill = media == null && point_in_rect (x, y, empty.hit_open_pill);

        set_cursor_from_name ((on_control || on_pill) ? "pointer" : "default");
    }

    private bool on_key_pressed (uint keyval, uint keycode, Gdk.ModifierType state) {
        wake_controls ();

        bool ctrl = Gdk.ModifierType.CONTROL_MASK in state;

        if (keyval == Gdk.Key.space) {
            if (media != null) {
                if (media.get_playing ()) media.pause (); else media.play_now ();
            }
            return true;
        }

        if (keyval == Gdk.Key.Left && media != null) {
            int64 ts = media.get_timestamp () - 5000000;
            if (ts < 0) ts = 0;
            media.seek (ts);
            return true;
        }

        if (keyval == Gdk.Key.Right && media != null) {
            int64 dur = media.get_duration ();
            int64 ts  = media.get_timestamp () + 5000000;
            if (dur > 0 && ts > dur) ts = dur;
            media.seek (ts);
            return true;
        }

        if (keyval == Gdk.Key.f || keyval == Gdk.Key.F) {
            toggle_fullscreen ();
            return true;
        }

        if (keyval == Gdk.Key.Escape) {
            var win = get_root () as Gtk.Window;
            if (win != null && win.is_fullscreen ())
                win.unfullscreen ();
            return true;
        }

        if (ctrl && (keyval == Gdk.Key.o || keyval == Gdk.Key.O)) {
            open_file_dialog ();
            return true;
        }

        return false;
    }

    // -------------------------------------------------------------------
    // Seek / volume helpers
    // -------------------------------------------------------------------

    private void seek_to_ratio (double ratio) {
        if (media == null) return;
        if (ratio < 0.0) ratio = 0.0;
        if (ratio > 1.0) ratio = 1.0;
        int64 dur = media.get_duration ();
        if (dur > 0)
            media.seek ((int64)(ratio * (double) dur));
    }

    private void set_volume_ratio (double ratio) {
        if (media == null) return;
        if (ratio < 0.0) ratio = 0.0;
        if (ratio > 1.0) ratio = 1.0;
        media.set_volume (ratio);
        queue_draw ();
    }

    // -------------------------------------------------------------------
    // Snapshot — composes the GSK render-node tree from component subtrees
    // -------------------------------------------------------------------

    public override void snapshot (Gtk.Snapshot snap) {
        float w = (float) get_width ();
        float h = (float) get_height ();

        if (media == null || !media.is_prepared ()) {
            snap.append_node (empty.build_node (w, h, this));
            return;
        }

        Graphene.Rect vr = compute_video_rect (w, h);
        float vw = vr.get_width ();
        float vh = vr.get_height ();
        if (vw < 1.0f || vh < 1.0f) return;

        // Black letterbox backdrop
        var black = new Gsk.ColorNode ({ 0f, 0f, 0f, 1f }, make_rect (0, 0, w, h));

        // VIDEO #1 — raw frame translated to its letterbox position
        var sub1 = new Gtk.Snapshot ();
        media.snapshot (sub1, vw, vh);
        var vid1 = sub1.to_node ();
        Gsk.RenderNode vid1_node = (vid1 != null)
            ? (Gsk.RenderNode) new Gsk.TransformNode (
                vid1,
                new Gsk.Transform ().translate (make_pt (vr.get_x (), vr.get_y ())))
            : black;

        var controls_node = controls.build_node (w, h, vr, media, this);
        var controls_dim  = new Gsk.OpacityNode (controls_node, controls_opacity);

        Gsk.RenderNode[] scene = { black, vid1_node, controls_dim };
        snap.append_node (new Gsk.ContainerNode (scene));
    }

    // -------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------

    private Graphene.Rect compute_video_rect (float w, float h) {
        double ar = ((Gdk.Paintable) media).get_intrinsic_aspect_ratio ();
        if (ar <= 0.0) ar = 16.0 / 9.0;
        float vw, vh, vx, vy;
        if ((double) w / (double) h > ar) {
            vh = h; vw = (float)(h * ar);
            vx = (w - vw) / 2.0f; vy = 0.0f;
        } else {
            vw = w; vh = (float)(w / ar);
            vx = 0.0f; vy = (h - vh) / 2.0f;
        }
        return make_rect (vx, vy, vw, vh);
    }

    private static bool point_in_rect (double px, double py, Graphene.Rect r) {
        return px >= r.get_x () && px < r.get_x () + r.get_width ()
            && py >= r.get_y () && py < r.get_y () + r.get_height ();
    }
}
