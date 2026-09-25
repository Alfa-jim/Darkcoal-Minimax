#!/usr/bin/env bash

# Start SSH server if PUBLIC_KEY is set (enables remote access and dev-sync.sh)
if [ -n "$PUBLIC_KEY" ]; then
    mkdir -p ~/.ssh
    echo "$PUBLIC_KEY" > ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/authorized_keys

    # Generate host keys if they don't exist (removed during image build for security)
    for key_type in rsa ecdsa ed25519; do
        key_file="/etc/ssh/ssh_host_${key_type}_key"
        if [ ! -f "$key_file" ]; then
            ssh-keygen -t "$key_type" -f "$key_file" -q -N ''
        fi
    done

    service ssh start && echo "worker-comfyui: SSH server started" || echo "worker-comfyui: SSH server could not be started" >&2
fi

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# ---------------------------------------------------------------------------
# GPU pre-flight check
# Verify that the GPU is accessible before starting ComfyUI. If PyTorch
# cannot initialize CUDA the worker will never be able to process jobs,
# so we fail fast with an actionable error message.
# ---------------------------------------------------------------------------
echo "worker-comfyui: Checking GPU availability..."
if ! GPU_CHECK=$(python3 -c "
import torch
try:
    torch.cuda.init()
    name = torch.cuda.get_device_name(0)
    cap = torch.cuda.get_device_capability(0)
    # Launch a real kernel. The driver-only calls above succeed even when this
    # PyTorch build has no compiled kernels for the GPU architecture (e.g. an
    # older torch on a newer GPU). Without this, the worker boots, ComfyUI dies
    # on the first GPU op, and it surfaces as the misleading 'server not
    # reachable' error instead of a clear cause here.
    _ = (torch.zeros(8, device='cuda') + 1).sum().item()
    torch.cuda.synchronize()
    print(f'OK: {name} (sm_{cap[0]}{cap[1]}), torch {torch.__version__}, cuda {torch.version.cuda}')
except Exception as e:
    print(f'FAIL: {e}')
    exit(1)
" 2>&1); then
    echo "worker-comfyui: GPU is not available or incompatible with this PyTorch build:"
    echo "worker-comfyui: $GPU_CHECK"
    echo "worker-comfyui: A 'no kernel image is available' error means this torch build"
    echo "worker-comfyui: lacks kernels for this GPU. Otherwise the GPU may not be"
    echo "worker-comfyui: properly initialized — please contact RunPod support."
    exit 1
fi
echo "worker-comfyui: GPU available — $GPU_CHECK"

# Ensure ComfyUI-Manager runs in offline network mode inside the container
comfy-manager-set-mode offline || echo "worker-comfyui - Could not set ComfyUI-Manager network_mode" >&2

# Pod vs Serverless mount: Pod terminal is /workspace, Serverless mounts same Network Volume at /runpod-volume.
# ComfyUI reads /runpod-volume via extra_model_paths.yaml, so if /workspace has models we symlink them into /runpod-volume for consistency. (from darkcoal-illustrious)
if [ ! -d /runpod-volume/models ] && [ -d /workspace/models ]; then
    echo "worker-comfyui: Pod compat — /workspace/models found, symlinking into /runpod-volume" >&2
    mkdir -p /runpod-volume
    for d in /workspace/models/*; do
        bn=$(basename "$d")
        if [ ! -e "/runpod-volume/models/$bn" ]; then
            ln -s "$d" "/runpod-volume/models/$bn" 2>/dev/null || true
        fi
    done
    if [ ! -e /runpod-volume/models ] && [ -d /workspace/models ]; then
        ln -s /workspace/models /runpod-volume/models 2>/dev/null || true
    fi
fi

echo "worker-comfyui: Checking for GGUF at /runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf"
if [ -f "/runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf" ]; then
  echo "  FOUND: /runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf ($(du -h "/runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf" 2>/dev/null | cut -f1))"
else
  echo "  missing: /runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf (Network Volume not attached or file not at that path - see README)"
  # fallback check
  if [ -f "/runpod-volume/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf" ]; then
    echo "  FOUND fallback: /runpod-volume/models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf"
  fi
fi

echo "worker-comfyui: Starting ComfyUI"

# Allow operators to tweak verbosity; default is DEBUG.
: "${COMFY_LOG_LEVEL:=DEBUG}"

# PID file used by the handler to detect if ComfyUI is still running
COMFY_PID_FILE="/tmp/comfyui.pid"

# Serve the API and don't shutdown the container
if [ "$SERVE_API_LOCALLY" == "true" ]; then
    python -u /comfyui/main.py --disable-auto-launch --disable-metadata --listen --verbose "${COMFY_LOG_LEVEL}" --log-stdout &
    echo $! > "$COMFY_PID_FILE"

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
    python -u /comfyui/main.py --disable-auto-launch --disable-metadata --verbose "${COMFY_LOG_LEVEL}" --log-stdout &
    echo $! > "$COMFY_PID_FILE"

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py
fi