// C libraries used by the GUI on macOS only (translated by the build; Linux's is c.h).
// FreeType alone: Core Text and Core Audio are declared in the Zig files that call them
// (fontfind_coretext.zig, audio_coreaudio.zig), as their headers translate to some 14,000
// to 17,000 declarations each.
#include <ft2build.h>
#include FT_FREETYPE_H
