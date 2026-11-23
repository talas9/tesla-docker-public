#!/bin/sh
# fwlib.sh — shared firmware helpers (sourced by initiator.sh and teslactl).
# Recognised firmware files in $TESLA_DATA: *.squashfs *.sqfs *.ice
# A .ice is a SquashFS followed by dm-verity/FEC/signature trailer; the squashfs
# is at the front, so we find the 'hsqs' magic (0x73717368) and mount at that
# offset (normally 0). Pure sh.

fw_files() {   # print basenames of candidate firmware files in $1
    for f in "$1"/*.squashfs "$1"/*.sqfs "$1"/*.ice; do
        [ -f "$f" ] && basename "$f"
    done
}

fw_offset() {  # print byte offset of the squashfs superblock in file $1 (default 0)
    off=$(head -c 4194304 "$1" 2>/dev/null | grep -obUaF 'hsqs' | head -n1 | cut -d: -f1)
    echo "${off:-0}"
}

# ---- x11vnc (shared by initiator.sh and `teslactl vnc on|off`) ----
# x11vnc ALWAYS runs (noVNC/websockify proxies to it) and ALWAYS requires a
# password. ENABLE_VNC (or `teslactl vnc on`) only decides whether it listens
# on the container interface (0.0.0.0 -> reachable via the compose 127.0.0.1:5900
# mapping) or on container-loopback only (raw VNC unreachable from the host).
vnc_enabled() {   # live state file wins over the env default
    st=$(cat "${RUN:-/run/tesla}/enable_vnc" 2>/dev/null || echo "${ENABLE_VNC:-false}")
    case "$st" in true|1|on|yes) return 0 ;; *) return 1 ;; esac
}

vnc_start() {     # (re)start x11vnc per current toggle; needs DISPLAY RUN VNC_PORT
    pkill -9 -x x11vnc 2>/dev/null || true
    pw=${VNC_PASSWORD:-}; [ -n "$pw" ] || pw=tesla      # never run without a password
    ( umask 077; printf '%s\n' "$pw" > "$RUN/vncpass" )
    if vnc_enabled; then bind="-listen 0.0.0.0"; else bind="-localhost"; fi
    # shellcheck disable=SC2086
    x11vnc -display "${DISPLAY:-:0}" -forever -shared -passwdfile "$RUN/vncpass" $bind \
        -rfbport "$VNC_PORT" -cursor most -noxdamage -bg \
        -o /var/log/tesla/x11vnc.log 2>/dev/null || true
}
