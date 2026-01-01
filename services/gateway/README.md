# gateway

macOS launchd-managed FastAPI gateway that proxies to local backends (Ollama + MLX) and exposes OpenAI-ish endpoints.

## Runtime layout

- App: `/var/lib/gateway/app`
- Venv (used by launchd): `/var/lib/gateway/env`
- Env file (read by the app): `/var/lib/gateway/app/.env`
- Data: `/var/lib/gateway/data` (SQLite memory DB)
- Tools working dir (sandbox/CWD for tool execution): `/var/lib/gateway/tools`
- Tool scripts/config shipped with the app: `/var/lib/gateway/app/tools`
- Logs: `/var/log/gateway/gateway.{out,err}.log`

JSONL logs written by the gateway (optional, best-effort):

- Request events: `/var/lib/gateway/data/requests.jsonl` (controlled by `REQUEST_LOG_ENABLED` / `REQUEST_LOG_PATH`)
- Tool bus events:
   - NDJSON: `/var/lib/gateway/data/tools/invocations.jsonl` (controlled by `TOOLS_LOG_PATH`, `TOOLS_LOG_MODE=ndjson|both`)
   - Per-invocation: `/var/lib/gateway/data/tools/{replay_id}.json` (controlled by `TOOLS_LOG_DIR`, `TOOLS_LOG_MODE=per_invocation|both`)

Rotation/cleanup notes:

- For NDJSON (`*.jsonl`), rotate/truncate externally (e.g., logrotate or a periodic job). The gateway app does not manage file size.
- For per-invocation logs, periodically delete old `{replay_id}.json` files by mtime/age.

Note: `deploy.sh` also creates a convenience symlink so you can run the streaming SDK test from either path:

- `/var/lib/gateway/app/tools/openai_sdk_stream_test.py` (canonical, deployed with the app)
- `/var/lib/gateway/tools/openai_sdk_stream_test.py` (symlink)

## Scripts

From `services/gateway/scripts/`:

- `install.sh`: Creates runtime dirs + venv, installs the launchd plist, optionally installs Python deps if gateway code is already deployed.
- `deploy.sh`: Rsyncs the **gateway app source tree** into `/var/lib/gateway/app` and restarts launchd; waits for `/health`.
- `restart.sh`: Restarts the launchd job.
- `status.sh`: Shows launchd state + listener + recent logs.
- `uninstall.sh`: Unloads and removes the plist.
- `verify.sh`: Comprehensive single-command verification (requires `GATEWAY_BEARER_TOKEN`; can require a healthy backend).
- `smoke_test.sh`: Alias for `verify.sh`.
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

### Model aliases (stable names like `coder`, `fast`)

Gateway supports a small alias registry so clients can send `model: "coder"` and the gateway resolves it to a specific backend + upstream model.

- Template: `services/gateway/env/model_aliases.json.example`
- Runtime path (read by the app): `/var/lib/gateway/app/model_aliases.json`
- Deploy behavior: `deploy.sh` copies the template into the runtime path **only if** the runtime file does not already exist.

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
- `GET /v1/tools/replay/{replay_id}` (fetch a logged invocation event)

#### Tool bus contract (stable fields)

`GET /v1/tools` returns a list of tool declarations:

- Always includes: `name`, `version`, `description`, `parameters`
- Also includes:
   - `declared`: `true|false` (allowlisted but missing declaration => `false`)
   - `source`: `builtin|registry|missing`

`POST /v1/tools/{name}` success response is a tool-defined payload with a stable envelope:

- `replay_id`: unique invocation id
- `request_hash`: deterministic sha256 over `{tool, version, arguments}`
- `tool_runtime_ms`, `tool_cpu_ms`, `tool_io_bytes`: best-effort metrics
- Tool-specific fields such as `ok`, `error`, `stdout`, `stderr`, `stdout_json`

Error responses (HTTP 4xx) use a consistent `detail` object:

- `detail.error`, `detail.error_type`, `detail.error_message`
- `detail.issues` is present for schema validation failures (`error_type=invalid_arguments`)

Safety is enforced via a local allowlist:

- `TOOLS_ALLOWLIST=read_file,write_file,http_fetch` (if set, this is the only allowlist)
- Or use toggles: `TOOLS_ALLOW_SHELL`, `TOOLS_ALLOW_FS`, `TOOLS_ALLOW_HTTP_FETCH`

`http_fetch` is restricted by host allowlist + limits:

- `TOOLS_HTTP_ALLOWED_HOSTS=127.0.0.1,localhost`
- `TOOLS_HTTP_TIMEOUT_SEC=10`
- `TOOLS_HTTP_MAX_BYTES=200000`

#### Explicit tool registry (infra-owned)

Gateway can optionally load additional tools from an explicit registry file (no implicit discovery). Each tool is:

- Declared with `name`, `version`, `description`, and JSON Schema `parameters`
- Executed via a deterministic subprocess wrapper (args JSON on stdin, timeout, stdout/stderr capture, exit code)

Env var:

- `TOOLS_REGISTRY_PATH=/var/lib/gateway/app/tools_registry.json`

Example template:

- `services/gateway/env/tools_registry.json.example`

#### Ops knobs (recommended defaults)

- Hard limits:
   - `TOOLS_MAX_CONCURRENT`, `TOOLS_CONCURRENCY_TIMEOUT_SEC`
   - `TOOLS_SUBPROCESS_STDOUT_MAX_CHARS`, `TOOLS_SUBPROCESS_STDERR_MAX_CHARS`
- Optional rate limiting (disabled by default): `TOOLS_RATE_LIMIT_RPS`, `TOOLS_RATE_LIMIT_BURST`
- Optional metrics endpoint: `GET /metrics` (bearer-protected, controlled by `METRICS_ENABLED`)
- Optional registry integrity: `TOOLS_REGISTRY_SHA256` (sha256 hex; mismatches cause registry to be ignored)

## Typical flow (macOS host)

1. Deploy or update gateway code into `/var/lib/gateway/app`:
   - run `services/gateway/scripts/deploy.sh`
   - if your gateway checkout is not in `../gateway`, use: `GATEWAY_SRC_DIR=/path/to/gateway services/gateway/scripts/deploy.sh`
2. Install service (first time only):
   - run `services/gateway/scripts/install.sh`
3. Validate:
   - `services/gateway/scripts/status.sh`
   - `GATEWAY_BEARER_TOKEN=... services/gateway/scripts/verify.sh`
   - (alias) `GATEWAY_BEARER_TOKEN=... services/gateway/scripts/smoke_test.sh`
   - (deeper) `GATEWAY_BEARER_TOKEN=... services/gateway/scripts/smoke_test_gateway.sh`
