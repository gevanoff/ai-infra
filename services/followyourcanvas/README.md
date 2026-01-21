# FollowYourCanvas (video generation service)

Linux systemd-managed FollowYourCanvas service for GPU-backed video generation.

This service is intended to run on a dedicated GPU host (Ubuntu or similar), bind **only** to localhost
(`127.0.0.1`), and be consumed through the gateway using the tool bus. The install scripts create a
virtual environment, clone the FollowYourCanvas repo, and install its dependencies. By default the
systemd service starts a small FastAPI shim that implements a stable `POST /v1/videos/generations`
contract.

## What you edit

- `env/followyourcanvas.env.example`
  - Adjust `FYC_HOST` / `FYC_PORT` to match your desired bind address and port.
  - Set either `FYC_UPSTREAM_BASE_URL` (proxy an existing HTTP server) or `FYC_RUN_COMMAND`
    (run inference via subprocess).
  - For subprocess mode, set `FYC_DEFAULT_CONFIG` to a config file under the repo (relative to
    `FYC_WORKDIR`) unless your client always provides `config` in the request payload.
  - The shim injects `FYC_REQUEST_JSON` and `FYC_OUTPUT_DIR` per request; you should not set those
    in the env file.
- `systemd/followyourcanvas.service`
  - Verify `User`, `WorkingDirectory`, and the `EnvironmentFile` path.
- `tools/followyourcanvas_generate.py`
  - If your FollowYourCanvas server uses a different API path or payload, update this script to
    match your server contract.

## Runtime layout

- Runtime dir: `/var/lib/followyourcanvas`
- Repo checkout: `/var/lib/followyourcanvas/app`
- Virtualenv: `/var/lib/followyourcanvas/venv`
- Env file: `/var/lib/followyourcanvas/followyourcanvas.env`
- Logs (systemd journal): `journalctl -u followyourcanvas -f`

## Install / manage

From `services/followyourcanvas/scripts/` on the GPU host (Linux):

- Install + start: `sudo ./install.sh`
- Restart: `sudo ./restart.sh`
- Status: `sudo ./status.sh`
- Uninstall: `sudo ./uninstall.sh`

## Gateway integration (tool bus)

The gateway can expose FollowYourCanvas through a tool definition. The install script optionally
copies the tool wrapper into `/var/lib/gateway/tools` if that directory exists.

1. Copy the tool wrapper (if you skipped install or need to update it):

   ```bash
   sudo cp services/followyourcanvas/tools/followyourcanvas_generate.py /var/lib/gateway/tools/
   sudo chmod 755 /var/lib/gateway/tools/followyourcanvas_generate.py
   ```

2. Update `/var/lib/gateway/app/tools_registry.json` to include the new tool definition.
   - See `services/gateway/env/tools_registry.json.example` for the ready-to-copy entry.

3. Restart the gateway:

   ```bash
   sudo services/gateway/scripts/restart.sh
   ```

The tool posts to `POST ${FYC_API_BASE_URL}/v1/videos/generations` and returns the upstream JSON.
If your FollowYourCanvas server uses a different endpoint, update `FYC_API_BASE_URL` in
`/var/lib/followyourcanvas/followyourcanvas.env` and/or edit the tool wrapper script.

## Notes

- The install script defaults `FYC_REPO_URL` to the canonical upstream repo; override it if you use a fork.
- If you prefer a manual install, clone the repo into `/var/lib/followyourcanvas/app`, create the
  venv in `/var/lib/followyourcanvas/venv`, and install requirements as documented upstream.
- Keep the service bound to `127.0.0.1` and route access through the gateway (or an SSH tunnel).
