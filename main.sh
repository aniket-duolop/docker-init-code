# ------------------------
# Runtime model download block (drop-in replacement)
# - preserves COMFY_MODELS_DIR, HF_TOKEN handling and huggingface-cli usage
# - parallelizes downloads using hf_dl_bg (uses hf_dl_with_retries/hf_dl_bg from earlier)
# ------------------------

# ensure HF_TOKEN is read from environment (do not overwrite if already set)
HF_TOKEN="${HF_TOKEN:-}"

# Non-interactive HF login if token provided (keeps same behavior as earlier)
if [ -n "$HF_TOKEN" ]; then
  echo "[INFO] HF_TOKEN present — performing non-interactive huggingface-cli login..."
  # create cache dir to avoid interactive prompt issues
  mkdir -p "$HOME/.cache/huggingface"
  # login; ignore failure but warn
  if huggingface-cli login --token "$HF_TOKEN"; then
    echo "[INFO] huggingface-cli login OK"
  else
    echo "[WARN] huggingface-cli login failed (token may be invalid); downloads may fail for private models"
  fi
else
  echo "[WARN] No HF_TOKEN provided; proceeding. Public models will download, private ones will fail."
fi

echo "[INFO] Downloading model files to $COMFY_MODELS_DIR (parallel, using huggingface-cli)..."

# concurrency settings (tunable)
MAXJOBS=4
MAX_RETRIES=${MAX_RETRIES:-3}      # leave default if already set elsewhere
RETRY_BASE_SLEEP=${RETRY_BASE_SLEEP:-2}

# ensure status dir exists and is clean
rm -rf /tmp/hf_download_status || true
mkdir -p /tmp/hf_download_status

# hf_dl_with_retries and hf_dl_bg should be defined earlier in your script.
# If they are not, include the definitions from your previous hf snippet unchanged.

# List of downloads (repo|filename|subdir relative to $COMFY_MODELS_DIR)
DOWNLOAD_ITEMS=(
  # diffusion models / VAE / wav2vec (replace or add as needed)
  "Kijai/WanVideo_comfy|Wan2_1_VAE_bf16.safetensors|diffusion_models"
  "Kijai/WanVideo_comfy|Wan2_1_VAE_bf16.safetensors|vae"   # if you want same file in both places remove as appropriate
  "TencentGameMate/chinese-wav2vec2-base|pytorch_model.bin|transformers/TencentGameMate/chinese-wav2vec2-base"
  "TencentGameMate/chinese-wav2vec2-base|config.json|transformers/TencentGameMate/chinese-wav2vec2-base"
  "TencentGameMate/chinese-wav2vec2-base|preprocessor_config.json|transformers/TencentGameMate/chinese-wav2vec2-base"
  # add more items exactly as you did previously
)

# Spawn downloads in background while throttling concurrency
for it in "${DOWNLOAD_ITEMS[@]}"; do
  repo="${it%%|*}"
  rest="${it#*|}"
  file="${rest%%|*}"
  subdir="${rest#*|}"

  dest="$COMFY_MODELS_DIR/$subdir"
  mkdir -p "$dest"

  # Use the same background wrapper you previously used:
  hf_dl_bg "$repo" "$file" "$dest"

  # throttle to MAXJOBS background jobs
  while [ "$(jobs -rp | wc -l)" -ge "$MAXJOBS" ]; do
    sleep 0.3
  done
done

# wait for downloads to finish
wait

# Summary (same minimal style as your prior script)
echo ""
echo "=== HuggingFace download summary ==="
if [ -f /tmp/hf_download_status/success.txt ]; then
  sed -n '1,200p' /tmp/hf_download_status/success.txt
else
  echo "No successful downloads recorded."
fi

if [ -f /tmp/hf_download_status/failed.txt ]; then
  echo ""
  echo "Failed downloads:"
  sed -n '1,200p' /tmp/hf_download_status/failed.txt
  echo "[WARN] Some downloads failed. Check logs above."
else
  echo ""
  echo "All downloads completed or were attempted (no failed downloads recorded)."
fi

echo "✅ Model download section finished."
# ------------------------
# End of replacement block
# ------------------------
