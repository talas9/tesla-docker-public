#!/bin/sh
# mac/setup-mac.sh — one-click Mac (Lima + Rosetta) runner for the Tesla UI.
#
# #############################################################################
# # LIMITATIONS — READ FIRST                                                 #
# #   * Linux x86-64 + Docker (./install.sh, README.md) is the SUPPORTED,    #
# #     recommended path. Use this script only when a Mac is the only       #
# #     machine available. See docs/COMPATIBILITY.md for the full matrix.   #
# #   * This script does NOT use this repo's Docker image/engine. Docker    #
# #     Desktop on a Mac has no GPU passthrough and runs this image's       #
# #     x86-64 binaries under emulation, not Rosetta — it buys nothing on   #
# #     a Mac. This script instead drives a Lima (aarch64 Ubuntu) VM with   #
# #     Rosetta's binfmt hook, which runs the x86-64 QtCar binary directly  #
# #     in the guest via a chroot — a separate, proven recipe.              #
# #   * NO GPU. Software rendering only (llvmpipe, optionally; softpipe     #
# #     always). This is an Apple `vz` limitation, not fixable here.        #
# #   * Slower than native Linux (Rosetta binary translation).              #
# #   * Touch is UNSOLVED on this path (view-only). The touch_shim ABI      #
# #     mismatches this firmware build. See docs/COMPATIBILITY.md.          #
# #############################################################################
#
# Usage:
#   mac/setup-mac.sh /path/to/extracted/firmware/tree [vnc_password]
#
# What it does, idempotently:
#   1. brew-installs lima, qemu, e2fsprogs if missing.
#   2. Creates/starts a Lima VM `tesla-vm` (aarch64, vz backend, rosetta
#      enabled) if it doesn't already exist/run.
#   3. Inside the VM: populates /tesla from the firmware dir you point it at,
#      installs this repo's zero-dependency softpipe driver, optionally
#      layers on llvmpipe via the Ubuntu 22.04 (jammy) amd64 libLLVM-15 trick,
#      starts Xvfb :0 + x11vnc (password) + noVNC, then chroots and launches
#      QtCar under Rosetta.
#   4. Prints the VNC / noVNC access info (Lima auto-forwards 127.0.0.1:5900).
#
# Source of the recipe: proven Oct-15-2026 Lima+Rosetta session (see this
# repo's docs/COMPATIBILITY.md for the write-up). Commands below are the same
# ones that were verified to render the Model 3 QtCar UI.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
VM_NAME=tesla-vm
VNC_PORT=5900
NOVNC_PORT=6080
RES=1920x1200

FW_DIR="${1:-}"
VNC_PASSWORD="${2:-tesla}"

if [ -z "$FW_DIR" ]; then
    echo "usage: $0 /path/to/extracted/firmware/tree [vnc_password]" >&2
    echo "  (an .ice/.squashfs is not enough here — this path chroots into an" >&2
    echo "   extracted tree; extract one first, e.g. with squashfuse/unsquashfs)" >&2
    exit 1
fi
FW_DIR=$(cd "$FW_DIR" && pwd)
if [ ! -d "$FW_DIR" ]; then
    echo "ERROR: firmware dir not found: $FW_DIR" >&2
    exit 1
fi

echo "==> Mac/Lima/Rosetta path (NOT the recommended path — see docs/COMPATIBILITY.md)"
echo "==> firmware dir : $FW_DIR"
echo "==> lima VM      : $VM_NAME"

# ---------------------------------------------------------------------------
# 1. Host-side prereqs (brew)
# ---------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew not found. Install it from https://brew.sh first." >&2
    exit 1
fi

echo "==> checking brew deps: lima, qemu, e2fsprogs"
for pkg in lima qemu e2fsprogs; do
    if brew list --formula 2>/dev/null | grep -qx "$pkg"; then
        echo "    $pkg: already installed"
    else
        echo "    $pkg: installing..."
        brew install "$pkg"
    fi
done

if ! command -v limactl >/dev/null 2>&1; then
    echo "ERROR: limactl not on PATH after brew install lima" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Lima VM: aarch64 Ubuntu, vz backend, Rosetta enabled
# ---------------------------------------------------------------------------
LIMA_YAML="$REPO_DIR/mac/tesla-vm.lima.yaml"
mkdir -p "$REPO_DIR/mac"
cat > "$LIMA_YAML" <<EOF
vmType: "vz"
os: "Linux"
arch: "aarch64"
images:
  - location: "https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-arm64.img"
    arch: "aarch64"
mounts:
  - location: "~"
    writable: true
  - location: "$REPO_DIR"
    writable: true
cpus: 4
memory: "6GiB"
disk: "40GiB"
rosetta:
  enabled: true
  binfmt: true
containerd:
  system: false
  user: false
EOF

if limactl list --json 2>/dev/null | grep -q "\"name\":\"$VM_NAME\""; then
    echo "==> lima VM $VM_NAME already exists"
    if ! limactl list 2>/dev/null | grep "^$VM_NAME" | grep -qi running; then
        echo "==> starting $VM_NAME"
        limactl start "$VM_NAME"
    else
        echo "==> $VM_NAME already running"
    fi
else
    echo "==> creating + starting $VM_NAME (aarch64 + Rosetta)"
    limactl start --name="$VM_NAME" --tty=false "$LIMA_YAML"
fi

lima_run() { limactl shell "$VM_NAME" sh -c "$1"; }

# ---------------------------------------------------------------------------
# 3. Guest-side setup: populate /tesla, drivers, X stack, chroot + QtCar
# ---------------------------------------------------------------------------
echo "==> guest: verifying Rosetta binfmt is active"
lima_run 'cat /proc/sys/fs/binfmt_misc/rosetta 2>/dev/null | grep -q enabled && echo rosetta-ok || echo "WARNING: rosetta binfmt not enabled yet"'

echo "==> guest: populating /tesla from firmware dir (idempotent: cp -a, no clobber of your edits across re-runs beyond refresh)"
lima_run "sudo mkdir -p /tesla && sudo cp -a '$FW_DIR'/. /tesla/"

echo "==> guest: installing zero-dependency softpipe Mesa driver (this repo's engine/mods/swrast_dri_nollvm.so)"
lima_run "sudo mkdir -p /tesla/usr/lib/dri && sudo cp '$REPO_DIR/engine/mods/swrast_dri_nollvm.so' /tesla/usr/lib/dri/swrast_dri.so"

echo "==> guest: installing Xvfb, x11vnc, noVNC/websockify, dbus (apt)"
lima_run 'sudo apt-get update -y && sudo apt-get install -y xvfb x11vnc novnc websockify dbus-x11'

# --- Optional llvmpipe speed-up (Ubuntu 22.04/jammy amd64 libLLVM-15 trick) ---
echo "==> guest: optional llvmpipe deps (jammy amd64 libLLVM-15, built against glibc 2.35 — matches firmware glibc; a newer native libLLVM-15 needs glibc 2.36+ which this firmware does not have)"
lima_run '
set -e
sudo dpkg --add-architecture amd64
echo "deb [arch=amd64] http://archive.ubuntu.com/ubuntu jammy main universe" | sudo tee /etc/apt/sources.list.d/jammy-amd64.list
echo "deb [arch=amd64] http://archive.ubuntu.com/ubuntu jammy-updates main universe" | sudo tee -a /etc/apt/sources.list.d/jammy-amd64.list
sudo apt-get update -y || true
mkdir -p /tmp/jammy-amd64 && cd /tmp/jammy-amd64
sudo apt-get download libllvm15:amd64 libzstd1:amd64 libz3-4:amd64 || { echo "llvmpipe deps unavailable, skipping (softpipe still works)"; exit 0; }
for d in *.deb; do dpkg-deb -x "$d" extracted; done
sudo cp extracted/usr/lib/x86_64-linux-gnu/libLLVM-15.so.1 /tesla/usr/lib/ 2>/dev/null || true
sudo cp extracted/usr/lib/x86_64-linux-gnu/libzstd.so.1 /tesla/usr/lib/ 2>/dev/null || true
sudo cp extracted/usr/lib/x86_64-linux-gnu/libz3.so.4 /tesla/usr/lib/ 2>/dev/null || true
sudo ln -sf libstdc++.so.6.0.30 /tesla/usr/lib/x86_64-linux-gnu/libstdc++.so.6 2>/dev/null || true
'
# If this repo later ships a jammy-built swrast_dri.so with llvmpipe support,
# drop it in here as engine/mods/swrast_dri_llvmpipe.so and this script will
# prefer it; for now softpipe (above) is the always-works default.

echo "==> guest: (re)launching X stack: Xvfb :0 -> x11vnc:$VNC_PORT -> noVNC:$NOVNC_PORT"
lima_run "
set -e
sudo pkill -9 -x Xvfb 2>/dev/null || true
sudo pkill -9 -x x11vnc 2>/dev/null || true
sudo pkill -9 -f websockify 2>/dev/null || true
sleep 1
sudo rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
sudo setsid Xvfb :0 -screen 0 ${RES}x24 -ac +extension GLX +extension RENDER >/tmp/xvfb.log 2>&1 < /dev/null &
sleep 1
[ -S /tmp/.X11-unix/X0 ] || { echo 'ERROR: Xvfb failed to create X0 socket'; exit 1; }
echo '$VNC_PASSWORD' | sudo tee /tmp/vncpass >/dev/null
sudo setsid x11vnc -display :0 -forever -shared -passwd '$VNC_PASSWORD' -listen 0.0.0.0 -rfbport $VNC_PORT -cursor most -noxdamage -bg -o /tmp/x11vnc.log < /dev/null
sudo setsid websockify --web=/usr/share/novnc/ $NOVNC_PORT localhost:$VNC_PORT >/tmp/novnc.log 2>&1 < /dev/null &
sleep 1
echo 'X stack up.'
"

echo "==> guest: chroot + launch QtCar (softpipe/llvmpipe, Rosetta-translated x86-64 — view-only, no working touch on this build)"
lima_run "
set -e
sudo mkdir -p /tesla/dev /tesla/proc /tesla/sys /tesla/tmp
sudo mount --bind /dev /tesla/dev 2>/dev/null || true
sudo mount -t proc proc /tesla/proc 2>/dev/null || true
sudo mount -t sysfs sys /tesla/sys 2>/dev/null || true
QTCAR_BIN=\$(sudo chroot /tesla sh -c 'command -v QtCar || find / -maxdepth 4 -name QtCar -type f 2>/dev/null | head -1')
if [ -z \"\$QTCAR_BIN\" ]; then
    echo 'ERROR: QtCar binary not found under /tesla — check the firmware dir you pointed this at.' >&2
    exit 1
fi
echo \"QtCar found at: \$QTCAR_BIN\"
sudo setsid chroot /tesla sh -c \"
    export DISPLAY=:0
    export GALLIUM_DRIVER=softpipe
    export LIBGL_ALWAYS_SOFTWARE=1
    export LIBGL_DRIVERS_PATH=/usr/lib/dri
    cd \\\$(dirname '\$QTCAR_BIN') && setsid ./\\\$(basename '\$QTCAR_BIN') >/tmp/qtcar.log 2>&1 </dev/null &
\" >/tmp/chroot-launch.log 2>&1 < /dev/null &
sleep 3
echo 'QtCar launch attempted — check /tmp/qtcar.log inside the VM (limactl shell $VM_NAME) if the screen stays black.'
"

echo ""
echo "============================================================================"
echo " Tesla UI (Mac / Lima+Rosetta — view-only, software rendering, no GPU)"
echo "============================================================================"
echo " Lima auto-forwards 127.0.0.1:$VNC_PORT and 127.0.0.1:$NOVNC_PORT to your Mac."
echo ""
echo "   Raw VNC  : localhost:$VNC_PORT        (password: $VNC_PASSWORD)"
echo "   noVNC    : http://127.0.0.1:$NOVNC_PORT/vnc.html?autoconnect=1&password=$VNC_PASSWORD"
echo ""
echo " Debug inside the VM:  limactl shell $VM_NAME"
echo "   tail -f /tmp/qtcar.log /tmp/xvfb.log /tmp/x11vnc.log /tmp/novnc.log"
echo ""
echo " Limitations: no GPU (software rendering only), touch does not work on"
echo " this firmware build (view-only), slower than native Linux. See"
echo " docs/COMPATIBILITY.md. For real speed + working touch, run ./install.sh"
echo " on an x86-64 Linux host instead."
echo "============================================================================"
