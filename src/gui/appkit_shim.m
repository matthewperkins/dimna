// AppKit for window_appkit.zig: the application, its windows, their CAMetalLayer views,
// the events, the display link and the presentation reports. The C interface and what may
// call what from which thread are in appkit_shim.h. Compiled with ARC.
//
// Everything of AppKit's here runs on the main thread. A call from another thread does its
// AppKit part there: `dispatch_sync` to the main queue where the caller must wait for the
// result (making, destroying, fullscreen), `dispatch_async` where it need not (title,
// cursor). The main thread never waits for another thread of dimna's: events go out
// through the `event` callback, which only merges them into the window's mailbox
// (window_appkit.zig), and the display link only sets a flag through the same callback.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <os/lock.h>
#import <stdatomic.h>
#include "appkit_shim.h"

// 1 from `dimna_aw_loop_begin` until `dimna_aw_loop_stop`: a window asked for from another
// thread is made by the loop.
static atomic_int loop_accepting;
// Window objects not yet freed (for the tests).
static atomic_int live_windows;

@class DimnaWindowObj;

// ---------------------------------------------------------------- the window's parts

// Borderless windows (fullscreen) cannot become key unless they say so: without this the
// fullscreen display would get no keys.
@interface DimnaNSWindow : NSWindow
@end
@implementation DimnaNSWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface DimnaView : NSView
@property(weak) DimnaWindowObj *owner;
@property(strong) NSCursor *cursor;
@end

@interface DimnaWindowObj : NSObject <NSWindowDelegate> {
  @public
    // The window's own context, for `event` (main thread only).
    void *event_ctx;
    // The same, for `presented` (any thread, under `presented_lock`).
    void *presented_ctx;
    os_unfair_lock presented_lock;
    DimnaAwCallbacks callbacks;
    atomic_uint refresh_ns;
    atomic_int want_frame;
}
@property(strong) DimnaNSWindow *window;
@property(strong) DimnaView *view;
@property(strong) CAMetalLayer *layer;
@property(strong) CADisplayLink *link;
@property BOOL fullscreen;
@property double cutX0, cutX1, cutBottom;
- (void)post:(DimnaAwEvent *)ev;
@end

// The windows made and not yet destroyed (main thread only), for Quit.
static NSMutableArray<DimnaWindowObj *> *windows;

static uint32_t modsOf(NSEventModifierFlags f) {
    uint32_t m = 0;
    if (f & NSEventModifierFlagShift) m |= DIMNA_AW_SHIFT;
    if (f & NSEventModifierFlagControl) m |= DIMNA_AW_CTRL;
    if (f & NSEventModifierFlagOption) m |= DIMNA_AW_ALT;
    if (f & NSEventModifierFlagCommand) m |= DIMNA_AW_CMD;
    return m;
}

// The refresh period of the screen, from its display mode (or its highest rate).
static uint32_t refreshOf(NSScreen *screen) {
    if (!screen) return 0;
    double hz = 0;
    CGDirectDisplayID did = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
    if (mode) {
        hz = CGDisplayModeGetRefreshRate(mode);
        CGDisplayModeRelease(mode);
    }
    if (hz <= 0) hz = (double)screen.maximumFramesPerSecond;
    return hz > 0 ? (uint32_t)(1e9 / hz + 0.5) : 0;
}

@implementation DimnaView

- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)wantsUpdateLayer { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)isOpaque { return YES; }

- (void)postKind:(uint32_t)kind event:(NSEvent *)e {
    DimnaAwEvent ev = {0};
    ev.kind = kind;
    ev.mods = modsOf(e.modifierFlags);
    ev.time = e.timestamp;
    [self.owner post:&ev];
}

- (void)postPointer:(uint32_t)kind event:(NSEvent *)e code:(uint32_t)code {
    DimnaAwEvent ev = {0};
    ev.kind = kind;
    ev.code = code;
    ev.mods = modsOf(e.modifierFlags);
    ev.time = e.timestamp;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    ev.x = p.x;
    ev.y = p.y;
    ev.height_pt = self.bounds.size.height;
    ev.scale = self.window ? self.window.backingScaleFactor : 1;
    [self.owner post:&ev];
}

// ---- keys

- (void)keyDown:(NSEvent *)e {
    DimnaAwEvent ev = {0};
    ev.kind = DIMNA_AW_KEY_DOWN;
    ev.mods = modsOf(e.modifierFlags);
    ev.flags = e.isARepeat ? DIMNA_AW_REPEAT : 0;
    ev.code = e.keyCode;
    ev.time = e.timestamp;
    // The key's character in the current layout with no modifier held.
    NSString *plain = [e charactersByApplyingModifiers:0];
    if (plain.length > 0) {
        uint32_t cp = 0;
        NSUInteger used = 0;
        [plain getBytes:&cp maxLength:4 usedLength:&used encoding:NSUTF32LittleEndianStringEncoding
                options:0 range:NSMakeRange(0, plain.length) remainingRange:NULL];
        ev.unmod = used == 4 ? cp : 0;
    }
    // What it typed (a dead key types nothing here; see window_appkit.zig).
    NSString *typed = e.characters;
    if (typed.length > 0) {
        const char *utf8 = typed.UTF8String;
        size_t n = utf8 ? strlen(utf8) : 0;
        if (n < sizeof ev.text) {
            memcpy(ev.text, utf8, n);
            ev.text_len = (uint32_t)n;
        }
    }
    [self.owner post:&ev];
}
// Taken here so that no key goes on to the responder chain's end, which beeps.
- (void)keyUp:(NSEvent *)e { (void)e; }
- (void)flagsChanged:(NSEvent *)e { [self postKind:DIMNA_AW_MODIFIERS event:e]; }

// ---- buttons and motion

- (void)mouseDown:(NSEvent *)e { [self postPointer:DIMNA_AW_BUTTON_DOWN event:e code:0]; }
- (void)mouseUp:(NSEvent *)e { [self postPointer:DIMNA_AW_BUTTON_UP event:e code:0]; }
- (void)rightMouseDown:(NSEvent *)e { [self postPointer:DIMNA_AW_BUTTON_DOWN event:e code:1]; }
- (void)rightMouseUp:(NSEvent *)e { [self postPointer:DIMNA_AW_BUTTON_UP event:e code:1]; }
- (void)otherMouseDown:(NSEvent *)e {
    [self postPointer:DIMNA_AW_BUTTON_DOWN event:e code:(uint32_t)e.buttonNumber];
}
- (void)otherMouseUp:(NSEvent *)e {
    [self postPointer:DIMNA_AW_BUTTON_UP event:e code:(uint32_t)e.buttonNumber];
}
- (void)mouseMoved:(NSEvent *)e { [self postPointer:DIMNA_AW_MOTION event:e code:0]; }
- (void)mouseDragged:(NSEvent *)e { [self postPointer:DIMNA_AW_MOTION event:e code:0]; }
- (void)rightMouseDragged:(NSEvent *)e { [self postPointer:DIMNA_AW_MOTION event:e code:0]; }
- (void)otherMouseDragged:(NSEvent *)e { [self postPointer:DIMNA_AW_MOTION event:e code:0]; }
- (void)mouseEntered:(NSEvent *)e { [self postPointer:DIMNA_AW_ENTER event:e code:0]; }
- (void)mouseExited:(NSEvent *)e { [self postKind:DIMNA_AW_LEAVE event:e]; }

- (void)scrollWheel:(NSEvent *)e {
    DimnaAwEvent ev = {0};
    ev.kind = DIMNA_AW_SCROLL;
    ev.mods = modsOf(e.modifierFlags);
    ev.time = e.timestamp;
    ev.x = e.scrollingDeltaX;
    ev.y = e.scrollingDeltaY;
    if (e.hasPreciseScrollingDeltas) ev.flags |= DIMNA_AW_PRECISE;
    if (e.momentumPhase != NSEventPhaseNone) ev.flags |= DIMNA_AW_MOMENTUM;
    [self.owner post:&ev];
}

- (void)magnifyWithEvent:(NSEvent *)e {
    DimnaAwEvent ev = {0};
    ev.kind = DIMNA_AW_MAGNIFY;
    ev.mods = modsOf(e.modifierFlags);
    ev.time = e.timestamp;
    ev.x = e.magnification;
    [self.owner post:&ev];
}

// ---- size, scale, cursor

- (void)postSize {
    DimnaAwEvent ev = {0};
    ev.kind = DIMNA_AW_SIZE;
    ev.x = self.bounds.size.width;
    ev.y = self.bounds.size.height;
    ev.scale = self.window ? self.window.backingScaleFactor : 1;
    [self.owner post:&ev];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self postSize];
}

// The window moved to a screen of another scale (or the screen's scale changed).
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    if (self.window) self.layer.contentsScale = self.window.backingScaleFactor;
    [self postSize];
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:self.cursor ? self.cursor : NSCursor.arrowCursor];
}

@end

@implementation DimnaWindowObj

- (void)post:(DimnaAwEvent *)ev {
    if (event_ctx) callbacks.event(event_ctx, ev);
}

// The display link, on the main thread at each refresh of the window's screen: one
// FRAME if a frame was presented since the last.
- (void)tick:(CADisplayLink *)link {
    (void)link;
    if (atomic_exchange(&want_frame, 0)) {
        DimnaAwEvent ev = {0};
        ev.kind = DIMNA_AW_FRAME;
        [self post:&ev];
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    DimnaAwEvent ev = {0};
    ev.kind = DIMNA_AW_CLOSE;
    [self post:&ev];
    // The window stays until dimna destroys it, as on Wayland.
    return NO;
}

- (void)windowDidChangeScreen:(NSNotification *)n {
    (void)n;
    atomic_store(&refresh_ns, refreshOf(self.window.screen));
}

- (void)dealloc { atomic_fetch_sub(&live_windows, 1); }

@end

// ---------------------------------------------------------------- the application

@interface DimnaAppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation DimnaAppDelegate
// Quit (Cmd-Q) and any other request to end the application close the windows as their
// close buttons do: dimna ends its loops itself.
- (void)closeAll:(id)sender {
    (void)sender;
    for (DimnaWindowObj *o in [windows copy]) {
        DimnaAwEvent ev = {0};
        ev.kind = DIMNA_AW_CLOSE;
        [o post:&ev];
    }
}
// The fullscreen display sits above the menu bar's level, which is above every other
// application's windows too. While dimna is not the active application it steps down to
// the ordinary level, so that Cmd-Tab shows the application switched to; and back up when
// dimna is active again.
- (void)applicationDidResignActive:(NSNotification *)note {
    (void)note;
    for (DimnaWindowObj *o in windows)
        if (o.fullscreen) o.window.level = NSNormalWindowLevel;
}
- (void)applicationDidBecomeActive:(NSNotification *)note {
    (void)note;
    for (DimnaWindowObj *o in windows)
        if (o.fullscreen) o.window.level = NSMainMenuWindowLevel + 1;
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    (void)app;
    [self closeAll:nil];
    return NSTerminateCancel;
}
@end

static DimnaAppDelegate *app_delegate;

// On the main thread: the application, its delegate and its menu, once.
static void ensureApp(void) {
    if (app_delegate) return;
    windows = [NSMutableArray array];
    [NSApplication sharedApplication];
    app_delegate = [DimnaAppDelegate new];
    NSApp.delegate = app_delegate;
    NSMenu *bar = [NSMenu new];
    NSMenuItem *app_item = [NSMenuItem new];
    [bar addItem:app_item];
    NSMenu *app_menu = [NSMenu new];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit dimna" action:@selector(closeAll:)
                                           keyEquivalent:@"q"];
    quit.target = app_delegate;
    // Hide (Cmd-H) and Minimize (Cmd-M) go to AppKit's own actions.
    [app_menu addItem:[[NSMenuItem alloc] initWithTitle:@"Hide dimna" action:@selector(hide:) keyEquivalent:@"h"]];
    [app_menu addItem:[[NSMenuItem alloc] initWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"]];
    [app_menu addItem:[NSMenuItem separatorItem]];
    [app_menu addItem:quit];
    app_item.submenu = app_menu;
    NSApp.mainMenu = bar;
}

int dimna_aw_is_main_thread(void) { return [NSThread isMainThread] ? 1 : 0; }
double dimna_aw_media_time(void) { return CACurrentMediaTime(); }

void dimna_aw_loop_begin(void) {
    @autoreleasepool {
        ensureApp();
    }
    atomic_store(&loop_accepting, 1);
}

void dimna_aw_loop_run(void) {
    @autoreleasepool {
        [NSApp run];
    }
}

void dimna_aw_loop_stop(void) {
    atomic_store(&loop_accepting, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSApp stop:nil];
      // `stop` takes effect after the next event; this is it (in this process only).
      NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                                    modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                          subtype:0 data1:0 data2:0];
      [NSApp postEvent:wake atStart:YES];
    });
}

void dimna_aw_pump_main(double timeout_s) {
    @autoreleasepool {
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout_s > 0 ? timeout_s : 0];
        for (;;) {
            NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until
                                               inMode:NSDefaultRunLoopMode dequeue:YES];
            if (!e) break;
            [NSApp sendEvent:e];
            until = [NSDate distantPast];
        }
    }
}

// Runs `work` on the main thread and waits for it; 0 (and nothing done) when that is not
// possible: not on the main thread and no loop running.
static int onMain(void (^work)(void)) {
    if ([NSThread isMainThread]) {
        @autoreleasepool {
            work();
        }
        return 1;
    }
    if (!atomic_load(&loop_accepting)) return 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
      @autoreleasepool {
          work();
      }
    });
    return 1;
}

static void copyName(char *dst, NSString *s) {
    const char *utf8 = s.UTF8String ? s.UTF8String : "";
    size_t n = strlen(utf8);
    if (n >= DIMNA_AW_NAME_LEN) {
        // Cut at a character's start.
        n = DIMNA_AW_NAME_LEN - 1;
        while (n > 0 && ((unsigned char)utf8[n] & 0xc0) == 0x80) n--;
    }
    memcpy(dst, utf8, n);
    dst[n] = 0;
}

static void fillInfo(DimnaWindowObj *o, DimnaAwInfo *info) {
    double scale = o.window.backingScaleFactor;
    NSSize pt = o.view.bounds.size;
    info->width_px = (uint32_t)(pt.width * scale + 0.5);
    info->height_px = (uint32_t)(pt.height * scale + 0.5);
    info->scale = scale;
    NSArray<NSScreen *> *screens = NSScreen.screens;
    uint32_t n = 0;
    for (NSScreen *s in screens) {
        if (n == DIMNA_AW_MAX_SCREENS) break;
        copyName(info->screen_names[n], s.localizedName);
        n++;
    }
    info->num_screens = n;
}

static DimnaWindowObj *makeWindow(NSString *title, void *ctx, DimnaAwCallbacks cb) {
    ensureApp();
    // A plain executable starts with no Dock icon and cannot take the keyboard; a regular
    // application can.
    if (NSApp.activationPolicy != NSApplicationActivationPolicyRegular)
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    DimnaWindowObj *o = [DimnaWindowObj new];
    atomic_fetch_add(&live_windows, 1);
    o->event_ctx = ctx;
    o->presented_ctx = ctx;
    o->presented_lock = OS_UNFAIR_LOCK_INIT;
    o->callbacks = cb;

    // 1280 x 800 points, or less to fit the screen.
    NSScreen *screen = NSScreen.mainScreen;
    NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1280, 800);
    CGFloat w = MIN(1280, visible.size.width * 0.9), h = MIN(800, visible.size.height * 0.9);
    NSRect rect = NSMakeRect(0, 0, w, h);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    DimnaNSWindow *win = [[DimnaNSWindow alloc] initWithContentRect:rect styleMask:style
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO];
    win.releasedWhenClosed = NO;
    // Nothing of the window is saved for the next start (no file under the home folder).
    win.restorable = NO;
    win.title = title;
    win.delegate = o;
    win.backgroundColor = NSColor.blackColor;
    win.opaque = YES;

    DimnaView *view = [[DimnaView alloc] initWithFrame:rect];
    view.owner = o;
    view.wantsLayer = YES;
    CAMetalLayer *layer = (CAMetalLayer *)view.layer;
    layer.opaque = YES;
    layer.contentsScale = win.backingScaleFactor;
    win.contentView = view;
    [win makeFirstResponder:view];
    [view addTrackingArea:[[NSTrackingArea alloc]
                              initWithRect:NSZeroRect
                                   options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                                           NSTrackingActiveAlways | NSTrackingInVisibleRect
                                     owner:view
                                  userInfo:nil]];
    o.window = win;
    o.view = view;
    o.layer = layer;

    // The process's first three windows (the display, then the control window and the
    // tiles, in either order) side by side, none over another: the display on the left
    // with most of the screen, the other two above each other on the right. (A window
    // under another one is shown through the window server's queue: free-running, the
    // display measured 45 ms behind another application's window against 6 in front.)
    // Any further window a little lower and to the right of the last.
    if (windows.count < 3 && screen) {
        CGFloat split = floor(visible.size.width * 0.62), half = floor(visible.size.height / 2);
        NSRect frame = windows.count == 0
            ? NSMakeRect(visible.origin.x, visible.origin.y, split, visible.size.height)
            : NSMakeRect(visible.origin.x + split, visible.origin.y + (windows.count == 1 ? half : 0),
                         visible.size.width - split, windows.count == 1 ? visible.size.height - half : half);
        [win setFrame:frame display:NO];
    } else {
        [win center];
        NSPoint at = win.frame.origin;
        CGFloat step = 24 * (CGFloat)(windows.count % 8);
        [win setFrameOrigin:NSMakePoint(at.x + step, at.y - step)];
    }
    [windows addObject:o];

    [win makeKeyAndOrderFront:nil];
    [NSApp activate];
    // Started from a terminal, activation alone can leave the window behind the terminal's
    // (macOS lets the front application keep its place), and a covered window is slow (see
    // the placement above). The user started dimna, so its window comes to the front.
    [win orderFrontRegardless];
    atomic_store(&o->refresh_ns, refreshOf(win.screen ? win.screen : screen));

    // At each refresh of the screen the view is on, on the main thread.
    o.link = [view displayLinkWithTarget:o selector:@selector(tick:)];
    [o.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    // Already under the pointer: say so, as Wayland's enter does.
    NSPoint mouse = [view convertPoint:[win mouseLocationOutsideOfEventStream] fromView:nil];
    if (NSPointInRect(mouse, view.bounds)) {
        DimnaAwEvent ev = {0};
        ev.kind = DIMNA_AW_ENTER;
        ev.x = mouse.x;
        ev.y = mouse.y;
        ev.height_pt = view.bounds.size.height;
        ev.scale = win.backingScaleFactor;
        [o post:&ev];
    }
    return o;
}

int dimna_aw_create(const char *title, void *ctx, DimnaAwCallbacks callbacks, DimnaAwInfo *info,
                    DimnaAwWindow **out) {
    __block DimnaWindowObj *made = nil;
    NSString *t = [NSString stringWithUTF8String:title ? title : ""];
    if (!t) t = @"dimna";
    if (!onMain(^{
          made = makeWindow(t, ctx, callbacks);
          if (made) fillInfo(made, info);
        }))
        return DIMNA_AW_NO_LOOP;
    if (!made) return DIMNA_AW_FAILED;
    *out = (__bridge_retained DimnaAwWindow *)made;
    return DIMNA_AW_OK;
}

void dimna_aw_destroy(DimnaAwWindow *w) {
    if (!w) return;
    DimnaWindowObj *o = (__bridge_transfer DimnaWindowObj *)w;
    // No presentation report reaches the window after this (one under way is waited for).
    os_unfair_lock_lock(&o->presented_lock);
    o->presented_ctx = NULL;
    os_unfair_lock_unlock(&o->presented_lock);
    void (^work)(void) = ^{
      o->event_ctx = NULL;
      [o.link invalidate];
      o.link = nil;
      [windows removeObject:o];
      if (o.fullscreen) {
          BOOL other = NO;
          for (DimnaWindowObj *x in windows) other = other || x.fullscreen;
          if (!other) NSApp.presentationOptions = NSApplicationPresentationDefault;
      }
      o.window.delegate = nil;
      [o.window orderOut:nil];
      [o.window close];
      o.view.owner = nil;
      o.window = nil;
      o.view = nil;
      o.layer = nil;
    };
    if (!onMain(work)) {
        // No loop to do it now (the loop ended first): no more events either; the main
        // thread does it the next time it runs one.
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

void *dimna_aw_layer(DimnaAwWindow *w) {
    DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
    return (__bridge void *)o.layer;
}

void dimna_aw_set_title(DimnaAwWindow *w, const char *title) {
    DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
    NSString *t = [NSString stringWithUTF8String:title ? title : ""];
    if (!t) return;
    dispatch_block_t work = ^{
      o.window.title = t;
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

void dimna_aw_set_cursor(DimnaAwWindow *w, int cursor) {
    DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
    dispatch_block_t work = ^{
      NSCursor *c = cursor == 1   ? NSCursor.openHandCursor
                    : cursor == 2 ? NSCursor.closedHandCursor
                                  : NSCursor.arrowCursor;
      o.view.cursor = c;
      [o.window invalidateCursorRectsForView:o.view];
      NSPoint p = [o.view convertPoint:[o.window mouseLocationOutsideOfEventStream] fromView:nil];
      if (NSPointInRect(p, o.view.bounds)) [c set];
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

int dimna_aw_fullscreen(DimnaAwWindow *w, const char *name) {
    DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
    NSString *want = [NSString stringWithUTF8String:name ? name : ""];
    __block int found = 0;
    onMain(^{
      for (NSScreen *s in NSScreen.screens) {
          if ([s.localizedName caseInsensitiveCompare:want] != NSOrderedSame) continue;
          found = 1;
          // What the latency probe found quickest: a borderless window over the whole
          // screen, above the menu bar (tools/metal-latency, "--fullscreen").
          o.fullscreen = YES;
          // Borderless, but it can still be put in the Dock (Cmd-M).
          o.window.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskMiniaturizable;
          // The camera housing: the strip the menu bar would have had, between the two
          // areas of it that the screen does show.
          if (s.safeAreaInsets.top > 0) {
              double scale = s.backingScaleFactor;
              o.cutX0 = NSWidth(s.auxiliaryTopLeftArea) * scale;
              o.cutX1 = (NSWidth(s.frame) - NSWidth(s.auxiliaryTopRightArea)) * scale;
              o.cutBottom = s.safeAreaInsets.top * scale;
          }
          // A titled window keeps its shadow when it becomes borderless, and a window with
          // a shadow is composited: measured, a refresh more with sync on (48.8 ms against
          // 16.3) until the shadow is off.
          o.window.hasShadow = NO;
          o.window.opaque = YES;
          o.window.level = NSMainMenuWindowLevel + 1;
          [o.window setFrame:s.frame display:YES];
          NSApp.presentationOptions =
              NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
          [o.window makeKeyAndOrderFront:nil];
          [o.window makeFirstResponder:o.view];
          atomic_store(&o->refresh_ns, refreshOf(s));
          break;
      }
    });
    return found;
}

int dimna_aw_top_cut(DimnaAwWindow *w, double cut[3]) {
    DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
    if (!o.fullscreen || o.cutBottom <= 0 || o.cutX1 <= o.cutX0) return 0;
    cut[0] = o.cutX0;
    cut[1] = o.cutX1;
    cut[2] = o.cutBottom;
    return 1;
}

void dimna_aw_set_icon(const void *bytes, size_t len) {
    static atomic_int set;
    if (atomic_exchange(&set, 1)) return;
    NSData *data = [NSData dataWithBytes:bytes length:len];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSImage *image = [[NSImage alloc] initWithData:data];
      if (image) NSApp.applicationIconImage = image;
    });
}

void dimna_aw_want_frame(DimnaAwWindow *w) {
    DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
    atomic_store(&o->want_frame, 1);
}

void dimna_aw_add_presented(DimnaAwWindow *w, void *drawable, uint64_t tag) {
    @autoreleasepool {
        DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
        id<CAMetalDrawable> d = (__bridge id<CAMetalDrawable>)drawable;
        uint32_t refresh = atomic_load(&o->refresh_ns);
        [d addPresentedHandler:^(id<MTLDrawable> shown) {
          double t = shown.presentedTime;
          os_unfair_lock_lock(&o->presented_lock);
          if (o->presented_ctx) o->callbacks.presented(o->presented_ctx, tag, t, refresh);
          os_unfair_lock_unlock(&o->presented_lock);
        }];
    }
}

// ---------------------------------------------------------------- for the tests

#ifdef DIMNA_APPKIT_TEST

static void onMainWait(dispatch_block_t work, int async) {
    if ([NSThread isMainThread]) work();
    else if (async) dispatch_async(dispatch_get_main_queue(), work);
    else dispatch_sync(dispatch_get_main_queue(), work);
}

static NSEventModifierFlags flagsOf(uint32_t mods) {
    NSEventModifierFlags f = 0;
    if (mods & DIMNA_AW_SHIFT) f |= NSEventModifierFlagShift;
    if (mods & DIMNA_AW_CTRL) f |= NSEventModifierFlagControl;
    if (mods & DIMNA_AW_ALT) f |= NSEventModifierFlagOption;
    if (mods & DIMNA_AW_CMD) f |= NSEventModifierFlagCommand;
    return f;
}

static NSEvent *keyEvent(DimnaWindowObj *o, NSEventType type, int code, NSString *chars,
                         uint32_t mods, int repeat) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flagsOf(mods)
                           timestamp:CACurrentMediaTime() windowNumber:o.window.windowNumber
                             context:nil characters:chars charactersIgnoringModifiers:chars
                           isARepeat:repeat != 0 keyCode:(unsigned short)code];
}

static NSEvent *mouseEvent(DimnaWindowObj *o, NSEventType type, double x, double y, uint32_t mods) {
    return [NSEvent mouseEventWithType:type location:NSMakePoint(x, y) modifierFlags:flagsOf(mods)
                             timestamp:CACurrentMediaTime() windowNumber:o.window.windowNumber
                               context:nil eventNumber:0 clickCount:1 pressure:1];
}

static NSEvent *wheelEvent(CGScrollEventUnit unit, double x, double y) {
    CGEventRef cg = CGEventCreateScrollWheelEvent(NULL, unit, 2, (int32_t)y, (int32_t)x);
    NSEvent *e = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    return e;
}

// A magnify gesture's event: there is no constructor for one, so it is made from a
// gesture CGEvent (type 29) of subtype magnify (field 110 = 8) with its magnification in
// field 113. Made, never posted.
static NSEvent *magnifyEvent(double m) {
    CGEventRef cg = CGEventCreate(NULL);
    CGEventSetType(cg, 29);
    CGEventSetIntegerValueField(cg, 110, 8);
    CGEventSetDoubleValueField(cg, 113, m);
    NSEvent *e = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    return e;
}

static void deliver(DimnaWindowObj *o, int what, int code, NSString *chars, uint32_t mods,
                    int repeat, int button, double x, double y) {
    DimnaView *v = o.view;
    switch (what) {
    case DIMNA_AW_T_KEY_DOWN:
        // Through the window, as AppKit hands a key to the first responder.
        [o.window sendEvent:keyEvent(o, NSEventTypeKeyDown, code, chars, mods, repeat)];
        break;
    case DIMNA_AW_T_KEY_UP:
        [o.window sendEvent:keyEvent(o, NSEventTypeKeyUp, code, chars, mods, 0)];
        break;
    case DIMNA_AW_T_FLAGS:
        [v flagsChanged:[NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint
                                    modifierFlags:flagsOf(mods) timestamp:CACurrentMediaTime()
                                     windowNumber:o.window.windowNumber context:nil
                                       characters:@"" charactersIgnoringModifiers:@""
                                        isARepeat:NO keyCode:56]];
        break;
    case DIMNA_AW_T_MOUSE_DOWN:
    case DIMNA_AW_T_MOUSE_UP: {
        BOOL down = what == DIMNA_AW_T_MOUSE_DOWN;
        if (button == 0) {
            NSEvent *e = mouseEvent(o, down ? NSEventTypeLeftMouseDown : NSEventTypeLeftMouseUp, x, y, mods);
            if (down) [v mouseDown:e];
            else [v mouseUp:e];
        } else if (button == 1) {
            NSEvent *e = mouseEvent(o, down ? NSEventTypeRightMouseDown : NSEventTypeRightMouseUp, x, y, mods);
            if (down) [v rightMouseDown:e];
            else [v rightMouseUp:e];
        } else {
            // The middle button's number is set only by a CGEvent.
            CGEventRef cg = CGEventCreateMouseEvent(NULL, down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp,
                                                    CGPointZero, kCGMouseButtonCenter);
            NSEvent *e = [NSEvent eventWithCGEvent:cg];
            CFRelease(cg);
            if (down) [v otherMouseDown:e];
            else [v otherMouseUp:e];
        }
        break;
    }
    case DIMNA_AW_T_MOVE: [v mouseMoved:mouseEvent(o, NSEventTypeMouseMoved, x, y, mods)]; break;
    case DIMNA_AW_T_ENTER:
        [v mouseEntered:[NSEvent enterExitEventWithType:NSEventTypeMouseEntered location:NSMakePoint(x, y)
                                          modifierFlags:0 timestamp:CACurrentMediaTime()
                                           windowNumber:o.window.windowNumber context:nil
                                            eventNumber:0 trackingNumber:0 userData:NULL]];
        break;
    case DIMNA_AW_T_EXIT:
        [v mouseExited:[NSEvent enterExitEventWithType:NSEventTypeMouseExited location:NSMakePoint(x, y)
                                         modifierFlags:0 timestamp:CACurrentMediaTime()
                                          windowNumber:o.window.windowNumber context:nil
                                           eventNumber:0 trackingNumber:0 userData:NULL]];
        break;
    case DIMNA_AW_T_WHEEL: [v scrollWheel:wheelEvent(kCGScrollEventUnitLine, x, y)]; break;
    case DIMNA_AW_T_PIXELS: [v scrollWheel:wheelEvent(kCGScrollEventUnitPixel, x, y)]; break;
    case DIMNA_AW_T_MAGNIFY: [v magnifyWithEvent:magnifyEvent(x)]; break;
    case DIMNA_AW_T_CMD_Q:
        [NSApp.mainMenu performKeyEquivalent:keyEvent(o, NSEventTypeKeyDown, 12, @"q", DIMNA_AW_CMD, 0)];
        break;
    case DIMNA_AW_T_CLOSE_BUTTON: [[o.window standardWindowButton:NSWindowCloseButton] performClick:nil]; break;
    }
}

void dimna_aw_test_deliver(DimnaAwWindow *w, int what, int code, const char *chars, uint32_t mods,
                           int repeat, int button, double x, double y, int async) {
    DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
    NSString *s = [NSString stringWithUTF8String:chars ? chars : ""];
    onMainWait(^{
      @autoreleasepool {
          deliver(o, what, code, s, mods, repeat, button, x, y);
      }
    }, async);
}

void dimna_aw_test_burst(DimnaAwWindow *w, int count, double y) {
    DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
    onMainWait(^{
      for (int i = 0; i < count; i++) {
          @autoreleasepool {
              if (i % 100 == 50) deliver(o, DIMNA_AW_T_KEY_DOWN, 0, @"a", 0, 0, 0, 0, 0);
              else if (i % 25 == 10) deliver(o, DIMNA_AW_T_WHEEL, 0, nil, 0, 0, 0, 0, -1);
              else if (i % 25 == 20) deliver(o, DIMNA_AW_T_MOUSE_DOWN, 0, nil, 0, 0, 0, i, y);
              else if (i % 25 == 21) deliver(o, DIMNA_AW_T_MOUSE_UP, 0, nil, 0, 0, 0, i, y);
              else deliver(o, DIMNA_AW_T_MOVE, 0, nil, 0, 0, 0, i, y);
          }
      }
    }, 0);
}

int dimna_aw_test_visible_windows(void) {
    __block int n = 0;
    onMainWait(^{
      for (NSWindow *win in NSApp.windows) n += win.isVisible ? 1 : 0;
    }, 0);
    return n;
}

int dimna_aw_test_live_windows(void) { return atomic_load(&live_windows); }

void dimna_aw_test_view_points(DimnaAwWindow *w, double *width, double *height) {
    DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
    __block NSSize s;
    onMainWait(^{
      s = o.view.bounds.size;
    }, 0);
    *width = s.width;
    *height = s.height;
}

void dimna_aw_test_state(DimnaAwWindow *w, int *active, int *visible, int on_top) {
    DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
    __block int a = 0, v = 0;
    onMainWait(^{
      if (on_top) {
          // Above other applications' windows without being the active application (a
          // window under another is not shown, and its frames are discarded).
          o.window.level = MAX(o.window.level, NSFloatingWindowLevel);
          [o.window orderFrontRegardless];
      }
      a = NSApp.isActive ? 1 : 0;
      v = (o.window.occlusionState & NSWindowOcclusionStateVisible) ? 1 : 0;
    }, 0);
    *active = a;
    *visible = v;
}

static id<MTLDevice> test_device;
static id<MTLCommandQueue> test_queue;

void *dimna_aw_test_next_drawable(DimnaAwWindow *w, int sync) {
    @autoreleasepool {
        DimnaWindowObj *o = (__bridge DimnaWindowObj *)w;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
          test_device = MTLCreateSystemDefaultDevice();
          test_queue = [test_device newCommandQueue];
        });
        if (!test_device) return NULL;
        CAMetalLayer *layer = o.layer;
        // A layer's properties set on a thread with no run loop reach the screen only in
        // an explicit transaction (an implicit one would wait for a run loop that never
        // comes: every frame would then be discarded).
        [CATransaction begin];
        if (!layer.device) {
            layer.device = test_device;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            // Two, as the latency probe's figures were taken with (three add a refresh).
            layer.maximumDrawableCount = 2;
        }
        if (layer.displaySyncEnabled != (sync != 0)) layer.displaySyncEnabled = sync != 0;
        CGSize want = CGSizeMake(layer.bounds.size.width * layer.contentsScale,
                                 layer.bounds.size.height * layer.contentsScale);
        if (!CGSizeEqualToSize(layer.drawableSize, want) && want.width > 0 && want.height > 0)
            layer.drawableSize = want;
        [CATransaction commit];
        id<CAMetalDrawable> d = [layer nextDrawable];
        return d ? (__bridge_retained void *)d : NULL;
    }
}

void dimna_aw_test_present(void *drawable, float red) {
    @autoreleasepool {
        id<CAMetalDrawable> d = (__bridge_transfer id<CAMetalDrawable>)drawable;
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = d.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(red, 0.1, 0.15, 1);
        id<MTLCommandBuffer> cb = [test_queue commandBuffer];
        [[cb renderCommandEncoderWithDescriptor:pass] endEncoding];
        [cb presentDrawable:d];
        [cb commit];
    }
}

#endif
