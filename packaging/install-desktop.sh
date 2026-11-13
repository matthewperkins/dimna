#!/bin/sh
# Installs an oez launcher into ~/.local/share/applications pointing at this checkout,
# and the oez icon into the user's hicolor icon theme.
# Build first: zig build --release=safe
#
#   packaging/install-desktop.sh [CONFIG_HOME]
#
# With CONFIG_HOME, the launcher starts oez with XDG_CONFIG_HOME set to that folder, so it
# reads CONFIG_HOME/oez/config.toml and views.toml instead of ~/.config/oez. The
# "simulated board" action always uses the built-in defaults: a config written for the
# board names headstages the simulator may not have.
set -e
config_home=${1:-}
if [ -n "$config_home" ]; then
    config_home=$(cd "$config_home" && pwd)
    [ -f "$config_home/oez/config.toml" ] || { echo "no $config_home/oez/config.toml" >&2; exit 1; }
fi
root=$(cd "$(dirname "$0")/.." && pwd)
data=${XDG_DATA_HOME:-$HOME/.local/share}
launch=$root/packaging/oez-launch.sh
[ -n "$config_home" ] && launch="env XDG_CONFIG_HOME=$config_home $launch"
# The simulator must not pick up a board config, nor the user's ~/.config/oez.
sim_launch="env XDG_CONFIG_HOME=$root/packaging/sim-config $root/packaging/oez-launch.sh --sim 32,16"
apps=$data/applications
mkdir -p "$apps"
# Install icons into the hicolor theme so launchers that only resolve icon
# names (e.g. Walker, hyprlauncher) can find them, not just file paths.
icons=$data/icons/hicolor
for sz in 32 48 64 128 256; do
    mkdir -p "$icons/${sz}x${sz}/apps"
    cp "$root/packaging/icon/oez-$sz.png" "$icons/${sz}x${sz}/apps/oez.png"
done
# The SVG is self-contained (no linked files), so it can be installed as the scalable icon.
mkdir -p "$icons/scalable/apps"
cp "$root/packaging/icon/oez-icon.svg" "$icons/scalable/apps/oez.svg"
# hyprtoolkit ignores theme dirs without an index.theme
[ -f "$icons/index.theme" ] || cp /usr/share/icons/hicolor/index.theme "$icons/" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -qtf "$icons" || true
cat >"$apps/oez.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=oEZ
GenericName=Electrophysiology acquisition
Comment=Acquire and record from the Open Ephys acquisition board
Exec=$launch
Icon=oez
Terminal=false
Categories=Science;
StartupWMClass=oez
StartupNotify=false
Actions=Simulator;

[Desktop Action Simulator]
Name=oEZ (simulated board)
Exec=$sim_launch
DESK
command -v update-desktop-database >/dev/null && update-desktop-database -q "$apps" || true
echo "installed $apps/oez.desktop${config_home:+ (config: $config_home/oez)}"
