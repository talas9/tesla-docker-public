# Platform compatibility

This engine's **primary, supported path is Linux x86-64 + Docker** (`./install.sh`,
see `README.md`). Everything below is about what happens off that path, in
particular on a Mac, documented honestly rather than left for someone to
discover the hard way.

| platform | path | GPU | speed | status |
|---|---|---|---|---|
| **Linux x86-64** | `./install.sh` → Docker (this repo) | software (llvmpipe/softpipe) | fastest of the software options, ~29 FPS llvmpipe | **recommended** — this is what the repo is built for |
| **macOS, Docker Desktop** | `docker compose up` on Mac | none | slow | **not recommended** — see below |
| **macOS, Lima + Rosetta** | `mac/setup-mac.sh` (chroot, not this repo's Docker image) | none (software only) | slower than native Linux | **works, with limits** — see below |

## Linux x86-64 + Docker — recommended
QtCar is an x86-64 binary. On an x86-64 Linux host, Docker runs it natively —
no translation layer, no nested virtualization. This is the only path that
gets Mesa `llvmpipe` (~29 FPS) with no extra glibc/library work. Use
`./install.sh`.

## Docker on a Mac — not recommended
Docker Desktop on macOS does not run containers on macOS directly: it runs a
Linux VM (via Apple's Virtualization.framework / HyperKit) and your containers
run inside *that* VM. Two problems stack on a Mac, neither fixable from inside
the container:
1. **No GPU passthrough.** The Docker Desktop Linux VM has no path to the
   Mac's GPU, so Mesa software rendering is the ceiling regardless — same as
   Linux, except:
2. **x86-64 emulation.** On Apple Silicon, the image's x86-64 binaries
   (QtCar, QtCarDvServer) run under QEMU emulation inside that Linux VM, not
   under Rosetta — Docker Desktop's "Rosetta for x86/amd64 emulation" setting
   accelerates *some* binary translation but does not give the container a
   native x86-64 CPU the way a real x86-64 host, or a VM with Rosetta's
   `binfmt` hook (see below), does.

Net: running this repo's Docker image on a Mac buys nothing over the Linux
path and costs you an extra, slower translation layer. If you're on a Mac and
want to run the Tesla UI at all, use the Lima+Rosetta path instead — it does
not use this repo's Docker image.

## macOS via Lima + Rosetta — works, with limits
This is a **separate, proven recipe** (not this repo's bwrap/teslactl engine):
an aarch64 Ubuntu VM (via [Lima](https://github.com/lima-vm/lima), Apple's
`vz` backend) with **Rosetta's `binfmt_misc` hook enabled**, so an **x86-64
QtCar binary runs *inside the Linux guest* under Rosetta** — not QEMU
emulation, not Docker's nested-VM translation. The firmware tree is populated
into the guest and QtCar is launched from a `chroot`, not a container.

Run it with `mac/setup-mac.sh`. What it gets you, and what it doesn't:

### What works
- Full Model 3 QtCar UI renders, verified via VNC screenshot.
- Mesa **softpipe** (always works) — zero extra dependencies, x86-64, no
  glibc version requirement.
- Mesa **llvmpipe** (optional, faster — ~29 FPS vs softpipe) — needs a glibc
  shim because the firmware's own glibc caps out at **2.35**, but the guest's
  native (jammy-equivalent) `libLLVM-15` on a newer Ubuntu release wants
  **glibc 2.36+**. Fix: pull the **Ubuntu 22.04 (jammy) amd64** build of
  `libllvm15`/`libzstd1`/`libz3-4` instead (built against glibc 2.35) and copy
  their `.so`s in. Exact commands are in `mac/setup-mac.sh`.
- VNC + noVNC access — Lima auto-forwards `127.0.0.1:5900` to the guest, so
  the host never needs its own tunnel for VNC; noVNC is bolted on top via the
  same `websockify`/`novnc` packages this repo's Docker image already uses.

### What does not work / limitations
- **No GPU.** Confirmed: Apple's `vz` framework gives Linux guests no 3D
  acceleration and no GPU passthrough. Software rendering (llvmpipe/softpipe)
  is the hard ceiling — there is no setting that fixes this.
- **Slower than native Linux.** Every QtCar instruction runs under Rosetta's
  binary translation inside the guest; expect noticeably lower frame rates
  than the Linux-native Docker path even with llvmpipe.
- **Touch is unsolved on this path.** The same `touch_shim.c` LD_PRELOAD shim
  this repo ships hits an ABI/symbol mismatch against this firmware build
  (`*** buffer overflow detected ***` when combined with
  `--touch evdev:/dev/input/touch`, or a blanked display with the shim alone
  but no `--touch`). QtCar renders fine **without** the shim — view-only.
  See `engine/shims/BUILD.md` for the same caveat in the Docker engine.
- **Operational gotcha — the X0 socket vanishes under churn.** Killing QtCar
  alone (instead of a full Xvfb+X0 relaunch) under repeated restarts can
  delete `/tmp/.X11-unix/X0`, after which QtCar can't connect and exits.
  `mac/setup-mac.sh` always does a full, clean relaunch of the X stack rather
  than restarting QtCar in place.
- **Display choice: VNC/noVNC vs native XQuartz.** Native output via XQuartz
  (`DISPLAY=<lima-guest-ip>:0` with `xhost +` on the Mac side — Lima NATs the
  guest, so IP-based `xhost` access fails with "Authorization required" and
  the plain, unqualified `xhost +` is what's needed) is possible, but
  indirect-GLX over that path is slow. **VNC/noVNC is smoother** for day to
  day use; `mac/setup-mac.sh` sets up VNC/noVNC by default.

### Bottom line
If you have access to an x86-64 Linux box (bare metal, cloud VM, whatever),
use `./install.sh` there — it is faster, simpler, and gets you the real touch
path this repo implements. The Lima+Rosetta route exists for when a Mac is
the only machine available, and is view-only (no working touch) with a
software-rendering ceiling.
