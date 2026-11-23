# tesla-docker

## One-command quickstart

```sh
./install.sh /path/to/firmware.ice            # or firmware.squashfs, or an extracted firmware dir
./install.sh /path/to/firmware.ice --target root@myhost   # build + run on a remote host over SSH
```

It validates docker+compose, puts the firmware in `./data/` (a directory is packed with
`mksquashfs`; a `.ice` is mounted directly), builds, starts, selects the firmware, waits for
QtCar, then **prints the SSH tunnel command, URLs and credentials**. Needs x86-64 + Docker.

Everything binds `127.0.0.1` only; **SSH tunnel is the transport**, and app-level passwords are
the second layer. Tunnel (both screens):
```sh
ssh -N -L 8080:127.0.0.1:8080 -L 6080:127.0.0.1:6080 -L 5900:127.0.0.1:5900 root@host
```
| what | open | auth |
|------|------|------|
| Web UI + HTTP API | http://127.0.0.1:8080/ | HTTP Basic: `WEBUI_USER` / `WEBUI_PASSWORD` |
| noVNC (browser, always on) | http://127.0.0.1:6080/vnc.html?autoconnect=1 | VNC password |
| Raw VNC (opt-in) | RealVNC/TigerVNC viewer to `localhost:5900` | VNC password |

### Config (set in `.env` next to `docker-compose.yml`; `install.sh` writes it)
| var | default | meaning |
|-----|---------|---------|
| `WEBUI_USER` | `admin` | Basic Auth user (web UI **and** `/cgi-bin/api`) |
| `WEBUI_PASSWORD` | random | **Required.** If blank/weak a random one is generated, logged (`docker logs tesla-ui`) and kept in `/run/tesla/webui_password` |
| `VNC_PASSWORD` | `tesla` | Password for noVNC + raw VNC (never run without; VNC uses only the first 8 chars) |
| `ENABLE_VNC` | `false` | Raw VNC on :5900. noVNC is unaffected. Live toggle without restart: `teslactl vnc on\|off` (or the web UI "Raw VNC" card). The compose mapping `127.0.0.1:5900:5900` is always present (host-loopback only); x11vnc only listens on the container interface when enabled. Changing the compose port mapping itself needs `docker compose up -d`. |
| `TESLA_GL`, `TESLA_RES`, `TESLA_TOUCH` | see Tuning | |

API: `curl -u admin:<pw> 'http://127.0.0.1:8080/cgi-bin/api?action=status'`.
LLM/agent entry point: [`AGENTS.md`](AGENTS.md).

A **firmware-agnostic** Tesla UI emulation platform, shipped as a Docker image.

The image contains the **engine only** — the X stack, software GL, touch
injection, a control plane and a web UI. It ships **no Tesla firmware and no
Tesla IP**, so it is safe to publish. You supply a Tesla UI firmware **SquashFS**
image out-of-band (into the `data/` volume); the engine mounts it read-only,
overlays a writable layer, applies agnostic mods, and boots `QtCar` into a
headless X server you view over noVNC in the browser.

```
browser ── :8080 web UI ──┐                      ┌─ Xvfb :0 ─ x11vnc ─ websockify :6080 ─ noVNC
                          ├─ teslactl (sh) ───────┤
docker exec teslactl ─────┘   (CLI + HTTP, same)  └─ bwrap[ merged root ] ─ QtCarDvServer + QtCar
                                                        ▲ touch_shim.so (LD_PRELOAD)
            x11_touch_bridge (XI2 → FIFO) ──────────────┘   sdv: presence/keep-awake DVs
```

## What's off-the-shelf vs bespoke
Prebuilt components (assembled, not re-implemented):
- **noVNC + websockify** — web VNC.
- **squashfuse + fuse-overlayfs** — read-only firmware mount + writable overlay.
- **bubblewrap (bwrap)** — namespaced sandbox into the merged root (cleaner than
  raw chroot: stable `/dev` `/proc` `/run`, auto teardown).
- **runit (`runsvdir`/`sv`) + tini** — PID1 + process supervision (non-Python).
- **busybox httpd** — web server + sh CGI.
- **Mesa** `swrast`/llvmpipe — software GL.

Bespoke Tesla glue only: `engine/initiator.sh`, `teslactl`, the C touch
`shim`/`bridge`, and the `sdv` presence sequence.

## No Python
Everything is pure `sh` + C. There is no Python anywhere in the image.

---

## A-Z: run it

### 0. Prereqs
- Docker (with `docker compose` v2) on an **x86-64** host (QtCar is x86-64).
- A Tesla UI firmware: a `.ice` (mounted directly via squashfuse at the `hsqs` offset), a `.squashfs`,
  or an extracted tree (`install.sh` packs it). To make a squashfs by hand from an extracted
  firmware tree:
  ```
  mksquashfs /path/to/firmware/2025.20.8 model3-2025.20.8.squashfs -comp zstd
  ```

### 1. Build + run (primary path — docker compose)
```
git clone <this repo> && cd tesla-docker
mkdir -p data
docker compose up -d --build
```
This builds the engine image and starts the container with the correct caps
(`SYS_ADMIN` + `/dev/fuse`, **not** `--privileged`), 4g / 4cpu limits, and ports
bound to `127.0.0.1` only.

> Lifecycle wrapper (up/down/restart/logs/status): `./deploy.sh up`. Full flow incl. firmware: `./install.sh`.

### 2. Add firmware (out-of-band)
```
cp model3-2025.20.8.squashfs data/        # or a .ice
docker compose exec tesla-ui teslactl firmware list
docker compose exec tesla-ui teslactl firmware select model3-2025.20.8.squashfs
```

### 3. Start the UI
```
docker compose exec tesla-ui teslactl start
docker compose exec tesla-ui teslactl logs -f      # watch it come up
```

### 4. Access
Local: open **http://127.0.0.1:8080/** (control panel with embedded noVNC; Basic Auth).

Remote host (no public ports): tunnel first, then use either screen:
```
ssh -N -L 8080:127.0.0.1:8080 -L 6080:127.0.0.1:6080 -L 5900:127.0.0.1:5900 root@host
```
- **Raw VNC**: enable (`ENABLE_VNC=true`, or `teslactl vnc on`), then point RealVNC/any viewer at `localhost:5900`, enter the VNC password.
- **noVNC (web)**: browse `http://127.0.0.1:6080/vnc.html?autoconnect=1` (or use the web UI's embedded pane).

### 5. Drive it
- Click in the noVNC pane → `x11_touch_bridge` turns clicks into touches.
- Presence/keep-awake data values are set automatically once QtCar is up; set
  more via the **Config** panel or `teslactl config set dv <name> <value>`.

---

## Remote deploy (SSH host, e.g. the compose stack on example.com)
```
./install.sh fw.ice --target root@example.com    # full flow
TARGET=root@example.com ./deploy.sh up            # lifecycle only
```
This rsync/tars the build context to the host (excluding `data/` and `.git`),
runs `docker compose up -d --build` there, and prints the tunnel command. Place
firmware on the host's `data/` dir and `teslactl start` as above. The container
is isolated from other compose services and never opens a public port.

---

## Control surface
`teslactl` (and the identical HTTP API) — see `docs/LLM_RUNBOOK.md` and
`docs/SKILL.md`:

| verb | effect |
|------|--------|
| `start` / `stop` / `restart` / `shutdown` | control the UI ("VM"). `shutdown` also unmounts firmware. |
| `status` | services, mounted firmware, process table, VNC URL |
| `logs [-f] [N]` | tail the engine log |
| `firmware list` / `firmware select <name>` | choose a `/data/*.ice`, `*.squashfs` or `*.sqfs` |
| `vnc on\|off\|status` | live toggle of raw VNC (:5900) |
| `config set dv <name> <value>` / `config get dv <name>` | live data value via `sdv` |
| `config set gw <id> <value>` / `config get gw <id>` | gateway config override |
| `debug` | diagnostics dump |
| `vnc-url` | print noVNC / VNC URLs |

---

## Tuning
- `TESLA_GL=llvmpipe` (compose env) — faster software GL (~29 FPS vs softpipe);
  the image ships both.
- `TESLA_RES=1920x1200` — framebuffer size.
- `TESLA_TOUCH=0` — view-only (disable the shim; use if a firmware build
  misbehaves with the touch shim — see `engine/shims/BUILD.md`).

## Running on a Mac (Lima, with limitations)
The Docker path above is **Linux-x86-first**: QtCar is x86-64, and on a Mac,
Docker Desktop gives neither GPU passthrough nor a native x86-64 CPU, so the
Docker image buys nothing there. If a Mac is the only machine you have, use
`mac/setup-mac.sh` instead — it runs a Lima (aarch64 Ubuntu + Rosetta) VM and
chroots QtCar directly in the guest. It works, but is view-only (no working
touch on this firmware build), software-rendered only (no GPU), and slower
than the native Linux path. Full matrix + exact limitations:
[`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md).

## Troubleshooting
- **`/dev/fuse missing`** → the container must run with `--device /dev/fuse`
  (compose sets this).
- **`squashfuse mount failed`** → check the image is a valid SquashFS and
  `SYS_ADMIN` is granted.
- **QtCar not found** → the selected squashfs isn't a QtCar UI build.
- **Black screen / no touch registering** → presence DVs; try
  `teslactl config set dv CD_displayState 1`. DV name spellings can differ per
  firmware build (see notes in `engine/initiator.sh`).
- **401 on the web UI** → use `WEBUI_USER`/`WEBUI_PASSWORD` (`.env`, or `docker exec tesla-ui cat /run/tesla/webui_password`).
- **Raw VNC refused** → it is opt-in: `teslactl vnc on`; also needs the tunnel to :5900.
- **noVNC blank** → ensure `teslactl start` ran and port 6080 is tunnelled.
- Everything logs to `docker compose logs -f` and to `teslactl logs -f`.
