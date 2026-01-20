# FollowYourCanvas (video generation service)

Linux systemd-managed FollowYourCanvas service for GPU-backed video generation.

This service is intended to run on a dedicated GPU host (Ubuntu or similar), bind **only** to localhost
(`127.0.0.1`), and be consumed through the gateway using the tool bus. The install scripts create a
virtual environment, clone the FollowYourCanvas repo, and install its dependencies, but you still
need to set the exact launch command that matches your FollowYourCanvas checkout.

## What you edit

- `env/followyourcanvas.env.example`
  - Update `FYC_CMD` to the exact command used to launch the FollowYourCanvas HTTP server.
  - Adjust `FYC_HOST` / `FYC_PORT` to match your desired bind address and port.
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

- The install script expects you to provide the FollowYourCanvas repo URL via `FYC_REPO_URL`.
- If you prefer a manual install, clone the repo into `/var/lib/followyourcanvas/app`, create the
  venv in `/var/lib/followyourcanvas/venv`, and install requirements as documented upstream.
- Keep the service bound to `127.0.0.1` and route access through the gateway (or an SSH tunnel).
