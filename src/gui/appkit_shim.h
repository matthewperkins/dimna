// The C interface of appkit_shim.m: what window_appkit.zig calls to have AppKit make,
// show and destroy windows, and what the shim calls back with. No Objective-C type crosses
// it: windows and layers are opaque pointers. Translated for Zig by the build (`appkit_c`).
//
// Threads: every function may be called from any thread unless it says otherwise; the
// shim does AppKit's part on the main thread. The callbacks run on the main thread
// (`event`) or on a thread of the system's (`presented`), never on the window's own.

#ifndef DIMNA_APPKIT_SHIM_H
#define DIMNA_APPKIT_SHIM_H

#include <stddef.h>
#include <stdint.h>

// ---- the application's loop (window.run) ----

// On the main thread: makes the application (once) and marks the loop as about to run, so
// that windows asked for from other threads from now on are made by it.
void dimna_aw_loop_begin(void);
// On the main thread: runs the application's loop until `dimna_aw_loop_stop`.
void dimna_aw_loop_run(void);
// From any thread: ends `dimna_aw_loop_run` (at once if it is not running yet: the next
// `dimna_aw_loop_run` returns at once). Windows asked for after this fail.
void dimna_aw_loop_stop(void);
// 1 on the process's main thread.
int dimna_aw_is_main_thread(void);
// The time `CAMetalLayer` drawables report presentation in (`CACurrentMediaTime`), s.
double dimna_aw_media_time(void);

// ---- events, from the shim to the window ----

enum {
    DIMNA_AW_KEY_DOWN = 1, // code: virtual key code; unmod: the key's character in the
                           // layout without modifiers (UTF-32, 0 if none); text: what it typed
    DIMNA_AW_MODIFIERS,    // mods only
    DIMNA_AW_BUTTON_DOWN,  // code: 0 left, 1 right, 2 middle (NSEvent.buttonNumber)
    DIMNA_AW_BUTTON_UP,
    DIMNA_AW_MOTION,       // x, y: in the view, points, origin bottom left
    DIMNA_AW_ENTER,        // x, y as for motion
    DIMNA_AW_LEAVE,
    DIMNA_AW_SCROLL,       // x, y: NSEvent.scrollingDeltaX/Y; flags: DIMNA_AW_PRECISE
    DIMNA_AW_MAGNIFY,      // x: NSEvent.magnification
    DIMNA_AW_SIZE,         // x, y: the view's size in backing pixels; scale
    DIMNA_AW_CLOSE,        // the close button, or Quit
    DIMNA_AW_FRAME,        // the display link's refresh
};

// Modifier bits (`mods`).
enum { DIMNA_AW_SHIFT = 1, DIMNA_AW_CTRL = 2, DIMNA_AW_ALT = 4, DIMNA_AW_CMD = 8 };
// Flag bits (`flags`).
enum { DIMNA_AW_REPEAT = 1, DIMNA_AW_PRECISE = 2, DIMNA_AW_MOMENTUM = 4 };

typedef struct {
    uint32_t kind;
    uint32_t mods;
    uint32_t flags;
    uint32_t code;
    uint32_t unmod;
    uint32_t text_len;
    double x, y;
    // The view's height in points and its backing scale, for motion and enter (to turn
    // points with y up into pixels with y down), and for size.
    double height_pt, scale;
    // NSEvent.timestamp (s, on the clock of `dimna_aw_media_time`); 0 for size, close, frame.
    double time;
    char text[32];
} DimnaAwEvent;

typedef struct {
    // On the main thread, for each event of the window.
    void (*event)(void *ctx, const DimnaAwEvent *event);
    // On a thread of the system's: a frame given to `dimna_aw_add_presented` reached the
    // screen at `time` (s, `dimna_aw_media_time`'s clock; 0: it never did), on a screen
    // refreshing every `refresh_ns`.
    void (*presented)(void *ctx, uint64_t tag, double time, uint32_t refresh_ns);
} DimnaAwCallbacks;

// ---- windows ----

typedef struct DimnaAwWindow DimnaAwWindow;

#define DIMNA_AW_MAX_SCREENS 8
#define DIMNA_AW_NAME_LEN 64

// What `dimna_aw_create` reports of the window and the screens, at the time it was made.
typedef struct {
    uint32_t width_px, height_px;
    double scale;
    uint32_t num_screens;
    // The screens' names as macOS shows them (NSScreen.localizedName), UTF-8, cut to fit.
    char screen_names[DIMNA_AW_MAX_SCREENS][DIMNA_AW_NAME_LEN];
} DimnaAwInfo;

enum {
    DIMNA_AW_OK = 0,
    // Not on the main thread, and no loop running to make the window (window.run is not
    // running): nothing was made.
    DIMNA_AW_NO_LOOP = 1,
    DIMNA_AW_FAILED = 2,
};

// Makes a window with a view backed by a CAMetalLayer, shows it, and brings it forward.
// `ctx` is passed to the callbacks until `dimna_aw_destroy`. Waits for the main thread
// when called from another.
int dimna_aw_create(const char *title, void *ctx, DimnaAwCallbacks callbacks, DimnaAwInfo *info,
                    DimnaAwWindow **out);
// Stops the callbacks (also a presentation report still on its way), closes and frees the
// window. Waits for the main thread when called from another.
void dimna_aw_destroy(DimnaAwWindow *w);
// The window's CAMetalLayer (not retained for the caller; valid until destroy).
void *dimna_aw_layer(DimnaAwWindow *w);
void dimna_aw_set_title(DimnaAwWindow *w, const char *title);
// 0 the arrow, 1 the open hand, 2 the closed hand.
void dimna_aw_set_cursor(DimnaAwWindow *w, int cursor);
// The window covers screen `name` (case ignored), borderless, above the menu bar, with the
// menu bar and the Dock hidden while dimna is the active application. 0: no such screen.
int dimna_aw_fullscreen(DimnaAwWindow *w, const char *name);
// The part of the top edge the fullscreen window's screen does not show (a laptop's camera
// housing): `cut` gets its left edge, right edge and depth in pixels of the window. 0: the
// window is not fullscreen, or its screen has none.
int dimna_aw_top_cut(DimnaAwWindow *w, double cut[3]);
// The application's picture in the Dock and the application switcher, from an image
// file's bytes (PNG). Any thread; the first call counts.
void dimna_aw_set_icon(const void *bytes, size_t len);
// The display link asks for one refresh (`DIMNA_AW_FRAME`) after this call. Any thread.
void dimna_aw_want_frame(DimnaAwWindow *w);
// On the thread drawing: asks `drawable` (an id<CAMetalDrawable>) to report when it
// reaches the screen, through the `presented` callback with `tag`.
void dimna_aw_add_presented(DimnaAwWindow *w, void *drawable, uint64_t tag);
// On the main thread when no loop is running: handles the application's events for up to
// `timeout_s` (the first one waited for, the rest taken as they are).
void dimna_aw_pump_main(double timeout_s);

// ---- for the tests only (compiled with DIMNA_APPKIT_TEST) ----

enum {
    DIMNA_AW_T_KEY_DOWN = 1, // code, chars (with modifiers), mods, repeat
    DIMNA_AW_T_KEY_UP,
    DIMNA_AW_T_FLAGS,        // mods
    DIMNA_AW_T_MOUSE_DOWN,   // button (0 left, 1 right, 2 middle), x, y (points, y up)
    DIMNA_AW_T_MOUSE_UP,
    DIMNA_AW_T_MOVE,         // x, y
    DIMNA_AW_T_ENTER,        // x, y
    DIMNA_AW_T_EXIT,
    DIMNA_AW_T_WHEEL,        // x, y: lines (a mouse wheel's clicks)
    DIMNA_AW_T_PIXELS,       // x, y: pixels (a trackpad's)
    DIMNA_AW_T_MAGNIFY,      // x: magnification
    DIMNA_AW_T_CMD_Q,        // Cmd-Q through the menu
    DIMNA_AW_T_CLOSE_BUTTON, // the close button
};
// Builds the NSEvent on the main thread and hands it to the window's view (or the menu),
// as AppKit would, in this process only: nothing is posted to the system. Waits for it
// unless `async` (then it returns at once and the main thread does it next).
void dimna_aw_test_deliver(DimnaAwWindow *w, int what, int code, const char *chars, uint32_t mods,
                           int repeat, int button, double x, double y, int async);
// The same `count` times in one go on the main thread (motion with x = i, y fixed).
void dimna_aw_test_burst(DimnaAwWindow *w, int count, double y);
// Windows of this process on screen, and window objects of the shim not yet freed.
int dimna_aw_test_visible_windows(void);
int dimna_aw_test_live_windows(void);
// Whether dimna is the active application and the window is (at least partly) visible;
// `on_top`: first raise the window above other applications' windows.
void dimna_aw_test_state(DimnaAwWindow *w, int *active, int *visible, int on_top);
// The view's size in points.
void dimna_aw_test_view_points(DimnaAwWindow *w, double *width, double *height);
// A stand-in for the renderer: the layer's next drawable (retained, or NULL), cleared to
// a colour and presented by `dimna_aw_test_present` (which releases it).
void *dimna_aw_test_next_drawable(DimnaAwWindow *w, int sync);
void dimna_aw_test_present(void *drawable, float red);

#endif
