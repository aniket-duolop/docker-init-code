#!/bin/bash
set -euo pipefail

# ------------------------
# Robust parallel startup script
# - preserves your original hf_dl, git, pip, and python commands
# - runs clone / downloads / installs in parallel but ensures installs
#   complete enough that downloads and ComfyUI won't fail due to missing CLI/libs
# ------------------------

START_TIME=$(date +%s)
cd /

# ------------------------
# Configuration (tunable)
# ------------------------
WORKDIR="${WORKDIR:-/workspace}"
COMFY_REPO="${COMFY_REPO:-https://github.com/comfyanonymous/ComfyUI.git}"
COMFY_DIR="${COMFY_DIR:-$WORKDIR/ComfyUI}"
COMFY_MODELS_DIR="${COMFY_MODELS_DIR:-$COMFY_DIR/models}"
PORT="${PORT:-8188}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
MAXJOBS="${MAXJOBS:-4}"           # concurrency for pip/model downloads
HF_TOKEN="${HF_TOKEN:-}"          # from env if provided

mkdir -p "$WORKDIR"
# Do NOT pre-create COMFY_DIR in a way that breaks cloning; tasks will handle it.
# But declare model dir path variable early so it's never "unbound"
: "${COMFY_MODELS_DIR:?COMFY_MODELS_DIR must be set}"

# Ensure a pip cache dir exists (optional speedup if you mount it)
mkdir -p /root/.cache/pip

echo "[BOOT] WORKDIR=$WORKDIR COMFY_DIR=$COMFY_DIR COMFY_MODELS_DIR=$COMFY_MODELS_DIR"

# ------------------------
# Helper: hf_dl (UNCHANGED behavior)
# Use huggingface-cli download exactly as you had
# ------------------------
hf_dl() {
  local repo="$1"
  local file="$2"
  local dest="$3"

  echo "[HF_DL] Downloading $file from $repo → $dest"
  mkdir -p "$dest"
  huggingface-cli download "$repo" "$file" --local-dir "$dest" --local-dir-use-symlinks False || {
    echo "[HF_DL] ERROR: huggingface-cli failed to download $file from $repo. Check token/permissions and that the path is correct."
    return 1
  }
}

# ------------------------
# STEP 0 — ensure basic runtime pieces serially (safe prep)
# - python/pip already present from base image; ensure pip updated
# - install huggingface_hub so huggingface-cli exists
# ------------------------
echo "[SETUP] Preparing base Python tooling..."
# upgrade pip (best-effort)
python3 -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true

echo "[SETUP] Installing huggingface_hub (provides huggingface-cli)..."
python3 -m pip install --no-input "huggingface_hub==0.36.0" >/dev/null 2>&1 || true

# If token provided, login non-interactively (correct --token usage)
if [ -n "$HF_TOKEN" ]; then
  echo "[SETUP] Logging into Hugging Face CLI..."
  mkdir -p "$HOME/.cache/huggingface"
  # Use the proper CLI option --token "$HF_TOKEN"
  if huggingface-cli login --token "$HF_TOKEN"; then
    echo "[SETUP] HF login OK"
  else
    echo "[SETUP] WARN: HF login failed (token may be invalid). Downloads of private models may fail."
  fi
else
  echo "[SETUP] WARN: No HF_TOKEN provided; only public models will download."
fi

# ------------------------
# Prepare status dirs used by background tasks
# ------------------------
rm -rf /tmp/hf_download_status /tmp/custom_node_install_status || true
mkdir -p /tmp/hf_download_status /tmp/custom_node_install_status /tmp/task_logs

# ------------------------
# clone_task: clone comfy + custom nodes (parallelizable)
# - handles existing dir safely (git pull if present)
# ------------------------
clone_task() {
  set -e
  echo "[CLONE] Starting clone_task..."
  # Clone or update ComfyUI:
  if [ -d "$COMFY_DIR/.git" ]; then
    echo "[CLONE] Found git repo at $COMFY_DIR — fetching and pulling main"
    git -C "$COMFY_DIR" fetch --depth 1 origin main || true
    git -C "$COMFY_DIR" pull --ff-only || true
  elif [ -d "$COMFY_DIR" ] && [ "$(ls -A "$COMFY_DIR")" != "" ]; then
    # existing non-git directory — clone into temp and replace
    echo "[CLONE] $COMFY_DIR exists but is not a git repo — cloning into temp"
    rm -rf /tmp/ComfyUI_tmp || true
    git clone --depth 1 "$COMFY_REPO" /tmp/ComfyUI_tmp || {
      echo "[CLONE] WARN: clone into temp failed; leaving existing directory in place"
      return 0
    }
    rm -rf "$COMFY_DIR"
    mv /tmp/ComfyUI_tmp "$COMFY_DIR"
  else
    # fresh clone
    echo "[CLONE] Cloning ComfyUI into $COMFY_DIR"
    git clone --depth 1 "$COMFY_REPO" "$COMFY_DIR"
  fi

  # custom nodes (safe, idempotent)
  mkdir -p "$COMFY_DIR/custom_nodes"
  cd "$COMFY_DIR/custom_nodes" || return

  clone_if_missing() {
    local url="$1"
    local folder
    folder="$(basename "$url" .git)"
    if [ ! -d "$folder" ]; then
      echo "[CLONE] Cloning $url"
      git clone --depth 1 "$url" || echo "[CLONE] WARN: git clone failed for $url"
    else
      echo "[CLONE] $folder already present"
      # attempt to update shallowly
      git -C "$folder" fetch --depth 1 origin main || true
    fi
  }

  clone_if_missing "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
  clone_if_missing "https://github.com/kijai/comfyui-kjnodes.git"
  clone_if_missing "https://github.com/kijai/ComfyUI-MelBandRoFormer.git"
  clone_if_missing "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
  clone_if_missing "https://github.com/ltdrdata/ComfyUI-Manager.git"

  echo "[CLONE] clone_task finished"
}

# ------------------------
# install_task: install requirements (main + custom-nodes) — runs in parallel
# - ensures key packages that custom prestartup needs are present:
#   safetensors, aiohttp, and anything from requirements.txt (excluding torch)
# ------------------------
install_task() {
  set -e
  echo "[INSTALL] Starting install_task..."
  # ensure dir exists (clone may be running concurrently)
  mkdir -p "$COMFY_DIR"
  cd "$COMFY_DIR" || return

  # create model dirs now if not present
  mkdir -p "$COMFY_MODELS_DIR"/{diffusion_models,vae,clip_vision,text_encoders,loras}

  # main requirements (exclude torch-family exactly as original)
  if [ -f requirements.txt ]; then
    echo "[INSTALL] Installing main requirements (excluding torch-family)..."
    grep -Ei -v '^(torch|torchvision|torchaudio)\b' requirements.txt > /tmp/reqs-no-torch.txt || true
    python3 -m pip install --no-input -r /tmp/reqs-no-torch.txt || {
      echo "[INSTALL] WARN: main pip install returned non-zero; continuing"
    }
  else
    echo "[INSTALL] WARN: requirements.txt not found — skipping main pip install"
  fi

  # ensure a few runtime libs custom nodes commonly require (prestartup errors previously)
  # keep these installs minimal and idempotent
  echo "[INSTALL] Ensuring critical runtime libs (safetensors, aiohttp, websockets, httpx)..."
  python3 -m pip install --no-input safetensors aiohttp httpx websockets || {
    echo "[INSTALL] WARN: installing critical libs failed (continuing)"
  }

  # ensure huggingface_hub present (idempotent)
  python3 -m pip install --no-input "huggingface_hub==0.36.0" || true

  # install custom node requirements in parallel but limited by MAXJOBS
  cd "$COMFY_DIR" || return
  req_files=(
    "custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt"
    "custom_nodes/comfyui-kjnodes/requirements.txt"
    "custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt"
    "custom_nodes/ComfyUI-MelBandRoFormer/requirements.txt"
    "custom_nodes/ComfyUI-Manager/requirements.txt"
  )

  # child installs will write status to /tmp/custom_node_install_status
  rm -f /tmp/custom_node_install_status/* || true

  for repo_req in "${req_files[@]}"; do
    if [ -f "$repo_req" ]; then
      (
        echo "[INSTALL] pip installing $repo_req"
        if python3 -m pip install --no-input -r "$repo_req"; then
          echo "OK|$repo_req" >> /tmp/custom_node_install_status/success.txt
        else
          echo "FAIL|$repo_req" >> /tmp/custom_node_install_status/failed.txt
        fi
      ) &
      # throttle node pip jobs
      while [ "$(jobs -rp | wc -l)" -ge "$MAXJOBS" ]; do
        sleep 0.25
      done
    else
      echo "[INSTALL] No requirements file at $repo_req — skipping."
    fi
  done

  # wait for all node installs spawned in this task to finish
  wait

  echo "[INSTALL] install_task finished"
}

# ------------------------
# download_task: run all hf_dl calls in parallel (kept behaviour identical)
# - waits until huggingface-cli exists (installed earlier) and model dirs exist
# - uses hf_dl wrapper unchanged
# ------------------------
download_task() {
  set -e
  echo "[DOWNLOAD] Starting download_task..."

  # allow the install_task to at least ensure huggingface-cli exists (but don't block forever)
  HF_WAIT=30
  waited=0
  while [ "$waited" -lt "$HF_WAIT" ] && ! command -v huggingface-cli >/dev/null 2>&1; do
    sleep 1
    waited=$((waited+1))
  done
  if command -v huggingface-cli >/dev/null 2>&1; then
    echo "[DOWNLOAD] huggingface-cli available, proceeding with downloads"
  else
    echo "[DOWNLOAD] WARN: huggingface-cli not available after ${HF_WAIT}s — downloads may fail"
  fi

  # ensure model dir exists
  mkdir -p "$COMFY_MODELS_DIR"
  mkdir -p "$COMFY_MODELS_DIR"/{diffusion_models,vae,transformers,clip_vision,text_encoders,loras}

  # hf_dl background wrapper (keeps hf_dl function same)
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

  # Clear old status
  rm -f /tmp/hf_download_status/* || true

  # ------------------------
  # IMPORTANT: Add your hf_dl calls below exactly as you previously had them.
  # I include the ones you used earlier (keeps behaviour identical).
  # If you have more hf_dl lines in your original script, add them here.
  # ------------------------
  hf_dl_bg "Kijai/WanVideo_comfy" "Wan2_1_VAE_bf16.safetensors" "$COMFY_MODELS_DIR/vae" || true

  hf_dl_bg "TencentGameMate/chinese-wav2vec2-base" "pytorch_model.bin" "$COMFY_MODELS_DIR/transformers/TencentGameMate/chinese-wav2vec2-base" || true
  hf_dl_bg "TencentGameMate/chinese-wav2vec2-base" "config.json" "$COMFY_MODELS_DIR/transformers/TencentGameMate/chinese-wav2vec2-base" || true
  hf_dl_bg "TencentGameMate/chinese-wav2vec2-base" "preprocessor_config.json" "$COMFY_MODELS_DIR/transformers/TencentGameMate/chinese-wav2vec2-base" || true

  # Add any other hf_dl(...) lines you originally had here in the same format.

  # throttle and wait for downloads to finish
  while [ "$(jobs -rp | wc -l)" -gt 0 ]; do
    sleep 0.5
  done

  echo "[DOWNLOAD] download_task finished"
}

# ------------------------
# RUN the three tasks in parallel
# ------------------------
# Start clone/install/download in parallel
clone_task &
CLONE_PID=$!

install_task &
INSTALL_PID=$!

download_task &
DOWNLOAD_PID=$!

echo "[MAIN] Waiting for clone/install/download tasks (pids: $CLONE_PID $INSTALL_PID $DOWNLOAD_PID)..."

# Wait on each; if one fails, continue but warn (keeps behaviour similar)
wait "$CLONE_PID" || echo "[MAIN] WARN: clone_task exited non-zero"
wait "$INSTALL_PID" || echo "[MAIN] WARN: install_task exited non-zero"
wait "$DOWNLOAD_PID" || echo "[MAIN] WARN: download_task exited non-zero"

# Report install/download summaries (non-fatal)
echo ""
echo "=== Summary: HF downloads ==="
if [ -f /tmp/hf_download_status/success.txt ]; then
  sed -n '1,200p' /tmp/hf_download_status/success.txt || true
fi
if [ -f /tmp/hf_download_status/failed.txt ]; then
  echo "FAILED downloads:"
  sed -n '1,200p' /tmp/hf_download_status/failed.txt || true
fi

echo ""
echo "=== Summary: custom-node installs ==="
if [ -f /tmp/custom_node_install_status/success.txt ]; then
  sed -n '1,200p' /tmp/custom_node_install_status/success.txt || true
fi
if [ -f /tmp/custom_node_install_status/failed.txt ]; then
  echo "FAILED custom node installs:"
  sed -n '1,200p' /tmp/custom_node_install_status/failed.txt || true
fi

# ------------------------
# Final: Start ComfyUI (only after orchestration above)
# ------------------------
echo "=== Setup complete. Starting ComfyUI ==="
if [ -f "$COMFY_DIR/main.py" ]; then
  cd "$COMFY_DIR"
  python3 main.py --listen "$LISTEN_ADDR" --port "$PORT" --use-sage-attention &
else
  echo "[ERROR] main.py not found at $COMFY_DIR/main.py — cannot start ComfyUI"
fi

# Wait for the ComfyUI process (if started)
wait 2>/dev/null || true

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo ""
echo "======================================"
echo "🚀 Total setup time: ${ELAPSED} seconds"
echo "======================================"
