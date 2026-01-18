# librechat

macOS launchd-managed LibreChat (LAN web UI) backed by a local MongoDB.

This service is intended to run on the same host as the gateway (`ai2` in your setup), and to talk to the gateway via a custom OpenAI-compatible endpoint (e.g. `http://ai2:8800/v1`).

## Runtime layout

- App (deployed working tree): `/var/lib/librechat/app`
- Data: `/var/lib/librechat/data`
- MongoDB:
  - Config: `/var/lib/librechat/mongo/mongod.conf`
  - Data: `/var/lib/librechat/mongo/data`
- Logs: `/var/log/librechat/`
- Env file (read by LibreChat backend via dotenv): `/var/lib/librechat/app/.env`
- YAML config (referenced by `CONFIG_PATH`): `/var/lib/librechat/app/librechat.yaml`

## Launchd

Plists installed under `/Library/LaunchDaemons/`:

- `com.ai.librechat.mongodb` (mongod, loopback-only)
- `com.ai.librechat` (LibreChat backend, default port 3080)

Note: the installer creates root-owned wrapper scripts in `/var/lib/librechat/bin/` for `node` and `mongod`. This avoids a common macOS `launchctl bootstrap` failure (`Bootstrap failed: 5: Input/output error`) caused by LaunchDaemons refusing to execute binaries inside user-writable Homebrew trees, and also avoids `dyld` crashes that can happen when copying the Homebrew `node` binary without its companion `libnode.*.dylib`.

## LAN firewall (pf)

`install.sh` installs a pf anchor:

- Anchor file: `/etc/pf.anchors/com.ai.librechat`
- pf.conf lines:
  - `anchor "com.ai.librechat"`
  - `load anchor "com.ai.librechat" from "/etc/pf.anchors/com.ai.librechat"`

The anchor is configured to allow TCP/3080 only from `10.10.22.0/24` (plus localhost) and block other inbound traffic to that port.

## Scripts

From `services/librechat/scripts/`:

- `install.sh`: Creates runtime dirs under `/var/lib/librechat`, creates a `librechat` service user if missing, installs MongoDB + Node via Homebrew (optional), installs pf rule, installs launchd plists.
- `deploy.sh`: Pulls/clones LibreChat source (git) to a host-local checkout, rsyncs into `/var/lib/librechat/app`, runs `npm ci` + `npm run frontend`, restarts launchd, waits for `/health`.
- `restart.sh`: Restarts both MongoDB and LibreChat launchd jobs.
- `status.sh`: Shows launchd state + listeners + recent logs.
- `verify.sh`: Hits `http://127.0.0.1:3080/health` and checks MongoDB is listening.
- `uninstall.sh`: Stops/unloads plists, removes pf anchor lines, optionally purges data.

## Source discovery (deploy)

`deploy.sh` looks for a LibreChat source checkout to update via git:

1. `LIBRECHAT_SRC_DIR` (if set)
2. `${AI_INFRA_BASE}/librechat` or `${AI_INFRA_BASE}/LibreChat`
3. `$HOME/ai/librechat`, `$HOME/src/librechat`, `$HOME/repos/librechat`, etc.

If not found, it will clone from `LIBRECHAT_GIT_URL` (defaults to `https://github.com/danny-avila/LibreChat.git`).

## Notes

- This setup is HTTP-only. Keep it LAN-only (pf rule enforces this for port 3080).
- MongoDB is bound to `127.0.0.1` only.
