#!/bin/bash
set -euo pipefail

START_TIME=$(date +%s)
cd /

WORKDIR="/workspace"
COMFY_REPO="https://github.com/comfyanonymous/ComfyUI.git"
COMFY_DIR="$WORKDIR/ComfyUI"
PORT=8188
LISTEN_ADDR="0.0.0.0"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ------------------------
# Helpers & Globals
# ------------------------
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

# hf_dl uses huggingface-cli; ensure huggingface_hub is installed prior to starting downloads
hf_dl() {
  local repo="$1"
  local file="$2"
  local dest="$3"

  log "Downloading $file from $repo → $dest"
  mkdir -p "$dest"
  huggingface-cli download "$repo" "$file" --local-dir "$dest" --local-dir-use-symlinks False || {
    log "[ERROR] huggingface-cli failed to download $file from $repo. Check token/permissions and the path."
    return 1
  }
}

# clone a repo if folder missing (basename used)
clone_if_missing() {
  local url="$1"
  local folder
  folder="$(basename "$url" .git)"
  if [ ! -d "$folder" ]; then
    log "Cloning $url"
    git clone "$url" || log "[WARN] git clone failed for $url"
  else
    log "$folder already cloned"
  fi
}

# ------------------------
# 1) Clone ComfyUI repository (or skip if exists)
# ------------------------
clone_comfy() {
  if [ ! -d "$COMFY_DIR" ]; then
    log "Cloning ComfyUI into $COMFY_DIR"
    git clone "$COMFY_REPO" "$COMFY_DIR"
  else
    log "ComfyUI already exists at $COMFY_DIR"
  fi
  cd "$COMFY_DIR"
  log "Entered $COMFY_DIR"
}

# ------------------------
# 2) Ensure model directories exist
# ------------------------
create_model_dirs() {
  COMFY_MODELS_DIR="$COMFY_DIR/models"
  mkdir -p "$COMFY_MODELS_DIR/diffusion_models"
  mkdir -p "$COMFY_MODELS_DIR/vae"
  mkdir -p "$COMFY_MODELS_DIR/clip_vision"
  mkdir -p "$COMFY_MODELS_DIR/text_encoders"
  mkdir -p "$COMFY_MODELS_DIR/loras"
  log "Created model directories under $COMFY_MODELS_DIR"
}

# ------------------------
# 3) Clone & prepare custom_nodes (requirements live here)
# ------------------------
clone_custom_nodes() {
  CUSTOM_DIR="$COMFY_DIR/custom_nodes"
  mkdir -p "$CUSTOM_DIR"
  cd "$CUSTOM_DIR"

  clone_if_missing "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
  clone_if_missing "https://github.com/kijai/comfyui-kjnodes.git"
  clone_if_missing "https://github.com/kijai/ComfyUI-MelBandRoFormer.git"
  clone_if_missing "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
  clone_if_missing "https://github.com/ltdrdata/ComfyUI-Manager.git"

  # return to COMFY_DIR
  cd "$COMFY_DIR"
  log "Custom nodes cloned (if missing)."
}

# ------------------------
# 4) Install huggingface_hub early (so downloads can run)
# ------------------------
install_huggingface_cli() {
  log "Installing huggingface_hub (CLI) pinned version..."
  pip install "huggingface_hub==0.36.0"
  log "huggingface_hub installed."
}

# ---------------
# 5a) Install python requirements (non-torch base + node reqs)
# This will be run in background in parallel with model downloads.
# ---------------
install_requirements() {
  log "Starting requirements installation..."

  cd "$COMFY_DIR"

  # Base requirements.txt (filter out torch-family lines)
  if [ -f requirements.txt ]; then
    log "Filtering out torch-family packages from requirements.txt and installing rest..."
    grep -Ei -v '^(torch|torchvision|torchaudio)\b' requirements.txt > /tmp/reqs-no-torch.txt || true
    pip install --no-input -r /tmp/reqs-no-torch.txt || log "[WARN] pip install of base requirements failed"
  else
    log "[WARN] requirements.txt not found in $COMFY_DIR — skipping base requirement install."
  fi

  # Install requirements from custom node repos (if present)
  req_files=(
    "custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt"
    "custom_nodes/comfyui-kjnodes/requirements.txt"
    "custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt"
    "custom_nodes/ComfyUI-MelBandRoFormer/requirements.txt"
    "custom_nodes/ComfyUI-Manager/requirements.txt"
  )

  for repo_req in "${req_files[@]}"; do
    if [ -f "$repo_req" ]; then
      log "Installing requirements from $repo_req"
      pip install --no-input -r "$repo_req" || log "[WARN] pip install failed for $repo_req"
    else
      log "No requirements file at $repo_req — skipping."
    fi
  done

  log "Requirements installation finished."
}

# ---------------
# 5b) Download HF model files (run in parallel)
# ---------------
download_models() {
  log "Starting Hugging Face model downloads..."
  COMFY_MODELS_DIR="$COMFY_DIR/models"
  # Example: VAE
  hf_dl "Kijai/WanVideo_comfy" "Wan2_1_VAE_bf16.safetensors" "$COMFY_MODELS_DIR/vae" || true

  # Add additional hf_dl calls as needed (commented out entries kept for your convenience)
  # hf_dl "Kijai/WanVideo_comfy_GGUF" "InfiniteTalk/Wan2_1-InfiniteTalk_Single_Q8.gguf" "$COMFY_MODELS_DIR/diffusion_models" || true
  # hf_dl "Kijai/WanVideo_comfy_GGUF" "InfiniteTalk/Wan2_1-InfiniteTalk_Multi_Q8.gguf" "$COMFY_MODELS_DIR/diffusion_models" || true
  # hf_dl "city96/Wan2.1-I2V-14B-480P-gguf" "wan2.1-i2v-14b-480p-Q8_0.gguf" "$COMFY_MODELS_DIR/diffusion_models" || true
  # hf_dl "Kijai/MelBandRoFormer_comfy" "MelBandRoformer_fp16.safetensors" "$COMFY_MODELS_DIR/diffusion_models" || true

  # Transformers example (if needed)
  # W2V_DIR="$COMFY_MODELS_DIR/transformers/TencentGameMate/chinese-wav2vec2-base"
  # hf_dl "TencentGameMate/chinese-wav2vec2-base" "pytorch_model.bin" "$W2V_DIR" || true
  # hf_dl "TencentGameMate/chinese-wav2vec2-base" "config.json" "$W2V_DIR" || true
  # hf_dl "TencentGameMate/chinese-wav2vec2-base" "preprocessor_config.json" "$W2V_DIR" || true

  log "Model download section finished (some downloads may have failed — check the log above)."
}

# ------------------------
# MAIN flow (keeps your original order, only split into functions)
# ------------------------
clone_comfy
create_model_dirs
clone_custom_nodes

# Install huggingface hub CLI before downloads start
install_huggingface_cli

# If HF token provided, do non-interactive login (same behavior as your original script)
if [ -n "${HF_TOKEN:-}" ]; then
  log "Logging into Hugging Face CLI using HUGGINGFACE_TOKEN environment variable..."
  mkdir -p "$HOME/.cache/huggingface"
  echo "$HF_TOKEN" | huggingface-cli login --token || log "[WARN] huggingface-cli login failed. You may need to run 'huggingface-cli login' manually."
else
  log "[WARN] No HUGGINGFACE_TOKEN provided. To enable downloads, export HUGGINGFACE_TOKEN and re-run this script."
fi

# Safety: ensure we are in COMFY_DIR
cd "$COMFY_DIR"

# Trap to kill background jobs on exit
bg_pids=()
cleanup() {
  for pid in "${bg_pids[@]:-}"; do
    if kill -0 "$pid" 2>/dev/null; then
      log "Killing background job $pid"
      kill "$pid" || true
    fi
  done
}
trap cleanup EXIT

# Start both long-running tasks in background to run in parallel
install_requirements &
bg_pids+=($!)
download_models &
bg_pids+=($!)

log "Waiting for background tasks to finish (install_requirements & download_models)..."
# wait for all background pids we recorded
for pid in "${bg_pids[@]}"; do
  if wait "$pid"; then
    log "Background job $pid completed successfully."
  else
    log "Background job $pid exited with non-zero status."
  fi
done

# ------------------------
# Final info + start ComfyUI
# ------------------------
log "=== Setup complete. Starting ComfyUI ==="
log "Listening on $LISTEN_ADDR:$PORT"

# Start ComfyUI (same flags you used)
python main.py --listen "$LISTEN_ADDR" --port "$PORT" --use-sage-attention &

# Wait for the server process (so we can print elapsed time after termination)
wait

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo ""
echo "======================================"
echo "🚀 Total setup time: ${ELAPSED} seconds"
echo "======================================"
