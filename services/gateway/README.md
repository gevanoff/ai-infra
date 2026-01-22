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
- `smoke_test_gateway.sh`: Hits `/health`, `/v1/models`, `/v1/embeddings`, `/v1/responses` (requires `GATEWAY_BEARER_TOKEN`).

Appliance helpers:

- `freeze_release.sh`: Writes a timestamped release manifest under `/var/lib/gateway/data/releases/`.
- `appliance_smoketest.sh`: Runs the verifier in `--appliance` mode (requires healthy backend + chat stream + embeddings + tool + replay).
- `appliance_install_or_upgrade.sh`: Idempotent wrapper: install → deploy → freeze_release → appliance_smoketest.

Deploy post-hook:

- `deploy.sh --post-deploy-hook` (or `GATEWAY_POST_DEPLOY_HOOK=1`) runs `freeze_release.sh` then `appliance_smoketest.sh` after a successful deploy.

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

### Security notes (recommended defaults)

The example env file is intentionally conservative:

- Bind to loopback by default (`GATEWAY_HOST=127.0.0.1`). If you change to `0.0.0.0` for LAN access, also set `IP_ALLOWLIST` to trusted IPs/CIDRs and rely on firewall rules. Do not expose the gateway directly to the public Internet.
- Keep high-privilege tools disabled by default (`TOOLS_ALLOW_SHELL=false`, `TOOLS_ALLOW_FS=false`). Only enable them when you need them, and prefer narrow allowlisting (global `TOOLS_ALLOWLIST` and/or per-token `GATEWAY_TOKEN_POLICIES_JSON` with `tools_allowlist`).
- Treat gateway logs as potentially sensitive. Request logs and tool logs can include prompts, tool arguments, and outputs; keep `/var/lib/gateway/data` private and rotate/clean logs.

### Images (text-to-image via external image server)

Gateway can optionally expose `POST /v1/images/generations` (bearer-protected) by proxying to an external image server.

Env vars (in `/var/lib/gateway/app/.env`):

- `IMAGES_BACKEND=mock|http_a1111|http_openai_images` (default `mock` returns a placeholder SVG)
- `IMAGES_HTTP_BASE_URL=http://127.0.0.1:7860` (A1111 default) or `http://127.0.0.1:18181` (Nexa default)
- `IMAGES_HTTP_TIMEOUT_SEC=120`
- `IMAGES_A1111_STEPS=20`
- `IMAGES_MAX_PIXELS=2000000`
- `IMAGES_OPENAI_MODEL=...` (optional; some OpenAI-ish image servers require it, but the InvokeAI shim can use an upstream default model)

Automatic1111 requirements (when `IMAGES_BACKEND=http_a1111`):

- Run an A1111 server as a separate process (ideally on the same host).
- Start A1111 with `--api` so `/sdapi/v1/txt2img` is available.
- A1111 commonly has no auth; keep it on localhost or protect it with firewall/SSH.

Nexa / OpenAI-style server requirements (when `IMAGES_BACKEND=http_openai_images`):

- Run a server that exposes `POST /v1/images/generations`.
- Ensure it returns `response_format=b64_json` (gateway requests that).

Optional: multi-token auth

- `GATEWAY_BEARER_TOKENS=tok1,tok2,...` (comma-separated). If set, any listed token is accepted.
- If `GATEWAY_BEARER_TOKENS` is empty, gateway falls back to `GATEWAY_BEARER_TOKEN`.

Optional: per-token policy JSON

- `GATEWAY_TOKEN_POLICIES_JSON` can apply best-effort per-token overrides (useful for associates).
- Format: JSON object mapping bearer token -> policy object.
- Supported keys currently used by the gateway:
   - `tools_allowlist`: comma-separated tool allowlist for that token.
   - `tools_allow_shell`, `tools_allow_fs`, `tools_allow_http_fetch`, `tools_allow_git`: booleans.
   - `tools_allow_system_info`, `tools_allow_models_refresh`: booleans.
   - `tools_rate_limit_rps`, `tools_rate_limit_burst`: numbers.
   - `max_request_bytes`: number (overrides `MAX_REQUEST_BYTES` for that token).
   - `ip_allowlist`: comma-separated IPs/CIDRs (overrides `IP_ALLOWLIST` for that token).

Hardening notes:

- If you set `GATEWAY_TOKEN_POLICIES_JSON`, consider also setting `GATEWAY_TOKEN_POLICIES_STRICT=true` so a malformed JSON value fails closed instead of silently disabling restrictions.
- Prefer managing policies as a JSON file and embedding it into the env var with `jq -c`.
   - Template: `services/gateway/env/token_policies.json.example`
   - Example: `GATEWAY_TOKEN_POLICIES_JSON=$(jq -c . /var/lib/gateway/app/token_policies.json)`

Example:

- `GATEWAY_TOKEN_POLICIES_JSON={"ASSOCIATE_TOKEN":{"tools_allowlist":"noop,http_fetch_local","tools_rate_limit_rps":2,"tools_rate_limit_burst":4}}`

Optional request guardrails

- `MAX_REQUEST_BYTES` (default 1,000,000). Requests larger than this return HTTP 413.
- `IP_ALLOWLIST` (comma-separated IPs/CIDRs). When set, only those clients are allowed.

### Router policy (automatic backend/model selection)

Gateway can automatically pick a backend + model per request:

Agent specs: you can provide `AGENT_SPECS_PATH` (JSON) to define named agents and their configuration (model, tier, tool allowlists). An example template lives at `services/gateway/env/agent_specs.json.example` and demonstrates a `music` agent that allows `heartmula_generate` for tier 1 agents.

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
- Model `auto` (lets the gateway policy pick a backend/model)

Request-type routing (optional):

- Enable with `ROUTER_ENABLE_REQUEST_TYPE=true` (requires `ROUTER_ENABLE_POLICY=true`)
- Optional header `X-Request-Type: coding|chat` to force the request type

Responses include:

- `X-Backend-Used`, `X-Model-Used`, `X-Router-Reason`

### Model aliases (stable names like `coder`, `fast`)

Gateway supports a small alias registry so clients can send `model: "coder"` and the gateway resolves it to a specific backend + upstream model.

- Template: `services/gateway/env/model_aliases.json.example`
- Runtime path (read by the app): `/var/lib/gateway/app/model_aliases.json`
- Deploy behavior: `deploy.sh` copies the template into the runtime path **only if** the runtime file does not already exist.

Recommended baseline (Option A: Ollama-first)

- `DEFAULT_BACKEND=ollama`
- `ROUTER_ENABLE_POLICY=true`
- Set `OLLAMA_MODEL_STRONG`/`OLLAMA_MODEL_FAST` to your preferred quality/speed models.
- Use aliases to provide stable client-facing names:
   - `default` -> strong general model (tools allowed)
   - `fast` -> cheap/low-latency model (no tools)
   - `coder` -> coding/tooling model (tools allowed)
   - `long` -> long-context model (no tools)
   - optional `giant` -> very large model for special cases

Note: if `/var/lib/gateway/app/model_aliases.json` already exists on the host, updating the template in this repo will not change behavior until you update the runtime file (or delete it and redeploy).

### Memory v2

Memory v2 stores typed memories with source + timestamps, supports filtered retrieval, and supports compaction.

Env vars:

- `MEMORY_V2_ENABLED=true|false`
- `MEMORY_V2_MAX_AGE_SEC=...` (used by default retrieval/compaction)
- `MEMORY_V2_TYPES_DEFAULT=fact,preference,project`

Per-request retrieval overrides (optional)

Memory injection can be overridden per request using `X-Memory-*` headers:

- `X-Memory-Enabled: true|false`
- `X-Memory-Types: fact,preference,project` (comma-separated)
- `X-Memory-Sources: ...` (comma-separated; source names)
- `X-Memory-Top-K: <int>`
- `X-Memory-Min-Sim: <float>`
- `X-Memory-Max-Age-Sec: <int>`
- `X-Memory-Max-Chars: <int>`

Example (`curl`)

```bash
curl -sS http://127.0.0.1:8800/v1/chat/completions \
   -H "Authorization: Bearer $GATEWAY_BEARER_TOKEN" \
   -H "Content-Type: application/json" \
   -H "X-Memory-Enabled: true" \
   -H "X-Memory-Types: fact,project" \
   -H "X-Memory-Top-K: 4" \
   -H "X-Memory-Min-Sim: 0.30" \
   --data '{"model":"fast","messages":[{"role":"user","content":"What do you remember about this project?"}]}' \
   | python -m json.tool
```

Endpoints (bearer-protected):

- `POST /v1/memory/upsert`
- `GET /v1/memory/list`
- `POST /v1/memory/search`
- `POST /v1/memory/compact`

Additional endpoints (bearer-protected):

- `POST /v1/memory/delete` (delete by id list)
- `GET /v1/memory/export` (export/list with filters)
- `POST /v1/memory/import` (bulk import; re-embeds each item)

Note: if `MEMORY_V2_ENABLED=false`, these endpoints return `400 memory v2 disabled`.

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

Per-token allowlists (optional):

- You can override the allowlist per token via `GATEWAY_TOKEN_POLICIES_JSON` using `tools_allowlist`.

`http_fetch` is restricted by host allowlist + limits:

- `TOOLS_HTTP_ALLOWED_HOSTS=127.0.0.1,localhost`
- `TOOLS_HTTP_TIMEOUT_SEC=10`
- `TOOLS_HTTP_MAX_BYTES=200000`

Additional safe tools (optional):

- `http_fetch_local`: like `http_fetch` but hard-restricted to localhost.
- `system_info`: returns non-sensitive runtime info (enable with `TOOLS_ALLOW_SYSTEM_INFO=true`).
- `models_refresh`: pings upstream endpoints (enable with `TOOLS_ALLOW_MODELS_REFRESH=true`).

These tools can also be enabled per-token via `GATEWAY_TOKEN_POLICIES_JSON` keys `tools_allow_system_info` and `tools_allow_models_refresh`.

### OpenAI Responses API (minimal)

Gateway exposes a minimal `POST /v1/responses` endpoint (bearer-protected) for clients that use the newer Responses API.

- Best-effort mapping onto the existing chat completion path.
- Supports both non-streaming and SSE streaming.
- Limitation: streaming responses do not support tool calls (stream + tools returns 400).

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
