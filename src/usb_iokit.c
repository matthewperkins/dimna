// IOKit's USB user client, for src/usb_darwin.zig (which states what each function is for
// and maps the codes returned here). IOKit's USB interfaces are tables of function pointers
// behind CFPlugIn (IOUSBLib.h); calling them from C keeps their layout the header's.
//
// Nothing here starts a thread, and a transfer's completion is received on the thread that
// made it: an interface's completions arrive as Mach messages on the interface's own port
// (CreateInterfaceAsyncPort), which `dimna_usb_bulk` reads with a timeout. No run loop.
//
// Every function returns an IOReturn (0 = success) unless it says otherwise.

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint64_t entry_id;    // the IORegistry entry's id: what dimna_usb_open takes
    uint32_t location_id; // where the device is plugged in (the same from run to run)
    uint32_t address;     // its USB address on its bus
    uint32_t speed;       // kUSBDeviceSpeed*: 0 low, 1 full, 2 high, 3 super, 4 and up faster; 0xffffffff unknown
} dimna_usb_loc;

enum { max_interfaces = 4, max_endpoints = 32 };

typedef struct {
    IOUSBInterfaceInterface942 **intf; // NULL: slot free
    uint32_t number;
    mach_port_t port; // completions of this interface's asynchronous transfers
} claimed;

typedef struct {
    IOUSBDeviceInterface942 **dev;
    claimed ifs[max_interfaces];
    // Endpoint address -> (slot in ifs, pipe reference), filled when an interface is claimed.
    // Index: the endpoint number, plus 16 for IN. pipe 0 = not known.
    uint8_t ep_if[max_endpoints];
    uint8_t ep_pipe[max_endpoints];
    // The one transfer in flight.
    volatile int done;
    IOReturn result;
    uint32_t bytes;
    // Set when an aborted transfer never reported back: its completion may still arrive,
    // so no further transfer is started.
    int broken;
} device;

static int ep_index(uint8_t endpoint) { return (endpoint & 0x0f) | ((endpoint & 0x80) ? 16 : 0); }

static int number_property(io_service_t service, CFStringRef key, uint32_t *out) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!v) return 0;
    int ok = CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, out);
    CFRelease(v);
    return ok;
}

// The product string as UTF-8, or -1 if the entry has none under `key` (or it does not fit).
static long string_property(io_service_t service, CFStringRef key, char *out, size_t cap) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!v) return -1;
    long n = -1;
    if (CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString((CFStringRef)v, out, (CFIndex)cap, kCFStringEncodingUTF8))
        n = (long)strlen(out);
    CFRelease(v);
    return n;
}

// Reads the IORegistry only: no device is opened or sent anything. Returns how many
// devices matched; the first `out_len` of them are in `out`, in the registry's order (the
// caller sorts).
size_t dimna_usb_find(uint16_t vendor, const uint16_t *products, size_t nproducts, const char *product, size_t product_len,
                      dimna_usb_loc *out, size_t out_len) {
    io_iterator_t it = IO_OBJECT_NULL;
    // IOServiceGetMatchingServices consumes the matching dictionary.
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOUSBHostDeviceClassName), &it) != KERN_SUCCESS) return 0;
    size_t n = 0;
    io_service_t s;
    while ((s = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        uint32_t vid = 0, pid = 0;
        int match = number_property(s, CFSTR("idVendor"), &vid) && vid == vendor && number_property(s, CFSTR("idProduct"), &pid);
        if (match) {
            match = 0;
            for (size_t i = 0; i < nproducts; i++) match |= products[i] == pid;
        }
        if (match) {
            char name[256];
            long len = string_property(s, CFSTR("USB Product Name"), name, sizeof name);
            if (len < 0) len = string_property(s, CFSTR("kUSBProductString"), name, sizeof name);
            match = len >= 0 && (size_t)len == product_len && memcmp(name, product, product_len) == 0;
        }
        if (match) {
            dimna_usb_loc loc = {0, 0, 0, 0xffffffffu};
            IORegistryEntryGetRegistryEntryID(s, &loc.entry_id);
            number_property(s, CFSTR("locationID"), &loc.location_id);
            if (!number_property(s, CFSTR("USB Address"), &loc.address)) number_property(s, CFSTR("kUSBAddress"), &loc.address);
            if (!number_property(s, CFSTR("Device Speed"), &loc.speed)) number_property(s, CFSTR("USBSpeed"), &loc.speed);
            if (n < out_len) out[n] = loc;
            n++;
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return n;
}

// The COM-style interface `iid` of the user client of type `type` on `service`.
static IOReturn plugin_interface(io_service_t service, CFUUIDRef type, CFUUIDRef iid, void **out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn r = IOCreatePlugInInterfaceForService(service, type, kIOCFPlugInInterfaceID, &plugin, &score);
    if (r != kIOReturnSuccess) return r;
    if (!plugin) return kIOReturnNoResources;
    HRESULT h = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(iid), (LPVOID *)out);
    (*plugin)->Release(plugin);
    return (h == S_OK && *out) ? kIOReturnSuccess : kIOReturnUnsupported;
}

// Opens nothing on the device itself (control requests and looking up its interfaces do
// not need the device open, and opening it would shut out its other users); the
// interfaces are opened by dimna_usb_claim. kIOReturnNoDevice if the entry is gone.
IOReturn dimna_usb_open(uint64_t entry_id, void **handle) {
    *handle = NULL;
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(entry_id));
    if (s == IO_OBJECT_NULL) return kIOReturnNoDevice;
    device *d = calloc(1, sizeof *d);
    if (!d) {
        IOObjectRelease(s);
        return kIOReturnNoMemory;
    }
    IOReturn r = plugin_interface(s, kIOUSBDeviceUserClientTypeID, kIOUSBDeviceInterfaceID942, (void **)&d->dev);
    IOObjectRelease(s);
    if (r != kIOReturnSuccess) {
        free(d);
        return r;
    }
    *handle = d;
    return kIOReturnSuccess;
}

static void drop(claimed *c) {
    if (!c->intf) return;
    (*c->intf)->USBInterfaceClose(c->intf);
    (*c->intf)->Release(c->intf);
    // The port was made by CreateInterfaceAsyncPort and goes with the interface.
    c->intf = NULL;
    c->port = MACH_PORT_NULL;
}

void dimna_usb_release(void *handle, uint32_t interface_number) {
    device *d = handle;
    if (!d) return;
    for (int i = 0; i < max_interfaces; i++) {
        if (!d->ifs[i].intf || d->ifs[i].number != interface_number) continue;
        for (int e = 0; e < max_endpoints; e++)
            if (d->ep_pipe[e] && d->ep_if[e] == i) d->ep_pipe[e] = 0;
        drop(&d->ifs[i]);
    }
}

void dimna_usb_close(void *handle) {
    device *d = handle;
    if (!d) return;
    for (int i = 0; i < max_interfaces; i++) drop(&d->ifs[i]);
    (*d->dev)->Release(d->dev);
    free(d);
}

// Opens interface `interface_number` for this program alone and learns its endpoints.
// kIOReturnExclusiveAccess: another program (or a kernel driver) has it.
// kIOReturnNotFound: the device has no such interface.
IOReturn dimna_usb_claim(void *handle, uint32_t interface_number) {
    device *d = handle;
    if (!d) return kIOReturnNoDevice;
    int slot = -1;
    for (int i = 0; i < max_interfaces; i++) {
        if (d->ifs[i].intf && d->ifs[i].number == interface_number) return kIOReturnSuccess;
        if (!d->ifs[i].intf && slot < 0) slot = i;
    }
    if (slot < 0) return kIOReturnNoResources;

    IOUSBFindInterfaceRequest req = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
                                     kIOUSBFindInterfaceDontCare};
    io_iterator_t it = IO_OBJECT_NULL;
    IOReturn r = (*d->dev)->CreateInterfaceIterator(d->dev, &req, &it);
    if (r != kIOReturnSuccess) return r;
    IOUSBInterfaceInterface942 **intf = NULL;
    io_service_t s;
    r = kIOReturnNotFound;
    while ((s = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        IOUSBInterfaceInterface942 **cand = NULL;
        IOReturn pr = plugin_interface(s, kIOUSBInterfaceUserClientTypeID, kIOUSBInterfaceInterfaceID942, (void **)&cand);
        IOObjectRelease(s);
        if (pr != kIOReturnSuccess) {
            r = pr;
            continue;
        }
        UInt8 num = 0xff;
        if ((*cand)->GetInterfaceNumber(cand, &num) == kIOReturnSuccess && num == interface_number) {
            intf = cand;
            break;
        }
        (*cand)->Release(cand);
    }
    IOObjectRelease(it);
    if (!intf) return r;

    r = (*intf)->USBInterfaceOpen(intf);
    if (r != kIOReturnSuccess) {
        (*intf)->Release(intf);
        return r;
    }
    mach_port_t port = MACH_PORT_NULL;
    r = (*intf)->CreateInterfaceAsyncPort(intf, &port);
    UInt8 count = 0;
    if (r == kIOReturnSuccess) r = (*intf)->GetNumEndpoints(intf, &count);
    if (r != kIOReturnSuccess) {
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        return r;
    }
    // Pipe references run from 1 to the number of endpoints (0 is the control pipe).
    for (UInt8 pipe = 1; pipe <= count; pipe++) {
        UInt8 direction, number, type, interval;
        UInt16 max_packet;
        if ((*intf)->GetPipeProperties(intf, pipe, &direction, &number, &type, &max_packet, &interval) != kIOReturnSuccess) continue;
        if (direction != kUSBIn && direction != kUSBOut) continue;
        int e = (number & 0x0f) | (direction == kUSBIn ? 16 : 0);
        d->ep_if[e] = (uint8_t)slot;
        d->ep_pipe[e] = pipe;
    }
    d->ifs[slot].intf = intf;
    d->ifs[slot].number = interface_number;
    d->ifs[slot].port = port;
    return kIOReturnSuccess;
}

// One control transfer on the default pipe. `*moved` is the bytes moved.
IOReturn dimna_usb_control(void *handle, uint8_t request_type, uint8_t request, uint16_t value, uint16_t index, void *data,
                           uint16_t len, uint32_t timeout_ms, uint32_t *moved) {
    device *d = handle;
    *moved = 0;
    if (!d) return kIOReturnNoDevice;
    IOUSBDevRequestTO req = {
        .bmRequestType = request_type,
        .bRequest = request,
        .wValue = value,
        .wIndex = index,
        .wLength = len,
        .pData = data,
        .wLenDone = 0,
        .noDataTimeout = timeout_ms,
        .completionTimeout = timeout_ms,
    };
    IOReturn r = (*d->dev)->DeviceRequestTO(d->dev, &req);
    *moved = req.wLenDone;
    return r;
}

static void completed(void *refcon, IOReturn result, void *arg0) {
    device *d = refcon;
    d->result = result;
    d->bytes = (uint32_t)(uintptr_t)arg0;
    d->done = 1;
}

// DIMNA_USB_STATS=N: every read of more than 64 bytes that took longer than N microseconds
// (4000 if N is below 100), or was started more than that after the one before it ended, is reported on stderr with where
// the time went: `away` (between the reads: the caller's work and sleep), `submit` (starting
// the transfer), `wait` (until its completion arrived). For finding late blocks.
static int stats_on = -1;
static uint64_t stats_last_end, stats_start, stats_limit = 4000;
static uint64_t now_us(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000u; }

static uint64_t now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000u; }

// Waits up to `ms` for a message on `port` and runs the completion it carries. Returns 0
// when the wait timed out, 1 otherwise (a message was handled, or the wait was interrupted).
static int pump(mach_port_t port, uint32_t ms) {
    union {
        mach_msg_header_t header;
        char bytes[1024];
    } msg;
    kern_return_t k = mach_msg(&msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof msg, port, ms, MACH_PORT_NULL);
    if (k == MACH_RCV_TIMED_OUT) return 0;
    if (k == MACH_MSG_SUCCESS) IODispatchCalloutFromMessage(NULL, &msg.header, NULL);
    return 1;
}

// How long an aborted transfer is given to report back before the device is given up.
enum { abort_wait_ms = 2000 };

// One bulk transfer on `endpoint` (bit 7 set = IN), given up after `timeout_ms`.
// Returns the transfer's own result; `*actual` is the bytes moved, also when it was given
// up, and `*timed_out` is set when it was this function that gave it up (the result is
// then what IOKit reports for an aborted transfer, and is not an error).
// kIOReturnNotFound: no claimed interface has that endpoint.
IOReturn dimna_usb_bulk(void *handle, uint8_t endpoint, void *buf, uint32_t len, int32_t timeout_ms, uint32_t *actual,
                        int *timed_out) {
    device *d = handle;
    *actual = 0;
    *timed_out = 0;
    if (!d || d->broken) return kIOReturnNoDevice;
    int e = ep_index(endpoint);
    UInt8 pipe = d->ep_pipe[e];
    if (!pipe) return kIOReturnNotFound;
    claimed *c = &d->ifs[d->ep_if[e]];

    if (stats_on < 0) {
        const char *v = getenv("DIMNA_USB_STATS");
        stats_on = v != NULL;
        if (v && atoi(v) >= 100) stats_limit = (uint64_t)atoi(v);
        stats_start = now_us();
    }
    int stats = stats_on && (endpoint & 0x80) && len > 64;
    uint64_t t0 = stats ? now_us() : 0;
    d->done = 0;
    IOReturn r = (endpoint & 0x80) ? (*c->intf)->ReadPipeAsync(c->intf, pipe, buf, len, completed, d)
                                   : (*c->intf)->WritePipeAsync(c->intf, pipe, buf, len, completed, d);
    if (r != kIOReturnSuccess) return r;

    uint64_t t1 = stats ? now_us() : 0;
    uint64_t deadline = now_ms() + (uint64_t)(timeout_ms > 0 ? timeout_ms : 0);
    while (!d->done) {
        uint64_t now = now_ms();
        if (now >= deadline) {
            // One last look without waiting: it may have completed in the meantime.
            pump(c->port, 0);
            break;
        }
        pump(c->port, (uint32_t)(deadline - now));
    }
    if (!d->done) {
        // Give it up. The abort makes the transfer complete (kIOReturnAborted) with the
        // bytes that had arrived; wait for that, so nothing is in flight on return.
        *timed_out = 1;
        (*c->intf)->AbortPipe(c->intf, pipe);
        uint64_t give_up = now_ms() + abort_wait_ms;
        while (!d->done) {
            uint64_t now = now_ms();
            if (now >= give_up) {
                d->broken = 1;
                return kIOReturnNoDevice;
            }
            pump(c->port, (uint32_t)(give_up - now));
        }
        // It completed on its own just before the abort took hold: not a timeout.
        if (d->result == kIOReturnSuccess) *timed_out = 0;
    }
    if (stats) {
        uint64_t t2 = now_us();
        uint64_t away = stats_last_end ? t0 - stats_last_end : 0;
        if (away > stats_limit || t2 - t0 > stats_limit)
            fprintf(stderr, "usb-stats t=%.3f s away %.2f ms submit %.2f ms wait %.2f ms bytes %u%s\n", (double)(t0 - stats_start) / 1e6,
                    (double)away / 1e3, (double)(t1 - t0) / 1e3, (double)(t2 - t1) / 1e3, d->bytes, *timed_out ? " TIMEOUT" : "");
        stats_last_end = t2;
    }
    *actual = d->bytes;
    return d->result;
}

void dimna_usb_clear_halt(void *handle, uint8_t endpoint) {
    device *d = handle;
    if (!d) return;
    int e = ep_index(endpoint);
    if (!d->ep_pipe[e]) return;
    claimed *c = &d->ifs[d->ep_if[e]];
    (*c->intf)->ClearPipeStallBothEnds(c->intf, d->ep_pipe[e]);
}
