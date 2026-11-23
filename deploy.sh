#!/bin/sh
# deploy.sh — thin one-command wrapper around docker compose (the primary path).
# A-Z: build the engine image, run it with the right caps/limits (from
# docker-compose.yml), and print the access URLs. Works locally or against an
# SSH host.
#
# For the full one-command flow INCLUDING firmware prep, firmware selection and
# credentials, use ./install.sh <firmware> [--target user@host]. deploy.sh is the
# lifecycle wrapper (up/down/restart/logs/status) for an already-installed stack.
#
# Usage:
#   ./deploy.sh [up|down|restart|logs|status]      # local (default: up)
#   TARGET=user@host ./deploy.sh up                # remote over SSH
#
# Env:
#   TESLA_IMAGE   image tag            (default tesla-docker:latest)
#   DATA          host firmware dir    (default ./data)
#   TARGET        ssh host or "local"  (default local)
set -eu

CMD=${1:-up}
TESLA_IMAGE=${TESLA_IMAGE:-tesla-docker:latest}
DATA=${DATA:-./data}
TARGET=${TARGET:-local}
export TESLA_IMAGE

# docker compose (v2) or docker-compose (v1)
dc() {
    if docker compose version >/dev/null 2>&1; then docker compose "$@";
    else docker-compose "$@"; fi
}

run_local() {
    mkdir -p "$DATA"
    case "$CMD" in
        up)       dc up -d --build ;;
        down)     dc down ;;
        restart)  dc restart ;;
        logs)     dc logs -f ;;
        status)   dc ps; dc exec tesla-ui teslactl status || true ;;
        *) echo "usage: $0 [up|down|restart|logs|status]" >&2; exit 2 ;;
    esac
    print_urls
}

run_remote() {
    # Copy the build context to the host, then compose there.
    DIR=$(basename "$(pwd)")
    echo "[deploy] syncing to $TARGET:~/$DIR ..."
    # shellcheck disable=SC2086
    tar --exclude=./data --exclude='./.git' -cf - . | ssh "$TARGET" "mkdir -p ~/$DIR && tar -C ~/$DIR -xf -"
    echo "[deploy] running 'docker compose $CMD' on $TARGET ..."
    ssh "$TARGET" "cd ~/$DIR && TESLA_IMAGE=$TESLA_IMAGE $(compose_remote_cmd)"
    cat <<EOF

[deploy] Done on $TARGET.
Tunnel the UI to your workstation:
  ssh -N -L 8080:127.0.0.1:8080 -L 6080:127.0.0.1:6080 -L 5900:127.0.0.1:5900 $TARGET
Then open:  http://127.0.0.1:8080/   (Basic Auth; creds in $TARGET:~/$DIR/.env or: docker exec tesla-ui cat /run/tesla/webui_password)
Raw VNC (only if enabled: teslactl vnc on): localhost:5900
EOF
}

compose_remote_cmd() {
    case "$CMD" in
        up)      echo "(docker compose up -d --build || docker-compose up -d --build)" ;;
        down)    echo "(docker compose down || docker-compose down)" ;;
        restart) echo "(docker compose restart || docker-compose restart)" ;;
        status)  echo "(docker compose ps || docker-compose ps)" ;;
        logs)    echo "(docker compose logs --tail=200 || docker-compose logs --tail=200)" ;;
        *) echo "true" ;;
    esac
}

print_urls() {
    [ "$CMD" = up ] || return 0
    cat <<'EOF'

============================================================
 tesla-docker is up.
 Web UI + control API : http://127.0.0.1:8080/
 noVNC (also embedded): http://127.0.0.1:6080/vnc.html   (VNC password)
 Raw VNC (opt-in)     : localhost:5900 (ENABLE_VNC=true or teslactl vnc on)
 Web login            : see .env / docker exec tesla-ui cat /run/tesla/webui_password
 CLI                  : docker compose exec tesla-ui teslactl status
 Next:
   (easier: ./install.sh <firmware.ice|.squashfs|dir>)
   1) cp <firmware>.ice ./data/
   2) docker compose exec tesla-ui teslactl firmware select <firmware>.ice
   3) docker compose exec tesla-ui teslactl start
   4) open the web UI (tunnel first if remote)
============================================================
EOF
}

if [ "$TARGET" = local ]; then run_local; else run_remote; fi
