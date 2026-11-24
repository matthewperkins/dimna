#!/bin/sh
# Sets up an unpacked dimna release tarball for the current user, without root:
#
#   packaging/install-user.sh           install the menu entry and icons, print the root
#                                       steps, then run the checks
#   packaging/install-user.sh --check   only the checks; exit status 1 if one needs action
#
# Installs into ${XDG_DATA_HOME:-~/.local/share}: applications/dimna.desktop, pointing at
# this folder's bin/dimna (through packaging/dimna-desktop-launch.sh, which keeps a log in
# ${XDG_STATE_HOME:-~/.local/state}/dimna/dimna.log), and the icon in icons/hicolor.
# Moving or deleting the unpacked folder breaks the entry; run this again from the new place.
#
# The machine setup that needs root (the board's udev rule, the real-time limits, the two
# groups) is only PRINTED, for you to read and run; this script never runs sudo.
#
# The checks only look: the board's device node is found through /sys/bus/usb/devices
# (vendor 0403) and tested for access permission; it is never opened.
#
# For a source checkout, packaging/install-desktop.sh does the same for zig-out/bin.
set -eu

check_only=false
case "${1:-}" in
"") ;;
--check) check_only=true ;;
*)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd -P)
products="601e 601f 602a 602b 602c 602d 602f" # as in packaging/60-dimna-ft60x.rules

# ---- install ----
if ! $check_only; then
    if [ ! -x "$root/bin/dimna" ] || [ ! -f "$root/packaging/dimna.desktop" ]; then
        echo "$root has no bin/dimna or packaging/dimna.desktop: this script is for an unpacked" >&2
        echo "release tarball. In a source checkout use packaging/install-desktop.sh." >&2
        exit 1
    fi
    # The entry's Exec lines quote the paths; characters the desktop-entry format or sed
    # would need escaping for are refused rather than escaped.
    case "$root" in
    *[\"\'\`\$\\%\|\&]* | *"
"*)
        echo "the path $root contains one of \" ' \` \$ \\ % | & or a newline;" >&2
        echo "unpack the tarball somewhere else" >&2
        exit 1
        ;;
    esac

    data=${XDG_DATA_HOME:-$HOME/.local/share}
    apps=$data/applications
    icons=$data/icons/hicolor
    for sz in 32 48 64 128 256; do
        mkdir -p "$icons/${sz}x${sz}/apps"
        cp "$root/packaging/icon/dimna-$sz.png" "$icons/${sz}x${sz}/apps/dimna.png"
    done
    mkdir -p "$icons/scalable/apps"
    cp "$root/packaging/icon/dimna-icon.svg" "$icons/scalable/apps/dimna.svg"
    # Some launchers (hyprtoolkit's) ignore an icon folder without an index.theme.
    [ -f "$icons/index.theme" ] || cp /usr/share/icons/hicolor/index.theme "$icons/" 2>/dev/null || true
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -qtf "$icons" || true; fi

    # The packaged entry, with its /usr paths replaced by this folder's.
    mkdir -p "$apps"
    sed -e "s|XDG_CONFIG_HOME=/usr/share/dimna/sim-config|\"XDG_CONFIG_HOME=$root/packaging/sim-config\"|" \
        -e "s|/usr/libexec/dimna/dimna-desktop-launch /usr/bin/dimna|\"$root/packaging/dimna-desktop-launch.sh\" \"$root/bin/dimna\"|" \
        "$root/packaging/dimna.desktop" >"$apps/dimna.desktop.tmp"
    mv "$apps/dimna.desktop.tmp" "$apps/dimna.desktop"
    if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q "$apps" || true; fi
    echo "installed $apps/dimna.desktop and the dimna icon in $icons"
    echo "  (pointing at $root/bin/dimna)"

    cat <<EOF

Root steps, not run by this script. Read them, then run them yourself (sudo):

  # 1. The groups the two files below name (system groups; skip one that exists):
  getent group dimna    || sudo groupadd --system dimna
  getent group realtime || sudo groupadd --system realtime
  # 2. The board's udev rule: the active local session and the dimna group may open it.
  sudo install -m 0644 '$root/packaging/60-dimna-ft60x.rules' /etc/udev/rules.d/60-dimna-ft60x.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=0403
  # 3. Real-time priority and locked memory for the realtime group (needs a new login):
  sudo install -m 0644 '$root/packaging/99-dimna-realtime.conf' /etc/security/limits.d/99-dimna-realtime.conf
  # 4. Yourself into both groups, then log out and in:
  sudo usermod -aG dimna,realtime $(id -un)

An older rule for the same board (an Open Ephys install's /etc/udev/rules.d/*ft600*.rules)
may still set MODE="0666"; remove it if only the dimna group should reach the board.
EOF
    echo
fi

# ---- checks ----
need=0
ok() { echo "  ok    $*"; }
todo() {
    echo "  TODO  $*"
    need=$((need + 1))
}
note() { echo "  note  $*"; }

echo "Checks:"

# The board: an FT60x of the rule's product IDs, by sysfs; the node is only stat()ed.
sysfs=${DIMNA_SYSFS_USB:-/sys/bus/usb/devices}
found=false
for d in "$sysfs"/*; do
    [ -r "$d/idVendor" ] && [ -r "$d/idProduct" ] || continue
    [ "$(cat "$d/idVendor")" = 0403 ] || continue
    p=$(cat "$d/idProduct")
    case " $products " in *" $p "*) ;; *) continue ;; esac
    found=true
    node=$(printf '/dev/bus/usb/%03d/%03d' "$(cat "$d/busnum")" "$(cat "$d/devnum")")
    if [ -r "$node" ] && [ -w "$node" ]; then
        ok "board (0403:$p) at $node: readable and writable by $(id -un)"
    else
        todo "board (0403:$p) at $node: not accessible to $(id -un) ($(ls -l "$node" 2>&1));" \
            "install the udev rule and join the dimna group (root steps 1, 2, 4)"
    fi
done
$found || note "no board plugged in (USB vendor 0403, products $products); plug it in and run '$0 --check'"

# Real-time limits: the acquisition thread asks for SCHED_FIFO priority 90 (else the most the
# limit allows) and locks its memory. 95, so that it runs above PipeWire's audio thread inside
# dimna, which asks for 88 and gets what the limit allows.
rtprio=$(ulimit -r 2>/dev/null || echo unknown)
case "$rtprio" in
unlimited) ok "real-time priority limit (ulimit -r): unlimited" ;;
'' | *[!0-9]*) todo "real-time priority limit (ulimit -r): cannot read it ($rtprio)" ;;
*)
    if [ "$rtprio" -ge 95 ]; then
        ok "real-time priority limit (ulimit -r): $rtprio (acquisition asks for 90, above PipeWire's 88)"
    else
        todo "real-time priority limit (ulimit -r): $rtprio; 95 wanted (acquisition asks for 90, and must be above" \
            "PipeWire's audio thread, which gets up to 88); root steps 1, 3, 4"
    fi
    ;;
esac
memlock=$(ulimit -l 2>/dev/null || echo unknown)
if [ "$memlock" = unlimited ]; then
    ok "locked-memory limit (ulimit -l): unlimited"
else
    todo "locked-memory limit (ulimit -l): $memlock KiB, dimna locks all its memory: unlimited needed; root steps 1, 3, 4"
fi

# Fonts for the two languages that need more than the Latin script (optional).
has_font() { command -v fc-list >/dev/null 2>&1 && [ -n "$(fc-list "$1" family 2>/dev/null)" ]; }
if ! command -v fc-list >/dev/null 2>&1; then
    note "fc-list (fontconfig) not found, so the fonts were not checked"
else
    if has_font "Noto Sans CJK SC"; then
        ok "font Noto Sans CJK SC (Chinese)"
    else
        note "no Noto Sans CJK SC: only Chinese (language = \"zh\") needs it" \
            "(fonts-noto-cjk, google-noto-sans-cjk-ttc-fonts, noto-fonts-cjk)"
    fi
    if has_font "Vazirmatn"; then
        ok "font Vazirmatn (Persian)"
    elif has_font "Noto Sans Arabic"; then
        ok "font Noto Sans Arabic (Persian)"
    else
        note "no Noto Sans Arabic or Vazirmatn: only Persian (language = \"fa\") needs one" \
            "(fonts-noto-core, google-noto-sans-arabic-fonts, noto-fonts)"
    fi
fi

# Persian's letters are joined by HarfBuzz and FriBidi, opened at run time if present.
for lib in libharfbuzz.so.0 libfribidi.so.0; do
    where=
    for dir in /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib /lib64 /lib/x86_64-linux-gnu /lib; do
        if [ -e "$dir/$lib" ]; then
            where=$dir/$lib
            break
        fi
    done
    if [ -n "$where" ]; then
        ok "$lib (Persian) at $where"
    else
        note "no $lib: only Persian needs it, to join its letters (dimna shows them unjoined without)"
    fi
done

# A Wayland session (the display needs one; dimna-headless does not).
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
    /*) sock=$WAYLAND_DISPLAY ;;
    *) sock=${XDG_RUNTIME_DIR:-/nonexistent}/$WAYLAND_DISPLAY ;;
    esac
    if [ -S "$sock" ]; then
        ok "Wayland session ($sock)"
    else
        todo "WAYLAND_DISPLAY is $WAYLAND_DISPLAY but $sock is not a socket"
    fi
else
    todo "no Wayland session (WAYLAND_DISPLAY is not set): dimna's windows need one, dimna-headless does not"
fi

if [ "$need" -eq 0 ]; then
    echo "Nothing needs doing."
else
    echo "$need check(s) need action (TODO above)."
fi
if $check_only && [ "$need" -gt 0 ]; then exit 1; fi
exit 0
