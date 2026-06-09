# Quran Muaalem — CLAUDE.md

## Project Overview

**Quran Muaalem** (القرآن المعلّم) is an AI-powered Quranic recitation correction system. It accepts audio recordings of Quranic recitation, transcribes them to phonemes, compares them against the correct reference phonemes (with tajweed rules applied), and returns structured error reports.

**Deployment Goal**: Expose the service on an AWS EC2 instance (or similar) so a mobile app can POST audio recordings and receive back a list of recitation errors per verse.

---

## Architecture

The system is split into **two processes** that must both be running:

```
Mobile App
    │  POST audio (multipart)
    ▼
┌──────────────────────────────────┐
│  APP  (FastAPI, default :8001)   │  ← public-facing REST API
│  src/quran_muaalem/app/serve.py  │
└──────────────────────┬───────────┘
                       │ HTTP POST /predict (audio)
                       ▼
┌──────────────────────────────────┐
│  ENGINE  (LitServe, default :8000)│  ← ML inference, internal only
│  src/quran_muaalem/engine/serve.py│
└──────────────────────────────────┘
         (Wav2Vec2-BERT multi-level CTC model)
```

The **Engine** runs the heavy ML model (Wav2Vec2-BERT) for batched audio-to-phoneme inference. The **App** calls the Engine, then handles phonetic search and tajweed comparison logic. **Never expose the Engine port to the internet.**

---

## Key Entry Points

| Command | What it starts | Default port |
|---|---|---|
| `uv run quran-muaalem-engine` | ML inference server | 8000 |
| `uv run quran-muaalem-app` | REST API server | 8001 |
| `uv run quran-muaalem-ui` | Gradio demo UI | 7860 |

---

## Directory Map

```
src/quran_muaalem/
├── inference.py                 # Muaalem class — load model, run batch inference
├── decode.py                    # CTC decode, phoneme alignment, sliding window
├── explain.py                   # Terminal output formatting
├── explain_gradio.py            # Gradio output formatting
├── gradio_app.py                # Gradio web UI
├── muaalem_typing.py            # Core data types: Unit, SingleUnit, Sifa, MuaalemOutput
│
├── app/
│   ├── serve.py                 # FastAPI endpoints — /search /correct-recitation /transcript /health
│   ├── types.py                 # Pydantic request/response models
│   ├── settings.py              # AppSettings (env vars, pydantic-settings)
│   └── main.py                  # uvicorn launcher
│
├── engine/
│   ├── serve.py                 # LitAPI class — batching, audio processing, model call
│   ├── settings.py              # EngineSettings (env vars, pydantic-settings)
│   └── main.py                  # LitServer launcher
│
└── modeling/
    ├── modeling_multi_level_ctc.py      # Wav2Vec2BertForMultilevelCTC — custom HF model
    ├── configuration_multi_level_ctc.py # Config dataclass for the model
    ├── multi_level_tokenizer.py         # Phoneme + sifat tokenizer
    └── vocab.py                         # Phoneme and tajweed feature vocabularies
```

---

## API Reference

### POST `/correct-recitation` (App :8001) — **Primary mobile endpoint**

The main endpoint for the mobile app. Accepts a recitation audio clip and returns tajweed errors.

**Request** (multipart/form-data):
- `file`: audio file (WAV preferred, 16 kHz)
- `phonetic_text` *(optional)*: skip audio transcription, use raw phonemes directly
- `error_ratio` *(optional, float, default 0.1)*: Levenshtein tolerance for verse search
- MoshafAttributes fields *(all optional, default = Hafs recitation)*:
  - `rewaya`, `recitation_speed`, `takbeer`
  - Madd lengths: `madd_monfasel_len`, `madd_mottasel_len`, `madd_mottasel_waqf`, `madd_aared_len`, `madd_alleen_len`
  - ~20 more tajweed variant toggles (see `app/types.py:MoshafAttributesForm`)

**Response** (JSON):
```json
{
  "start": {"sura_idx": 0, "aya_idx": 0, "uthmani_word_idx": 0, "phoneme_idx": 0},
  "end":   {"sura_idx": 0, "aya_idx": 0, "uthmani_word_idx": 2, "phoneme_idx": 14},
  "predicted_phonemes": "ءَلِفلَااممِۦۦم",
  "reference_phonemes":  "ءَلِفلَااااااممممِۦۦۦۦۦۦم",
  "uthmani_text": "الٓمٓ",
  "errors": [
    {
      "uthmani_pos": [1, 2],
      "ph_pos": [7, 13],
      "error_type": "tajweed",
      "speech_error_type": "replace",
      "expected_ph": "اااааа",
      "predicted_ph": "اا",
      "expected_len": 6,
      "predicted_len": 2,
      "ref_tajweed_rules": [
        {
          "name": {"ar": "المد اللازم", "en": "Lazem Madd"},
          "golden_len": 6,
          "correctness_type": "count"
        }
      ]
    }
  ]
}
```

### POST `/search` (App :8001)

Phonetic verse search. Returns matching Quranic spans sorted by similarity.

**Request**: same `file` / `phonetic_text` / `error_ratio` as above.

**Response**:
```json
{
  "phonemes": "...",
  "results": [{"start": {...}, "end": {...}, "uthmani_text": "..."}],
  "message": null
}
```

### POST `/transcript` (App :8001)

Raw audio-to-phoneme transcription only, no verse matching.

### GET `/health` (App :8001)

```json
{"status": "healthy", "engine_status": "connected"}
```

### POST `/predict` (Engine :8000) — internal

Called only by the App. Accepts audio bytes, returns `{"phonemes": "..."}`.

---

## Configuration (Environment Variables)

### Engine (`src/quran_muaalem/engine/settings.py`)

| Variable | Default | Notes |
|---|---|---|
| `MODEL_NAME_OR_PATH` | `obadx/muaalem-model-v3_2` | HuggingFace model ID or local path |
| `DTYPE` | `bfloat16` | `float32` / `float16` / `bfloat16` |
| `MAX_AUDIO_SECONDS` | `15.0` | Hard cap on input audio length |
| `MAX_BATCH_SIZE` | `128` | LitServe batch accumulation |
| `BATCH_TIMEOUT` | `0.4` | Seconds to wait before dispatching a partial batch |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8000` | Engine listen port |
| `ACCELERATOR` | `cuda` | `cuda` / `cpu` / `mps` |
| `DEVICES` | `1` | Number of GPUs |
| `WORKERS_PER_DEVICE` | `1` | LitServe workers per GPU |
| `TIMEOUT` | `90.0` | Request timeout (seconds) |

### App (`src/quran_muaalem/app/settings.py`)

| Variable | Default | Notes |
|---|---|---|
| `ENGINE_URL` | `http://0.0.0.0:8000/predict` | Where App calls Engine |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8001` | App listen port |
| `ERROR_RATIO` | `0.1` | Default phonetic search tolerance |
| `MAX_WORKERS_PHONETIC_SEARCH` | `cpu_count // 2` | Thread pool for verse search |
| `MAX_WORKERS_PHONETIZATION` | `cpu_count // 2` | Thread pool for reference generation |

**On EC2**: set `ENGINE_URL=http://localhost:8000/predict` (internal) and expose only port 8001 externally. Set `ACCELERATOR=cpu` if running without a GPU instance.

---

## Dependencies & Installation

```bash
# Install with all extras (engine + ui + test)
pip install "quran-muaalem[engine,ui,test]"

# Or from source
uv sync --all-extras

# System packages required
apt-get install -y ffmpeg libsndfile1 portaudio19-dev
```

**Python**: 3.10 – 3.14 (tested in CI)

Key dependencies:
- `torch >= 2.7.0` — deep learning
- `transformers >= 4.55.0` — Wav2Vec2-BERT
- `quran-transcript >= 0.5.2` — Quranic phonetization & tajweed rules
- `litserve >= 0.2.17` — batched ML inference server
- `fastapi + uvicorn` — REST API

---

## ML Model

**Architecture**: `Wav2Vec2BertForMultilevelCTC` (custom HF model)
- Backbone: Wav2Vec2-BERT (1024-dim hidden, 24 layers, 16 attention heads)
- 11 CTC output heads: 1 phoneme head (44 classes) + 10 tajweed feature heads
- Input: 16 kHz audio, max 15 seconds
- Weights: `obadx/muaalem-model-v3_2` on Hugging Face (auto-downloaded on first run)

**Tajweed feature heads** (multi-class per level):
`hams_or_jahr`, `shidda_or_rakhawa`, `tafkheem_or_taqeeq`, `itbaq`, `safeer`, `qalqla`, `tikraar`, `tafashie`, `istitala`, `ghonna`

**Decoding pipeline**:
1. Feature extraction → batched BERT backbone → 11 CTC logit streams
2. Greedy CTC decode (collapse repeats, drop blank/PAD)
3. Sliding-window alignment of predicted phonemes against Quran index
4. Compare vs. reference phonemes (from `quran_transcript.quran_phonetizer`)
5. diff-match-patch diff → classify errors by type and tajweed rule

---

## Running Locally (Development)

```bash
# Terminal 1 — Engine (GPU or CPU)
ACCELERATOR=cpu uv run quran-muaalem-engine

# Terminal 2 — App
ENGINE_URL=http://localhost:8000/predict uv run quran-muaalem-app

# Health check
curl http://localhost:8001/health
```

---

## Tests

```bash
# All tests (requires model download, slow)
uv run pytest -v

# Skip slow tests (no model download)
uv run pytest -v --skip-slow
```

Test files live in `tests/`. Slow tests are marked `@pytest.mark.slow`.

---

## Deployment Notes (AWS EC2)

**What the mobile app needs**: single HTTPS endpoint `POST /correct-recitation` on the public IP/domain, returning structured error JSON.

### EC2 Instance Selection

**Model footprint**: 660M parameters, **1.5 GB GPU VRAM** (bfloat16), ~2.6 GB system RAM (float32 on CPU).

Full RAM budget on a CPU-only instance:
- OS: ~1.5 GB
- Python + PyTorch + all deps: ~2.5 GB
- Model weights (float32): ~2.6 GB
- Peak inference activations: ~2 GB
- App process + phonetic search: ~0.5 GB
- **Total peak: ~9 GB → minimum 16 GB RAM**

| Instance | vCPU | RAM | GPU | On-demand/mo | Spot/mo | Latency/request |
|---|---|---|---|---|---|---|
| `t3.xlarge` | 4 | 16 GB | — | ~$121 | ~$36 | 8–15 s (burstable) |
| `m6i.xlarge` | 4 | 16 GB | — | ~$140 | ~$42 | 4–8 s |
| `m7i.xlarge` | 4 | 16 GB | — | ~$148 | ~$45 | 3–6 s |
| `g4dn.xlarge` | 4 | 16 GB | T4 16 GB | ~$383 | ~$115 | 1–2 s |

**Recommendation**:
- **Start / beta testing**: `t3.xlarge` spot (~$36/mo). Burstable CPU is fine for low traffic (<5 concurrent users). Latency ~10s is acceptable for an async "record then submit" flow.
- **Production sweet spot**: `g4dn.xlarge` spot (~$115/mo). GPU gives 5–8× faster inference at roughly the same monthly cost as a CPU instance on-demand. Worth it once the app has real users.
- Never use less than 16 GB RAM; 8 GB instances will OOM during peak inference.

**EBS storage**: 40 GB `gp3` (~$3.20/mo) — minimum required by the Deep Learning AMI snapshot. Covers OS (8 GB) + Python deps/torch (2.5 GB) + model cache (1.5 GB) + Docker layers (3 GB) + logs + headroom.

**CPU-mode env vars** (for `t3.xlarge` / `m6i.xlarge`):
```
DTYPE=float32
ACCELERATOR=cpu
MAX_BATCH_SIZE=8
WORKERS_PER_DEVICE=2
```

**GPU-mode env vars** (for `g4dn.xlarge`):
```
DTYPE=bfloat16
ACCELERATOR=cuda
MAX_BATCH_SIZE=128
WORKERS_PER_DEVICE=1
```

**Networking**: expose only port 443 (HTTPS via nginx → 8001) externally. Engine port 8000 must stay internal (localhost only). Set `ENGINE_URL=http://localhost:8000/predict` in the App's env.

### Infrastructure Files (all implemented)

```
deploy/
├── terraform/
│   ├── main.tf                    # EC2 g4dn.xlarge spot, SG, EIP, IAM role
│   ├── variables.tf               # All input variables with descriptions
│   ├── outputs.tf                 # public_ip, ssh_command, next_steps
│   ├── user_data.sh               # First-boot: clone repo, start services
│   └── terraform.tfvars.example   # Copy to terraform.tfvars, fill secrets
├── nginx/
│   └── nginx.conf                 # HTTP→HTTPS redirect + HTTPS proxy to app:8001
├── Dockerfile.engine              # CUDA 12.4 base, installs CUDA torch + engine
├── Dockerfile.app                 # python:3.11-slim, CPU torch, installs engine
└── scripts/
    └── init-ssl.sh                # One-time HTTPS bootstrap (dummy cert → real cert)

docker-compose.yml                 # engine + app + nginx + certbot
.env.example                       # Template for all environment variables
.github/workflows/deploy.yml       # CI/CD: push to main → SSH deploy (skip .md/docs)
```

### How to Deploy (first time)

```bash
# 1. Provision infrastructure
cd deploy/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your SSH key, repo URL, etc.
terraform init
terraform apply
# Note the public_ip from outputs

# 2. Point DNS
# Add A record:  recite-ayah.quranlingo.app → <public_ip>
# Wait ~5 min for propagation

# 3. Set up HTTPS (run on the EC2 instance)
ssh ubuntu@<public_ip>
/app/deploy/scripts/init-ssl.sh your@email.com

# 4. Add GitHub Secrets (Settings → Secrets → Actions)
# EC2_HOST  = <public_ip>
# EC2_SSH_KEY = <private key matching the public key in terraform.tfvars>
```

### Deployment Checklist

- [x] `deploy/Dockerfile.engine` — CUDA 12.4 + CUDA torch + engine
- [x] `deploy/Dockerfile.app` — slim Python + CPU torch + engine
- [x] `docker-compose.yml` — engine + app + nginx + certbot renewal
- [x] `.env.example` — template for all env vars
- [x] `deploy/nginx/nginx.conf` — HTTPS termination, ACME challenge, CORS, 20 MB body limit
- [x] Docker `restart: unless-stopped` + `HEALTHCHECK` on all services
- [x] `.github/workflows/deploy.yml` — push to `main` triggers SSH deploy, skips `.md`/`docs/`
- [x] CORS headers in nginx (`Access-Control-Allow-Origin: *`)
- [x] `deploy/terraform/` — full IaC: EC2 spot, SG, EIP, IAM role, user_data
- [x] `deploy/scripts/init-ssl.sh` — one-time Let's Encrypt bootstrap
- [ ] Test end-to-end with real device audio (mobile sends M4A/AAC — verify ffmpeg handles it)
- [ ] Lock down `ssh_allowed_cidr` in terraform.tfvars to your IP after initial setup
