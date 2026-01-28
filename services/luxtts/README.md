# LuxTTS

FastAPI shim for LuxTTS exposing OpenAI-compatible `POST /v1/audio/speech`.

## Recommended host

- **ai1** if the model fits within <8GB VRAM or supports CPU inference.
- **ada2** if CUDA is required or performance is insufficient on ai1.
- **macOS ai2** if upstream supports MPS/Core ML.

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

- Env template: `env/luxtts.env.example`
- Runtime env: `/etc/luxtts/luxtts.env`

The shim supports:
- **Proxy mode** (`LUXTTS_UPSTREAM_BASE_URL`): forwards OpenAI TTS requests to an upstream server.
- **Subprocess mode** (`LUXTTS_RUN_COMMAND`): runs a command per request. The command should read
  `LUXTTS_REQUEST_JSON` and write audio to `LUXTTS_OUTPUT_PATH`.
