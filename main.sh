#!/bin/bash
set -euo pipefail

START_TIME=$(date +%s)
cd /

WORKDIR="/workspace"
COMFY_REPO="https://github.com/comfyanonymous/ComfyUI.git"
COMFY_DIR="$WORKDIR/ComfyUI"
PORT=8188
LISTEN_ADDR="0.0.0.0"

# concurrency
MAXJOBS=${MAXJOBS:-4}

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# -------------------------
# STEP 0: install huggingface_hub and do HF login (serial, required)
# -------------------------
echo "[SETUP] Installing huggingface_hub..."
pip install --upgrade pip >/dev/null 2>&1 || true
pip install "huggingface_hub==0.36.0"

# HF login: use correct --token invocation
if [ -n "${HF_TOKEN:-}" ]; then
  echo "[SETUP] Logging in to Hugging Face..."
  mkdir -p "$HOME/.cache/huggingface"
  if huggingface-cli login --token "$HF_TOKEN"; then
    echo "[SETUP] HF login OK"
  else
    echo "[WARN] HF login failed (token may be invalid)"
  fi
else
  echo "[WARN] No HF_TOKEN provided; public models only."
fi

# Define hf_dl exactly as your original (unchanged)
hf_dl() {
  local repo="$1"
  local file="$2"
  local dest="$3"

  echo "Downloading $file from $repo → $dest"
  mkdir -p "$dest"
  huggingface-cli download "$repo" "$file" --local-dir "$dest" --local-dir-use-symlinks False || {
    echo "[ERROR] huggingface-cli failed to download $file from $repo. Check token/permissions and that the path is correct."
    return 1
  }
}

# --------------------------------------------------------------------
# CLONE TASK (handles existing non-empty dir safely)
# --------------------------------------------------------------------
clone_task() {
  # If repo already a git repo, do a lightweight pull
  if [ -d "$COMFY_DIR/.git" ]; then
    echo "[CLONE] Found existing git repo at $COMFY_DIR — pulling latest changes"
    git -C "$COMFY_DIR" fetch --depth=1 origin main || true
    git -C "$COMFY_DIR" pull --ff-only || true
  elif [ -d "$COMFY_DIR" ] && [ "$(ls -A "$COMFY_DIR")" != "" ]; then
    # exists but not a git repo (or partially present) — clone into temp and replace
    echo "[CLONE] $COMFY_DIR exists but is not a git repo. Cloning into temp and replacing..."
    rm -rf "/tmp/ComfyUI_tmp" || true
    git clone --depth 1 "$COMFY_REPO" "/tmp/ComfyUI_tmp" || {
      echo "[CLONE] WARN: clone into temp failed; leaving existing directory in place"
      return 0
    }
    rm -rf "$COMFY_DIR"
    mv "/tmp/ComfyUI_tmp" "$COMFY_DIR"
  else
    # not present — clone normally
    echo "[CLONE] Cloning ComfyUI into $COMFY_DIR"
    git clone --depth 1 "$COMFY_REPO" "$COMFY_DIR"
  fi

  # clone custom nodes (same as before)
  mkdir -p "$COMFY_DIR/custom_nodes"
  cd "$COMFY_DIR/custom_nodes"

  clone_if_missing() {
    local url="$1"
    local folder
    folder="$(basename "$url" .git)"
    if [ ! -d "$folder" ]; then
      echo "[CLONE] Cloning $url"
      git clone "$url" || echo "[CLONE] WARN: git clone failed for $url"
    else
      echo "[CLONE] $folder already cloned"
    fi
  }

  clone_if_missing "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
  clone_if_missing "https://github.com/kijai/comfyui-kjnodes.git"
  clone_if_missing "https://github.com/kijai/ComfyUI-MelBandRoFormer.git"
  clone_if_missing "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
  clone_if_missing "https://github.com/ltdrdata/ComfyUI-Manager.git"

  echo "[CLONE] clone_task finished"
}

# --------------------------------------------------------------------
# INSTALL TASK (pip installs main + custom nodes) - runs in parallel
# --------------------------------------------------------------------
install_task() {
  # ensure repo dir exists (clone_task may still be running)
  mkdir -p "$COMFY_DIR"
  cd "$COMFY_DIR" || return 0

  # create models dirs (safe)
  COMFY_MODELS_DIR="$COMFY_DIR/models"
  mkdir -p "$COMFY_MODELS_DIR/diffusion_models"
  mkdir -p "$COMFY_MODELS_DIR/vae"
  mkdir -p "$COMFY_MODELS_DIR/clip_vision"
  mkdir -p "$COMFY_MODELS_DIR/text_encoders"
  mkdir -p "$COMFY_MODELS_DIR/loras"

  echo "[INSTALL] Installing ComfyUI python deps (excluding torch-family)..."
  if [ -f requirements.txt ]; then
    grep -Ei -v '^(torch|torchvision|torchaudio)\b' requirements.txt > /tmp/reqs-no-torch.txt || true
    pip install --no-input -r /tmp/reqs-no-torch.txt || echo "[INSTALL] WARN: main pip install returned non-zero"
  else
    echo "[INSTALL] WARN: requirements.txt not found — skipping base requirement install."
  fi

  echo "[INSTALL] Installing huggingface_hub (CLI) pinned version..."
  pip install "huggingface_hub==0.36.0" || echo "[INSTALL] WARN: huggingface_hub install failed"

  # install custom node requirements in parallel but within this task
  req_files=(
    "custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt"
    "custom_nodes/comfyui-kjnodes/requirements.txt"
    "custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt"
    "custom_nodes/ComfyUI-MelBandRoFormer/requirements.txt"
    "custom_nodes/ComfyUI-Manager/requirements.txt"
  )

  for repo_req in "${req_files[@]}"; do
    if [ -f "$repo_req" ]; then
      (
        echo "[INSTALL] pip installing $repo_req"
        pip install --no-input -r "$repo_req" || echo "[INSTALL] WARN: pip install failed for $repo_req"
      ) &
      # throttle node pip installs
      while [ "$(jobs -rp | wc -l)" -ge "$MAXJOBS" ]; do
        sleep 0.3
      done
    else
      echo "[INSTALL] No requirements file at $repo_req — skipping."
    fi
  done

  # wait for background installs started in this task
  wait

  echo "[INSTALL] install_task finished"
}

# --------------------------------------------------------------------
# DOWNLOAD TASK (runs in parallel, but waits briefly if hf not ready)
# --------------------------------------------------------------------
download_task() {
  # Wait small time for huggingface_cli to be installed and login to finish (but proceed if not)
  HF_READY_TIMEOUT=30
  waited=0
  while [ "$waited" -lt "$HF_READY_TIMEOUT" ] && ! command -v huggingface-cli >/dev/null 2>&1; do
    sleep 1
    waited=$((waited+1))
  done
  if command -v huggingface-cli >/dev/null 2>&1; then
    echo "[DOWNLOAD] huggingface-cli available — proceeding with downloads"
  else
    echo "[DOWNLOAD] huggingface-cli not found after ${HF_READY_TIMEOUT}s — attempting downloads anyway (they may fail)"
  fi

  # Make sure models dir exists
  mkdir -p "$COMFY_MODELS_DIR" || true

  # Here we use your hf_dl function — but do them in parallel (no hardcoded new files)
  # If you want to add more hf_dl calls, add them here exactly as you had originally.
  # The example below mirrors your original script's single hf_dl call.
  echo "[DOWNLOAD] Launching hf_dl downloads in parallel (throttled)"
  hf_dl_bg() {
    local repo="$1"
    local file="$2"
    local dest="$3"
    (
      if hf_dl "$repo" "$file" "$dest"; then
        echo "OK|$repo|$file" >> /tmp/hf_download_status/success.txt
      else
        echo "FAIL|$repo|$file" >> /tmp/hf_download_status/failed.txt
      fi
    ) &
  }

  rm -rf /tmp/hf_download_status || true
  mkdir -p /tmp/hf_download_status

  # mirror original hf_dl calls (you can add others here)
  hf_dl_bg "Kijai/WanVideo_comfy" "Wan2_1_VAE_bf16.safetensors" "$COMFY_MODELS_DIR/vae"

  # include wav2vec files exactly like original if desired
  hf_dl_bg "TencentGameMate/chinese-wav2vec2-base" "pytorch_model.bin" "$COMFY_MODELS_DIR/transformers/TencentGameMate/chinese-wav2vec2-base"
  hf_dl_bg "TencentGameMate/chinese-wav2vec2-base" "config.json" "$COMFY_MODELS_DIR/transformers/TencentGameMate/chinese-wav2vec2-base"
  hf_dl_bg "TencentGameMate/chinese-wav2vec2-base" "preprocessor_config.json" "$COMFY_MODELS_DIR/transformers/TencentGameMate/chinese-wav2vec2-base"

  # throttle and wait for downloads to finish
  while [ "$(jobs -rp | wc -l)" -gt 0 ]; do
    sleep 0.5
  done

  echo "[DOWNLOAD] download_task finished"
}

# --------------------------------------------------------------------
# Run the three tasks in parallel
# --------------------------------------------------------------------
clone_task &
CLONE_PID=$!

install_task &
INSTALL_PID=$!

download_task &
DOWNLOAD_PID=$!

echo "[MAIN] Waiting for clone/install/download tasks (pids: $CLONE_PID $INSTALL_PID $DOWNLOAD_PID)..."
wait $CLONE_PID || echo "[MAIN] WARN: clone_task exited non-zero"
wait $INSTALL_PID || echo "[MAIN] WARN: install_task exited non-zero"
wait $DOWNLOAD_PID || echo "[MAIN] WARN: download_task exited non-zero"

# --------------------------------------------------------------------
# Start ComfyUI (same as your original)
# --------------------------------------------------------------------
cd "$COMFY_DIR"
echo "=== Setup complete. Starting ComfyUI ==="
echo "[INFO] Listening on $LISTEN_ADDR:$PORT"

python main.py --listen "$LISTEN_ADDR" --port "$PORT" --use-sage-attention &

wait

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo ""
echo "======================================"
echo "🚀 Total setup time: ${ELAPSED} seconds"
echo "======================================"
