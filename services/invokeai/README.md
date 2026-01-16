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

# Shim (OpenAI Images compatibility)
sudo systemctl start invokeai-openai-images-shim
sudo systemctl stop invokeai-openai-images-shim
sudo systemctl restart invokeai-openai-images-shim

# View status
sudo systemctl status invokeai
sudo systemctl status invokeai-openai-images-shim

# View logs
sudo journalctl -u invokeai -f
sudo journalctl -u invokeai-openai-images-shim -f

# Enable/disable autostart
sudo systemctl enable invokeai
sudo systemctl disable invokeai
```

## Health Endpoints

- `http://ada2.local:7860/healthz` - Liveness check (always returns 200)
- `http://ada2.local:7860/readyz` - Readiness check (proxies to the shim, which checks InvokeAI)

## Web UI

Access at `http://ada2.local:7860` to:
- Download/manage models
- Test image generation
- Configure workflows

## API Endpoint

OpenAI-compatible endpoint for gateway integration (provided by the shim):

```
POST http://ada2.local:7860/v1/images/generations
```

InvokeAI native API (not OpenAI-compatible) is available under:

```
http://ada2.local:7860/api/v1/
```

## Quick Validation (Shim Stub Mode)

The shim systemd unit defaults to `SHIM_MODE=stub`, which returns a tiny PNG as `b64_json`. This validates nginx routing + gateway contract without requiring an InvokeAI workflow.

Readiness (nginx -> shim -> InvokeAI):

```bash
curl -sS http://ada2.local:7860/readyz
```

OpenAI images contract smoke test (must return `data[0].b64_json`):

```bash
curl -sS -X POST http://ada2.local:7860/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{"prompt":"shim smoke test","response_format":"b64_json"}'
```

Expected shape:

```json
{"created": 1234567890, "data": [{"b64_json": "...base64 png..."}]}
```

## Enable Real Mode (InvokeAI Queue)

Once stub mode is working, switch the shim to `SHIM_MODE=invokeai_queue` so it enqueues a real InvokeAI workflow and returns the generated image as `b64_json`.

Note on `model` handling:

- The gateway may send a model string that does not match InvokeAI's internal model registry.
- By default, the shim treats the requested model as best-effort and will fall back to the model embedded in the workflow template.
- To make mismatched models a hard error, set `SHIM_STRICT_MODEL=true` in the shim service environment.

InvokeAI model input mode:

- `SHIM_MODEL_INPUT_MODE=id|name|dict` controls what the shim writes into model-selection fields in the queued graph.
- Recommended for InvokeAI 6.x: `SHIM_MODEL_INPUT_MODE=id` (most compatible with strict queue validation).

This repo deploys a default template to:

```bash
/var/lib/invokeai/openai_images_shim/graph_template.json
```

Enable via a systemd override on ada2:

```bash
sudo systemctl edit invokeai-openai-images-shim
```

Add:

```ini
[Service]
Environment="SHIM_MODE=invokeai_queue"
Environment="SHIM_GRAPH_TEMPLATE_PATH=/var/lib/invokeai/openai_images_shim/graph_template.json"
# Output node id for the default SDXL template (the l2i node)
Environment="SHIM_OUTPUT_NODE_ID=63e91020-83b2-4f35-b174-ad9692aabb48"
```

Then restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart invokeai-openai-images-shim
```

Smoke-test real generation (this may take 10–60s):

```bash
curl -sS -X POST http://127.0.0.1:7860/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{"prompt":"real mode test","response_format":"b64_json","size":"1024x1024","seed":1234,"steps":20,"cfg_scale":6}'
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
