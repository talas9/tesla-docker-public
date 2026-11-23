# Agnostic mods

Firmware-independent assets the initiator installs into / applies against the
merged firmware root. None of these are Tesla IP.

| File | Purpose |
|------|---------|
| `swrast_dri_nollvm.so` | Mesa **softpipe** software GL driver (zero external deps, no GLIBC/LLVM version coupling). Copied into the merged root at `/usr/lib/dri/swrast_dri.so` so QtCar renders with `GALLIUM_DRIVER=softpipe`. The image also ships `libgl1-mesa-dri` (llvmpipe) as a faster alternative — select with `TESLA_GL=llvmpipe`. |
| `model3_gateway_values.json` | **Reference** Model 3 gateway/vehicle-config values (92 config IDs, from `rootedmodel3securedconfig.bin` + UDS logs). Used as the default seed for the gateway config editor. |
| `GATEWAY_PROTOCOL.md` | **Reference** for the gateway UDP API (`:3500`, read `0x0b00<id>`, write `0x0c00<id><val>`, promote/unlock) and the config-ID map. |

The gateway values are a *reference template* only — the emulated gateway is a
stand-in. Real CAN/UDP gateway behaviour is out of scope for the UI engine.
