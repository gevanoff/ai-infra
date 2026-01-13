#!/bin/bash
# Install InvokeAI on ada2 (Ubuntu + CUDA)
#
# Run as root or with sudo:
#   sudo ./install.sh

set -e

echo "=== InvokeAI Installation ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root"
  exit 1
fi

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v nvidia-smi &> /dev/null; then
  echo "Error: NVIDIA drivers not found. Install CUDA drivers first."
  exit 1
fi

if ! command -v python3.11 &> /dev/null; then
  echo "Installing Python 3.11..."
  apt update
  apt install -y python3.11 python3.11-venv python3.11-dev build-essential
fi

if ! command -v nginx &> /dev/null; then
  echo "Installing nginx..."
  apt install -y nginx
fi

echo "✓ Prerequisites satisfied"
echo ""

# Create invokeai user
echo "Creating invokeai user..."
if ! id invokeai &> /dev/null; then
  useradd -r -m -s /bin/bash invokeai
  echo "✓ User created"
else
  echo "✓ User already exists"
fi
echo ""

# Set up InvokeAI directory
echo "Setting up InvokeAI in /var/lib/invokeai..."
mkdir -p /var/lib/invokeai
chown invokeai:invokeai /var/lib/invokeai

# Create venv and install InvokeAI
echo "Installing InvokeAI (this may take 10-15 minutes)..."
sudo -u invokeai bash << 'EOSU'
cd /var/lib/invokeai

# Create venv
python3.11 -m venv venv
source venv/bin/activate

# Upgrade pip
pip install --upgrade pip setuptools wheel

# Install InvokeAI with xformers
pip install InvokeAI[xformers] --use-pep517 --extra-index-url https://download.pytorch.org/whl/cu121

echo "✓ InvokeAI installed"
EOSU

echo ""

# Copy config
echo "Setting up configuration..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/../invokeai.yaml.example" /var/lib/invokeai/invokeai.yaml
chown invokeai:invokeai /var/lib/invokeai/invokeai.yaml
echo "✓ Config created at /var/lib/invokeai/invokeai.yaml"
echo ""

# Install systemd service
echo "Installing systemd service..."
cp "$SCRIPT_DIR/../systemd/invokeai.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable invokeai
echo "✓ Service installed"
echo ""

# Install nginx config
echo "Installing nginx proxy..."
cp "$SCRIPT_DIR/../nginx/invokeai.conf" /etc/nginx/sites-available/
ln -sf /etc/nginx/sites-available/invokeai.conf /etc/nginx/sites-enabled/

# Remove default nginx site if it exists
rm -f /etc/nginx/sites-enabled/default

# Test nginx config
if nginx -t; then
  systemctl restart nginx
  echo "✓ Nginx configured"
else
  echo "✗ Nginx configuration error"
  exit 1
fi
echo ""

# Start InvokeAI
echo "Starting InvokeAI service..."
systemctl start invokeai
sleep 5

if systemctl is-active --quiet invokeai; then
  echo "✓ InvokeAI is running"
else
  echo "✗ InvokeAI failed to start"
  echo "Check logs: sudo journalctl -u invokeai -n 50"
  exit 1
fi
echo ""

# Check health
echo "Checking health endpoints..."
sleep 10

if curl -sf http://127.0.0.1:7860/healthz > /dev/null; then
  echo "✓ Health check passed"
else
  echo "✗ Health check failed"
  echo "Check nginx logs: sudo tail /var/log/nginx/invokeai-error.log"
fi
echo ""

echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo "1. Access web UI: http://ada2.local:7860"
echo "2. Download models via Model Manager in the UI"
echo "3. Test image generation"
echo "4. Configure gateway to use this service"
echo ""
echo "Logs:"
echo "  sudo journalctl -u invokeai -f"
echo "  sudo tail -f /var/log/nginx/invokeai-access.log"
echo ""
echo "Management:"
echo "  sudo systemctl status invokeai"
echo "  sudo systemctl restart invokeai"
