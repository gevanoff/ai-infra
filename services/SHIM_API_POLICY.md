# Shim API policy (ai-infra backends)

This document standardizes the shim APIs used to expose backend services to the gateway and other clients.
The goals are:

- Predictable endpoints and metadata for all services.
- Minimal backend changes required when adding a new service.
- A consistent way for UI/client tooling to discover available features.

## Common endpoints (all services)

Every shim must expose the following endpoints:

| Endpoint | Method | Purpose | Notes |
| --- | --- | --- | --- |
| `/health` | `GET` | Liveness check | Returns `200` if the shim process is running. Should not depend on backend availability. |
| `/readyz` | `GET` | Readiness check | Returns `200` only if the backend is reachable and can handle a basic request. |
| `/v1/metadata` | `GET` | Shim manifest | Standardized JSON format describing service metadata, endpoints, and configurable options. |

### `/v1/metadata` schema (v1)

The response JSON must match this schema (fields may be extended as needed):

```json
{
  "schema_version": "v1",
  "service": {
    "name": "skyreels-v2",
    "version": "2025.09.01",
    "description": "SkyReels V2 video generation shim"
  },
  "backend": {
    "name": "skyreels-v2",
    "vendor": "SkyReels",
    "base_url": "http://127.0.0.1:9000"
  },
  "endpoints": [
    {
      "path": "/v1/videos/generations",
      "method": "POST",
      "operation_id": "videos.generate",
      "summary": "Generate a video",
      "request_schema": "https://example.com/schemas/videos.generate.json",
      "response_schema": "https://example.com/schemas/videos.generate.response.json"
    }
  ],
  "capabilities": {
    "domains": ["video"],
    "modalities": ["video"],
    "streaming": false,
    "max_concurrency": 2
  },
  "ui": {
    "options": [
      {
        "key": "resolution",
        "label": "Resolution",
        "type": "enum",
        "values": ["720p", "1080p"],
        "default": "720p"
      }
    ]
  }
}
```

#### Required fields

- `schema_version`: must be `v1` for the initial version.
- `service.name`: must match the service directory name in `services/`.
- `endpoints`: list of endpoints exposed by the shim. Each entry must include `path`, `method`, and `operation_id`.

#### Recommended fields

- `service.version`: a release/date string.
- `backend.base_url`: the upstream/base URL the shim talks to (when applicable).
- `capabilities.domains`: e.g. `chat`, `image`, `audio`, `video`, `ocr`, `asr`.
- `ui.options`: standardized list of options that a UI or gateway can use to render controls.

### UI option schema

Each `ui.options` entry uses the following keys:

- `key` (string): stable identifier for the option, often a request JSON field.
- `label` (string): human-readable label.
- `type` (string): `string`, `number`, `integer`, `boolean`, `enum`, or `json`.
- `default` (optional): default value.
- `values` (optional): allowed values for enums.
- `min`/`max` (optional): bounds for numeric inputs.
- `description` (optional): help text.

## Service-specific endpoints

Services should expose their primary API under a stable `/v1/...` path that mirrors the OpenAI-ish
patterns where possible (e.g. `/v1/chat/completions`, `/v1/audio/speech`, `/v1/audio/transcriptions`,
`/v1/images/generations`, `/v1/videos/generations`). If a service does not fit those patterns, define
it under `/v1/<service>/<action>` and document it in the service README and in `/v1/metadata`.

## Shim behavior guidelines

- Shims must be stateless and idempotent. Avoid storing per-request state outside the request lifecycle.
- Environment variables and config files should define all backend-specific settings.
- Add new backends by implementing the shim interface and metadata, without modifying other services.
- The gateway (or any consuming client) should be able to enumerate `/v1/metadata` for discovery and
  render UI options without service-specific hardcoding.

## Versioning

When the schema changes, increment `schema_version` (e.g. `v2`) and document the differences here.
Legacy fields should remain supported as long as feasible.
