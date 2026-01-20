# Infra inventories (factual)

Date: 2026-01-03

This document is a factual inventory of infrastructure components described by the `ai-infra` repository and the `gateway` service it deploys. It avoids inference and only records what is explicitly present in source files and documentation.

## Scope

- `ai-infra/`: macOS `launchd` scripts and examples for running local AI services.
- `gateway/`: FastAPI service deployed by `ai-infra/services/gateway`.

## Source files (authoritative inputs used)

### ai-infra

- `ai-infra/README.md`
- `ai-infra/services/gateway/README.md`
- `ai-infra/services/gateway/launchd/com.ai.gateway.plist.example`
- `ai-infra/services/ollama/launchd/com.ollama.service.plist.example`
- `ai-infra/services/mlx/launchd/com.mlx.openai.server.plist.example`
- `ai-infra/services/nexa/launchd/com.nexa.image.server.plist.example`
- `ai-infra/services/heartmula/launchd/com.heartmula.server.plist.example`
- `ai-infra/services/gateway/env/gateway.env.example`
- `ai-infra/services/gateway/env/model_aliases.json.example`
- `ai-infra/services/gateway/env/tools_registry.json.example`

### gateway

- `gateway/README.md`
- `gateway/app/config.py`
- `gateway/app/main.py`
- `gateway/app/openai_routes.py`

## ai-infra inventory

### System map (processes, listeners, network edges)

Services are described as macOS `launchd` jobs in `ai-infra/services/*/launchd/*.plist.example`.

- Gateway (launchd job)
  - Label: `com.ai.gateway`
  - Program: `uvicorn app.main:app`
  - Listener: `0.0.0.0:8800`
  - Log config: `/var/lib/gateway/app/tools/uvicorn_log_config.json`
  - Stdout/stderr logs: `/var/log/gateway/gateway.out.log`, `/var/log/gateway/gateway.err.log`
  - Source: `ai-infra/services/gateway/launchd/com.ai.gateway.plist.example`

- Ollama (launchd job)
  - Label: `com.ollama.server`
  - Program: `/usr/local/bin/ollama serve`
  - Listener: `127.0.0.1:11434` via `OLLAMA_HOST=127.0.0.1:11434`
  - Linux note: if Ollama is hosted on Ubuntu (systemd unit `ollama`) and needs LAN access, bind to `0.0.0.0:11434` and restrict inbound traffic with firewall rules (the install script allows `tcp/11434` from `10.10.22.0/24` by default).
  - Models directory: `/var/lib/ollama/models` via `OLLAMA_MODELS=/var/lib/ollama/models`
  - Stdout/stderr logs: `/var/log/ollama/ollama.out.log`, `/var/log/ollama/ollama.err.log`
  - Source: `ai-infra/services/ollama/launchd/com.ollama.service.plist.example`

- MLX OpenAI server (launchd job)
  - Label: `com.mlx.openai.server`
  - Program: `/var/lib/mlx/env/bin/mlx-openai-server launch ... --host 127.0.0.1 --port 10240`
  - Listener: `127.0.0.1:10240`
  - Stdout/stderr logs: `/var/log/mlx/mlx-openai.out.log`, `/var/log/mlx/mlx-openai.err.log`
  - Source: `ai-infra/services/mlx/launchd/com.mlx.openai.server.plist.example`

- Nexa image server (launchd job; optional)
  - Label: `com.nexa.image.server`
  - ProgramArguments run: `/bin/zsh -lc "exec nexa serve --host 127.0.0.1:18181 --keepalive 600"` (example)
  - Listener: `127.0.0.1:18181` (example in plist)
  - Stdout/stderr logs: `/var/log/nexa/nexa.out.log`, `/var/log/nexa/nexa.err.log`
  - Source: `ai-infra/services/nexa/launchd/com.nexa.image.server.plist.example`

- HeartMula music generator (launchd job; optional)
  - Label: `com.heartmula.server`
  - ProgramArguments run: `/var/lib/heartmula/env/bin/heartmula serve --host 127.0.0.1 --port 9920` (example)
  - Listener: `127.0.0.1:9920` (example in plist)
  - Stdout/stderr logs: `/var/log/heartmula/heartmula.out.log`, `/var/log/heartmula/heartmula.err.log`
  - Source: `ai-infra/services/heartmula/launchd/com.heartmula.server.plist.example`

Upstream connections configured for gateway:

- `OLLAMA_BASE_URL=http://127.0.0.1:11434`
- `MLX_BASE_URL=http://127.0.0.1:10240/v1`

Source: `ai-infra/services/gateway/env/gateway.env.example`

### Component inventory

- Service folders:
  - `ai-infra/services/gateway/`
  - `ai-infra/services/heartmula/`
  - `ai-infra/services/ollama/`
  - `ai-infra/services/mlx/`
  - `ai-infra/services/nexa/`
  - `ai-infra/services/all/`

Source: `ai-infra/README.md`

- Common per-service structure described:
  - `launchd/*.plist.example`
  - `scripts/` lifecycle scripts
  - `env/*.env.example` (when applicable)
  - `models/manifest.txt` (when applicable)

Source: `ai-infra/README.md`

### Runtime layout (gateway)

Paths used/described for the macOS gateway runtime:

- App: `/var/lib/gateway/app`
- Venv: `/var/lib/gateway/env`
- Env file read by the app: `/var/lib/gateway/app/.env`
- Data: `/var/lib/gateway/data`
- Tools working dir: `/var/lib/gateway/tools`
- Tool scripts/config shipped with the app: `/var/lib/gateway/app/tools`
- Logs: `/var/log/gateway/gateway.{out,err}.log`

Source: `ai-infra/services/gateway/README.md`

Optional JSONL logs written by the gateway (best-effort):

- Request events: `/var/lib/gateway/data/requests.jsonl`
- Tool bus events:
  - NDJSON: `/var/lib/gateway/data/tools/invocations.jsonl`
  - Per-invocation: `/var/lib/gateway/data/tools/{replay_id}.json`

Source: `ai-infra/services/gateway/README.md`

### Deploy source discovery (gateway)

`deploy.sh` searches for the gateway repo checkout in this order:

1. `GATEWAY_SRC_DIR`
2. `../gateway`
3. `../../gateway`

A directory is considered valid if it contains `app/main.py`.

Source: `ai-infra/services/gateway/README.md`

### Configuration artifacts

- Gateway env template: `ai-infra/services/gateway/env/gateway.env.example`
- Model alias template: `ai-infra/services/gateway/env/model_aliases.json.example`
- Tool registry template: `ai-infra/services/gateway/env/tools_registry.json.example`

## gateway inventory

This section inventories the `gateway` service as described by its repo and the code paths referenced by `ai-infra`.

### System map (processes, listeners, network edges)

- The gateway is a FastAPI app (run via Uvicorn in `ai-infra` launchd example).
  - Source: `gateway/app/main.py`, `ai-infra/services/gateway/launchd/com.ai.gateway.plist.example`

- Default upstream base URLs (settings defaults):
  - `OLLAMA_BASE_URL = http://127.0.0.1:11434`
  - `MLX_BASE_URL = http://127.0.0.1:10240/v1`
  - Source: `gateway/app/config.py`

- Startup performs a best-effort check of Ollama model availability via `GET {OLLAMA_BASE_URL}/api/tags`.
  - Source: `gateway/app/main.py`

### Component inventory (routers and major modules)

Routers included by the FastAPI app:

- Health routes: `gateway/app/health_routes.py`
- OpenAI-ish routes: `gateway/app/openai_routes.py`
- Images routes: `gateway/app/images_routes.py`
- Memory routes: `gateway/app/memory_routes.py`
- Tools bus: `gateway/app/tools_bus.py`
- Agent runtime v1 routes: `gateway/app/agent_routes.py`
- UI routes: `gateway/app/ui_routes.py`

Source: router includes in `gateway/app/main.py`

Middlewares and behavior visible in `gateway/app/main.py`:

- Request-size guard middleware (413 on oversize) with optional per-token override via token policy.
- Request logging middleware that sets `X-Request-Id` and records best-effort metrics, including streaming instrumentation.
- Static assets mounted at `/static`.

Source: `gateway/app/main.py`

### API endpoints (examples observed)

Bearer protection is applied in handlers by calling `require_bearer(req)`.

Examples defined in `gateway/app/openai_routes.py`:

- `GET /v1/models`
- `POST /v1/chat/completions`

Chat completions flow includes:

- Calls `inject_memory(...)` to modify messages prior to routing.
- Calls `decide_route(...)` with `enable_policy=S.ROUTER_ENABLE_POLICY`.
- Rejects `stream=true` when tools are provided (`400`).

Source: `gateway/app/openai_routes.py`

### Configuration (settings)

Settings are defined by `Settings(BaseSettings)` and read env vars (with an absolute env file configured):

- `env_file = /var/lib/gateway/app/.env`

Source: `gateway/app/config.py`

Selected settings (non-exhaustive; as defined in code):

- Listen: `GATEWAY_HOST`, `GATEWAY_PORT`
- Auth: `GATEWAY_BEARER_TOKEN`, optional `GATEWAY_BEARER_TOKENS`, `GATEWAY_TOKEN_POLICIES_JSON`
- Guardrails: `MAX_REQUEST_BYTES`, `IP_ALLOWLIST`
- UI allowlist: `UI_IP_ALLOWLIST`
- Images: `IMAGES_BACKEND`, `IMAGES_HTTP_BASE_URL`, `IMAGES_OPENAI_MODEL`, etc.
- Routing: `DEFAULT_BACKEND`, `ROUTER_ENABLE_POLICY`, `ROUTER_LONG_CONTEXT_CHARS`
- Tool bus: `TOOLS_*` settings including allowlist toggles, logging paths/modes, registry path
- Memory: `MEMORY_*` and `MEMORY_V2_*` settings
- Metrics toggle: `METRICS_ENABLED`

Source: `gateway/app/config.py`

## Diagrams (published)

Mermaid diagrams for the total system + gateway request flows are published on the website page:

- `websites/gabrielevanoff.com/ai/infrastructure.html`

(These diagrams are not stored in `ai-infra/` or `gateway/`.)
