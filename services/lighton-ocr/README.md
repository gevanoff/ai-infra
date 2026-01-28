# LightOnOCR-2-1B

FastAPI shim for LightOnOCR-2-1B that exposes a stable `POST /v1/ocr` contract and optional gateway tool integration.

## Recommended host

- **Default**: `ada2` (CUDA GPU) until proven small enough for `ai1`.
- **Possible**: `ai1` if you can run the model within <8GB VRAM or CPU-only inference.
- **macOS ai2**: Use only if the upstream runtime supports MPS/Core ML.

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

- Env template: `env/lighton-ocr.env.example`
- Runtime env: `/etc/lighton-ocr/lighton-ocr.env`

The shim supports:
- **Proxy mode** (`LIGHTON_OCR_UPSTREAM_BASE_URL`): forwards requests to an upstream server.
- **Subprocess mode** (`LIGHTON_OCR_RUN_COMMAND`): runs a local command per request. The command should read
  `LIGHTON_OCR_REQUEST_JSON` and write OCR output JSON to `LIGHTON_OCR_OUTPUT_JSON`. If present,
  `LIGHTON_OCR_INPUT_PATH` points to an input image file.

## Gateway integration (tool bus)

Install the tool wrapper and register it with the gateway:

```bash
sudo cp services/lighton-ocr/tools/lighton_ocr_tool.py /var/lib/gateway/tools/
sudo chmod 755 /var/lib/gateway/tools/lighton_ocr_tool.py
```

Then add a tool entry to `/var/lib/gateway/app/tools_registry.json` (see
`services/gateway/env/tools_registry.json.example`) and restart the gateway.
