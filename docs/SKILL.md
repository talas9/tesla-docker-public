---
name: tesla-docker
description: "Control the tesla-docker firmware-agnostic Tesla UI emulator. Use when asked to start/stop/inspect the Tesla UI, select firmware, set data values (sdv) or gateway config, or read engine logs. Pure sh + C engine; control via `teslactl` (CLI) or the identical HTTP API."
---

# tesla-docker control skill

A Docker image that boots a Tesla `QtCar` UI from a firmware **.ice / SquashFS** you
supply out-of-band. Engine-only image (no Tesla IP). Control plane = `teslactl`,
exposed identically as a CLI and an HTTP API.

## When to use
- "start / stop / restart the Tesla UI", "boot QtCar", "show the screen"
- "pick firmware X", "list firmware"
- "set CD_displayState / a data value", "set gateway config id N"
- "why is the screen black", "is touch working", "show engine logs"

## Prereqs check
```
docker ps --filter name=tesla-ui          # container running?
docker exec tesla-ui teslactl status      # engine health
docker exec tesla-ui teslactl firmware list
```
If no container: `./install.sh <firmware.ice|.squashfs|dir> [--target user@host]` (one command), or `docker compose up -d --build`.
If no firmware listed: a `*.ice` / `*.squashfs` must be copied into the host `./data/` dir.

## Golden path
```
docker exec tesla-ui teslactl firmware select <name>.squashfs
docker exec tesla-ui teslactl start
docker exec tesla-ui teslactl logs -f        # wait for presence: lines + "QtCar  UP"
```
View: tunnel `ssh -N -L 8080:127.0.0.1:8080 -L 6080:127.0.0.1:6080 -L 5900:127.0.0.1:5900 <host>`, open
`http://127.0.0.1:8080/` (Basic Auth: WEBUI_USER/WEBUI_PASSWORD) or noVNC `:6080/vnc.html`; raw VNC `localhost:5900` after `teslactl vnc on`.

## Every verb
`start | stop | restart | shutdown | status | logs [-f] [N] |
firmware list | firmware select <name> |
config get dv <name> | config set dv <name> <value> |
config get gw <id> | config set gw <id> <value> |
vnc on|off|status | debug | vnc-url | help`

HTTP equivalent (Basic Auth): `curl -u user:pw 'http://<host>:8080/cgi-bin/api?action=<a>&<params>'`
(action names and params in `docs/LLM_RUNBOOK.md`).

## Decision hints
- **Black screen** → `teslactl config set dv CD_displayState 1`; confirm
  `teslactl debug` shows `com.tesla.*` on the bus (else QtCar isn't up yet).
- **Touch ignored** → ensure `TESLA_TOUCH=1`; presence DVs set? If a build
  aborts with the shim, relaunch with `TESLA_TOUCH=0` for view-only.
- **Mount errors** → `teslactl debug` → check `/dev/fuse` present and
  `SYS_ADMIN` granted; the container must not be `--privileged`.
- **Switch firmware** → `firmware select` auto-stops + unmounts; then `start`.
- **Stuck/looping** → `teslactl restart` (full clean relaunch).

## Invariants (do not violate)
- Never bake firmware into the image or commit it to the repo.
- Never use `--privileged`; caps are `SYS_ADMIN` + `/dev/fuse`.
- `sdv` / `config set dv` only work after QtCar is up.
- No Python — the engine is sh + C only.
