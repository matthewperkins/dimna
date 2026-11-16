#!/bin/sh
# Launcher used by dimna.desktop: runs the built program and keeps its log, since a desktop
# launch has no terminal. Output is appended to ${XDG_STATE_HOME:-~/.local/state}/dimna/dimna.log.
# The program reads its settings from ${XDG_CONFIG_HOME:-~/.config}/dimna/config.toml.
# Build first: zig build --release=safe
#
# If the user unit dimna-jack.service is installed (packaging/dimna-jack.service), it is
# started first (JACK takes the sound card, PipeWire stops), and when dimna exits, however
# it exits, it is stopped and PipeWire's sockets and services are started again. Without
# the unit, dimna is run exactly as before.
root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
state=${XDG_STATE_HOME:-$HOME/.local/state}/dimna
mkdir -p "$state"
echo "=== $(date '+%F %T') dimna $*" >>"$state/dimna.log"
systemctl --user cat dimna-jack.service >/dev/null 2>&1 ||
    exec "$root/zig-out/bin/dimna" "$@" >>"$state/dimna.log" 2>&1

# With JACK. The signals that end a session wait for dimna instead of ending this script
# (dimna gets them too, and quits); a trap that is not empty leaves dimna's own handling as
# it is.
trap ':' INT TERM HUP
systemctl --user start dimna-jack.service >>"$state/dimna.log" 2>&1 ||
    echo "dimna-jack.service did not start: see journalctl --user -u dimna-jack" >>"$state/dimna.log"
"$root/zig-out/bin/dimna" "$@" >>"$state/dimna.log" 2>&1
status=$?
systemctl --user stop dimna-jack.service >>"$state/dimna.log" 2>&1
for unit in pipewire.socket pipewire-pulse.socket pipewire.service pipewire-pulse.service wireplumber.service; do
    systemctl --user start "$unit" >>"$state/dimna.log" 2>&1
done
exit $status
