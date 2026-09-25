# MiniMax H3 Pruned GGUF - RunPod Serverless Worker
# Ref2VA Q4_K_M (11.6GB) optimized for single GPU (A6000/4090 24GB)
# Based on worker-comfyui-upstream

ARG BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04

FROM ${BASE_IMAGE} AS base

# IMPORTANT: H3 requires ComfyUI v0.30.0+ for native MiniMax architecture
ARG COMFYUI_VERSION=0.33.1
ARG CUDA_VERSION_FOR_COMFY=12.8
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
    git \
    wget \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    openssh-server \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip

RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

RUN uv pip install comfy-cli==1.13.0 pip setuptools wheel

# Install ComfyUI v0.33.1 with CUDA 12.8 (required for H3 native backend)
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Install ComfyUI-GGUF (required for H3 Pruned GGUF - UnetLoaderGGUF)
RUN git clone https://github.com/city96/ComfyUI-GGUF /comfyui/custom_nodes/ComfyUI-GGUF \
    && uv pip install -r /comfyui/custom_nodes/ComfyUI-GGUF/requirements.txt || true

# Mirror deps to launch venv + pin transformers/hf-hub (same fix as upstream DR-1170)
RUN uv pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 \
      --index-url https://download.pytorch.org/whl/cu128 \
    && uv pip install -r /comfyui/requirements.txt \
    && for r in /comfyui/custom_nodes/*/requirements.txt; do \
         [ -f "$r" ] && uv pip install -r "$r" || true; \
       done \
    && uv pip install "transformers>=4.50.3,<5" "huggingface-hub<1.0"

# Smoke test
RUN cd /comfyui && timeout 300 python main.py --quick-test-for-ci --cpu

WORKDIR /comfyui
ADD src/extra_model_paths.yaml ./
# Validate extra_model_paths matches working darkcoal repos (unet_gguf + diffusion_models required for GGUF)
RUN python -c "import yaml, pathlib; p=pathlib.Path('extra_model_paths.yaml'); cfg=yaml.safe_load(p.read_text()); assert 'runpod_worker_comfy' in cfg, cfg; c=cfg['runpod_worker_comfy']; assert 'unet_gguf' in c, 'unet_gguf missing - GGUF will not be found on volume'; assert 'diffusion_models' in c, 'diffusion_models missing'; assert 'unet' in c; print('extra_model_paths.yaml OK:', list(c.keys()))" \
 && python -c "import folder_paths, utils.extra_config; utils.extra_config.load_extra_path_config('extra_model_paths.yaml'); print('extra paths loaded OK:', [k for k in folder_paths.folder_names_and_paths if 'diffusion' in k or 'unet' in k])"

WORKDIR /
RUN uv pip install runpod requests websocket-client

ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh

COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install
ENV PIP_NO_INPUT=1
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

CMD ["/start.sh"]

# Downloader stage - optional bake (we use Network Volume instead)
FROM base AS downloader
WORKDIR /comfyui
RUN mkdir -p models/checkpoints models/vae models/unet models/clip models/text_encoders models/diffusion_models models/model_patches
# We DONT bake 11.6GB GGUF into image - use Network Volume for faster deploys
# If you want baked: uncomment next line
# RUN wget -O models/unet/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf https://huggingface.co/Abiray/MiniMax-H3-Pruned-GGUF/resolve/main/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf

FROM base AS final
COPY --from=downloader /comfyui/models /comfyui/models
