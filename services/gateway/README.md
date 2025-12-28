# gateway

macOS launchd-managed FastAPI gateway that proxies to local backends (Ollama + MLX) and exposes OpenAI-ish endpoints.

## Runtime layout

- App: `/var/lib/gateway/app`
- Venv (used by launchd): `/var/lib/gateway/env`
- Env file (read by the app): `/var/lib/gateway/app/.env`
- Data: `/var/lib/gateway/data` (SQLite memory DB)
- Tools working dir: `/var/lib/gateway/tools`
- Logs: `/var/log/gateway/gateway.{out,err}.log`

## Scripts

From `services/gateway/scripts/`:

- `install.sh`: Creates runtime dirs + venv, installs the launchd plist, optionally installs Python deps if gateway code is already deployed.
- `deploy.sh`: Rsyncs this repo’s `services/gateway/` contents into `/var/lib/gateway/app` and restarts launchd; waits for `/health`.
- `restart.sh`: Restarts the launchd job.
- `status.sh`: Shows launchd state + listener + recent logs.
- `uninstall.sh`: Unloads and removes the plist.
- `smoke_test_gateway.sh`: Hits `/health`, `/v1/models`, `/v1/embeddings` (requires `GATEWAY_BEARER_TOKEN`).

## Launchd

Plist example: `services/gateway/launchd/com.ai.gateway.plist.example`

- Label: `com.ai.gateway`
- Entry point: `uvicorn app.main:app`
- Log config: `/var/lib/gateway/app/tools/uvicorn_log_config.json`

## Configuration

Example env file: `services/gateway/env/gateway.env.example`

You must set `GATEWAY_BEARER_TOKEN` to a secret value in `/var/lib/gateway/app/.env`.

## Typical flow (macOS host)

1. Deploy or update gateway code into `/var/lib/gateway/app`:
   - run `services/gateway/scripts/deploy.sh`
2. Install service (first time only):
   - run `services/gateway/scripts/install.sh`
3. Validate:
   - `services/gateway/scripts/status.sh`
   - `GATEWAY_BEARER_TOKEN=... services/gateway/scripts/smoke_test_gateway.sh`
