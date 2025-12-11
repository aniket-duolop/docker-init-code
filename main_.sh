#!/bin/bash
set -euo pipefail

START_TIME=$(date +%s)
cd /

WORKDIR="/workspace"
COMFY_REPO="https://github.com/comfyanonymous/ComfyUI.git"
COMFY_DIR="$WORKDIR/ComfyUI"
PORT=8188
LISTEN_ADDR="0.0.0.0"

# ---- concurrency tuning ----
MAXJOBS=${MAXJOBS:-4}    # adjust to your CPU/IO/bandwidth (4 is a safe default)

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


echo "[INFO] Installing ComfyUI python deps (excluding torch-family)..."
if [ -f requirements.txt ]; then
  # filter out torch-family lines robustly and install
  grep -Ei -v '^(torch|torchvision|torchaudio)\b' requirements.txt > /tmp/reqs-no-torch.txt || true

  # Run main pip install in background (same command as before) and capture pid
  echo "[INFO] Starting main pip install in background (pip install --no-input -r /tmp/reqs-no-torch.txt)"
  (
    set -x
    pip install --no-input -r /tmp/reqs-no-torch.txt
  ) > /tmp/pip_main_install.log 2>&1 &
  PIP_MAIN_PID=$!
else
  echo "[WARN] requirements.txt not found in $COMFY_DIR — skipping base requirement install."
  PIP_MAIN_PID=""
fi


# ------------------------
# Hugging Face CLI / hub setup
# ------------------------
echo "[INFO] Installing huggingface_hub (CLI) pinned version..."
# $PIP install "huggingface_hub==0.36.0"
pip install "huggingface_hub==0.36.0"

# If token provided via env, log in non-interactively
if [ -n "${HF_TOKEN:-}" ]; then
  echo "[INFO] Logging into Hugging Face CLI using HUGGINGFACE_TOKEN environment variable..."
  # create temporary netrc to avoid interactive prompt for login
  mkdir -p "$HOME/.cache/huggingface"
  echo "$HF_TOKEN" | huggingface-cli login --token || {
    echo "[WARN] huggingface-cli login failed. You may need to run 'huggingface-cli login' manually."
  }
else
  echo "[WARN] No HUGGINGFACE_TOKEN provided. To enable downloads, export HUGGINGFACE_TOKEN and re-run this script."
fi

# ------------------------
# Helper: huggingface download wrapper (unchanged)
# ------------------------
hf_dl() {
  local repo="$1"
  local file="$2"
  local dest="$3"

  echo "Downloading $file from $repo → $dest"
  mkdir -p "$dest"
  # Use huggingface-cli download. This assumes huggingface-cli is available and logged in (or model is public).
  huggingface-cli download "$repo" "$file" --local-dir "$dest" --local-dir-use-symlinks False || {
    echo "[ERROR] huggingface-cli failed to download $file from $repo. Check token/permissions and that the path is correct."
    return 1
  }
}

# ----- New: background wrapper for hf_dl that records status (keeps hf_dl identical) -----
# status dir
rm -rf /tmp/hf_download_status || true
mkdir -p /tmp/hf_download_status

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

# ------------------------
# Download models (GGUF / safetensors / text encoders / VAEs / LoRAs)
# Adjust repo/file names if they change on HF.
# This runs the same hf_dl calls as before but in parallel (throttled by MAXJOBS)
# ------------------------
echo "[INFO] Downloading model files to $COMFY_MODELS_DIR (this may take a while)..."

# Build list of downloads exactly corresponding to your hf_dl calls (preserve functionality)
DOWNLOAD_ITEMS=(
  "Kijai/WanVideo_comfy|Wan2_1_VAE_bf16.safetensors|$COMFY_MODELS_DIR/vae"
  # Add more items here if you uncomment / add hf_dl lines later
)

# spawn downloads in background while throttling concurrency
for it in "${DOWNLOAD_ITEMS[@]}"; do
  repo="${it%%|*}"
  rest="${it#*|}"
  file="${rest%%|*}"
  dest="${rest#*|}"

  hf_dl_bg "$repo" "$file" "$dest"

  # throttle to MAXJOBS
  while [ "$(jobs -rp | wc -l)" -ge "$MAXJOBS" ]; do
    sleep 0.3
  done
done

# Note: if you have literal hf_dl calls elsewhere not reflected in DOWNLOAD_ITEMS, add them to the list above.
# Waiting for downloads will happen below (after launching custom node installs) so installs+downloads run concurrently.


echo "✅ Model download section launched (some downloads may have failed — check the log above and summary after installs)."


# ------------------------
# Custom nodes: clone and install
# ------------------------
echo "[INFO] Ensuring custom_nodes and node repos exist..."
CUSTOM_DIR="$COMFY_DIR/custom_nodes"
mkdir -p "$CUSTOM_DIR"
cd "$CUSTOM_DIR"

# Clone if not present (unchanged)
clone_if_missing() {
  local url="$1"
  local folder
  folder="$(basename "$url" .git)"
  if [ ! -d "$folder" ]; then
    echo "[INFO] Cloning $url"
    git clone "$url" || echo "[WARN] git clone failed for $url"
  else
    echo "[INFO] $folder already cloned"
  fi
}

clone_if_missing "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
clone_if_missing "https://github.com/kijai/comfyui-kjnodes.git"
clone_if_missing "https://github.com/kijai/ComfyUI-MelBandRoFormer.git"
clone_if_missing "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
clone_if_missing "https://github.com/ltdrdata/ComfyUI-Manager.git"

# install their requirements (if found) -- parallelized, same pip command as before
cd "$COMFY_DIR"

# Use an array to avoid line-continuation syntax issues
req_files=(
  "custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt"
  "custom_nodes/comfyui-kjnodes/requirements.txt"
  "custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt"
  "custom_nodes/ComfyUI-MelBandRoFormer/requirements.txt"
  "custom_nodes/ComfyUI-Manager/requirements.txt"
)

# prepare status dir for node installs
rm -rf /tmp/custom_node_install_status || true
mkdir -p /tmp/custom_node_install_status
CUSTOM_LOGDIR="/tmp/custom_node_logs"
rm -rf "$CUSTOM_LOGDIR" || true
mkdir -p "$CUSTOM_LOGDIR"

# function to run node pip installs in background (same pip args)
node_install_bg() {
  local repo_req="$1"
  local logfile="$2"
  (
    echo "[INFO] pip installing $repo_req"
    if pip install --no-input -r "$repo_req"; then
      echo "OK|$repo_req" >> /tmp/custom_node_install_status/success.txt
    else
      echo "FAIL|$repo_req" >> /tmp/custom_node_install_status/failed.txt
    fi
  ) >"$logfile" 2>&1 &
}

# spawn installs, throttled
for repo_req in "${req_files[@]}"; do
  if [ -f "$repo_req" ]; then
    logfile="$CUSTOM_LOGDIR/$(basename "$repo_req").log"
    node_install_bg "$repo_req" "$logfile"

    # throttle node pip jobs to avoid overwhelming I/O
    while [ "$(jobs -rp | wc -l)" -ge "$MAXJOBS" ]; do
      sleep 0.3
    done
  else
    echo "[INFO] No requirements file at $repo_req — skipping."
  fi
done

# ------------------------
# Wait for all background tasks: pip main, node installs, hf downloads
# ------------------------
echo "[INFO] Waiting for background installs and downloads to finish..."
# Wait for background jobs launched in this shell (pip main, hf_dl_bg, node_install_bg)
wait

# optional: inspect exit status files and logs (no change in functionality)
echo ""
echo "=== Background tasks summary ==="
if [ -f /tmp/pip_main_install.log ]; then
  echo "Main pip install log tail:"
  tail -n 8 /tmp/pip_main_install.log || true
fi

echo ""
if [ -f /tmp/hf_download_status/success.txt ]; then
  echo "HF download successes:"
  sed -n '1,200p' /tmp/hf_download_status/success.txt || true
fi
if [ -f /tmp/hf_download_status/failed.txt ]; then
  echo "HF download failures:"
  sed -n '1,200p' /tmp/hf_download_status/failed.txt || true
fi

echo ""
if [ -f /tmp/custom_node_install_status/success.txt ]; then
  echo "Custom node install successes:"
  sed -n '1,200p' /tmp/custom_node_install_status/success.txt || true
fi
if [ -f /tmp/custom_node_install_status/failed.txt ]; then
  echo "Custom node install failures:"
  sed -n '1,200p' /tmp/custom_node_install_status/failed.txt || true
fi

# ------------------------
# Final info + start ComfyUI (unchanged)
# ------------------------
echo "=== Setup complete. Starting ComfyUI ==="
echo "[INFO] Listening on $LISTEN_ADDR:$PORT"

# Start ComfyUI (unchanged)
python main.py --listen "$LISTEN_ADDR" --port "$PORT" --use-sage-attention &

wait

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo ""
echo "======================================"
echo "🚀 Total setup time: ${ELAPSED} seconds"
echo "======================================"
