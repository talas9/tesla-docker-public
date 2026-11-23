#!/bin/sh
# entrypoint.sh — container PID (under tini). Prepares runtime dirs and hands
# off to runit's runsvdir, which supervises the `webui` (always-on) and
# `engine` (on-demand) services. Logs go to stdout (docker logs) and to
# $TESLA_LOG for the CLI/UI to tail.
set -u

: "${TESLA_DATA:=/data}"
: "${TESLA_LOG:=/var/log/tesla/engine.log}"
: "${SVDIR:=/etc/service}"

mkdir -p /run/tesla /var/log/tesla "$TESLA_DATA" /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
: > "$TESLA_LOG" 2>/dev/null || true

echo "=============================================="
echo " tesla-docker engine — firmware-agnostic UI"
echo " control:  docker exec <ctr> teslactl status"
echo " web/API:  http://127.0.0.1:${TESLA_HTTP_PORT:-8080}/"
echo " firmware: drop *.ice/*.squashfs into $TESLA_DATA, then: teslactl firmware select <name> && teslactl start"
echo "=============================================="

if ls "$TESLA_DATA"/*.squashfs "$TESLA_DATA"/*.sqfs "$TESLA_DATA"/*.ice >/dev/null 2>&1; then
    echo "[entrypoint] firmware image(s) present in $TESLA_DATA:"
    ls -1 "$TESLA_DATA"/*.squashfs "$TESLA_DATA"/*.sqfs "$TESLA_DATA"/*.ice 2>/dev/null | sed 's#.*/#  - #'
else
    echo "[entrypoint] NOTE: no firmware in $TESLA_DATA yet (engine will stay idle)."
fi

# runsvdir supervises /etc/service. `engine` has a `down` file => stays idle
# until `teslactl start`. webui comes up immediately.
exec runsvdir -P "$SVDIR"
