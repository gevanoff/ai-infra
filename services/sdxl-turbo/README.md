# SDXL Turbo

This service runs a lightweight FastAPI shim around the Diffusers SDXL Turbo pipeline.

## Install (Ubuntu 22.04)

```bash
sudo ./services/sdxl-turbo/scripts/install.sh
```

## Configure

Edit the environment file installed at `/etc/sdxl-turbo/sdxl-turbo.env` and adjust model, device,
cache, or defaults. You can also set `SDXL_TURBO_TORCH_PIP` and `SDXL_TURBO_TORCH_INDEX_URL`
before running `install.sh` to control the PyTorch wheel that is installed.

## Deploy updates

```bash
sudo ./services/sdxl-turbo/scripts/deploy.sh
```

## Uninstall

```bash
sudo ./services/sdxl-turbo/scripts/uninstall.sh
```

## API

- `GET /health`
- `GET /readyz`
- `GET /v1/models`
- `POST /v1/generate`

Example request:

```bash
curl -X POST http://localhost:9050/v1/generate \
  -H "Content-Type: application/json" \
  -d '{"prompt": "a cinematic photo of a cat astronaut"}'
```

The response includes a base64-encoded PNG under `data[0].b64_json`.
