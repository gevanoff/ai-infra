# InvokeAI Image Generation Service

InvokeAI running on ada2 (RTX 6000 Ada, 46GB VRAM) for SDXL image generation.

## Prerequisites

- Ubuntu 22.04+ with CUDA drivers installed
- RTX 6000 Ada (or similar GPU with 24GB+ VRAM)
- Python 3.11+
- nginx (for health endpoints)

## Installation

Run as root or with sudo:

```bash
cd ~/ai/ai-infra/services/invokeai
./scripts/install.sh
```

This will:
1. Create `invokeai` user
2. Install Python dependencies
3. Set up InvokeAI in `/var/lib/invokeai`
4. Configure systemd service
5. Set up nginx health endpoints
6. Download default models (SDXL)

## Configuration

### InvokeAI Config

Edit `/var/lib/invokeai/invokeai.yaml`:

```yaml
InvokeAI:
  Web Server:
    host: 0.0.0.0
    port: 9090  # Internal port (nginx proxies from 7860)
    
  Generation:
    precision: float16
    
  Model Cache:
    ram: 16.0
    vram: 40.0
```

### Nginx Proxy

Edit `/etc/nginx/sites-available/invokeai` to customize health endpoints or timeouts.

## Service Management

```bash
# Start/stop/restart
sudo systemctl start invokeai
sudo systemctl stop invokeai
sudo systemctl restart invokeai

# View status
sudo systemctl status invokeai

# View logs
sudo journalctl -u invokeai -f

# Enable/disable autostart
sudo systemctl enable invokeai
sudo systemctl disable invokeai
```

## Health Endpoints

- `http://ada2.local:7860/healthz` - Liveness check (always returns 200)
- `http://ada2.local:7860/readyz` - Readiness check (proxies to InvokeAI API)

## Web UI

Access at `http://ada2.local:7860` to:
- Download/manage models
- Test image generation
- Configure workflows

## API Endpoint

OpenAI-compatible endpoint for gateway integration:

```
POST http://ada2.local:7860/api/v1/images/generations
```

## Monitoring

### GPU Usage
```bash
watch -n 1 nvidia-smi
```

### Service Logs
```bash
sudo journalctl -u invokeai -f
```

### Nginx Access Logs
```bash
sudo tail -f /var/log/nginx/access.log
```

## Troubleshooting

### Service won't start
```bash
# Check logs
sudo journalctl -u invokeai -n 100

# Verify Python deps
sudo -u invokeai bash -c 'cd /var/lib/invokeai && source venv/bin/activate && python -c "import invokeai; print(invokeai.__version__)"'
```

### Out of memory
- Use SD 1.5 instead of SDXL
- Reduce `vram` in invokeai.yaml
- Lower gateway concurrency limit in `backends_config.yaml`

### Models not loading
```bash
# Check models directory
ls -la /var/lib/invokeai/models/

# Reinstall via web UI
# Access http://ada2.local:7860 → Model Manager
```

## Integration with Gateway

The gateway routes images to this service via:

```bash
# In gateway .env:
IMAGES_BACKEND=http_openai_images
IMAGES_BACKEND_CLASS=gpu_heavy
IMAGES_HTTP_BASE_URL=http://ada2.local:7860
IMAGES_OPENAI_MODEL=sd-xl-base-1.0
```

See `../../gateway/IMAGE_BACKEND_SETUP.md` for full integration docs.
