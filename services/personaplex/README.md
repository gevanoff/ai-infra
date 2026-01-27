# PersonaPlex

FastAPI shim for PersonaPlex that exposes OpenAI-compatible chat (`POST /v1/chat/completions`).

## Recommended host

- **ada2** (NVIDIA GPU). PersonaPlex is expected to rely on CUDA.
- **ai2** only if upstream supports MPS/Core ML.

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

- Env template: `env/personaplex.env.example`
- Runtime env: `/etc/personaplex/personaplex.env`

The shim supports:
- **Proxy mode** (`PERSONAPLEX_UPSTREAM_BASE_URL`): forwards OpenAI chat to an upstream server.
- **Subprocess mode** (`PERSONAPLEX_RUN_COMMAND`): runs a command per request. The command receives
  `PERSONAPLEX_REQUEST_JSON` in the environment and must write a JSON response to stdout.
