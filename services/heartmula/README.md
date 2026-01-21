# heartmula (music generator)

macOS launchd-managed HeartMula music generation service.

This service is intended to run **only on localhost** (bind `127.0.0.1`) and be consumed by the gateway via an HTTP base URL.

## What you edit

- Systemd template: `systemd/com.heartmula.server.service.example`
  - Update `EnvironmentFile` values in `/etc/heartmula/heartmula.env` to match your installation.
  - Keep `HEARTMULA_HOST=127.0.0.1` (or equivalent) so it is not exposed to the LAN.
  - The port is arbitrary; pick one and keep the gateway pointed at it.

## Runtime layout

- Runtime dir: `/var/lib/heartmula`
- Logs managed via `journalctl -u com.heartmula.server.service`

## Installation (ada2 / Ubuntu/Debian-like)

We provide an idempotent installer `install_ada2.sh` that attempts to perform the following steps on a CUDA-capable Ubuntu/Debian server (ada2):

1. Install system packages (build tools, Python 3.10, libs)
2. Create a `heartmula` system user and `/var/lib/heartmula`
3. Create a Python venv at `/var/lib/heartmula/env`
4. Install PyTorch (attempts CUDA wheel if GPU detected, otherwise CPU wheel)
5. Attempt to install optional `triton` (best-effort)
6. Clone `heartlib` and `pip install -e` it into the venv
7. Create `/etc/heartmula/heartmula.env` with defaults (including `HEARTMULA_DEVICE=cuda` and `HEARTMULA_DTYPE=float16`)
8. Install systemd service and start it

To run the installer on ada2 (SSH into the host):

```bash
# On ada2 as a user with sudo
cd /path/to/ai-infra/services/heartmula/scripts
sudo ./install_ada2.sh
```

If you need to redeploy the service after changing env or code, use the `deploy_ada2.sh` helper:

```bash
sudo ./deploy_ada2.sh
```

Notes & troubleshooting

- CUDA & drivers: The installer will detect `nvidia-smi`. If `nvidia-smi` is absent, the script will still install a CPU PyTorch wheel as a fallback but HeartMula performance will be severely limited. Install the correct NVIDIA drivers + CUDA toolkit for ada2 before running the installer for best results.
- Triton: The installer will try to `pip install triton` (best-effort). Triton support is optional and may require additional configuration; if Triton install fails, check the pip error and consider installing a matching Triton wheel for your CUDA version.

## Gateway integration

Point the gateway at the HeartMula HTTP endpoint (example values shown):

```
HEARTMULA_BASE_URL=http://ada2:9920
HEARTMULA_TIMEOUT_SEC=600  # long runs may require higher timeouts
```

> **Timeouts:** Generating audio can take longer than a typical HTTP request timeout. The gateway uses `HEARTMULA_TIMEOUT_SEC` (default 120s). If you expect longer runs, increase the gateway timeout (for example `HEARTMULA_TIMEOUT_SEC=600`) or set a duration-aware timeout in your gateway/backends config. The gateway includes a heuristic to extend the timeout based on the `duration` field in requests, but very long generations may still require a higher global timeout.

Use the same host/port you configured in the launchd plist. The gateway host should be able to reach this URL (either localhost or a LAN address if you move HeartMula to a different machine).

## Notes

- The plist runs HeartMula under a dedicated `heartmula` user by default. Create it first (or set `HEARTMULA_USER` and edit the plist `UserName`).
- launchd does not read `.env` files automatically; encode required env vars under `EnvironmentVariables` in the plist.

Environment variables you may want to set:

- `HEARTMULA_MODEL_PATH` — path to model checkpoints (default: `/var/lib/heartmula/ckpt`).
- `HEARTMULA_OUTPUT_DIR` — where generated audio is written (default: `/var/lib/heartmula/output`).
- `HEARTMULA_VERSION` — model version to load (default: `3B`).
- `HEARTMULA_DTYPE` — `float32` or `float16` (use `float16` only with CUDA devices).
- `HEARTMULA_DEVICE` — preferred device (`cpu`, `cuda`, or `mps`). **Default is CUDA if available, otherwise CPU.** Use `HEARTMULA_DEVICE=cpu` to force CPU.
- `HEARTMULA_FORCE_MPS` — set to `1` to force MPS even though it may lack full autocast support (use at your own risk).

Notes about MPS: By default the server avoids using MPS autocast due to limited support; if you must run on Apple Silicon and understand the limitations, set `HEARTMULA_DEVICE=mps` and `HEARTMULA_FORCE_MPS=1` in the plist.

## Recommended HeartMula command

The service runs the FastAPI server automatically:

- `python /var/lib/heartmula/heartmula_server.py` (runs on 127.0.0.1:9920)
