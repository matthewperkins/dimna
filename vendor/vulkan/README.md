# Vulkan registry

`vk.xml`, the Vulkan API registry that vulkan-zig generates dimna's Vulkan bindings from
(`build.zig`). Vendored so a build does not need the vulkan-headers package, which has a
different name and install path on Debian-family systems.

Copied unmodified from an Arch Linux system, 2026-11-14: **vulkan-headers 1:1.4.363.0**,
`/usr/share/vulkan/registry/vk.xml` (https://github.com/KhronosGroup/Vulkan-Headers).

| file | sha256 |
|---|---|
| `vk.xml` | `55ec60950cfb18c3575dcf5fd52741b2bb70eb1e466408f803a91049973ee6fb` |

Licence: `Apache-2.0 OR MIT` (SPDX line in the file's header; Copyright The Khronos Group Inc.).
`zig build -Dvk-registry=<path>` uses another `vk.xml` instead.
