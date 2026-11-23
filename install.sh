#!/bin/sh
# install.sh — one command, A to Z.
#
#   ./install.sh <firmware.ice | firmware.squashfs | firmware-dir> [--target user@host]
#
# Local:   validates docker+compose, puts the firmware in ./data/ (a directory is
#          packed with mksquashfs), builds + starts the container, selects the
#          firmware, starts the UI, waits for it, prints tunnel cmds/URLs/password.
# Remote:  --target rsyncs this repo + the firmware to the host and runs this same
#          script there (build/run happen on the remote host).
#
# Env (persisted to ./.env, which compose auto-loads):
#      ENABLE_VNC=true|false (raw VNC :5900, default false)  VNC_PASSWORD (default tesla)
#      WEBUI_USER (admin)  WEBUI_PASSWORD (random if unset)
#      TESLA_IMAGE  WAIT_SECS (default 180)
#      REMOTE_DIR (remote checkout dir, default tesla-docker)
set -eu

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "[install] ERROR: $*" >&2; exit 1; }
say() { echo "[install] $*"; }

INPUT=""; TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target) [ $# -ge 2 ] || usage; TARGET=$2; shift 2 ;;
        --target=*) TARGET=${1#--target=}; shift ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) [ -z "$INPUT" ] || usage; INPUT=$1; shift ;;
    esac
done
[ -n "$INPUT" ] || usage
[ -e "$INPUT" ] || die "not found: $INPUT"

HERE=$(cd "$(dirname "$0")" && pwd)
ENABLE_VNC=${ENABLE_VNC:-}
VNC_PASSWORD=${VNC_PASSWORD:-}
WEBUI_USER=${WEBUI_USER:-}
WEBUI_PASSWORD=${WEBUI_PASSWORD:-}
WAIT_SECS=${WAIT_SECS:-180}
REMOTE_DIR=${REMOTE_DIR:-tesla-docker}
[ -z "${TESLA_IMAGE:-}" ] || export TESLA_IMAGE

SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"

# ------------------------------------------------------------------ remote ---
if [ -n "$TARGET" ]; then
    command -v ssh >/dev/null || die "ssh not found"
    command -v rsync >/dev/null || die "rsync not found"
    BASE=$(basename "$INPUT")
    say "syncing repo to $TARGET:~/$REMOTE_DIR ..."
    ssh "$TARGET" "mkdir -p ~/$REMOTE_DIR/.input"
    rsync -a --delete --exclude='/data' --exclude='/.input' --exclude='.git' --exclude='.DS_Store' \
        "$HERE"/ "$TARGET:$REMOTE_DIR/"
    say "uploading firmware '$BASE' (large; rsync is resumable) ..."
    if [ -d "$INPUT" ]; then rsync -a --partial "$INPUT"/ "$TARGET:$REMOTE_DIR/.input/$BASE/"
    else rsync -a --partial --progress "$INPUT" "$TARGET:$REMOTE_DIR/.input/$BASE"; fi
    say "running install on $TARGET ..."
    ssh -t "$TARGET" "cd ~/$REMOTE_DIR && ENABLE_VNC='$ENABLE_VNC' VNC_PASSWORD='$VNC_PASSWORD' WEBUI_USER='$WEBUI_USER' WEBUI_PASSWORD='$WEBUI_PASSWORD' WAIT_SECS=$WAIT_SECS \
        INSTALL_REMOTE_HOST='$TARGET' sh ./install.sh '.input/$BASE'"
    exit $?
fi

# ------------------------------------------------------------------- local ---
# 1. docker + compose
command -v docker >/dev/null 2>&1 || die "docker not found — install Docker Engine first (https://docs.docker.com/engine/install/)"
docker info >/dev/null 2>&1 || die "docker daemon not reachable (is it running / do you need sudo or the docker group?)"
if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
else die "docker compose not found (install the compose v2 plugin)"; fi
say "docker ok; compose: $DC"

# 2. firmware -> ./data
cd "$HERE"
mkdir -p data
case "$INPUT" in
    *.ice|*.squashfs|*.sqfs) if [ -f "$INPUT" ]; then FW=$(basename "$INPUT"); else die "$INPUT is not a file"; fi
        if [ "$(cd "$(dirname "$INPUT")" && pwd)/$FW" != "$HERE/data/$FW" ]; then
            say "copying $FW -> data/ ..."; cp "$INPUT" "data/$FW"
        fi ;;
    *)
        [ -d "$INPUT" ] || die "unsupported input (need .ice, .squashfs, .sqfs or a directory): $INPUT"
        if ! command -v mksquashfs >/dev/null 2>&1; then
            say "mksquashfs missing — installing squashfs-tools ..."
            if command -v apt-get >/dev/null; then $SUDO apt-get update -qq && $SUDO apt-get install -y squashfs-tools
            elif command -v dnf >/dev/null; then $SUDO dnf install -y squashfs-tools
            elif command -v yum >/dev/null; then $SUDO yum install -y squashfs-tools
            elif command -v apk >/dev/null; then $SUDO apk add squashfs-tools
            elif command -v brew >/dev/null; then brew install squashfs
            else die "cannot install squashfs-tools automatically; install it and re-run"; fi
        fi
        NAME=$(basename "$(cd "$INPUT" && pwd)"); FW="$NAME.squashfs"
        say "mksquashfs $INPUT -> data/$FW (zstd; may take a while) ..."
        mksquashfs "$INPUT" "data/$FW" -comp zstd -noappend ;;
esac
[ -s "data/$FW" ] || die "data/$FW is empty/missing"
say "firmware ready: data/$FW"

# 2b. credentials -> ./.env (compose auto-loads it; existing keys are kept)
touch .env; chmod 600 .env
envset() { grep -q "^$1=" .env || { [ -n "$2" ] && echo "$1=$2" >> .env; } || true; }
rand() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
envset ENABLE_VNC "${ENABLE_VNC:-false}"
envset VNC_PASSWORD "${VNC_PASSWORD:-tesla}"
envset WEBUI_USER "${WEBUI_USER:-admin}"
envset WEBUI_PASSWORD "${WEBUI_PASSWORD:-$(rand 16)}"
envget() { grep "^$1=" .env | tail -n1 | cut -d= -f2-; }
ENABLE_VNC=$(envget ENABLE_VNC); VNC_PASSWORD=$(envget VNC_PASSWORD)
WEBUI_USER=$(envget WEBUI_USER); WEBUI_PASSWORD=$(envget WEBUI_PASSWORD)

# 3. build + up
say "docker compose build && up -d ..."
$DC build
$DC up -d

# 4. wait for control plane, select firmware, start
T() { docker exec tesla-ui teslactl "$@"; }
i=0
until T status >/dev/null 2>&1; do
    i=$((i+1)); [ $i -le 60 ] || die "container control plane never came up ($DC logs tesla-ui)"; sleep 1
done
# effective web password (the container may have generated/replaced a blank/weak one)
EFF=$(docker exec tesla-ui cat /run/tesla/webui_password 2>/dev/null || true)
[ -z "$EFF" ] || WEBUI_PASSWORD=$EFF
say "selecting firmware $FW"
T firmware select "$FW"
T start

# 5. wait for UI
say "waiting up to ${WAIT_SECS}s for QtCar ..."
i=0; UP=0
while [ $i -lt "$WAIT_SECS" ]; do
    if T status 2>/dev/null | grep -Eq 'QtCar +UP'; then UP=1; break; fi
    i=$((i+5)); sleep 5
done
if [ "$UP" = 1 ]; then say "QtCar is UP"
else say "WARNING: QtCar not UP after ${WAIT_SECS}s — check: docker exec tesla-ui teslactl logs 200  /  teslactl debug"; fi

# 6. report
HOSTREF=${INSTALL_REMOTE_HOST:-<user@host>}
cat <<EOT

============================================================
 tesla-docker ready   (firmware: $FW)
 Credentials (also in ./.env; second layer behind the SSH tunnel):
   Web UI / API  : user=$WEBUI_USER  password=$WEBUI_PASSWORD   (HTTP Basic Auth)
   VNC (noVNC/raw): password=$VNC_PASSWORD   (VNC uses only the first 8 chars)
   Raw VNC on :5900 is $( [ "$ENABLE_VNC" = true ] && echo ENABLED || echo "OFF (enable: ENABLE_VNC=true in .env + compose up -d, or live: docker exec tesla-ui teslactl vnc on)" )
EOT
if [ -n "${INSTALL_REMOTE_HOST:-}" ]; then
cat <<EOT

 On your workstation, open a tunnel:
   ssh -N -L 8080:127.0.0.1:8080 -L 6080:127.0.0.1:6080 -L 5900:127.0.0.1:5900 $HOSTREF
EOT
else
cat <<EOT

 Ports are bound to 127.0.0.1 on this machine. From another machine, tunnel:
   ssh -N -L 8080:127.0.0.1:8080 -L 6080:127.0.0.1:6080 -L 5900:127.0.0.1:5900 <user@this-host>
EOT
fi
cat <<EOT

 URLs (after the tunnel):
   Web UI + API : http://127.0.0.1:8080/
   noVNC (web)  : http://127.0.0.1:6080/vnc.html?autoconnect=1   (password: $VNC_PASSWORD)
   Raw VNC      : localhost:5900   (RealVNC/TigerVNC viewer; only when raw VNC is ON)
   API example  : curl -u '$WEBUI_USER:$WEBUI_PASSWORD' 'http://127.0.0.1:8080/cgi-bin/api?action=status'
 Control: docker exec tesla-ui teslactl status | logs -f | restart
============================================================
EOT
