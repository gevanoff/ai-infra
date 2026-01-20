# heartmula (music generator)

macOS launchd-managed HeartMula music generation service.

This service is intended to run **only on localhost** (bind `127.0.0.1`) and be consumed by the gateway via an HTTP base URL.

## What you edit

- Plist template: `launchd/com.heartmula.server.plist.example`
  - Update the `ProgramArguments` command string to match the exact HeartMula command you already run successfully.
  - Keep `--host 127.0.0.1` (or equivalent) so it is not exposed to the LAN.
  - The port is arbitrary; pick one and keep the gateway pointed at it.

## Runtime layout

- Runtime dir: `/var/lib/heartmula`
- Logs:
  - `/var/log/heartmula/heartmula.out.log`
  - `/var/log/heartmula/heartmula.err.log`

## Install / manage

From `services/heartmula/scripts/` on the Mac host:

- Install + start: `./install.sh`
- Restart: `./restart.sh`
- Status: `./status.sh`
- Uninstall: `./uninstall.sh`

## Gateway integration

Point the gateway at the HeartMula HTTP endpoint (example values shown):

```
HEARTMULA_BASE_URL=http://127.0.0.1:9920
```

Use the same host/port you configured in the launchd plist. The gateway host should be able to reach this URL (either localhost or a LAN address if you move HeartMula to a different machine).

## Notes

- The plist runs HeartMula under a dedicated `heartmula` user by default. Create it first (or set `HEARTMULA_USER` and edit the plist `UserName`).
- launchd does not read `.env` files automatically; encode required env vars under `EnvironmentVariables` in the plist.

## Recommended HeartMula command

This is the known-working pattern used by the example plist:

- `heartmula serve --host 127.0.0.1 --port 9920`
