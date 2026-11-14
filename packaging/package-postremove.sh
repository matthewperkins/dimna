#!/bin/sh
# Run as root by the .deb (postrm) and the .rpm (%postun) after the package's files are gone
# (packaging/nfpm.yaml), and on an upgrade after the old version's files are replaced.
# Reloads udev's rules so the board's rule is forgotten once its file is removed. The groups
# dimna and realtime are left as they are: other programs or the system's own setup may use
# them, and their members are the administrator's choice.
set -u
if command -v udevadm >/dev/null 2>&1 && [ -S /run/udev/control ]; then
    udevadm control --reload-rules || true
fi
exit 0
