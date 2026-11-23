# LLM runbook — driving tesla-docker

Machine-oriented control surface. Everything routes through `teslactl`, exposed
two identical ways: the CLI (`docker exec`) and HTTP (busybox CGI). Same scripts,
same logging — prefer the CLI when you have a shell to the host.

## Container handle
- Container name: `tesla-ui` (compose `container_name`).
- CLI prefix: `docker exec tesla-ui teslactl <verb> [args]`
  (or `docker compose exec tesla-ui teslactl ...` from the repo dir).
- HTTP base: `http://127.0.0.1:8080/cgi-bin/api?action=<action>` (tunnel if remote). **Basic Auth required**: `curl -u "$WEBUI_USER:$WEBUI_PASSWORD" ...` (see `.env` or `/run/tesla/webui_password`).
- noVNC: `http://127.0.0.1:6080/vnc.html` (VNC password). Raw VNC `localhost:5900` only when `ENABLE_VNC=true` / `teslactl vnc on`.

## Lifecycle (do this in order)
1. `docker compose up -d --build` (or `./deploy.sh up`).
2. Ensure firmware present: `teslactl firmware list`. If empty, a
   `*.ice`/`*.squashfs` must be placed in the host `./data/` dir first (out-of-band).
3. `teslactl firmware select <name>`.
4. `teslactl start`.
5. Poll `teslactl status` until `QtCar  UP`.
6. Read `teslactl logs -f` for progress; the `[engine]`/`[inner]`/`presence:`
   lines narrate mount → X stack → QtCar → DV application.

## Verb ↔ HTTP action map
| CLI | HTTP action | notes |
|-----|-------------|-------|
| `teslactl start` | `start` | removes the runit `down` file, `sv up engine` |
| `teslactl stop` | `stop` | `sv down engine` + sets `down` file |
| `teslactl restart` | `restart` | full clean relaunch (fixes X0 churn) |
| `teslactl shutdown` | `shutdown` | stop + unmount firmware |
| `teslactl status` | `status` | parse `QtCar  UP/down`, mount, selected fw |
| `teslactl logs -f [N]` | `logs&n=N` | HTTP returns last N lines (no follow) |
| `teslactl firmware list` | `firmware-list` | `*` marks selected |
| `teslactl firmware select <n>` | `firmware-select&name=<n>` | stops+unmounts first |
| `teslactl config set dv <k> <v>` | `config-set-dv&name=<k>&value=<v>` | live via `sdv` |
| `teslactl config get dv <k>` | `config-get-dv&name=<k>` | best-effort D-Bus get |
| `teslactl config set gw <id> <v>` | `config-set-gw&id=<id>&value=<v>` | stored override |
| `teslactl config get gw <id>` | `config-get-gw&id=<id>` | override or default |
| `teslactl debug` | `debug` | mounts, procs, dbus names, X clients, `/dev/fuse`, log tail |
| `teslactl vnc-url` | `vnc-url` | prints URLs |
| `teslactl vnc on\|off\|status` | `vnc-on` / `vnc-off` / `vnc-status` | live raw-VNC toggle (x11vnc bind); web UI has a card for it |

## Reading state / debugging
- `teslactl status` — one-shot health (services + per-process UP/down + mount + VNC).
- `teslactl debug` — deeper: `mount`, process table, `com.tesla.*` D-Bus names,
  `xlsclients`, `/dev/fuse` presence, last 40 log lines.
- `teslactl logs 500` — last 500 engine-log lines.
- `docker compose logs -f tesla-ui` — raw stdout (entrypoint + runit + services).

## Presence / keep-awake (why the screen may be black)
QtCar gates display+touch on user presence. The initiator auto-applies, once
QtCar registers `com.tesla.Debug`:
`GUI_keepVehicleAwakeDiagToolConnected=true`, `CD_displayState=1`,
`VAPI_driverPresent=true`, `VAPI_keyfobPresent=true`, `GUI_passengerPresent=true`.
If a build uses different DV names, set them yourself:
`teslactl config set dv <Name> <value>`. `sdv` only works **after** QtCar is up.

## Touch
Clicks in noVNC → `x11_touch_bridge` (XI2) → FIFO `/tesla/tmp/touch_cmd` →
`touch_shim.so` (LD_PRELOAD in QtCar) → synthetic evdev. Disable with
`TESLA_TOUCH=0` (view-only) if a build misbehaves.

## Safety / scope
- Never run with `--privileged`; the compose file uses `SYS_ADMIN` + `/dev/fuse`.
- Do not commit or copy firmware into the image or repo (IP-safe boundary).
- Ports stay on `127.0.0.1`; reach them via SSH tunnel. App passwords (WEBUI_*, VNC_PASSWORD) are the second layer; never run without them.
