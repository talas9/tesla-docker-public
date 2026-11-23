/*
 * X11-to-Touch Bridge for Tesla QtCar
 *
 * Listens for XI2 raw pointer events on display :0
 * Writes "x y\n" commands to the shim's FIFO (persistent connection).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>

#define CMD_FIFO "/tesla/tmp/touch_cmd"

static volatile int running = 1;
static int fifo_fd = -1;

void sighandler(int s) { running = 0; }

static int connect_fifo(void) {
    int fd = open(CMD_FIFO, O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "[BRIDGE] FIFO open failed: %s\n", strerror(errno));
        return -1;
    }
    fprintf(stderr, "[BRIDGE] FIFO connected (fd=%d)\n", fd);
    return fd;
}

static int send_tap(int x, int y) {
    if (fifo_fd < 0) {
        fifo_fd = connect_fifo();
        if (fifo_fd < 0) return -1;
    }
    char buf[64];
    int len = snprintf(buf, sizeof(buf), "%d %d\n", x, y);
    ssize_t n = write(fifo_fd, buf, len);
    if (n != len) {
        fprintf(stderr, "[BRIDGE] write failed (n=%zd, errno=%d): %s\n", n, errno, strerror(errno));
        close(fifo_fd);
        fifo_fd = -1;
        /* Retry once */
        fifo_fd = connect_fifo();
        if (fifo_fd >= 0) {
            n = write(fifo_fd, buf, len);
            if (n != len) {
                fprintf(stderr, "[BRIDGE] retry write also failed\n");
                close(fifo_fd);
                fifo_fd = -1;
                return -1;
            }
        }
    }
    return 0;
}

int main() {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGINT, sighandler);
    signal(SIGTERM, sighandler);

    Display *dpy = XOpenDisplay(":0");
    if (!dpy) { fprintf(stderr, "Cannot open display :0\n"); return 1; }

    int xi_opcode, xi_event, xi_error;
    if (!XQueryExtension(dpy, "XInputExtension", &xi_opcode, &xi_event, &xi_error)) {
        fprintf(stderr, "XInput not available\n");
        return 1;
    }

    int major = 2, minor = 2;
    XIQueryVersion(dpy, &major, &minor);
    fprintf(stderr, "[BRIDGE] XI2 v%d.%d\n", major, minor);

    Window root = DefaultRootWindow(dpy);

    XIEventMask evmask;
    unsigned char mask[4] = {0};
    evmask.deviceid = XIAllMasterDevices;
    evmask.mask_len = sizeof(mask);
    evmask.mask = mask;
    XISetMask(mask, XI_RawButtonPress);
    XISetMask(mask, XI_RawButtonRelease);
    XISetMask(mask, XI_RawMotion);

    XISelectEvents(dpy, root, &evmask, 1);
    XSync(dpy, False);

    fprintf(stderr, "[BRIDGE] X11 Touch Bridge v2 started\n");
    fprintf(stderr, "[BRIDGE] FIFO: %s\n", CMD_FIFO);

    fifo_fd = connect_fifo();

    int pressed = 0;
    int last_x = 0, last_y = 0;
    XEvent ev;

    while (running) {
        XNextEvent(dpy, &ev);

        if (ev.type != GenericEvent || ev.xcookie.extension != xi_opcode)
            continue;
        if (!XGetEventData(dpy, &ev.xcookie))
            continue;

        XIRawEvent *raw = (XIRawEvent *)ev.xcookie.data;

        switch (ev.xcookie.evtype) {
            case XI_RawButtonPress:
                if (raw->detail == 1) {
                    pressed = 1;
                    Window rr, cr;
                    int rx, ry, wx, wy;
                    unsigned int msk;
                    XQueryPointer(dpy, root, &rr, &cr, &rx, &ry, &wx, &wy, &msk);
                    last_x = rx;
                    last_y = ry;
                    if (send_tap(rx, ry) == 0) {
                        fprintf(stderr, "[BRIDGE] TAP %d,%d OK\n", rx, ry);
                    }
                }
                break;
            case XI_RawButtonRelease:
                if (raw->detail == 1) pressed = 0;
                break;
            case XI_RawMotion:
                if (pressed) {
                    Window rr, cr;
                    int rx, ry, wx, wy;
                    unsigned int msk;
                    XQueryPointer(dpy, root, &rr, &cr, &rx, &ry, &wx, &wy, &msk);
                    int dx = rx - last_x;
                    int dy = ry - last_y;
                    if (dx*dx + dy*dy > 100) {
                        last_x = rx;
                        last_y = ry;
                        send_tap(rx, ry);
                    }
                }
                break;
        }

        XFreeEventData(dpy, &ev.xcookie);
    }

    if (fifo_fd >= 0) close(fifo_fd);
    XCloseDisplay(dpy);
    return 0;
}
