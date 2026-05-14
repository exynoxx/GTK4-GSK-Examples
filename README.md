# The missing demos of GTK Scene Graph Kit

I had a hard time finding examples for the GSK lib, so here is a collection of small GTK 4 / GSK demos that build hardware accelerated graphics using GSK instead of going through `Gtk.DrawingArea` + Cairo. Each demo is a standalone
project with its own `meson.build`.

## Dependencies

### Ubuntu / Debian

```sh
sudo apt install build-essential meson ninja-build valac libgtk-4-dev \
    libgtk4-layer-shell-dev gjs \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav
```

### Fedora

```sh
sudo dnf install gcc meson ninja-build vala gtk4-devel gtk4-layer-shell-devel \
    gjs gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-libav
```

## Build & run

```sh
cd 01-initial
meson setup build
meson compile -C build
./build/gsk-demo
```

The GJS demo needs no build step:

```sh
cd 05-gjs
gjs -m main.js
```

## Demos

| Demo | Language | What's going on |
| --- | --- | --- |
| `01-initial` | Vala | Single `Gtk.Widget` whose `snapshot()` composes a frame from scratch. The "hello world" of GSK node trees. |
| `02-video-player` | Vala | Simple video player. Supports drag-and-drop and CLI file argument. |
| `03-live-numbers` | Vala | Dashboard showcasing various gauges (GTK ≥ 4.14). |
| `04-mixed` | Vala | Mixing stock GTK widgets with custom GSK-drawn widgets in the same window. |
| `05-gjs` | JavaScript (GJS) | Port of `01-initial` to GJS, included as a reference for the GJS-vs-Vala API differences. |
| `06-kinetic` | Vala | Motion showcase: rotating conic sky (GTK ≥ 4.14). |
| `07-layer-notifications` | Vala | Notification banners painted with GSK nodes on a `gtk4-layer-shell` surface (Wayland only). Run once to start, then `./fire-notification.sh "Title" "Body"` to push more. |