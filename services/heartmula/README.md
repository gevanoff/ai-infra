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

## Installation

1. **Install HeartMula library** (run as root or with sudo):
   ```bash
   cd /var/lib/heartmula
   git clone https://github.com/HeartMuLa/heartlib.git
   cd heartlib
   /var/lib/heartmula/env/bin/pip install -e .
   ```

2. **Download models** (run as heartmula user):
   ```bash
   sudo -u heartmula -i
   cd /var/lib/heartmula
   mkdir -p ckpt output
   
   # Using HuggingFace
   pip install huggingface_hub
   hf download --local-dir './ckpt' 'HeartMuLa/HeartMuLaGen'
   hf download --local-dir './ckpt/HeartMuLa-oss-3B' 'HeartMuLa/HeartMuLa-oss-3B'
   hf download --local-dir './ckpt/HeartCodec-oss' 'HeartMuLa/HeartCodec-oss'
   ```

3. **Install and start service**:
   ```bash
   cd /path/to/ai-infra/services/heartmula/scripts
   ./install.sh
   ```

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

The service runs the FastAPI server automatically:

- `python /var/lib/heartmula/heartmula_server.py` (runs on 127.0.0.1:9920)
