#!/bin/sh
# Starts dimna from its desktop entry (dimna.desktop) and keeps what it prints, since a
# desktop launch has no terminal: appended to ${XDG_STATE_HOME:-~/.local/state}/dimna/dimna.log.
#
#   dimna-desktop-launch.sh DIMNA_BINARY [ARGS...]
#
# The package installs it as /usr/libexec/dimna/dimna-desktop-launch (DIMNA_BINARY is
# /usr/bin/dimna); packaging/install-user.sh points the user's entry at the unpacked copy.
#
# If the user unit dimna-jack.service is installed (packaging/dimna-jack.service), it is
# started first (JACK takes the sound card, PipeWire stops), and when dimna exits, however
# it exits, it is stopped and PipeWire's sockets and services are started again. Without
# the unit, dimna is run exactly as before.
[ $# -ge 1 ] || { echo "usage: $0 DIMNA_BINARY [ARGS...]" >&2; exit 2; }
bin=$1
shift
state=${XDG_STATE_HOME:-$HOME/.local/state}/dimna
log=
if mkdir -p "$state" 2>/dev/null; then
    echo "=== $(date '+%F %T') $bin $*" >>"$state/dimna.log"
    systemctl --user cat dimna-jack.service >/dev/null 2>&1 ||
        exec "$bin" "$@" >>"$state/dimna.log" 2>&1
    log=$state/dimna.log
else
    systemctl --user cat dimna-jack.service >/dev/null 2>&1 || exec "$bin" "$@"
fi

# With JACK. The signals that end a session wait for dimna instead of ending this script
# (dimna gets them too, and quits); a trap that is not empty leaves dimna's own handling as
# it is.
trap ':' INT TERM HUP
# Runs a command with its output in the log, if there is one.
logged() {
    if [ -n "$log" ]; then "$@" >>"$log" 2>&1; else "$@"; fi
}
logged systemctl --user start dimna-jack.service ||
    logged echo "dimna-jack.service did not start: see journalctl --user -u dimna-jack"
logged "$bin" "$@"
status=$?
logged systemctl --user stop dimna-jack.service
for unit in pipewire.socket pipewire-pulse.socket pipewire.service pipewire-pulse.service wireplumber.service; do
    logged systemctl --user start "$unit"
done
exit $status
