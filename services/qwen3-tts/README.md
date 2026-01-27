# Qwen3-TTS

FastAPI shim for Qwen3-TTS exposing OpenAI-compatible `POST /v1/audio/speech`.

## Recommended host

- **ada2** (NVIDIA GPU) by default.
- **ai1** only if the model can run in <8GB VRAM or CPU mode.
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

- Env template: `env/qwen3-tts.env.example`
- Runtime env: `/etc/qwen3-tts/qwen3-tts.env`

The shim supports:
- **Proxy mode** (`QWEN3_TTS_UPSTREAM_BASE_URL`): forwards OpenAI TTS requests to an upstream server.
- **Subprocess mode** (`QWEN3_TTS_RUN_COMMAND`): runs a command per request. The command should read
  `QWEN3_TTS_REQUEST_JSON` and write audio to `QWEN3_TTS_OUTPUT_PATH`.
