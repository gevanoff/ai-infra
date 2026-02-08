# Service template

Use this directory as the starting point for new backend services. Copy the template to
`services/<service-name>` and replace placeholders.

## Directory layout

- `env/<service>.env.example`: Example environment settings used by `configure.sh`.
- `launchd/com.<service>.plist.example`: macOS launchd unit template.
- `systemd/<service>.service.example`: systemd unit template.
- `scripts/`: lifecycle scripts (`install.sh`, `deploy.sh`, `restart.sh`, `uninstall.sh`, `configure.sh`).
- `shim/`: optional shim code.

## Required scripts

All services must provide the following scripts:

- `scripts/install.sh`: install dependencies and set up runtime directories (macOS + systemd).
- `scripts/deploy.sh`: deploy or update service code/config/shim.
- `scripts/restart.sh`: restart the service via launchd/systemd or process manager.
- `scripts/uninstall.sh`: remove runtime/service definitions.
- `scripts/configure.sh`: reconcile runtime config with example templates (creates a timestamped
  backup before writing).

## Shim API policy

New shims must follow the standardized shim API contract documented in
`services/SHIM_API_POLICY.md`, including `/health`, `/readyz`, and `/v1/metadata` endpoints.
