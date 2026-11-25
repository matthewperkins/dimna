# FreeType

FreeType 2.14.3, for dimna on macOS only: `build.zig` (`addMacGui`) compiles it and links it
statically, so that a Mac needs no FreeType installed (no Homebrew) and an app has no
library to carry. Linux uses the distribution's FreeType.

Source: `freetype-2.14.3.tar.xz`, sha256
`36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f`, the same file from
https://download.savannah.gnu.org/releases/freetype/ and from SourceForge
(project `freetype`, `freetype2/2.14.3/`), fetched 2026-11-24. 2.14.3 is the version dimna
had been running with from Homebrew until then.

Copied unmodified from it:

- `include/` (all of it);
- `src/base`, `src/sfnt`, `src/truetype`, `src/cff`, `src/psaux`, `src/psnames`,
  `src/pshinter`, `src/autofit`, `src/smooth`, `src/raster`, `src/gzip` (its own zlib, for
  WOFF and the gzip stream, which `sfnt` refers to), without their make and build-system
  files (`*.mk`, `Jamfile`, `meson.build`, `CMakeLists.txt`, `*.py`, `*.sh`);
- `LICENSE.TXT`, `FTL.TXT` and `GPLv2.TXT` (from `docs/`).

Not copied: every other module (Type 1, CID, PFR, Type 42, Windows FNT, PCF, BDF, the cache,
the signed-distance-field and OT-SVG renderers, LZW, bzip2, the validators), `builds/`,
`docs/`, `tests/`, `devel/`. So dimna on macOS opens TrueType and OpenType fonts and
collections (what macOS installs), and not the older formats those modules read.

dimna's own file: `dimna/dimna_ftmodule.h`, the list of modules compiled in, given to
FreeType as `FT_CONFIG_MODULES_H`. `include/freetype/config/ftoption.h` is upstream's
default: no PNG (so no colour bitmap glyphs), no HarfBuzz, no Brotli (no WOFF2), no bzip2.

To check the copy against the tarball: the sha256 of the list `shasum -a 256` prints for
every file here but this README and `dimna/`, sorted by path (`LC_ALL=C sort`), is
`cbfcd6b8a47a95c1491efb0f17ed9883471a5e7915e5f3b65025df14d352d515`:

    cd vendor/freetype && find . -type f -not -name README.md -not -path "./dimna/*" |
        LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256

Licence: FreeType is offered under the FreeType License (`FTL.TXT`) or the GNU GPL version
2 or later (`GPLv2.TXT`); see `LICENSE.TXT`. Portions of dimna on macOS are copyright
The FreeType Project (www.freetype.org). All rights reserved.
