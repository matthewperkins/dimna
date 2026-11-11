// LD_PRELOAD shim that logs the usbdevfs ioctls a program makes (what a user-space USB library
// puts on the wire) to the file named by $OEZ_USBLOG. Used to learn the FT600 protocol from
// FTDI's D3XX library; see ../../src/ft600.zig. It does not see programs that make raw
// syscalls (oEZ's own transport does; use OEZ_USB_TRACE=1 for that).
//
//   gcc -shared -fPIC -O1 -o usbshim.so usbshim.c -ldl -lpthread
//   OEZ_USBLOG=/tmp/usb.log LD_PRELOAD=./usbshim.so program ...
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <time.h>
#include <linux/usbdevice_fs.h>

static int (*real_ioctl)(int, unsigned long, ...);
static FILE *lg;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static double t0;

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void init(void)
{
    if (real_ioctl) return;
    real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    const char *p = getenv("OEZ_USBLOG");
    lg = p ? fopen(p, "w") : NULL;
    t0 = now();
}

static void hex(const unsigned char *b, int n, int max)
{
    int m = n < max ? n : max;
    for (int i = 0; i < m; i++) fprintf(lg, "%02x", b[i]);
    if (n > max) fprintf(lg, "..(+%d)", n - max);
}

static const char *tname(int t)
{
    return t == 0 ? "ISO" : t == 1 ? "INT" : t == 2 ? "CTRL" : "BULK";
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    va_start(ap, req);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    init();
    if (!lg || _IOC_TYPE(req) != 'U') return real_ioctl(fd, req, arg);
    if (req == USBDEVFS_SUBMITURB) {
        struct usbdevfs_urb *u = arg;
        unsigned char *b = u->buffer;
        pthread_mutex_lock(&mu);
        fprintf(lg, "%10.6f SUBMIT %p %s ep=%02x len=%d ", now() - t0, (void *)u, tname(u->type), u->endpoint, u->buffer_length);
        if (u->type == 2) { // control: 8-byte setup, then data if host-to-device
            hex(b, 8, 8);
            fprintf(lg, " ");
            if (!(b[0] & 0x80)) hex(b + 8, u->buffer_length - 8, 256);
        } else if (!(u->endpoint & 0x80)) {
            hex(b, u->buffer_length, 256);
        }
        fprintf(lg, "\n");
        pthread_mutex_unlock(&mu);
        return real_ioctl(fd, req, arg);
    }
    if (req == USBDEVFS_REAPURB || req == USBDEVFS_REAPURBNDELAY) {
        int r = real_ioctl(fd, req, arg);
        if (r == 0) {
            struct usbdevfs_urb *u = *(struct usbdevfs_urb **)arg;
            unsigned char *b = u->buffer;
            pthread_mutex_lock(&mu);
            fprintf(lg, "%10.6f REAP   %p %s ep=%02x status=%d actual=%d ", now() - t0, (void *)u, tname(u->type), u->endpoint, u->status, u->actual_length);
            if (u->type == 2) {
                if (b[0] & 0x80) hex(b + 8, u->actual_length, 256);
            } else if (u->endpoint & 0x80) {
                hex(b, u->actual_length, u->actual_length <= 256 ? 256 : 48);
            }
            fprintf(lg, "\n");
            pthread_mutex_unlock(&mu);
        }
        return r;
    }
    int r = real_ioctl(fd, req, arg);
    pthread_mutex_lock(&mu);
    fprintf(lg, "%10.6f ioctl 'U' nr=%lu r=%d", now() - t0, (unsigned long)_IOC_NR(req), r);
    if (req == USBDEVFS_CLAIMINTERFACE || req == USBDEVFS_RELEASEINTERFACE || req == USBDEVFS_CLEAR_HALT || req == USBDEVFS_RESETEP)
        fprintf(lg, " arg=0x%x", *(unsigned *)arg);
    if (req == USBDEVFS_DISCARDURB) fprintf(lg, " discard %p", arg);
    fprintf(lg, "\n");
    pthread_mutex_unlock(&mu);
    return r;
}
