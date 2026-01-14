#!/bin/bash
# Deploy/update InvokeAI configuration
#
# This script is called by deploy-host.sh to:
# - Update configuration files
# - Restart the service
# - NOT do full reinstalls (use install.sh for that)

set -e

echo "=== Deploying InvokeAI Configuration ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check if running as root or can sudo
if [ "$EUID" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

# Check if InvokeAI is installed
if [ ! -d /var/lib/invokeai ]; then
  echo "Error: InvokeAI not installed. Run install.sh first."
  exit 1
fi

echo "Updating configuration files..."

# Update invokeai.yaml if example is newer
if [ -f "$SERVICE_DIR/invokeai.yaml.example" ]; then
  if ! cmp -s "$SERVICE_DIR/invokeai.yaml.example" /var/lib/invokeai/invokeai.yaml; then
    echo "  Backing up existing invokeai.yaml..."
    $SUDO cp /var/lib/invokeai/invokeai.yaml /var/lib/invokeai/invokeai.yaml.bak
    
    echo "  Installing updated invokeai.yaml..."
    $SUDO cp "$SERVICE_DIR/invokeai.yaml.example" /var/lib/invokeai/invokeai.yaml
    $SUDO chown invokeai:invokeai /var/lib/invokeai/invokeai.yaml
    echo "  ✓ Config updated (backup at invokeai.yaml.bak)"
  else
    echo "  ✓ Config unchanged"
  fi
fi

# Update systemd service
if [ -f "$SERVICE_DIR/systemd/invokeai.service" ]; then
  if ! cmp -s "$SERVICE_DIR/systemd/invokeai.service" /etc/systemd/system/invokeai.service; then
    echo "  Updating systemd service..."
    $SUDO cp "$SERVICE_DIR/systemd/invokeai.service" /etc/systemd/system/
    $SUDO systemctl daemon-reload
    echo "  ✓ Service updated"
  else
    echo "  ✓ Service unchanged"
  fi
fi

# Update OpenAI images shim code
if [ -f "$SERVICE_DIR/shim/openai_images_shim.py" ]; then
  $SUDO mkdir -p /var/lib/invokeai/openai_images_shim
  if [ ! -f /var/lib/invokeai/openai_images_shim/openai_images_shim.py ] || ! cmp -s "$SERVICE_DIR/shim/openai_images_shim.py" /var/lib/invokeai/openai_images_shim/openai_images_shim.py; then
    echo "  Updating OpenAI images shim code..."
    $SUDO cp "$SERVICE_DIR/shim/openai_images_shim.py" /var/lib/invokeai/openai_images_shim/openai_images_shim.py
    $SUDO chown -R invokeai:invokeai /var/lib/invokeai/openai_images_shim
    echo "  ✓ Shim code updated"
  else
    echo "  ✓ Shim code unchanged"
  fi
fi

# Update optional graph template
if [ -f "$SERVICE_DIR/shim/graph_template.json" ]; then
  $SUDO mkdir -p /var/lib/invokeai/openai_images_shim
  if [ ! -f /var/lib/invokeai/openai_images_shim/graph_template.json ] || ! cmp -s "$SERVICE_DIR/shim/graph_template.json" /var/lib/invokeai/openai_images_shim/graph_template.json; then
    echo "  Updating OpenAI images shim graph template..."
    $SUDO cp "$SERVICE_DIR/shim/graph_template.json" /var/lib/invokeai/openai_images_shim/graph_template.json
    $SUDO chown invokeai:invokeai /var/lib/invokeai/openai_images_shim/graph_template.json
    echo "  ✓ Shim graph template updated"
  else
    echo "  ✓ Shim graph template unchanged"
  fi
fi

# Update OpenAI images shim systemd service
if [ -f "$SERVICE_DIR/systemd/invokeai-openai-images-shim.service" ]; then
  if [ ! -f /etc/systemd/system/invokeai-openai-images-shim.service ] || ! cmp -s "$SERVICE_DIR/systemd/invokeai-openai-images-shim.service" /etc/systemd/system/invokeai-openai-images-shim.service; then
    echo "  Updating OpenAI images shim systemd service..."
    $SUDO cp "$SERVICE_DIR/systemd/invokeai-openai-images-shim.service" /etc/systemd/system/
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable invokeai-openai-images-shim >/dev/null 2>&1 || true
    echo "  ✓ Shim service updated"
  else
    echo "  ✓ Shim service unchanged"
  fi
fi

# Update nginx config
if [ -f "$SERVICE_DIR/nginx/invokeai.conf" ]; then
  $SUDO mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  if ! cmp -s "$SERVICE_DIR/nginx/invokeai.conf" /etc/nginx/sites-available/invokeai; then
    echo "  Updating nginx config..."
    $SUDO cp "$SERVICE_DIR/nginx/invokeai.conf" /etc/nginx/sites-available/invokeai
    $SUDO ln -sf /etc/nginx/sites-available/invokeai /etc/nginx/sites-enabled/invokeai
    $SUDO ln -sf /etc/nginx/sites-available/invokeai /etc/nginx/sites-enabled/invokeai.conf
    
    if $SUDO nginx -t 2>/dev/null; then
      $SUDO systemctl reload nginx
      echo "  ✓ Nginx updated and reloaded"
    else
      echo "  ✗ Nginx config test failed"
      exit 1
    fi
  else
    echo "  ✓ Nginx unchanged"
  fi
fi

echo ""
echo "Restarting InvokeAI service..."
$SUDO systemctl restart invokeai

echo "Restarting OpenAI Images Shim service..."
$SUDO systemctl restart invokeai-openai-images-shim

# Wait for service to come up
sleep 5

if $SUDO systemctl is-active --quiet invokeai; then
  echo "✓ InvokeAI restarted successfully"
else
  echo "✗ InvokeAI failed to start"
  echo "Check logs: sudo journalctl -u invokeai -n 50"
  exit 1
fi

if $SUDO systemctl is-active --quiet invokeai-openai-images-shim; then
  echo "✓ OpenAI Images Shim restarted successfully"
else
  echo "✗ OpenAI Images Shim failed to start"
  echo "Check logs: sudo journalctl -u invokeai-openai-images-shim -n 50"
  exit 1
fi

echo ""
echo "Checking health..."
sleep 5

if curl -sf http://127.0.0.1:7860/healthz > /dev/null 2>&1; then
  echo "✓ Health check passed"
else
  echo "⚠ Health check failed (may still be starting)"
fi

echo ""
echo "=== Deployment Complete ==="
