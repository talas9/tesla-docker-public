/*
 * Tesla QtCar Touch Shim (LD_PRELOAD)
 *
 * Intercepts:
 * - getsockopt(SO_PEERSEC) -> returns "unconfined"
 * - open/open64("/dev/input/touch") -> redirects to /tmp/touch_evdev FIFO
 * - QtCarTouchDriver methods -> stubs for display state
 * - ioctl on touch fd -> returns fake device info
 *
 * Also sets QTCAR_DISABLE_WATCHDOG=1 and disables display power-off.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/socket.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <linux/input.h>
#include <pthread.h>

#define EVDEV_FIFO "/tmp/touch_evdev"
#define TEXT_FIFO  "/tmp/touch_cmd"

static int touch_fd = -1;  /* The fd returned for /dev/input/touch */
static int pipe_write_fd = -1;

/* ========== 1. PEERSEC fix ========== */
int getsockopt(int sockfd, int level, int optname, void *optval, socklen_t *optlen) {
    typedef int (*real_t)(int, int, int, void *, socklen_t *);
    real_t real_fn = (real_t)dlsym(RTLD_NEXT, "getsockopt");
    if (level == SOL_SOCKET && optname == SO_PEERSEC) {
        const char *label = "unconfined";
        size_t len = strlen(label) + 1;
        if (*optlen < len) { *optlen = len; errno = ERANGE; return -1; }
        memcpy(optval, label, len);
        *optlen = len;
        return 0;
    }
    return real_fn(sockfd, level, optname, optval, optlen);
}

/* ========== 2. Evdev event helpers ========== */
static void write_event(int fd, unsigned short type, unsigned short code, int value) {
    struct input_event ev;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    ev.input_event_sec = ts.tv_sec;
    ev.input_event_usec = ts.tv_nsec / 1000;
    ev.type = type;
    ev.code = code;
    ev.value = value;
    write(fd, &ev, sizeof(ev));
}

static void do_tap(int fd, int x, int y) {
    /* Touch down */
    write_event(fd, EV_ABS, ABS_MT_SLOT, 0);
    write_event(fd, EV_ABS, ABS_MT_TRACKING_ID, 1);
    write_event(fd, EV_ABS, ABS_MT_POSITION_X, x);
    write_event(fd, EV_ABS, ABS_MT_POSITION_Y, y);
    write_event(fd, EV_ABS, ABS_X, x);
    write_event(fd, EV_ABS, ABS_Y, y);
    write_event(fd, EV_KEY, BTN_TOUCH, 1);
    write_event(fd, EV_SYN, SYN_REPORT, 0);

    usleep(50000);  /* 50ms hold */

    /* Touch up */
    write_event(fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
    write_event(fd, EV_KEY, BTN_TOUCH, 0);
    write_event(fd, EV_SYN, SYN_REPORT, 0);
}

/* ========== 3. Text command reader thread ========== */
static void *cmd_thread(void *arg) {
    int wfd = *(int *)arg;

    while (1) {
        /* Create FIFO if needed */
        struct stat st;
        if (stat(TEXT_FIFO, &st) != 0 || !S_ISFIFO(st.st_mode)) {
            unlink(TEXT_FIFO);
            mkfifo(TEXT_FIFO, 0666);
        }

        fprintf(stderr, "[TOUCH_BRIDGE] Ready. Send 'x y' to %s\n", TEXT_FIFO);

        /* Open blocks until writer connects */
        FILE *f = fopen(TEXT_FIFO, "r");
        if (!f) {
            fprintf(stderr, "[TOUCH_BRIDGE] Cannot open %s: %s\n", TEXT_FIFO, strerror(errno));
            sleep(1);
            continue;
        }

        char line[256];
        while (fgets(line, sizeof(line), f)) {
            int x = 0, y = 0;
            if (sscanf(line, "%d %d", &x, &y) == 2) {
                fprintf(stderr, "[TOUCH] tap %d,%d\n", x, y);
                do_tap(wfd, x, y);
            }
        }

        fclose(f);
        /* Writer closed, loop back to reopen */
    }
    return NULL;
}

/* ========== 4. open/open64 interception ========== */

/* Create pipe pair, start cmd_thread writing to pipe, return read end */
static int create_touch_pipe(void) {
    int fds[2];
    if (pipe(fds) < 0) {
        fprintf(stderr, "[SHIM] pipe() failed: %s\n", strerror(errno));
        return -1;
    }

    pipe_write_fd = fds[1];
    touch_fd = fds[0];

    /* Start text command reader thread */
    pthread_t tid;
    pthread_create(&tid, NULL, cmd_thread, &pipe_write_fd);
    pthread_detach(tid);

    fprintf(stderr, "[SHIM] Touch pipe created: read=%d write=%d\n", fds[0], fds[1]);
    return fds[0];
}

int open(const char *pathname, int flags, ...) {
    typedef int (*real_t)(const char *, int, ...);
    real_t real_fn = (real_t)dlsym(RTLD_NEXT, "open");
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }

    if (pathname && strcmp(pathname, "/dev/input/touch") == 0) {
        fprintf(stderr, "[SHIM] open(/dev/input/touch) intercepted\n");
        if (touch_fd >= 0) return touch_fd;
        return create_touch_pipe();
    }

    if (flags & O_CREAT) return real_fn(pathname, flags, mode);
    return real_fn(pathname, flags);
}

int open64(const char *pathname, int flags, ...) {
    typedef int (*real_t)(const char *, int, ...);
    real_t real_fn = (real_t)dlsym(RTLD_NEXT, "open64");
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }

    if (pathname && strcmp(pathname, "/dev/input/touch") == 0) {
        fprintf(stderr, "[SHIM] open64(/dev/input/touch) intercepted\n");
        if (touch_fd >= 0) return touch_fd;
        return create_touch_pipe();
    }

    if (flags & O_CREAT) return real_fn(pathname, flags, mode);
    return real_fn(pathname, flags);
}

/* ========== 5. ioctl interception for touch device queries ========== */
int ioctl(int fd, unsigned long request, ...) {
    typedef int (*real_t)(int, unsigned long, ...);
    real_t real_fn = (real_t)dlsym(RTLD_NEXT, "ioctl");

    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    /* Intercept ioctl on our touch pipe fd */
    if (fd == touch_fd) {
        switch (request) {
            case EVIOCGNAME(256): {
                const char *name = "tesla-touch-bridge";
                strncpy((char *)arg, name, 256);
                return strlen(name);
            }
            case EVIOCGID: {
                struct input_id *id = (struct input_id *)arg;
                id->bustype = 0x18;  /* BUS_I2C */
                id->vendor = 0x1234;
                id->product = 0x5678;
                id->version = 0x0100;
                return 0;
            }
            default:
                /* For EVIOCGBIT and others, return 0 (success, empty) */
                errno = 0;
                return 0;
        }
    }

    return real_fn(fd, request, arg);
}

/* ========== 6. QtCar class method overrides ========== */

/* QtCarTouchDriver::open() - return pipe fd */
int _ZN16QtCarTouchDriver4openEv(void *self) {
    fprintf(stderr, "[SHIM] QtCarTouchDriver::open() -> pipe fd=%d\n", touch_fd);
    if (touch_fd < 0) create_touch_pipe();
    return touch_fd;
}

/* QtCarTouchDriver::checkDisplayState() */
void _ZN16QtCarTouchDriver17checkDisplayStateEv(void *self) { }

/* ManagedQtCarTouchDriver::checkDisplayState() */
void _ZN23ManagedQtCarTouchDriver17checkDisplayStateEv(void *self) { }

/* QtCarTouchDriver::isDisplayOn() - always true */
int _ZN16QtCarTouchDriver11isDisplayOnEv(void *self) { return 1; }

/* QtCarTouchDriver::isPowered() - always true */
int _ZN16QtCarTouchDriver9isPoweredEv(void *self) { return 1; }

/* ServiceDataListener::isValidSecurityProfile() - always true */
int _ZN19ServiceDataListener22isValidSecurityProfileEv(void *self) { return 1; }

/* DisplayStateManager::powerOff() - no-op */
void _ZN19DisplayStateManager8powerOffEv(void *self) { }

/* ========== 7. Constructor ========== */
__attribute__((constructor))
static void init_shim(void) {
    setenv("QTCAR_DISABLE_WATCHDOG", "1", 1);
    /* Force display state values so QtCar thinks display is ON */
    setenv("CD_displayState", "false", 1);
    setenv("GUI_powerOffRailsRequest", "false", 1);

    fprintf(stderr, "[SHIM] Tesla touch bridge shim loaded (v2 - evdev pipe)\n");

    /* Proactively create touch pipe + cmd_thread in constructor
     * so it's ready before QtCar even asks for /dev/input/touch */
    if (touch_fd < 0) {
        create_touch_pipe();
    }
}
