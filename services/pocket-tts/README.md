# Pocket TTS

This service provisions a Pocket TTS FastAPI shim for the gateway. It installs a Python venv under `/var/lib/pocket-tts`, exposes `/health`, `/v1/models`, and `/v1/audio/speech`, and can be run on macOS (launchd) or Ubuntu 22.04 (systemd).

## Install

```bash
# macOS or Ubuntu 22.04
./scripts/install.sh
```

## Deploy (update shim)

```bash
./scripts/deploy.sh
```

## Restart / uninstall

```bash
./scripts/restart.sh
./scripts/uninstall.sh
```

## Configuration

- Env template: `env/pocket-tts.env.example`
- Runtime env: `/etc/pocket-tts/pocket-tts.env`

The shim supports both a Python backend (importing `pocket_tts`) and a command backend via `POCKET_TTS_COMMAND`. See the env template for the configurable command flags.
