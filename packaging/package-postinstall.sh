#!/bin/sh
# Run as root by the .deb (postinst) and the .rpm (%post) after their files are in place
# (packaging/nfpm.yaml). Idempotent: an upgrade or a reinstall runs it again.
#
# - Creates the system groups dimna (the board's device node, 60-dimna-ft60x.rules) and
#   realtime (99-dimna-realtime.conf) if they are missing. It never adds anyone to them:
#   that is the user's decision (usermod -aG dimna,realtime USER, then log out and in).
# - Reloads udev's rules, so the rule sees the dimna group, and re-applies them to USB
#   devices of vendor 0403 (FTDI) only. Nothing is opened or written on any device.
# In a container without udev, the udev part is skipped.
set -u

for g in dimna realtime; do
    if ! getent group "$g" >/dev/null 2>&1; then
        if groupadd --system "$g"; then
            echo "dimna: created the system group $g"
        else
            echo "dimna: could not create the group $g; create it by hand: groupadd --system $g" >&2
        fi
    fi
done

if command -v udevadm >/dev/null 2>&1 && [ -S /run/udev/control ]; then
    udevadm control --reload-rules || echo "dimna: udevadm control --reload-rules failed" >&2
    udevadm trigger --subsystem-match=usb --attr-match=idVendor=0403 --action=change ||
        echo "dimna: udevadm trigger failed; unplug and replug the board" >&2
fi

cat <<'EOF'
dimna: to use the board without being logged in at the machine, and to record with
real-time priority, add yourself to the two groups, then log out and in:
    sudo usermod -aG dimna,realtime $USER
EOF
exit 0
