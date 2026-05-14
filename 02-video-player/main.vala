/**
 * GSK demo 02: glass video player — entry point and application setup.
 *
 * See controls_bar.vala for the full list of demonstrated GSK node types and
 * the "signature trick" frosted-glass explanation.
 */

int main (string[] args) {
    // HANDLES_COMMAND_LINE lets us receive positional args (the video path)
    // without GLib rejecting them as "this app can not open files".
    var app = new Gtk.Application ("org.example.GskVideoPlayer",
                                   GLib.ApplicationFlags.HANDLES_COMMAND_LINE);

    // The canvas and window are created once on first activation and reused
    // for subsequent command_line invocations (second terminal, etc.).
    VideoPlayerCanvas? canvas = null;
    Gtk.ApplicationWindow? win = null;

    app.activate.connect (() => {
        if (canvas != null) { win.present (); return; }

        canvas = new VideoPlayerCanvas ();

        win = new Gtk.ApplicationWindow (app);
        win.title = "GSK Video Player";
        win.set_default_size (960, 600);
        win.resizable = true;
        win.set_child (canvas);

        // Drag-and-drop: accept single GLib.File drops
        var drop = new Gtk.DropTarget (typeof (GLib.File), Gdk.DragAction.COPY);
        drop.drop.connect ((val, x, y) => {
            var f = val.get_object () as GLib.File;
            if (f != null) {
                canvas.load_file (f);
                win.title = f.get_basename ();
                return true;
            }
            return false;
        });
        canvas.add_controller (drop);

        // Drag-and-drop: also accept Gdk.FileList (multi-file drops from file
        // managers such as Nautilus).  Only the first file is loaded.
        var drop_list = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
        drop_list.drop.connect ((val, x, y) => {
            unowned Gdk.FileList? fl = (Gdk.FileList?) val.get_boxed ();
            if (fl == null) return false;
            var files = fl.get_files ();
            if (files == null) return false;
            canvas.load_file (files.data);
            win.title = files.data.get_basename ();
            return true;
        });
        canvas.add_controller (drop_list);

        win.present ();
    });

    app.command_line.connect ((cmdline) => {
        // Ensure the window exists, then load any positional argument.
        app.activate ();
        string[] argv = cmdline.get_arguments ();
        if (argv.length > 1 && canvas != null) {
            var f = GLib.File.new_for_commandline_arg (argv[1]);
            canvas.load_file (f);
            if (win != null) win.title = f.get_basename ();
        }
        return 0;
    });

    return app.run (args);
}
