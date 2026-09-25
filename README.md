# MiniMax H3 — RunPod Serverless — Ref2VA Q4_K_M (11.6GB) — AI Ad Videos

> **For your AI roleplay app ads:** `Ref2VA` = character-consistent video+audio with up to 9 reference images / 3 videos / 3 audios (max 12 assets). 24 FPS + 32kHz stereo. Single GPU.

Forked from `worker-comfyui-upstream` (ComfyUI v0.33.1) + `ComfyUI-GGUF` for `Abiray/MiniMax-H3-Pruned-GGUF`.

### Model

* **File:** `MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf` — **11.6 GB**, `Q4_K_M` Recommended for 16GB (runs best on 24GB A6000/4090). [https://huggingface.co/Abiray/MiniMax-H3-Pruned-GGUF](https://huggingface.co/Abiray/MiniMax-H3-Pruned-GGUF)
* **Output:** 4-15s, 16:9/9:16/1:1 etc, 768p native (2K via API Regenerate), 24 FPS, stereo 32kHz
* **VRAM:** ~13-15GB peak -> fits **A6000 48GB / RTX 4090 24GB / L4 24GB**. Use `Q3_K_M 8.9GB` if you must run on 16GB.
* **License:** `minimax-h3-community-license-agreement`

### Why 20GB Network Volume (not 30GB)?

Model is 11.6GB, but HF download needs 2x temp space + ComfyUI output cache 2-3GB. **20GB minimum** is sweet spot (`$1.40/mo` at $0.07/GB). 30GB was buffer for both FL2VA+Ref2VA.

### Deploy (10 min)

#### 0) Prereqs
* Docker Desktop not needed — GHCR auto-builds `ghcr.io/alfa-jim/darkcoal-minimax:latest`
* RunPod account + $10
* **Global Volume (recommended for rarely-used):** Console -> Storage -> `+ New volume` -> `Global volume` -> `h3-ref2va-q4` (elastic, no capacity to provision, region-independent). Alternative: 20GB Network Volume if you prefer (`Network volume` tied to one datacenter).

#### 1) Put model on Global Volume (one-time, 3 min via Pod) — **Global Volume = perfect for rarely-used**
```powershell
# Global Volume = elastic, no capacity to set, attachable to ANY region's Pod/Serverless
# Ideal for model serving: write once (download), read often (inference).

# A) Create Global Volume: Console -> Storage -> + New volume -> Storage type: Global volume -> Name: h3-ref2va-q4 -> Create

# B) Download via Pod: Console -> Pods -> + Deploy -> Attach h3-ref2va-q4 (Global) -> Connect
#    Mount path for Global Volume defaults to /workspace-global (if you also attach a Network Volume) or /workspace

# Check which mount you got:
ls /workspace-global 2>&1 || ls /workspace 2>&1
# Use the one that exists — example below uses /workspace-global (most common when both volumes possible)
# Working layout (from darkcoal-qwen-fast) — GGUF MUST be in diffusion_models/

# For Global Volume at /workspace-global:
mkdir -p /workspace-global/models/diffusion_models /workspace-global/models/unet
pip install -q huggingface_hub
hf download Abiray/MiniMax-H3-Pruned-GGUF MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf --local-dir /workspace-global/models/diffusion_models
ln -sf /workspace-global/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf /workspace-global/models/unet/
ls -lh /workspace-global/models/diffusion_models/  # must show 11.6G!

# If your Global Volume mounted at /workspace instead (no suffix):
# mkdir -p /workspace/models/diffusion_models && hf download ... --local-dir /workspace/models/diffusion_models

# For OLD Network Volume (if you still use it): same but at /runpod-volume
# mkdir -p /runpod-volume/models/diffusion_models && hf download ... --local-dir /runpod-volume/models/diffusion_models

# Why Global Volume for rarely-used: 
# - Network Volume: tied to ONE datacenter (EU-RO-1 etc), you pay $0.07/GB even if idle, and Serverless workers in other regions can't see it.
# - Global Volume: region-independent (any Serverless worker globally can mount it), elastic (no 20GB provisioning), you pay only for used bytes + tiny request fees ($0.005/1k writes, $0.0005/1k reads). Perfect for 11.6GB you read rarely.
# Caveat: Global Volume is object-backed, not POSIX: no file locking/atomic rename, last-write-wins on concurrent writes, eventual consistency, no permission bits. Fine for GGUF serving (read-heavy).
```

#### 2) Build & push Docker
```powershell
cd "C:\Users\dutap\OneDrive\Desktop\DSH workspace\worker-minimax-h3"
docker login
docker buildx build --platform linux/amd64 -t YOUR_DOCKER_USER/worker-minimax-h3:ref2va-q4 . --push
# verify
docker pull YOUR_DOCKER_USER/worker-minimax-h3:ref2va-q4
```

#### 3) Create Serverless Endpoint
1. https://console.runpod.io/serverless -> **New Endpoint**
2. **Container Image:** `ghcr.io/alfa-jim/darkcoal-minimax:latest` (auto-built via GitHub Actions, no Docker Desktop needed)
3. **Container Disk:** `25 GB`
4. **Storage:** Attach `h3-ref2va-q4` **Global volume** (type Global badge). Worker auto-detects `/runpod-volume` OR `/workspace-global` OR `/workspace` via `extra_model_paths.yaml` + `start.sh` symlink. Region-independent — any worker globally sees it.
5. **Env:** none required (or `HF_TOKEN` if private)
6. **Workers:** `Min 0` (must for $0 idle), `Max 2`, `Idle 5s`, `Execution 300s` (video gen is long)
7. **GPU:** `Flex -> A6000 (priority) + 4090` or just `A6000` — cheapest $/video is A6000 $0.53/hr Secure. Global Volume means you can deploy workers in **any region** without re-downloading model.
8. Save -> copy `ENDPOINT_ID`

#### 4) Test (text-to-video, no refs)
```powershell
$ENDPOINT="YOUR_ENDPOINT_ID"
$KEY="rpa_..."  # console.runpod.io/user/settings -> API Keys

$workflow = Get-Content "workflows/ref2va_q4_api.json" -Raw | ConvertFrom-Json
# Minimal workflow is in test_input.json - use that for first test
$body = Get-Content "test_input.json" -Raw

$job = Invoke-RestMethod -Uri "https://api.runpod.ai/v2/$ENDPOINT/run" -Method Post -Headers @{Authorization="Bearer $KEY"; "Content-Type"="application/json"} -Body $body
$job | ConvertTo-Json -Depth 5

$id = $job.id
do {
  Start-Sleep -Seconds 5
  $st = Invoke-RestMethod -Uri "https://api.runpod.ai/v2/$ENDPOINT/status/$id" -Headers @{Authorization="Bearer $KEY"}
  Write-Host $st.status
  if($st.status -eq "COMPLETED"){
    $st.output | ConvertTo-Json -Depth 5
    # if S3 disabled, output.images[0].data is base64 mp4
    # save video
    if($st.output.images){
      $b64 = $st.output.images[0].data
      $bytes = [Convert]::FromBase64String($b64)
      Set-Content -Path ".\ad_test.mp4" -Value $bytes -AsByteStream; Invoke-Item ".\ad_test.mp4"
    }
    break
  }
  if($st.status -eq "FAILED"){ $st | ConvertTo-Json -Depth 5; break }
} while($true)
```

#### 5) Generate Ad with Character Refs (Ref2VA — up to 9 images)

In ComfyUI API format, refs are uploaded via `images` array:

```json
{
  "input": {
    "workflow": { ... your exported Ref2VA workflow ... },
    "images": [
      {"name": "char_front.png", "image": "data:image/png;base64,..."},
      {"name": "char_side.png", "image": "data:image/png;base64,..."},
      {"name": "char_outfit.png", "image": "data:image/png;base64,..."}
    ]
  }
}
```

Workflow must use `LoadImage` nodes referencing `char_front.png` etc, connected to `MiniMaxH3Sampler.reference_images`. Export your ComfyUI graph via `Save (API Format)` and paste into `workflow` field.

**Tip for ad videos:** 5-6s, 16:9 1280x720, prompt like: `"cinematic ad for AI roleplay app, beautiful woman with [your character description], luxury bedroom, soft bokeh, winks at camera, whispers 'your story awaits', 4k, 24fps"` — Ref2VA keeps identity locked.

### Cost: Global Volume wins for rarely-used

* **Idle:** $0 (Min 0 workers)
* **Warm gen:** `~160s * $0.000147 (A6000 $0.53/hr) = $0.023/video` vs API $0.40-$0.65
* **Network Volume (old):** 20GB * $0.07 = $1.40/mo + tied to ONE datacenter
* **Global Volume (new, recommended):** Elastic (you store 11.6GB -> pay ~$0.81/mo actual used) + request fees `Class A $0.005/1k writes, Class B $0.0005/1k reads` -> for rarely-used (say 20 ads/mo = 20 reads) = **~$0.01/mo requests**. Region-independent, any worker can mount it without re-download.
* **500 ads/mo:** ~$13 compute + $0.81 storage vs $280 via API. Rarely-used (20/mo): ~$1.27 total vs $11.20 API.

### Updates

```powershell
docker buildx build --platform linux/amd64 -t YOUR_DOCKER_USER/worker-minimax-h3:ref2va-q4 . --push
# RunPod Console -> Endpoint -> Update to latest
```

### Troubleshooting

* `ComfyUI server not reachable` -> rebuild with `--platform linux/amd64`, check `docker logs`. This image bypassed `torch cu13` issue via `cu128` pin.
* `unet_name not in list` -> volume not mounted or file not at `/runpod-volume/models/diffusion_models/MiniMax-H3-Ref2VA-Pruned-Q4_K_M.gguf` (NOT just `/unet/`) -> check `extra_model_paths.yaml` has `unet_gguf: models/diffusion_models/` like working repos.
* OOM -> use `Q4_K_M` not `Q6_K`, ensure GPU 24GB+. L4/A6000 preferred.
* Slow cold start -> enable FlashBoot + ensure volume is same region as workers.

Repo pointing: Set `Container Image` to your pushed image and you're done.
