# ------------------------
# Self-contained parallel Hugging Face download block (drop-in)
# ------------------------

# ensures HF_TOKEN is read from environment (do not overwrite)
HF_TOKEN="${HF_TOKEN:-}"

# Non-interactive HF login if token provided
if [ -n "$HF_TOKEN" ]; then
  echo "[INFO] HF_TOKEN present — performing non-interactive huggingface-cli login..."
  mkdir -p "$HOME/.cache/huggingface"
  if huggingface-cli login --token "$HF_TOKEN"; then
    echo "[INFO] huggingface-cli login OK"
  else
    echo "[WARN] huggingface-cli login failed (token may be invalid); downloads for private models may fail"
  fi
else
  echo "[WARN] No HF_TOKEN provided; proceeding. Public models will download, private ones will fail."
fi

echo "[INFO] Preparing parallel Hugging Face downloads..."

# concurrency & retry tuning
MAXJOBS=${MAXJOBS:-4}        # tune this to your environment
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_BASE_SLEEP=${RETRY_BASE_SLEEP:-2}

# status folder
rm -rf /tmp/hf_download_status || true
mkdir -p /tmp/hf_download_status

# ------------------------
# hf_dl_with_retries: download a single file with retries, timing, and logging
# Usage: hf_dl_with_retries "<repo>" "<file>" "<dest>"
# ------------------------
hf_dl_with_retries() {
  local repo="$1"
  local file="$2"
  local dest="$3"
  local attempt=1
  local start_ts end_ts elapsed

  mkdir -p "$dest"

  while [ $attempt -le $MAX_RETRIES ]; do
    start_ts=$(date +%s)
    echo "[HF_DL] START repo='$repo' file='$file' dest='${dest}' attempt=${attempt}/${MAX_RETRIES}"
    # huggingface-cli returns non-zero on failure
    if huggingface-cli download "$repo" "$file" --local-dir "$dest" --local-dir-use-symlinks False ; then
      end_ts=$(date +%s)
      elapsed=$((end_ts - start_ts))
      echo "[HF_DL] OK    repo='$repo' file='$file' (took ${elapsed}s)"
      return 0
    else
      end_ts=$(date +%s)
      elapsed=$((end_ts - start_ts))
      echo "[HF_DL] FAIL  repo='$repo' file='$file' attempt=${attempt} (took ${elapsed}s)"
      # exponential backoff before retry
      sleep_sec=$(( RETRY_BASE_SLEEP * (2 ** (attempt - 1)) ))
      echo "[HF_DL] Retrying in ${sleep_sec}s..."
      sleep "$sleep_sec"
      attempt=$(( attempt + 1 ))
    fi
  done

  echo "[HF_DL] ERROR repo='$repo' file='$file' after ${MAX_RETRIES} attempts"
  return 1
}

# ------------------------
# hf_dl_bg: background wrapper for hf_dl_with_retries that records status files
# ------------------------
hf_dl_bg() {
  local repo="$1"
  local file="$2"
  local dest="$3"
  (
    if hf_dl_with_retries "$repo" "$file" "$dest" ; then
      mkdir -p /tmp/hf_download_status
      echo "OK|$repo|$file" >> /tmp/hf_download_status/success.txt
    else
      mkdir -p /tmp/hf_download_status
      echo "FAIL|$repo|$file" >> /tmp/hf_download_status/failed.txt
    fi
  ) &
}

# ------------------------
# DOWNLOAD_ITEMS: list files to download (repo|filename|subdir relative to $COMFY_MODELS_DIR)
# Modify this list exactly as you used previously
# ------------------------
DOWNLOAD_ITEMS=(
  "Kijai/WanVideo_comfy|Wan2_1_VAE_bf16.safetensors|diffusion_models"
  "Kijai/WanVideo_comfy|Wan2_1_VAE_bf16.safetensors.index|diffusion_models" # optional
  "Kijai/WanVideo_comfy|Wan2_1_VAE_bf16.safetensors.sha256|diffusion_models" # optional
  "Kijai/WanVideo_comfy|Wan2_1_VAE_bf16.safetensors|vae"   # if you want same file in another folder
  "TencentGameMate/chinese-wav2vec2-base|pytorch_model.bin|transformers/TencentGameMate/chinese-wav2vec2-base"
  "TencentGameMate/chinese-wav2vec2-base|config.json|transformers/TencentGameMate/chinese-wav2vec2-base"
  "TencentGameMate/chinese-wav2vec2-base|preprocessor_config.json|transformers/TencentGameMate/chinese-wav2vec2-base"
  # add more items if needed, in the same "repo|file|subdir" format
)

# spawn downloads (throttled)
for it in "${DOWNLOAD_ITEMS[@]}"; do
  repo="${it%%|*}"
  rest="${it#*|}"
  file="${rest%%|*}"
  subdir="${rest#*|}"

  dest="$COMFY_MODELS_DIR/$subdir"
  mkdir -p "$dest"

  hf_dl_bg "$repo" "$file" "$dest"

  # throttle to MAXJOBS background jobs
  while [ "$(jobs -rp | wc -l)" -ge "$MAXJOBS" ]; do
    sleep 0.3
  done
done

# wait for all background downloads to finish
wait

# ------------------------
# Summary
# ------------------------
echo ""
echo "=== HuggingFace download summary ==="
if [ -f /tmp/hf_download_status/success.txt ]; then
  echo "Successful downloads:"
  sed -n '1,200p' /tmp/hf_download_status/success.txt
else
  echo "No successful downloads recorded."
fi

if [ -f /tmp/hf_download_status/failed.txt ]; then
  echo ""
  echo "Failed downloads:"
  sed -n '1,200p' /tmp/hf_download_status/failed.txt
  echo ""
  echo "[WARN] Some downloads failed. Check logs above and ensure HF_TOKEN has correct permissions for private models."
else
  echo ""
  echo "All downloads completed (no failed downloads recorded)."
fi

echo "✅ Model download section finished."
# ------------------------
# End of self-contained download block
# ------------------------
