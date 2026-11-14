#!/bin/sh
# Starts dimna from its desktop entry (dimna.desktop) and keeps what it prints, since a
# desktop launch has no terminal: appended to ${XDG_STATE_HOME:-~/.local/state}/dimna/dimna.log.
#
#   dimna-desktop-launch.sh DIMNA_BINARY [ARGS...]
#
# The package installs it as /usr/libexec/dimna/dimna-desktop-launch (DIMNA_BINARY is
# /usr/bin/dimna); packaging/install-user.sh points the user's entry at the unpacked copy.
[ $# -ge 1 ] || { echo "usage: $0 DIMNA_BINARY [ARGS...]" >&2; exit 2; }
bin=$1
shift
state=${XDG_STATE_HOME:-$HOME/.local/state}/dimna
if mkdir -p "$state" 2>/dev/null; then
    echo "=== $(date '+%F %T') $bin $*" >>"$state/dimna.log"
    exec "$bin" "$@" >>"$state/dimna.log" 2>&1
fi
exec "$bin" "$@"
