#!/bin/bash
set -euo pipefail
cd /

# ------------------------
# System packages (aria2) - non-blocking if not available
# ------------------------
if command -v apt-get >/dev/null 2>&1; then
  echo "[INFO] Updating apt and installing aria2 (may prompt for sudo password)..."
  sudo apt-get update -y
  sudo apt-get install -y aria2 || true
else
  echo "[WARN] apt-get not found; skipping apt install of aria2."
fi

WORKDIR="/workspace"
COMFY_REPO="https://github.com/comfyanonymous/ComfyUI.git"
COMFY_DIR="$WORKDIR/ComfyUI"
PORT=8188
LISTEN_ADDR="0.0.0.0"

HF_TOKEN=""

mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ ! -d "$COMFY_DIR" ]; then
  echo "[INFO] Cloning ComfyUI into $COMFY_DIR"
  git clone "$COMFY_REPO" "$COMFY_DIR"
else
  echo "[INFO] ComfyUI already exists at $COMFY_DIR"
fi

cd "$COMFY_DIR"
echo "[INFO] Entered $COMFY_DIR"

# ------------------------
# Create models folders
# ------------------------
COMFY_MODELS_DIR="$COMFY_DIR/models"
mkdir -p "$COMFY_MODELS_DIR/diffusion_models"
mkdir -p "$COMFY_MODELS_DIR/vae"
mkdir -p "$COMFY_MODELS_DIR/clip_vision"
mkdir -p "$COMFY_MODELS_DIR/text_encoders"
mkdir -p "$COMFY_MODELS_DIR/loras"

# ------------------------
# Install python packages (requirements without torch family)
# ------------------------
echo "[INFO] Preparing pip and wheel..."
pip install --upgrade pip setuptools wheel

pip install fastapi uvicorn python-multipart requests

pip install packaging ninja

echo "[INFO] Installing ComfyUI python deps (excluding torch-family)..."
if [ -f requirements.txt ]; then
  # filter out torch-family lines robustly and install
  grep -Ei -v '^(torch|torchvision|torchaudio)\b' requirements.txt > /tmp/reqs-no-torch.txt || true
  $PIP install --no-input -r /tmp/reqs-no-torch.txt
else
  echo "[WARN] requirements.txt not found in $COMFY_DIR — skipping base requirement install."
fi


python3 -m http.server 3000
