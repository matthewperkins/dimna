# stb

Two single-file libraries by Sean Barrett (public domain / MIT, see `LICENSE`):

| file | version | sha256 |
|---|---|---|
| `stb_image.h` | 2.32 | `deb4f18c9ca21b751a1323019031c94c0bf5ca1d2929ef5913cc56f00aab6e91` |
| `stb_image_write.h` | 1.18 | `a8e7f77f0ccfdc9bac09a71268b131931ff81aafca82c393aeb6aaba10d9e7ca` |

Source: https://github.com/nothings/stb, commit `9600522de53973336fa033a289858a4354cbb04c`
(2026-11-12), copied unmodified from the owner's clone of it (`~/src/stb`).

dimna uses them only to read the colour-scheme image (`scheme_image` in the config; JPEG
and PNG, decoded from memory) and to write the swatch PNG of `dimna --print-scheme`.
`stb_impl.c` holds the implementations (JPEG and PNG only, no file I/O); `stb.h` is what
the build translates for Zig. `LICENSE` is the notice at the end of `stb_image.h`.
