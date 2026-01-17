# ai-infra

macOS launchd-based infrastructure scripts for running local AI services.

## Services

- `services/gateway`: FastAPI gateway exposing OpenAI-ish APIs; proxies to Ollama and MLX.
- `services/ollama`: Ollama runtime + model manifest.
- `services/mlx`: MLX OpenAI server runtime + model manifest.
- `services/all`: convenience scripts that call all services.

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

Appliance helpers:

- Freeze a release manifest: `services/gateway/scripts/freeze_release.sh`
- Run the appliance smoketest: `services/gateway/scripts/appliance_smoketest.sh`
- Idempotent install/upgrade wrapper: `services/gateway/scripts/appliance_install_or_upgrade.sh`
- Optional post-deploy hook: `services/gateway/scripts/deploy.sh --post-deploy-hook` (logs to `/var/log/gateway/post_deploy_hook.log`)

See [services/gateway/README.md](services/gateway/README.md).

Gateway supports:

- Policy-based routing (fast vs strong, long-context) with per-request overrides.
- Memory v2 (`/v1/memory/*`) with typed memories, filters, and compaction.
- Tool bus (`/v1/tools`) with strict allowlist + safe `http_fetch`.

## Ollama

- Install service: `services/ollama/scripts/install.sh`
- Pull models listed in the manifest: `services/ollama/scripts/pull-models.sh`
- Restart/status/uninstall: `services/ollama/scripts/{restart,status,uninstall}.sh`

Models are listed in [services/ollama/models/manifest.txt](services/ollama/models/manifest.txt).

## MLX

- Install service: `services/mlx/scripts/install.sh`
- Restart/status/uninstall: `services/mlx/scripts/{restart,status,uninstall}.sh`

Models are listed in [services/mlx/models/manifest.txt](services/mlx/models/manifest.txt).

## All services

Convenience wrappers:

- `services/all/scripts/install.sh`
- `services/all/scripts/restart.sh`
- `services/all/scripts/status.sh`

Cross-host checks (driven by `hosts.yaml`):

- `services/all/scripts/health-check.sh` (simple health endpoints)
- `services/all/scripts/verify-stack.sh` (functional checks; requires `--token` for gateway)
- `services/all/scripts/deploy-and-verify.sh` (deploy then verify; supports `--host` and `--check-images`)

Remote execution notes:

- For `services/all/scripts/{status,restart,install}.sh --host <name>`, the scripts assume the remote repos live under `${AI_INFRA_BASE:-~/ai}` on the remote host (set `AI_INFRA_BASE` on each host to override), or you can override locally with `AI_INFRA_REMOTE_BASE`.
- Remote commands run under a login shell (`bash -lc` on Ubuntu, `zsh -lc` on macOS) so normal dotfiles can provide `AI_INFRA_BASE`.

	- Note: a plain `ssh host 'echo $AI_INFRA_BASE'` often won't show it (non-login, non-interactive). To test the same way the scripts do:
		- Ubuntu/Linux: `ssh <host> 'bash -lc "echo $AI_INFRA_BASE"'`
		- macOS: `ssh <host> 'zsh -lc "echo $AI_INFRA_BASE"'`

	- If `bash -lc` prints an empty value, your `~/.bash_profile` likely has an early-return for non-interactive shells (common). Put `export AI_INFRA_BASE=...` in `~/.profile` (or above that guard), and optionally have `~/.bash_profile` source `~/.profile`.

Cross-host utilities:

- `services/all/scripts/pull-models.sh` (pull Ollama models fleet-wide from `services/ollama/models/manifest.txt`)
