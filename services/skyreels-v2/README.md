# SkyReels-V2

Linux/macOS shim for SkyReels-V2 video generation that exposes `POST /v1/videos/generations` and can
be consumed via the gateway tool bus.

## Recommended host

- **ada2** (NVIDIA GPU). Video generation is GPU-heavy.
- **macOS ai2** only if upstream supports MPS/Core ML.

## Install

```bash
./scripts/install.sh
```

## Deploy/update

```bash
./scripts/deploy.sh
```

## Restart / uninstall

```bash
./scripts/restart.sh
./scripts/status.sh
./scripts/uninstall.sh
```

## Configuration

- Env template: `env/skyreels-v2.env.example`
- Runtime env: `/etc/skyreels-v2/skyreels-v2.env`

The shim supports:
- **Proxy mode** (`SKYREELS_UPSTREAM_BASE_URL`): forwards requests to an upstream server.
- **Subprocess mode** (`SKYREELS_RUN_COMMAND`): runs a command per request. The command receives
  `SKYREELS_REQUEST_JSON` and `SKYREELS_OUTPUT_DIR`.

## PyTorch wheels (install-time)

Some GPU hosts need a specific PyTorch wheel index (CUDA vs CPU). The installer supports both a
fleet-wide default and a per-service override.

- Global (all services that opt-in): `AI_TORCH_INDEX_URL` or `AI_TORCH_EXTRA_INDEX_URL`
- SkyReels-specific override: `SKYREELS_TORCH_INDEX_URL` or `SKYREELS_TORCH_EXTRA_INDEX_URL`

Common values for `*_TORCH_INDEX_URL`:

- CUDA 12.1: `https://download.pytorch.org/whl/cu121`
- CPU only: `https://download.pytorch.org/whl/cpu`

## Gateway integration (tool bus)

```bash
sudo cp services/skyreels-v2/tools/skyreels_generate.py /var/lib/gateway/tools/
sudo chmod 755 /var/lib/gateway/tools/skyreels_generate.py
```

Then register the tool in `/var/lib/gateway/app/tools_registry.json` and restart the gateway.
