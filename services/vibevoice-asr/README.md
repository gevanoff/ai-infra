# VibeVoice-ASR

FastAPI shim for VibeVoice-ASR exposing OpenAI-compatible `POST /v1/audio/transcriptions`.

## Recommended host

- **ada2** (NVIDIA GPU) by default.
- **ai1** if the model runs within <8GB VRAM or CPU mode.
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

- Env template: `env/vibevoice-asr.env.example`
- Runtime env: `/etc/vibevoice-asr/vibevoice-asr.env`

The shim supports:
- **Proxy mode** (`VIBEVOICE_ASR_UPSTREAM_BASE_URL`): forwards OpenAI ASR requests to an upstream server.
- **Subprocess mode** (`VIBEVOICE_ASR_RUN_COMMAND`): runs a command per request. The command should read
  `VIBEVOICE_ASR_INPUT_PATH` and write JSON to `VIBEVOICE_ASR_OUTPUT_JSON`.
