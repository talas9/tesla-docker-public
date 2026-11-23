#!/bin/sh
# initiator.sh — the Tesla UI engine. Runs in the FOREGROUND as the runit
# `engine` service (service/engine/run). Pure sh (dash).
#
# On each (re)start it, idempotently:
#   1. selects + mounts a firmware squashfs  (squashfuse RO -> fuse-overlayfs RW)
#   2. applies agnostic mods (Mesa swrast, X dirs, dbus policy) into the merged root
#   3. (re)creates a clean X stack: dbus + Xvfb :0 + x11vnc + noVNC/websockify
#   4. starts the container-side x11_touch_bridge
#   5. backgrounds the presence/keep-awake sdv applier (waits for QtCar, then sets DVs)
#   6. exec's QtCarDvServer+QtCar inside bwrap (merged root = /)
# When QtCar exits, this script exits and runit restarts it => a full clean
# relaunch (the RE-verified cure for the vanishing-X0 churn), without
# re-mounting the firmware (step 1 is idempotent).
set -u

ENGINE_DIR=/opt/tesla/engine
. "$ENGINE_DIR/fwlib.sh"
: "${TESLA_DATA:=/data}"
: "${TESLA_ROOT:=/tesla}"
: "${TESLA_LOG:=/var/log/tesla/engine.log}"
: "${TESLA_RES:=1920x1200}"
: "${TESLA_GL:=softpipe}"
: "${TESLA_TOUCH:=1}"
: "${DISPLAY:=:0}"
: "${VNC_PORT:=5900}"
: "${VNC_PASSWORD:=tesla}"
: "${NOVNC_PORT:=6080}"

RUN=/run/tesla
LOWER=$RUN/lower
UPPER=$RUN/upper
WORK=$RUN/work
SELFILE=$RUN/selected
BUS=unix:path=/run/dbus/system_bus_socket
export DBUS_SYSTEM_BUS_ADDRESS="$BUS"

mkdir -p "$RUN" "$LOWER" "$UPPER" "$WORK" "$TESLA_ROOT" "$(dirname "$TESLA_LOG")" "$TESLA_DATA"

log() { printf '%s [engine] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$TESLA_LOG" ; }

die() { log "FATAL: $*"; sleep 3; exit 1; }   # sleep so runit doesn't hot-loop

# ---------------------------------------------------------------------------
# 1. Select + mount firmware (idempotent)
# ---------------------------------------------------------------------------
select_firmware() {
    if [ -f "$SELFILE" ] && [ -f "$TESLA_DATA/$(cat "$SELFILE")" ]; then
        cat "$SELFILE"; return 0
    fi
    # default: first *.squashfs / *.sqfs / *.ice in /data
    fw_files "$TESLA_DATA" | head -n1 | grep . 
}

mount_firmware() {
    if mountpoint -q "$TESLA_ROOT"; then
        log "firmware already mounted at $TESLA_ROOT"; return 0
    fi
    FW=$(select_firmware) || die "no firmware found in $TESLA_DATA (drop a *.ice / *.squashfs there, or: teslactl firmware select <name>)"
    log "selected firmware: $FW"
    [ -e /dev/fuse ] || die "/dev/fuse missing — run with --device /dev/fuse"

    OFF=$(fw_offset "$TESLA_DATA/$FW")
    log "squashfuse (RO) $TESLA_DATA/$FW (offset=$OFF) -> $LOWER"
    if [ "$OFF" -gt 0 ] 2>/dev/null; then
        squashfuse -o "offset=$OFF" "$TESLA_DATA/$FW" "$LOWER" || die "squashfuse mount failed (offset=$OFF)"
    else
        squashfuse "$TESLA_DATA/$FW" "$LOWER" || die "squashfuse mount failed (no 'hsqs' squashfs magic / bad image?)"
    fi

    log "fuse-overlayfs (RW) -> $TESLA_ROOT"
    fuse-overlayfs -o "lowerdir=$LOWER,upperdir=$UPPER,workdir=$WORK" "$TESLA_ROOT" \
        || die "fuse-overlayfs mount failed"
}

# ---------------------------------------------------------------------------
# 2. Apply agnostic mods into the merged (writable) root
# ---------------------------------------------------------------------------
apply_mods() {
    mkdir -p "$TESLA_ROOT/usr/lib/dri" "$TESLA_ROOT/tmp" "$TESLA_ROOT/run" \
             "$TESLA_ROOT/etc/dbus-1/system.d" "$TESLA_ROOT/home/tesla" 2>/dev/null || true

    case "$TESLA_GL" in
        softpipe)
            if [ -f "$ENGINE_DIR/mods/swrast_dri_nollvm.so" ]; then
                cp -f "$ENGINE_DIR/mods/swrast_dri_nollvm.so" \
                      "$TESLA_ROOT/usr/lib/dri/swrast_dri.so"
                log "installed Mesa softpipe swrast_dri.so"
            fi ;;
        llvmpipe)
            log "using image llvmpipe (libgl1-mesa-dri); not overwriting root driver" ;;
    esac

    # Permissive D-Bus policy so QtCar can own/use com.tesla.* on the system bus.
    cat > "$TESLA_ROOT/etc/dbus-1/system.d/tesla-allow.conf" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy context="default">
    <allow own_prefix="com.tesla"/>
    <allow send_type="method_call"/>
    <allow send_type="signal"/>
    <allow receive_type="method_call"/>
    <allow receive_type="signal"/>
  </policy>
</busconfig>
EOF
}

# ---------------------------------------------------------------------------
# 3. Clean X stack (always torn down + recreated for a stable relaunch)
# ---------------------------------------------------------------------------
start_x_stack() {
    log "resetting X stack"
    pkill -9 -x Xvfb 2>/dev/null || true
    pkill -9 -x x11vnc 2>/dev/null || true
    pkill -9 -f websockify 2>/dev/null || true
    pkill -9 -x x11_touch_bridge 2>/dev/null || true
    sleep 1
    rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
    mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

    # system D-Bus (shared by QtCar inside bwrap and by sdv on the container side)
    mkdir -p /run/dbus
    rm -f /run/dbus/pid
    if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
        dbus-daemon --system --fork 2>/dev/null || true
        log "dbus-daemon (system) started"
    fi

    log "Xvfb $DISPLAY ${TESLA_RES}x24"
    Xvfb "$DISPLAY" -screen 0 "${TESLA_RES}x24" -ac +extension GLX +extension RENDER \
        >/var/log/tesla/xvfb.log 2>&1 &
    i=0; while [ ! -S /tmp/.X11-unix/X0 ] && [ $i -lt 50 ]; do i=$((i+1)); sleep 0.1; done
    [ -S /tmp/.X11-unix/X0 ] || die "Xvfb failed to create X0 socket"
    DISPLAY=$DISPLAY xsetroot -solid black 2>/dev/null || true

    log "x11vnc on :$VNC_PORT"
    if vnc_enabled; then log "x11vnc on :$VNC_PORT (raw VNC ENABLED, password required)"
    else log "x11vnc on container-loopback :$VNC_PORT (raw VNC disabled; noVNC only)"; fi
    vnc_start

    # noVNC + websockify (prebuilt web VNC — not hand-rolled)
    log "noVNC/websockify on :$NOVNC_PORT"
    websockify --web=/usr/share/novnc/ "$NOVNC_PORT" "localhost:$VNC_PORT" \
        >/var/log/tesla/novnc.log 2>&1 &
}

# ---------------------------------------------------------------------------
# 4. Touch bridge (container side)
# ---------------------------------------------------------------------------
start_touch_bridge() {
    [ "$TESLA_TOUCH" = 1 ] || { log "touch disabled (TESLA_TOUCH=0)"; return 0; }
    mkdir -p "$TESLA_ROOT/tmp"
    log "x11_touch_bridge -> $TESLA_ROOT/tmp/touch_cmd"
    DISPLAY=$DISPLAY x11_touch_bridge >/var/log/tesla/touch_bridge.log 2>&1 &
}

# ---------------------------------------------------------------------------
# 5. Presence / keep-awake applier (background; waits for QtCar's D-Bus service)
# ---------------------------------------------------------------------------
apply_presence_async() {
    (
        # wait up to ~60s for QtCar to register com.tesla.Debug
        i=0
        while [ $i -lt 60 ]; do
            if dbus-send --system --print-reply --dest=org.freedesktop.DBus \
                 /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null \
                 | grep -q 'com.tesla.Debug'; then
                break
            fi
            i=$((i+1)); sleep 1
        done
        if [ $i -ge 60 ]; then
            log "presence: com.tesla.Debug never appeared; skipping sdv"
            exit 0
        fi
        log "presence: QtCar up, applying keep-awake + presence DVs"
        for pair in \
            "GUI_keepVehicleAwakeDiagToolConnected true" \
            "CD_displayState 1" \
            "VAPI_driverPresent true" \
            "VAPI_keyfobPresent true" \
            "GUI_passengerPresent true" ; do
            name=${pair%% *}; val=${pair#* }
            if "$ENGINE_DIR/sdv" "$name" "$val" >>"$TESLA_LOG" 2>&1; then
                log "presence: set $name=$val"
            else
                log "presence: FAILED $name=$val (DV name may differ per firmware)"
            fi
        done
    ) &
}

# ---------------------------------------------------------------------------
# 6. Launch QtCar inside bwrap (merged root = /)
# ---------------------------------------------------------------------------
launch() {
    log "entering bwrap sandbox (root=$TESLA_ROOT, GL=$TESLA_GL, touch=$TESLA_TOUCH)"
    exec bwrap \
        --bind "$TESLA_ROOT" / \
        --dev /dev \
        --proc /proc \
        --tmpfs /run \
        --ro-bind /run/dbus /run/dbus \
        --bind /tmp/.X11-unix /tmp/.X11-unix \
        --ro-bind "$ENGINE_DIR" /opt/tesla/engine \
        --setenv DISPLAY "$DISPLAY" \
        --setenv DBUS_SYSTEM_BUS_ADDRESS "$BUS" \
        --setenv TESLA_GL "$TESLA_GL" \
        --setenv TESLA_TOUCH "$TESLA_TOUCH" \
        --die-with-parent \
        /bin/sh /opt/tesla/engine/inner_supervise.sh
}

# ===========================================================================
log "=== engine starting ==="
mount_firmware
apply_mods
start_x_stack
start_touch_bridge
apply_presence_async
launch
