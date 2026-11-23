# AGENTS.md — tesla-docker (LLM entry point)

Firmware-agnostic Tesla UI (`QtCar`) emulator in Docker. Engine only: **no firmware/Tesla IP in the repo or image**.
You supply a `.ice`, `.squashfs` or extracted dir out-of-band. Pure sh + small C shims. Detail: `docs/LLM_RUNBOOK.md`, skill: `docs/SKILL.md`, humans: `README.md`.

## Deploy (one command)
```sh
./install.sh <firmware.ice | firmware.squashfs | firmware-dir> [--target user@host]
```
Checks docker/compose, stages firmware into `./data/` (dir -> `mksquashfs`), `compose build && up -d`, selects firmware, starts, waits for `QtCar UP`, prints tunnel + URLs + credentials (also in `./.env`). `--target` rsyncs repo+firmware and runs it remotely. `./deploy.sh up|down|restart|logs|status` = lifecycle only. **Do not run docker if it is not installed locally.**

## teslactl (container `tesla-ui`: `docker exec tesla-ui teslactl <verb>`)
`start | stop | restart | shutdown | status | logs [-f] [N] | firmware list | firmware select <name> | config get|set dv <name> [val] | config get|set gw <id> [val] | vnc on|off|status | debug | vnc-url | help`
(`firmware select` stops+unmounts first; `.ice`/`.squashfs`/`.sqfs` from `/data`.)

## HTTP API (HTTP Basic Auth required: `curl -u "$WEBUI_USER:$WEBUI_PASSWORD" ...`)
`http://127.0.0.1:8080/cgi-bin/api?action=` `status | start | stop | restart | shutdown | logs&n=N | firmware-list | firmware-select&name= | config-get-dv&name= | config-set-dv&name=&value= | config-get-gw&id= | config-set-gw&id=&value= | vnc-status | vnc-on | vnc-off | vnc-url | debug`

## Access (everything binds 127.0.0.1; SSH tunnel = transport, passwords = 2nd layer)
`ssh -N -L 8080:127.0.0.1:8080 -L 6080:127.0.0.1:6080 -L 5900:127.0.0.1:5900 root@host`
- Web UI/API `:8080` (Basic Auth `WEBUI_USER`/`WEBUI_PASSWORD`; blank => random, logged, in `/run/tesla/webui_password`)
- noVNC `:6080/vnc.html?autoconnect=1` always on (VNC password)
- Raw VNC `localhost:5900` (RealVNC etc.): opt-in `ENABLE_VNC=true` in `.env`, or live `teslactl vnc on`. `VNC_PASSWORD` default `tesla` (8 significant chars).

## Logs / debug
`teslactl status` (health) -> `teslactl debug` (mounts, procs, dbus, X clients, log tail) -> `teslactl logs -f` -> `docker compose logs -f tesla-ui`. Log tags: `[engine] [inner] [teslactl] presence:`. Files in container: `/var/log/tesla/{engine,xvfb,x11vnc,novnc}.log`.

## Add a firmware
Copy `.ice`/`.squashfs` into `./data/` (or re-run `install.sh`), `teslactl firmware list`, `firmware select <name>`, `start`. `.ice` = squashfs + verity/FEC/sig trailer; mounted by finding `hsqs` offset (`engine/fwlib.sh`) with `squashfuse -o offset=N`.

## Running on a Mac (Lima, with limitations)
This engine's Docker path is **Linux-x86-first** — x86-64 host required.
Docker Desktop on a Mac has no GPU passthrough and no native x86-64 CPU, so it
gives no benefit there; do not route a Mac user through `./install.sh`
expecting a good result. Instead point them at `mac/setup-mac.sh`, which runs
a separate, proven Lima (aarch64 Ubuntu + Rosetta) VM + chroot path — it does
NOT use this repo's Docker image/teslactl. Limitations: view-only (touch
unsolved on this firmware build), software rendering only (no GPU), slower
than native Linux. Full detail: `docs/COMPATIBILITY.md`.

## Gotchas
- Black screen / no input: QtCar gates on presence; initiator sets DVs via `sdv` only AFTER QtCar registers `com.tesla.Debug` (`config set dv` also needs QtCar up). Names can differ per firmware.
- `TESLA_TOUCH=0` default (fw 2025.20.8 touch_shim aborts QtCar); view-only until fixed (`engine/shims/BUILD.md`).
- `TESLA_GL=softpipe` default; `llvmpipe` optional and faster (~29 FPS).
- Needs `SYS_ADMIN`, `SYS_NICE`, `/dev/fuse`, seccomp+apparmor unconfined (bwrap pivot_root); never `--privileged`.
- x86-64 host only. Changing compose port mappings needs `compose up -d`; `vnc on|off` is live.
- Never commit firmware/keys (`.gitignore` blocks `data/`, `*.ice`, `*.squashfs`, `.env`).
