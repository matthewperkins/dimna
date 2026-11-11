// C API seen by Zig (translated by the build, see build.zig).
#include "oni.h"
#include <time.h> // localtime_r, for recording names and timestamps in local time

// Patch carried in vendor/liboni/onidriverloader.c: a directory tried before the default
// dlopen() search path when loading libonidriver_<name>.so.
void oni_set_driver_search_dir(const char *dir);

// oEZ patch in the same file: a driver compiled into the program, selected by name.
#include "onidriverloader.h"
void oni_register_builtin_driver(const char *name, const oni_driver_t *functions);
