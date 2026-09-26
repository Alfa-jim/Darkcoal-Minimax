#!/usr/bin/env bash
# ==============================================================================
# MiniMax H3 — RunPod POD bake command for Network Volume
# ==============================================================================
# PURPOSE: Bake the 11.6GB Q4_K_M GGUF into your Network Volume so that
#          Serverless workers can find it at /runpod-volume/models/...
#
# IMPORTANT MOUNT POINT BEHAVIOUR (RunPod):
#   • Inside a RENTED POD the same Network Volume appears at  /workspace
#     (the Pod terminal's $HOME-like mount — `ls /workspace` shows it)
#   • Inside a SERVERLESS WORKER the same volume appears at /runpod-volume
#     (via extra_model_paths.yaml `base_path: /runpod-volume`)
#   This script therefore writes to /workspace/... and also symlinks to
#   /runpod-volume/... so BOTH views are correct. Works regardless of
#   which path the Pod exposes.
#
# SOURCE:
#   • Primary (pruned Q4):  Abiray/MiniMax-H3-Pruned-GGUF
#     File:                 MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf  (11.6 GB)
#     Recommended for 16GB (best on 24GB A6000/4090).
#     Source HF page: https://huggingface.co/Abiray/MiniMax-H3-Pruned-GGUF
#
#   • Alternative upstream for non-pruned GGUFs:
#     unsloth/MiniMax-H3-GGUF  https://huggingface.co/unsloth/MiniMax-H3-GGUF
#     (The user reference link — use this if you want the full non-pruned
#      variant; file names differ but same UnetLoaderGGUF path.)
#
# USAGE:
#   1) RunPod Console → Pods → Deploy → Community Cloud → RTX 4090 or A6000
#      → Attach Network Volume:  h3-ref2va-q4  (20 GB, same region as your
#        future Serverless endpoint, e.g. EU-RO-1)  → Deploy  (CPU is fine, no GPU needed)
#   2) Connect → Terminal → paste ENTIRE file contents and run:
#         bash POD_BAKE_COMMAND.sh
#      (or chmod +x POD_BAKE_COMMAND.sh && ./POD_BAKE_COMMAND.sh)
#   3) Wait ~3-7 min (progress bar). If SSH drops, re-run — resumes safely.
#   4) When done you see  "=== SUCCESS"  → STOP / DELETE the Pod
#      (Network Volume persists). Then deploy Serverless endpoint attaching
#      the SAME volume.
#
# REQUIRED SPACE: 20 GB volume minimum (11.6 GB file + HF temp 2x buffer).
# ==============================================================================

set -e

# ── Config ───────────────────────────────────────────────────────────────────
REPO="Abiray/MiniMax-H3-Pruned-GGUF"
FILE="MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf"
# Alternative source (uncomment to use unsloth non-pruned):
# REPO="unsloth/MiniMax-H3-GGUF"
# FILE="minimax-h3-Q4_K_M.gguf"   # check exact name via `hf download --help` or tree
EXPECTED_GB="11.6"
EXPECTED_BYTES=12460000000

# Colours
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[0;90m'; NC='\033[0m'

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  MiniMax H3 Ref2VA Q4 bake — Network Volume (/workspace)  ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo "Repo: $REPO"
echo "File: $FILE"
echo ""

# ── Detect mount point ──────────────────────────────────────────────────────
# Pod shows volume at /workspace, Serverless at /runpod-volume.
# We use /workspace as PRIMARY write target per user instruction.
VOLUME="/workspace"
if [ -d "/workspace" ]; then
  VOLUME="/workspace"
elif [ -d "/runpod-volume" ]; then
  VOLUME="/runpod-volume"
else
  echo -e "${RED}ERROR: No volume mount found at /workspace or /runpod-volume.${NC}"
  echo "Did you attach the Network Volume to this Pod?"
  echo "Console → Pods → Deploy → attach volume h3-ref2va-q4 (Network, same region!) → Connect"
  echo "Then: ls /workspace 2>&1; ls /runpod-volume 2>&1  — one should exist"
  exit 1
fi

# Also detect secondary mount for cross-linking
SECONDARY=""
if [ "$VOLUME" = "/workspace" ] && [ -d "/runpod-volume" ]; then SECONDARY="/runpod-volume"; fi
if [ "$VOLUME" = "/runpod-volume" ] && [ -d "/workspace" ]; then SECONDARY="/workspace"; fi

TARGET_DIR="$VOLUME/models/diffusion_models"
TARGET_FILE="$TARGET_DIR/$FILE"
UNET_LINK="$VOLUME/models/unet/$FILE"

echo -e "${GREEN}Primary volume:${NC} $VOLUME"
if [ -n "$SECONDARY" ]; then echo -e "${GREEN}Secondary (linked):${NC} $SECONDARY"; fi
echo -e "${DIM}Target: $TARGET_FILE${NC}"
df -h "$VOLUME" | tail -1 | awk '{print "Free: " $4 "  Used: " $3 "  Size: " $2}'
echo ""

# ── Create dirs ──────────────────────────────────────────────────────────────
mkdir -p "$TARGET_DIR" "$VOLUME/models/unet"
if [ -n "$SECONDARY" ]; then
  mkdir -p "$SECONDARY/models/diffusion_models" "$SECONDARY/models/unet"
fi

# ── Already downloaded? ─────────────────────────────────────────────────────
if [ -f "$TARGET_FILE" ]; then
  SIZE=$(stat -c%s "$TARGET_FILE" 2>/dev/null || stat -f%z "$TARGET_FILE" 2>/dev/null || echo 0)
  SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $SIZE/1024/1024/1024}")
  echo -e "${YELLOW}File already exists: $SIZE_GB GB${NC}"
  if [ "$SIZE" -gt $((EXPECTED_BYTES - 700000000)) ] && [ "$SIZE" -lt $((EXPECTED_BYTES + 700000000)) ]; then
    if head -c 4 "$TARGET_FILE" 2>/dev/null | grep -q "GGUF" || [ "$(head -c 4 "$TARGET_FILE" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "47475546" ]; then
      echo -e "${GREEN}GGUF magic OK — verifying symlink...${NC}"
      ln -sf "$TARGET_FILE" "$UNET_LINK"
      if [ -n "$SECONDARY" ]; then
        ln -sf "$TARGET_FILE" "$SECONDARY/models/diffusion_models/$FILE" 2>/dev/null || true
        ln -sf "$SECONDARY/models/diffusion_models/$FILE" "$SECONDARY/models/unet/$FILE" 2>/dev/null || true
        mkdir -p /runpod-volume 2>/dev/null || true
        if [ ! -e "/runpod-volume/models" ] && [ -d "$VOLUME/models" ]; then
          ln -sf "$VOLUME/models" /runpod-volume/models 2>/dev/null || true
        fi
      fi
      ls -lh "$TARGET_FILE" "$UNET_LINK"
      echo ""
      echo -e "${GREEN}=== SUCCESS — already baked ===${NC}"
      echo "  $TARGET_FILE"
      echo "  $UNET_LINK (symlink)"
      if [ -n "$SECONDARY" ]; then echo "  $SECONDARY/models/diffusion_models/$FILE (cross-linked)"; fi
      echo "  Serverless will see it at: /runpod-volume/models/diffusion_models/$FILE"
      exit 0
    else
      echo -e "${YELLOW}GGUF header invalid — re-downloading${NC}"
      rm -f "$TARGET_FILE"
    fi
  else
    echo -e "${YELLOW}Size mismatch (expected ~$EXPECTED_GB GB, got $SIZE_GB) — resuming${NC}"
  fi
fi

# ── Install tools ───────────────────────────────────────────────────────────
echo -e "${GREEN}Installing download tools...${NC}"
pip install -q --upgrade huggingface_hub hf_transfer 2>&1 | tail -1 || pip install -q huggingface_hub 2>&1 | tail -1
export HF_HUB_ENABLE_HF_TRANSFER=1
echo -e "${DIM}hf_transfer=${HF_HUB_ENABLE_HF_TRANSFER}  huggingface-cli=$(command -v huggingface-cli || echo missing)${NC}"
echo ""

# ── Download ─────────────────────────────────────────────────────────────────
echo -e "${GREEN}Downloading via huggingface-cli (resumable, progress bar)...${NC}"
echo "If SSH drops, just re-run this script — it resumes automatically."
echo ""

set +e
if command -v huggingface-cli >/dev/null 2>&1; then
  huggingface-cli download "$REPO" "$FILE" --local-dir "$TARGET_DIR" --local-dir-use-symlinks False 2>&1
  HF_EXIT=$?
else
  HF_EXIT=127
fi

if [ $HF_EXIT -ne 0 ] || [ ! -f "$TARGET_FILE" ]; then
  echo -e "${YELLOW}huggingface-cli failed or file missing (exit $HF_EXIT) — falling back to wget -c...${NC}"
  URL="https://huggingface.co/$REPO/resolve/main/$FILE"
  if command -v aria2c >/dev/null 2>&1; then
    echo -e "${GREEN}Trying aria2c (16 connections, resume)...${NC}"
    aria2c -x 16 -s 16 -c --file-allocation=none --summary-interval=1 -d "$TARGET_DIR" -o "$FILE" "$URL"
    DL_EXIT=$?
  else
    echo -e "${GREEN}Using wget -c (resume + bar)...${NC}"
    wget -c --progress=bar:force --tries=5 --timeout=30 -O "$TARGET_FILE.tmp" "$URL"
    DL_EXIT=$?
    if [ $DL_EXIT -eq 0 ] && [ -f "$TARGET_FILE.tmp" ]; then mv -f "$TARGET_FILE.tmp" "$TARGET_FILE"; fi
  fi
  if [ "$DL_EXIT" -ne 0 ]; then
    echo -e "${RED}Download failed. Re-run this script to resume.${NC}"
    exit 1
  fi
fi
set -e

# ── Verify ───────────────────────────────────────────────────────────────────
if [ ! -f "$TARGET_FILE" ]; then
  FOUND=$(find "$TARGET_DIR" -name "$FILE" -type f 2>/dev/null | head -1)
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
echo -e "${GREEN}Downloaded: $SIZE_GB GB at $TARGET_FILE${NC}"
ls -lh "$TARGET_FILE"

# ── Symlink for ComfyUI-GGUF (UnetLoaderGGUF checks both paths) ─────────────
ln -sf "$TARGET_FILE" "$UNET_LINK"
echo -e "${GREEN}Symlink: $UNET_LINK -> $TARGET_FILE${NC}"
ls -lh "$UNET_LINK"

# ── Cross-link secondary mount (Pod /workspace <-> Serverless /runpod-volume) ─
if [ -n "$SECONDARY" ]; then
  echo -e "${GREEN}Cross-linking to $SECONDARY for Serverless compat...${NC}"
  ln -sf "$TARGET_FILE" "$SECONDARY/models/diffusion_models/$FILE" 2>/dev/null || cp -f "$TARGET_FILE" "$SECONDARY/models/diffusion_models/$FILE" 2>/dev/null || true
  ln -sf "$SECONDARY/models/diffusion_models/$FILE" "$SECONDARY/models/unet/$FILE" 2>/dev/null || true
  # Also ensure /runpod-volume/models exists (start.sh expects it)
  mkdir -p /runpod-volume 2>/dev/null || true
  if [ ! -e "/runpod-volume/models" ] && [ -d "$VOLUME/models" ]; then
    ln -sf "$VOLUME/models" /runpod-volume/models 2>/dev/null || true
  fi
fi

# ── Final report ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  === SUCCESS — volume baked ===                           ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo "  Primary:   $TARGET_FILE"
echo "  Symlink:   $UNET_LINK"
if [ -n "$SECONDARY" ]; then echo "  Secondary: $SECONDARY/models/diffusion_models/$FILE"; fi
echo "  Serverless sees: /runpod-volume/models/diffusion_models/$FILE"
echo "  Serverless sees: /runpod-volume/models/unet/$FILE (symlink)"
echo ""
echo -e "${GREEN}You can now STOP / DELETE this Pod — Network Volume persists.${NC}"
echo "Next: Deploy Serverless Endpoint"
echo "  1) GHCR image: ghcr.io/alfa-jim/darkcoal-minimax:latest  (auto-built via Actions → hit Build)"
echo "  2) Attach SAME Network Volume (h3-ref2va-q4, 20GB) — MUST be same region/datacenter!"
echo "  3) Container Disk 25GB → GPU A6000 or 4090 24GB → Min 0 / Max 2 / Idle 5s / Exec 300s"
echo "  4) Test via playground.html → endpoint runsync + key"
echo ""
echo -e "${DIM}To use unsloth/MiniMax-H3-GGUF instead, edit REPO/FILE at top of this script.${NC}"
