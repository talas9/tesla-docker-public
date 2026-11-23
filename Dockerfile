# tesla-docker — firmware-AGNOSTIC Tesla UI emulation engine.
#
# This image ships the ENGINE ONLY. It contains NO Tesla firmware and no Tesla
# IP. Firmware is supplied out-of-band as a SquashFS image dropped into the
# /data volume at runtime (see README.md). The image is therefore safe to
# publish publicly.
#
# Runtime isolation: Docker provides the outer sandbox. Inside, the selected
# firmware is mounted read-only with squashfuse and made writable with
# fuse-overlayfs, then QtCar is launched into the merged root with bubblewrap
# (bwrap) — chosen over raw chroot because it gives clean, auto-torn-down
# namespaces for /dev, /proc and /run and avoids the stale-mount / vanishing
# X-socket fragility documented for the chroot pipeline. See engine/initiator.sh.
#
# Needs at run time: --cap-add SYS_ADMIN --device /dev/fuse  (NOT --privileged).

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Engine runtime + build toolchain for the C shims.
#   X stack:     xvfb x11vnc novnc websockify
#   GL (sw):     libgl1-mesa-dri mesa-utils
#   IPC:         dbus (dbus-daemon, dbus-send)
#   input tools: xinput xdotool
#   squashfs:    squashfuse fuse-overlayfs  (+ fuse3 for /dev/fuse)
#   sandbox:     bubblewrap
#   control:     busybox (httpd + sh CGI), socat (vnc helper)
#   supervise:   runit (runsvdir/runsv/sv) + tini as PID1 — prebuilt, non-Python
#   build:       gcc libx11-dev libxi-dev  (compile touch_shim.c + x11_touch_bridge.c)
#   misc:        util-linux ca-certificates
# Off-the-shelf components (NOT hand-rolled): noVNC+websockify (web VNC),
# squashfuse+fuse-overlayfs (RO+RW mount), bubblewrap (sandbox), runit+tini
# (process supervision/PID1), busybox httpd (web + CGI). Only the Tesla-specific
# glue (initiator, teslactl, touch shim/bridge, sdv) is bespoke.
RUN apt-get update && apt-get install -y --no-install-recommends \
        xvfb x11vnc novnc websockify \
        libgl1-mesa-dri mesa-utils \
        dbus \
        xinput xdotool \
        squashfuse fuse-overlayfs fuse3 \
        bubblewrap \
        busybox socat \
        runit tini \
        gcc libx11-dev libxi-dev libc6-dev \
        util-linux ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ---- Engine, control plane, web UI, supervision tree ----
COPY engine/   /opt/tesla/engine/
COPY webui/    /opt/tesla/webui/
COPY service/  /etc/service/
COPY teslactl  /usr/local/bin/teslactl
COPY entrypoint.sh /opt/tesla/entrypoint.sh

# ---- Compile the C shims (native x86-64; QtCar is x86-64) ----
# touch_shim.so is LD_PRELOAD'd into QtCar; x11_touch_bridge runs on the
# container side and turns X11/XI2 clicks into FIFO taps.
RUN gcc -shared -fPIC -O2 \
        -o /opt/tesla/engine/touch_shim.so \
        /opt/tesla/engine/shims/touch_shim.c -ldl -lpthread \
 && gcc -O2 \
        -o /usr/local/bin/x11_touch_bridge \
        /opt/tesla/engine/shims/x11_touch_bridge.c -lX11 -lXi \
 && chmod +x /usr/local/bin/teslactl /opt/tesla/entrypoint.sh \
             /opt/tesla/engine/initiator.sh /opt/tesla/engine/inner_supervise.sh \
             /opt/tesla/engine/sdv \
             /etc/service/webui/run /etc/service/engine/run \
 && find /opt/tesla/webui/cgi-bin -type f -exec chmod +x {} + \
 && ln -sf /usr/local/bin/teslactl /usr/local/bin/tesla

# Firmware squashfs images live here (volume, supplied out-of-band).
VOLUME ["/data"]

# State / logs / runtime root.
RUN mkdir -p /run/tesla /var/log/tesla /tesla
ENV TESLA_DATA=/data \
    TESLA_ROOT=/tesla \
    TESLA_LOG=/var/log/tesla/engine.log \
    TESLA_HTTP_PORT=8080 \
    DISPLAY=:0 \
    VNC_PORT=5900 \
    NOVNC_PORT=6080 \
    SVDIR=/etc/service \
    TESLA_RES=1920x1200 \
    TESLA_GL=softpipe \
    TESLA_TOUCH=1

# Web UI / HTTP control API.
EXPOSE 8080
# noVNC (optional direct expose; deploy.sh tunnels by default).
EXPOSE 6080

# tini = PID1 (prebuilt init: reaps zombies, forwards signals) -> entrypoint -> runsvdir.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/tesla/entrypoint.sh"]
