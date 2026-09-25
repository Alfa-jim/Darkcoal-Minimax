#!/usr/bin/env bash
# download_ref2va_q4.sh — Safe, resumable GGUF download to RunPod Network Volume with progress bar
# Run this INSIDE a rented Pod (CPU is fine, no GPU needed) with your Network Volume attached at /runpod-volume
# Works even if you cancel/SSH drops mid-download — just re-run it.
set -e

# Auto-detect Pod vs Serverless mount (mirrors darkcoal-illustrious start.sh compat)
# Pod terminal: /workspace  | Serverless: /runpod-volume  | (legacy global: /workspace-global)
VOLUME=""
for CAND in "/runpod-volume" "/workspace" "/workspace-global"; do
  if [ -d "$CAND" ] && ( mountpoint -q "$CAND" 2>/dev/null || df "$CAND" >/dev/null 2>&1 ); then
    # Prefer /runpod-volume if it exists and has models or is a real mount; otherwise use first candidate that exists
    if [ "$CAND" = "/runpod-volume" ] && [ -d "$CAND" ]; then VOLUME="$CAND"; break; fi
    if [ -z "$VOLUME" ]; then VOLUME="$CAND"; fi
  fi
done
# Fallback: if /runpod-volume doesn't exist but /workspace does (Pod case), use /workspace
if [ -z "$VOLUME" ] || [ ! -d "$VOLUME" ]; then
  if [ -d "/workspace" ]; then VOLUME="/workspace"
  elif [ -d "/runpod-volume" ]; then VOLUME="/runpod-volume"
  else VOLUME="/runpod-volume" # default for error message
  fi
fi
MODEL_FILE="MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf"
REPO="Abiray/MiniMax-H3-Pruned-GGUF"
TARGET_DIR="$VOLUME/models/diffusion_models"
TARGET_FILE="$TARGET_DIR/$MODEL_FILE"
UNET_LINK="$VOLUME/models/unet/$MODEL_FILE"
EXPECTED_GB="11.6"
EXPECTED_BYTES=12460000000 # ~11.6GB, allow ±500MB tolerance

# Colors
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${GREEN}== MiniMax H3 Ref2VA Q4 download to Network Volume ==${NC}"
echo "Repo: $REPO"
echo "Target: $TARGET_FILE"
echo ""

# 1) Check volume is mounted (check all three mount points — Pod uses /workspace)
if [ ! -d "/runpod-volume" ] && [ ! -d "/workspace" ] && [ ! -d "/workspace-global" ]; then
  echo -e "${RED}ERROR: No volume found at /runpod-volume, /workspace, or /workspace-global.${NC}"
  echo "Did you attach the Network Volume to this Pod?"
  echo "Console -> Pods -> Deploy -> Attach volume h3-ref2va-q4 (Network, same region!) -> Connect"
  echo "Then run: ls /runpod-volume 2>&1; ls /workspace 2>&1 — one should show 'models/'"
  exit 1
fi
echo -e "${GREEN}Detected volume:${NC} $VOLUME"
if [ "$VOLUME" = "/workspace" ]; then
  echo -e "${YELLOW}Note: Pod mount is /workspace — script will also symlink to /runpod-volume for Serverless.${NC}"
fi
if ! mountpoint -q "$VOLUME" 2>/dev/null && [ ! -d "$VOLUME/models" ]; then
  echo -e "${YELLOW}WARNING: $VOLUME exists but may not be a mounted Network Volume yet. Continuing...${NC}"
fi
# Ensure /runpod-volume forwarding for Serverless (darkcoal compat)
if [ "$VOLUME" != "/runpod-volume" ] && [ -d "$VOLUME/models" ]; then
  echo -e "${GREEN}Pod compat:${NC} symlinking $VOLUME/models -> /runpod-volume/models for Serverless"
  mkdir -p /runpod-volume
  if [ ! -e /runpod-volume/models ] && [ -d "$VOLUME/models" ]; then
    ln -sf "$VOLUME/models" /runpod-volume/models 2>/dev/null || cp -rn "$VOLUME/models" /runpod-volume/ 2>/dev/null || true
  fi
fi

# 2) Create dirs
mkdir -p "$TARGET_DIR" "$VOLUME/models/unet"
echo -e "${GREEN}Volume OK:${NC} $(df -h "$VOLUME" | tail -1)"
echo -e "${GREEN}Free space:${NC} $(df -h "$VOLUME" | awk 'NR==2{print $4}') (need ~12GB)"
echo ""

# 3) Check if already done
if [ -f "$TARGET_FILE" ]; then
  SIZE=$(stat -c%s "$TARGET_FILE" 2>/dev/null || stat -f%z "$TARGET_FILE" 2>/dev/null || echo 0)
  SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $SIZE/1024/1024/1024}")
  echo -e "${YELLOW}File already exists: $SIZE_GB GB${NC}"
  if [ "$SIZE" -gt $((EXPECTED_BYTES - 500000000)) ] && [ "$SIZE" -lt $((EXPECTED_BYTES + 500000000)) ]; then
    echo -e "${GREEN}Size looks correct (~$EXPECTED_GB GB) — verifying...${NC}"
    # quick sanity: check it's not truncated (GGUF magic)
    if head -c 4 "$TARGET_FILE" | grep -q "GGUF" 2>/dev/null || [ "$(head -c 4 "$TARGET_FILE" | od -An -tx1 | tr -d ' \n')" = "47475546" ]; then
      echo -e "${GREEN}GGUF magic OK. Creating symlink and exiting.${NC}"
      ln -sf "$TARGET_FILE" "$UNET_LINK" 2>/dev/null || true
      ls -lh "$TARGET_FILE" "$UNET_LINK"
      exit 0
    else
      echo -e "${YELLOW}File exists but GGUF header invalid — will re-download.${NC}"
      rm -f "$TARGET_FILE"
    fi
  else
    echo -e "${YELLOW}Size mismatch (expected ~$EXPECTED_GB GB, got $SIZE_GB GB) — will resume/re-download.${NC}"
  fi
fi

# 4) Install tools (idempotent)
echo -e "${GREEN}Installing download tools...${NC}"
pip install -q --upgrade huggingface_hub hf_transfer 2>&1 | tail -1
# enable hf_transfer for faster + resumable transfers if available
export HF_HUB_ENABLE_HF_TRANSFER=1

# 5) Download with safe resume + progress bar
# Method 1: huggingface-cli (preferred - native resume, progress bar, checks hash)
# Method 2: wget -c fallback (if hf cli fails)
echo ""
echo -e "${GREEN}Downloading via huggingface-cli (resumable, progress bar)...${NC}"
echo "If SSH drops, just re-run this script — it resumes automatically."
echo ""

set +e
HF_CMD="huggingface-cli download $REPO $MODEL_FILE --local-dir $TARGET_DIR --local-dir-use-symlinks False"
# Newer hf_transfer respects --resume; older versions resume automatically on .incomplete files
# Try with explicit cache handling
if command -v huggingface-cli >/dev/null 2>&1; then
  # Use hf download wrapper that handles .incomplete safely
  huggingface-cli download "$REPO" "$MODEL_FILE" --local-dir "$TARGET_DIR" --local-dir-use-symlinks False 2>&1
  HF_EXIT=$?
else
  HF_EXIT=127
fi

if [ $HF_EXIT -ne 0 ] || [ ! -f "$TARGET_FILE" ]; then
  echo -e "${YELLOW}huggingface-cli failed or file missing (exit $HF_EXIT) — falling back to wget -c...${NC}"
  # Fallback: wget with continue + progress bar
  URL="https://huggingface.co/$REPO/resolve/main/$MODEL_FILE"
  # wget resume: -c continues, --progress=bar:force shows bar even non-tty, --tries 5, timeout 30
  # Use aria2c if available (faster, multi-connection), else wget
  if command -v aria2c >/dev/null 2>&1; then
    echo -e "${GREEN}Trying aria2c (16 connections, resume)...${NC}"
    aria2c -x 16 -s 16 -c --file-allocation=none --summary-interval=1 -d "$TARGET_DIR" -o "$MODEL_FILE" "$URL"
    DL_EXIT=$?
  else
    echo -e "${GREEN}Using wget -c (resume + bar)...${NC}"
    wget -c --progress=bar:force --tries=5 --timeout=30 -O "$TARGET_FILE.tmp" "$URL"
    DL_EXIT=$?
    if [ $DL_EXIT -eq 0 ] && [ -f "$TARGET_FILE.tmp" ]; then
      mv -f "$TARGET_FILE.tmp" "$TARGET_FILE"
    fi
  fi
  if [ $DL_EXIT -ne 0 ]; then
    echo -e "${RED}Download failed. Re-run this script to resume.${NC}"
    exit 1
  fi
fi
set -e

# 6) Verify and symlink
echo ""
echo -e "${GREEN}Verifying...${NC}"
if [ ! -f "$TARGET_FILE" ]; then
  # huggingface-cli may have placed it with different nesting? Check subdir
  FOUND=$(find "$TARGET_DIR" -name "$MODEL_FILE" -type f 2>/dev/null | head -1)
  if [ -n "$FOUND" ] && [ "$FOUND" != "$TARGET_FILE" ]; then
    echo -e "${YELLOW}Found at $FOUND — moving to $TARGET_FILE${NC}"
    mv -f "$FOUND" "$TARGET_FILE"
  else
    echo -e "${RED}ERROR: File not found after download. Check $TARGET_DIR${NC}"
    ls -lh "$TARGET_DIR" 2>&1 | head -20
    exit 1
  fi
fi

SIZE=$(stat -c%s "$TARGET_FILE" 2>/dev/null || stat -f%z "$TARGET_FILE" 2>/dev/null)
SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $SIZE/1024/1024/1024}")
echo -e "${GREEN}Done: $SIZE_GB GB at $TARGET_FILE${NC}"
ls -lh "$TARGET_FILE"

# Create symlink for UnetLoaderGGUF fallback (checks both diffusion_models and unet)
ln -sf "$TARGET_FILE" "$UNET_LINK" 2>/dev/null || true
echo -e "${GREEN}Symlink: $UNET_LINK -> $TARGET_FILE${NC}"
ls -lh "$UNET_LINK"

# Final check: ensure Serverless will find it (handle Pod /workspace vs Serverless /runpod-volume)
echo ""
# Ensure both locations have it (Pod uses /workspace, Serverless uses /runpod-volume)
for SYNC_VOL in "/runpod-volume" "/workspace" "/workspace-global"; do
  if [ -d "$SYNC_VOL" ] && [ "$SYNC_VOL" != "$VOLUME" ]; then
    mkdir -p "$SYNC_VOL/models/diffusion_models" "$SYNC_VOL/models/unet" 2>/dev/null || true
    if [ ! -f "$SYNC_VOL/models/diffusion_models/$MODEL_FILE" ] && [ -f "$TARGET_FILE" ]; then
      echo -e "${GREEN}Syncing to $SYNC_VOL for Serverless compat...${NC}"
      ln -sf "$TARGET_FILE" "$SYNC_VOL/models/diffusion_models/$MODEL_FILE" 2>/dev/null || cp -f "$TARGET_FILE" "$SYNC_VOL/models/diffusion_models/$MODEL_FILE" 2>/dev/null || true
      ln -sf "$SYNC_VOL/models/diffusion_models/$MODEL_FILE" "$SYNC_VOL/models/unet/$MODEL_FILE" 2>/dev/null || true
    fi
  fi
done
echo -e "${GREEN}=== SUCCESS — Serverless will find it at: ===${NC}"
echo "  /runpod-volume/models/diffusion_models/$MODEL_FILE"
echo "  /runpod-volume/models/unet/$MODEL_FILE (symlink)"
echo "  (Pod may show at /workspace/... — same data, symlinked)"
echo ""
echo -e "${GREEN}You can now STOP/DELETE this Pod — Network Volume persists.${NC}"
echo "Next: Deploy Serverless Endpoint with image ghcr.io/alfa-jim/darkcoal-minimax:latest and attach volume h3-ref2va-q4 (same region!)"
