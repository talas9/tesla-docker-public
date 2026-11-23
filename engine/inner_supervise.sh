#!/bin/sh
# inner_supervise.sh — runs INSIDE the bwrap sandbox whose root (/) is the
# overlay-merged firmware. Started by engine/initiator.sh. Pure sh.
#
# Launches QtCarDvServer then QtCar. QtCar runs in the foreground so this
# script (and thus the bwrap process the initiator tracks) stays alive exactly
# as long as the UI. Env toggles are passed in via --setenv by the initiator.
set -u

: "${TESLA_GL:=softpipe}"
: "${TESLA_TOUCH:=1}"
: "${DISPLAY:=:0}"

UI_BIN=/usr/tesla/UI/bin
export HOME=/home/tesla
export LD_LIBRARY_PATH="/usr/lib:/usr/lib/engines-3:/usr/tesla/UI/lib:/lib"
export LIBGL_ALWAYS_SOFTWARE=1
export LIBGL_DRIVERS_PATH=/usr/lib/dri
export EGL_PLATFORM=x11
export MESA_DISK_CACHE_SINGLE_FILE=1
export GALLIUM_DRIVER="$TESLA_GL"
[ "$TESLA_GL" = llvmpipe ] && export LP_NUM_THREADS=8
export QTCAR_DISABLE_WATCHDOG=1

mkdir -p /home/tesla/.Tesla/data /home/qtdvserver \
         /tmp/dvaccess /tmp/dbus_dvaccess \
         /run/chromium/policies /run/service 2>/dev/null || true

if [ ! -x "$UI_BIN/QtCar" ]; then
    echo "[inner] FATAL: $UI_BIN/QtCar not found in firmware root" >&2
    echo "[inner] This firmware squashfs does not look like a QtCar UI build." >&2
    exit 90
fi

cd "$UI_BIN" || exit 91

# --- QtCarDvServer (data-value / D-Bus server QtCar talks to) ---
if [ -x "$UI_BIN/QtCarDvServer" ]; then
    echo "[inner] starting QtCarDvServer"
    ./QtCarDvServer >/tmp/qtcardvserver.log 2>&1 &
    sleep 3
else
    echo "[inner] WARN: QtCarDvServer not present; continuing" >&2
fi

# --- touch shim (optional) ---
PRELOAD=""
if [ "$TESLA_TOUCH" = 1 ] && [ -f /opt/tesla/engine/touch_shim.so ]; then
    PRELOAD=/opt/tesla/engine/touch_shim.so
    echo "[inner] touch shim enabled (LD_PRELOAD=$PRELOAD)"
fi

TOUCH_ARG=""
[ "$TESLA_TOUCH" = 1 ] && TOUCH_ARG="--touch evdev:/dev/input/touch"

echo "[inner] starting QtCar (GL=$TESLA_GL touch=$TESLA_TOUCH)"
# exec so QtCar becomes PID of this bwrap session.
if [ -n "$PRELOAD" ]; then
    exec env LD_PRELOAD="$PRELOAD" ./QtCar $TOUCH_ARG
else
    exec ./QtCar $TOUCH_ARG
fi
