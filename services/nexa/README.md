# nexa (image server)

macOS launchd-managed Nexa image generation service.

This service is intended to run **only on localhost** (bind `127.0.0.1`) and be consumed by the gateway via an HTTP base URL.

## What you edit

- Plist template: `launchd/com.nexa.image.server.plist.example`
  - Update the `ProgramArguments` command string to match the exact Nexa command you already run successfully.
  - Keep `--host 127.0.0.1:<port>` (or equivalent) so it is not exposed to the LAN.
  - The port is arbitrary; pick one and keep the gateway pointed at it.

## Runtime layout

- Runtime dir: `/var/lib/nexa`
- Logs:
  - `/var/log/nexa/nexa.out.log`
  - `/var/log/nexa/nexa.err.log`

## Install / manage

From `services/nexa/scripts/` on the Mac host:

- Install + start: `./install.sh`
- The installer will download and install the Nexa CLI package automatically if `nexa` is not already in `PATH`.
- Restart: `./restart.sh`
- Status: `./status.sh`
- Uninstall: `./uninstall.sh`

## Nexa CLI install (manual)

If you prefer to install Nexa CLI yourself (or for debugging), this is the known-good sequence for Apple Silicon:

```bash
curl -L -o nexa-macos-arm64.pkg \
  https://public-storage.nexa4ai.com/nexa_sdk/downloads/nexa-cli_macos_arm64.pkg
pkgutil --check-signature nexa-macos-arm64.pkg
sudo installer -pkg nexa-macos-arm64.pkg -target /

# sox is required for some functionality

# Pull the preferred image generation model
nexa pull NexaAI/sdxl-turbo
```

## Notes

- The plist runs Nexa under a dedicated `nexa` user by default. Create it first (or set `NEXA_USER` and edit the plist `UserName`).
- launchd does not read `.env` files automatically; the recommended pattern is to encode required env vars under `EnvironmentVariables` in the plist.

## Recommended Nexa command

This is the known-working pattern used by the example plist:

- `nexa serve --host 127.0.0.1:18181 --keepalive 600`
