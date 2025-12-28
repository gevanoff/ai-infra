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
- `deploy.sh`: Rsyncs the **gateway app source tree** into `/var/lib/gateway/app` and restarts launchd; waits for `/health`.
- `restart.sh`: Restarts the launchd job.
- `status.sh`: Shows launchd state + listener + recent logs.
- `uninstall.sh`: Unloads and removes the plist.
- `smoke_test.sh`: Minimal checks: `/health` and `/v1/models` (requires `GATEWAY_BEARER_TOKEN`).
- `smoke_test_gateway.sh`: Hits `/health`, `/v1/models`, `/v1/embeddings` (requires `GATEWAY_BEARER_TOKEN`).

### Gateway source discovery (deploy)

`deploy.sh` needs to know where your **gateway repo checkout** lives (it is separate from `ai-infra`).

It searches in this order:

1. `GATEWAY_SRC_DIR` (if set)
2. Sibling checkout next to `ai-infra`: `../gateway`
3. One level higher: `../../gateway`

The directory is considered valid if it contains `app/main.py`.

## Launchd

Plist example: `services/gateway/launchd/com.ai.gateway.plist.example`

- Label: `com.ai.gateway`
- Entry point: `uvicorn app.main:app`
- Log config: `/var/lib/gateway/app/tools/uvicorn_log_config.json`

## Configuration

Example env file: `services/gateway/env/gateway.env.example`

You must set `GATEWAY_BEARER_TOKEN` to a secret value in `/var/lib/gateway/app/.env`.

### Router policy (automatic backend/model selection)

Gateway can automatically pick a backend + model per request:

- Tool-heavy / agentic requests (`tools` present) route to the configured **strong** model.
- “Fast/cheap” default routes to the configured **fast** model.
- Long-context requests route to MLX (if configured) once input size crosses a threshold.

Env vars:

- `DEFAULT_BACKEND=ollama|mlx`
- `OLLAMA_MODEL_STRONG=...`, `OLLAMA_MODEL_FAST=...`
- `MLX_MODEL_STRONG=...`, `MLX_MODEL_FAST=...`
- `ROUTER_LONG_CONTEXT_CHARS=40000`

Per-request overrides:

- Header `X-Backend: ollama|mlx`
- Model prefixes `ollama:<name>` / `mlx:<name>`

Responses include:

- `X-Backend-Used`, `X-Model-Used`, `X-Router-Reason`

### Memory v2

Memory v2 stores typed memories with source + timestamps, supports filtered retrieval, and supports compaction.

Env vars:

- `MEMORY_V2_ENABLED=true|false`
- `MEMORY_V2_MAX_AGE_SEC=...` (used by default retrieval/compaction)
- `MEMORY_V2_TYPES_DEFAULT=fact,preference,project`

Endpoints (bearer-protected):

- `POST /v1/memory/upsert`
- `GET /v1/memory/list`
- `POST /v1/memory/search`
- `POST /v1/memory/compact`

### Tool bus

Gateway can expose a local “tool bus” for agents.

Endpoints (bearer-protected):

- `GET /v1/tools` (schemas)
- `POST /v1/tools/{name}` (execute)

Safety is enforced via a local allowlist:

- `TOOLS_ALLOWLIST=read_file,write_file,http_fetch` (if set, this is the only allowlist)
- Or use toggles: `TOOLS_ALLOW_SHELL`, `TOOLS_ALLOW_FS`, `TOOLS_ALLOW_HTTP_FETCH`

`http_fetch` is restricted by host allowlist + limits:

- `TOOLS_HTTP_ALLOWED_HOSTS=127.0.0.1,localhost`
- `TOOLS_HTTP_TIMEOUT_SEC=10`
- `TOOLS_HTTP_MAX_BYTES=200000`

## Typical flow (macOS host)

1. Deploy or update gateway code into `/var/lib/gateway/app`:
   - run `services/gateway/scripts/deploy.sh`
   - if your gateway checkout is not in `../gateway`, use: `GATEWAY_SRC_DIR=/path/to/gateway services/gateway/scripts/deploy.sh`
2. Install service (first time only):
   - run `services/gateway/scripts/install.sh`
3. Validate:
   - `services/gateway/scripts/status.sh`
   - `GATEWAY_BEARER_TOKEN=... services/gateway/scripts/smoke_test.sh`
   - (deeper) `GATEWAY_BEARER_TOKEN=... services/gateway/scripts/smoke_test_gateway.sh`
