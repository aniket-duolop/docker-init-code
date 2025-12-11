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
  pip install --no-input -r /tmp/reqs-no-torch.txt
else
  echo "[WARN] requirements.txt not found in $COMFY_DIR — skipping base requirement install."
fi


# ------------------------
# Hugging Face CLI / hub setup
# ------------------------
echo "[INFO] Installing huggingface_hub (CLI) pinned version..."
# $PIP install "huggingface_hub==0.36.0"
pip install "huggingface_hub==0.36.0"

# If token provided via env, log in non-interactively
if [ -n "$HF_TOKEN" ]; then
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
# Helper: huggingface download wrapper
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

# ------------------------
# Download models (GGUF / safetensors / text encoders / VAEs / LoRAs)
# Adjust repo/file names if they change on HF.
# ------------------------
echo "[INFO] Downloading model files to $COMFY_MODELS_DIR (this may take a while)..."

# # 1) Diffusion Models (GGUF versions)
# hf_dl "Kijai/WanVideo_comfy_GGUF" "InfiniteTalk/Wan2_1-InfiniteTalk_Single_Q8.gguf" "$COMFY_MODELS_DIR/diffusion_models" || true
# hf_dl "Kijai/WanVideo_comfy_GGUF" "InfiniteTalk/Wan2_1-InfiniteTalk_Multi_Q8.gguf" "$COMFY_MODELS_DIR/diffusion_models" || true
# hf_dl "city96/Wan2.1-I2V-14B-480P-gguf" "wan2.1-i2v-14b-480p-Q8_0.gguf" "$COMFY_MODELS_DIR/diffusion_models" || true
# hf_dl "Kijai/MelBandRoFormer_comfy" "MelBandRoformer_fp16.safetensors" "$COMFY_MODELS_DIR/diffusion_models" || true

# 2) VAE
hf_dl "Kijai/WanVideo_comfy" "Wan2_1_VAE_bf16.safetensors" "$COMFY_MODELS_DIR/vae" || true

# # 3) CLIP Vision
# hf_dl "Comfy-Org/Wan_2.1_ComfyUI_repackaged" "split_files/clip_vision/clip_vision_h.safetensors" "$COMFY_MODELS_DIR/clip_vision" || true

# # 4) Text Encoder
# hf_dl "Kijai/WanVideo_comfy" "umt5-xxl-enc-bf16.safetensors" "$COMFY_MODELS_DIR/text_encoders" || true

# # 5) LoRA
# hf_dl "Kijai/WanVideo_comfy" "Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors" "$COMFY_MODELS_DIR/loras" || true

# # ------------------------
# # 6) Transformers - Chinese wav2vec2 base
# # ------------------------
# W2V_DIR="$COMFY_MODELS_DIR/transformers/TencentGameMate/chinese-wav2vec2-base"

# hf_dl "TencentGameMate/chinese-wav2vec2-base" "pytorch_model.bin" "$W2V_DIR" || true
# hf_dl "TencentGameMate/chinese-wav2vec2-base" "config.json" "$W2V_DIR" || true
# hf_dl "TencentGameMate/chinese-wav2vec2-base" "preprocessor_config.json" "$W2V_DIR" || true


echo "✅ Model download section finished (some downloads may have failed — check the log above)."

# ------------------------
# Custom nodes: clone and install
# ------------------------
echo "[INFO] Ensuring custom_nodes and node repos exist..."
CUSTOM_DIR="$COMFY_DIR/custom_nodes"
mkdir -p "$CUSTOM_DIR"
cd "$CUSTOM_DIR"

# Clone if not present
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

# ✅ Only new addition #1
clone_if_missing "https://github.com/ltdrdata/ComfyUI-Manager.git"

# install their requirements (if found)
cd "$COMFY_DIR"

# Use an array to avoid line-continuation syntax issues
req_files=(
  "custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt"
  "custom_nodes/comfyui-kjnodes/requirements.txt"
  "custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt"
  "custom_nodes/ComfyUI-MelBandRoFormer/requirements.txt"
  "custom_nodes/ComfyUI-Manager/requirements.txt"
)

for repo_req in "${req_files[@]}"; do
  if [ -f "$repo_req" ]; then
    echo "[INFO] Installing requirements from $repo_req"
    pip install --no-input -r "$repo_req" || echo "[WARN] pip install failed for $repo_req"
  else
    echo "[INFO] No requirements file at $repo_req — skipping."
  fi
done

# ------------------------
# Final info + start ComfyUI
# ------------------------
echo "=== Setup complete. Starting ComfyUI ==="
echo "[INFO] Listening on $LISTEN_ADDR:$PORT"


# Start ComfyUI
$PY main.py --listen "$LISTEN_ADDR" --port "$PORT" --use-sage-attention &

wait

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo ""
echo "======================================"
echo "🚀 Total setup time: ${ELAPSED} seconds"
echo "======================================"