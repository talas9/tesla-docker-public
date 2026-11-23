# Touch shims — build note

Two C components implement Python-free touch injection into QtCar.

## touch_shim.c  →  touch_shim.so  (LD_PRELOAD into QtCar)
Intercepts, inside the QtCar process:
- `getsockopt(SO_PEERSEC)` → returns `"unconfined"` (defeats the PEERSEC check).
- `open("/dev/input/touch")` / `open64(...)` → returns a pipe fd; a reader thread
  turns `"x y\n"` lines on FIFO `/tmp/touch_cmd` into synthetic evdev multitouch
  events on that pipe.
- `ioctl(EVIOCGNAME/EVIOCGID/...)` on the pipe fd → fake touch-device identity.
- QtCar C++ symbol overrides: `QtCarTouchDriver::{open,isDisplayOn,isPowered,
  checkDisplayState}`, `DisplayStateManager::powerOff`, etc.

Built in the image as:

    gcc -shared -fPIC -O2 -o touch_shim.so touch_shim.c -ldl -lpthread

**Architecture: must be x86-64** — QtCar is an x86-64 binary. This image is
`FROM ubuntu:22.04` (amd64), so the native `gcc` produces the correct ABI with
no cross-compile. (On the earlier aarch64 Lima host a cross toolchain was
needed; that is not the case here.)

## x11_touch_bridge.c  →  x11_touch_bridge  (runs container-side)
Selects XI2 raw pointer events on display `:0`, and on each click/drag writes
`"x y\n"` to the FIFO `/tesla/tmp/touch_cmd` — i.e. the merged firmware root is
mounted at `/tesla` on the container side so this hard-coded path lines up with
the shim's `/tmp/touch_cmd` seen from inside the bwrap root. Built as:

    gcc -O2 -o x11_touch_bridge x11_touch_bridge.c -lX11 -lXi

## Chain
    noVNC/VNC click → Xvfb :0 → x11_touch_bridge (XI2) → FIFO /tesla/tmp/touch_cmd
      → touch_shim reader thread (inside QtCar) → synthetic evdev → QtCar

QtCar only *reads* the events when a user is present, so the initiator also sets
the presence / keep-awake data values via `sdv` after QtCar is up (see
`engine/initiator.sh`).

## Known firmware caveat (from RE notes, build 2025.20.8)
On fw 2025.20.8 the shim + `--touch evdev:/dev/input/touch` combo was unstable
(buffer-overflow abort / display blanking) and QtCar rendered fine WITHOUT the
shim. The initiator therefore gates the shim behind `TESLA_TOUCH=1` (default on)
so a firmware where it misbehaves can run view-only with `TESLA_TOUCH=0`.
