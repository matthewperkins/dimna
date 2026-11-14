# Wayland protocol descriptions

The XML files the Wayland bindings are generated from (zig-wayland's scanner, `build.zig`),
so a build needs neither the wayland-protocols nor the wayland package installed, and does
not depend on a distribution's older copy (tearing-control, content-type and cursor-shape
are staging protocols that Debian 12 and Ubuntu 22.04 do not have).

Copied unmodified from an Arch Linux system, 2026-11-14, with the same directory layout as
`/usr/share/wayland-protocols`: **wayland-protocols 1.50** (https://gitlab.freedesktop.org/wayland/wayland-protocols)
for every file except `wayland.xml`, which is from **wayland 1.26.0**
(`/usr/share/wayland/wayland.xml`, https://gitlab.freedesktop.org/wayland/wayland).

| file | sha256 |
|---|---|
| `wayland.xml` | `cc860987e54f8d85c940e97fa1270c69b6e4ad31fbcf5a7f00107ce1157f5e07` |
| `stable/xdg-shell/xdg-shell.xml` | `8cd3980d0783e1f55d12901ac51533204af71487cc4dc69ee00bb7096647d9de` |
| `stable/presentation-time/presentation-time.xml` | `0a9e4ee351aada90af9d165a540b86ad9d85f740ce87cf8c26490dd1ae701b5f` |
| `stable/tablet/tablet-v2.xml` | `ac1128b26c779cf90b9ed71182ba5e34a7262826789adae206d825a4d45908b4` |
| `unstable/pointer-gestures/pointer-gestures-unstable-v1.xml` | `9f7b6ad542f444001312113395b8de6f24e59d6f0c57c9b44f6c3c498ef004d7` |
| `staging/tearing-control/tearing-control-v1.xml` | `846895b4a90ba1ddd75673cefc596480beef318f1694ec7dbca0fec54bb27043` |
| `staging/content-type/content-type-v1.xml` | `203d17a26baa2ab4a8c2c9cb737c953fa3263c73a0a8aa6e552a41b3eac2196d` |
| `staging/cursor-shape/cursor-shape-v1.xml` | `bb57d91e53a79dadab7c612dab87c233393cee73673feefa7442cfbfdd9aed2f` |

Licence: each file carries its own copyright and MIT-style permission notice in its header;
they are kept as they came. Check with `sha256sum` from this folder. Only these files are
used; add one here when `build.zig` starts to scan another protocol.
