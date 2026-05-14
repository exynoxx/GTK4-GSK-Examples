#!/bin/sh
# Fire a notification at the running gsk-demo. Starts the demo if it isn't
# already up (the binary is a single-instance Gtk.Application, so a second
# invocation routes the argv through the existing process).
#
# Usage:
#   ./fire-notification.sh "Title" "Body"
#   ./fire-notification.sh "Title" "Body" icon-name
#   ./fire-notification.sh "Title" "Body" icon-name {low|normal|critical}

set -eu

if [ "$#" -lt 2 ]; then
    echo "usage: $0 TITLE BODY [ICON] [low|normal|critical]" >&2
    exit 2
fi

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bin="$dir/build/gsk-demo"

if [ ! -x "$bin" ]; then
    echo "fire-notification.sh: $bin not built." >&2
    echo "  cd $dir && meson setup build && meson compile -C build" >&2
    exit 1
fi

exec "$bin" "$1" "$2" "${3:-}" "${4:-normal}"
