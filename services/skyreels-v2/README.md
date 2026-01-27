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

## Gateway integration (tool bus)

```bash
sudo cp services/skyreels-v2/tools/skyreels_generate.py /var/lib/gateway/tools/
sudo chmod 755 /var/lib/gateway/tools/skyreels_generate.py
```

Then register the tool in `/var/lib/gateway/app/tools_registry.json` and restart the gateway.
