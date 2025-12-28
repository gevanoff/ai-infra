# ai-infra

macOS launchd-based infrastructure scripts for running local AI services.

## Services

- `services/gateway`: FastAPI gateway exposing OpenAI-ish APIs; proxies to Ollama and MLX.
- `services/ollama`: Ollama runtime + model manifest.
- `services/mlx`: MLX OpenAI server runtime + model manifest.

Each service follows the same pattern:

- `launchd/*.plist.example`: launchd unit definitions (copy to `/Library/LaunchDaemons`).
- `scripts/`: lifecycle scripts (`install.sh`, `restart.sh`, `status.sh`, `uninstall.sh`, plus service-specific helpers).
- `env/*.env.example` (when applicable): example runtime configuration.
- `models/manifest.txt` (when applicable): models to pre-pull/enable.

## Prereqs

- Target host: macOS (launchd)
- Tools: `sudo`, `launchctl`, `plutil` (built-in)

## Gateway

Gateway has a dedicated deploy step because it ships code:

- Deploy/update code: `services/gateway/scripts/deploy.sh`
- Install service: `services/gateway/scripts/install.sh`
- Restart: `services/gateway/scripts/restart.sh`
- Status/logs: `services/gateway/scripts/status.sh`
- Smoke test (requires token): `services/gateway/scripts/smoke_test_gateway.sh`

See [services/gateway/README.md](services/gateway/README.md).

## Ollama

- Install service: `services/ollama/scripts/install.sh`
- Pull models listed in the manifest: `services/ollama/scripts/pull-models.sh`
- Restart/status/uninstall: `services/ollama/scripts/{restart,status,uninstall}.sh`

Models are listed in [services/ollama/models/manifest.txt](services/ollama/models/manifest.txt).

## MLX

- Install service: `services/mlx/scripts/install.sh`
- Restart/status/uninstall: `services/mlx/scripts/{restart,status,uninstall}.sh`

Models are listed in [services/mlx/models/manifest.txt](services/mlx/models/manifest.txt).
