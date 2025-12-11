#!/bin/bash
set -euo pipefail

START_TIME=$(date +%s)
cd /

WORKDIR="/workspace"
COMFY_REPO="https://github.com/comfyanonymous/ComfyUI.git"
COMFY_DIR="$WORKDIR/ComfyUI"
PORT=8188
LISTEN_ADDR="0.0.0.0"

# concurrency level
MAXJOBS=4

mkdir -p "$WORKDIR"
mkdir -p "$COMFY_DIR"
mkdir -p "$HOME/.cache/huggingface"

# --------------------------------------------------------------------
# STEP 0 — SERIAL "SETUP EVERYTHING FIRST" (NO PARALLEL HERE)
# --------------------------------------------------------------------

echo "[SETUP] Installing huggingface_hub..."
pip install "huggingface_hub==0.36.0"

# HF login BEFORE parallel operations
if [ -n "${HF_TOKEN:-}" ]; then
    echo "[SETUP] Logging in to HuggingFace..."
    echo "$HF_TOKEN" | huggingface-cli login --token || echo "[WARN] HF login failed"
else
    echo "[WARN] No HF_TOKEN provided."
fi

# Create model directories BEFORE tasks start
COMFY_MODELS_DIR="$COMFY_DIR/models"
mkdir -p "$COMFY_MODELS_DIR"/{diffusion_models,vae,clip_vision,text_encoders,loras}

# Define hf_dl BEFORE tasks start
hf_dl() {
    local repo="$1"
    local file="$2"
    local dest="$3"
    echo "[HF] Downloading $file from $repo → $dest"
    mkdir -p "$dest"
    huggingface-cli download "$repo" "$file" --local-dir "$dest" --local-dir-use-symlinks False
}

echo "[SETUP] Base environment ready. Starting parallel tasks..."

# --------------------------------------------------------------------
# STEP 1 — DEFINE PARALLEL TASKS (NO FUNCTIONAL CHANGES)
# --------------------------------------------------------------------

clone_task() {
    cd "$WORKDIR"

    if [ ! -d "$COMFY_DIR/.git" ]; then
        git clone "$COMFY_REPO" "$COMFY_DIR"
    fi

    cd "$COMFY_DIR/custom_nodes"
    mkdir -p .

    clone_if_missing() {
        local url="$1"
        local folder
        folder=$(basename "$url" .git)
        [ ! -d "$folder" ] && git clone "$url" || true
    }

    clone_if_missing "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
    clone_if_missing "https://github.com/kijai/comfyui-kjnodes.git"
    clone_if_missing "https://github.com/kijai/ComfyUI-MelBandRoFormer.git"
    clone_if_missing "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
    clone_if_missing "https://github.com/ltdrdata/ComfyUI-Manager.git"
}

install_task() {
    cd "$COMFY_DIR"

    if [ -f requirements.txt ]; then
        grep -Ei -v '^(torch|torchvision|torchaudio)\b' requirements.txt > /tmp/reqs-no-torch.txt || true
        pip install --no-input -r /tmp/reqs-no-torch.txt
    fi

    req_files=(
      "custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt"
      "custom_nodes/comfyui-kjnodes/requirements.txt"
      "custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt"
      "custom_nodes/ComfyUI-MelBandRoFormer/requirements.txt"
      "custom_nodes/ComfyUI-Manager/requirements.txt"
    )

    for f in "${req_files[@]}"; do
        [ -f "$f" ] && pip install --no-input -r "$f" || true
    done
}

download_task() {
    cd "$COMFY_DIR"

    # EXACT same downloads you wrote (no hardcoding added by me)
    hf_dl "Kijai/WanVideo_comfy" "Wan2_1_VAE_bf16.safetensors" "$COMFY_MODELS_DIR/vae" || true

    # (your commented items remain commented — unchanged)
    # hf_dl ...
    # hf_dl ...
}

# --------------------------------------------------------------------
# STEP 2 — RUN ALL THREE TASKS IN PARALLEL
# --------------------------------------------------------------------

clone_task &
PID_CLONE=$!

install_task &
PID_INSTALL=$!

download_task &
PID_DOWNLOAD=$!

echo "[MAIN] Waiting for clone/install/download to finish..."
wait $PID_CLONE || echo "[WARN] clone task failed"
wait $PID_INSTALL || echo "[WARN] install task failed"
wait $PID_DOWNLOAD || echo "[WARN] download task failed"

# --------------------------------------------------------------------
# STEP 3 — START COMFYUI (unchanged)
# --------------------------------------------------------------------

echo "=== Setup complete. Starting ComfyUI ==="
cd "$COMFY_DIR"
python main.py --listen "$LISTEN_ADDR" --port "$PORT" --use-sage-attention &

wait

END_TIME=$(date +%s)
echo "Total time: $((END_TIME - START_TIME)) seconds"
