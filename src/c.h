// C API seen by Zig (translated by the build, see build.zig).
#include "oni.h"
#include <time.h> // localtime_r, for recording names and timestamps in local time
#ifdef _WIN32
// Windows' C library has the same function under another name, with the arguments swapped.
static inline struct tm *localtime_r(const time_t *t, struct tm *out) { __time64_t t64 = *t; return _localtime64_s(out, &t64) == 0 ? out : 0; }
// Its struct tm has no tm_gmtoff: local time's offset from UTC in seconds at time `t`,
// whose local time is `local`, is that local time read as if it were UTC, less `t`.
static inline long long dimna_utc_offset_s(const struct tm *local, time_t t) { struct tm copy = *local; return (long long)_mkgmtime64(&copy) - (long long)t; }
#endif

// Patch carried in vendor/liboni/onidriverloader.c: a directory tried before the default
// dlopen() search path when loading libonidriver_<name>.so.
void oni_set_driver_search_dir(const char *dir);

// dimna patch in the same file: a driver compiled into the program, selected by name.
#include "onidriverloader.h"
void oni_register_builtin_driver(const char *name, const oni_driver_t *functions);
