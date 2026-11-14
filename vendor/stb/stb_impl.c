// The implementations of the two stb headers, compiled into the GUI only. dimna reads
// the colour-scheme image (JPEG or PNG, from memory: Zig reads the file) and writes the
// swatch PNG (to a callback). Nothing else of stb is compiled in.
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STBI_WRITE_NO_STDIO
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
