# Quran Muaalem — Developer Guide

## How It Works

The system is two processes that must both run:

```
Mobile App / Browser
      │  POST audio (multipart/form-data)
      ▼
┌─────────────────────────────────┐
│  APP  — FastAPI  :8001          │  public-facing REST API
│  src/quran_muaalem/app/serve.py │
└──────────────────┬──────────────┘
                   │ POST /predict (raw audio bytes)
                   ▼
┌─────────────────────────────────┐
│  ENGINE  — LitServe  :8000      │  ML inference, internal only
│  src/quran_muaalem/engine/serve │
└─────────────────────────────────┘
        Wav2Vec2-BERT multi-level CTC
```

**Engine** — runs the 660M-parameter Wav2Vec2-BERT model. Accepts audio, returns phonemes. GPU-accelerated. Never exposed externally.

**App** — public REST API. Receives audio from clients, calls the engine, runs phonetic search against the Quran index, compares predicted vs. reference phonemes, and returns a structured tajweed error report.

In production, Nginx sits in front and terminates HTTPS, proxying to the App on port 8001.

---

## Local Development

### Prerequisites

```bash
# System packages (macOS)
brew install ffmpeg portaudio libsndfile

# Python deps (uv recommended)
uv sync --all-extras
```

### Run both services

```bash
# Terminal 1 — Engine (CPU mode for local dev)
ACCELERATOR=cpu uv run quran-muaalem-engine

# Terminal 2 — App
ENGINE_URL=http://localhost:8000/predict uv run quran-muaalem-app
```

Health check:
```bash
curl http://localhost:8001/health
# {"status":"healthy","engine_status":"connected"}
```

Interactive API docs: http://localhost:8001/docs

### Run tests

```bash
uv run pytest -v --skip-slow   # fast (no model download)
uv run pytest -v               # full suite (downloads model on first run)
```

### Browser test tool

Open `tools/test_api.html` directly in a browser. It records from your microphone and POSTs to any API URL you configure. Defaults to the live production endpoint. Change it to `http://localhost:8001` for local testing.

---

## Production Deployment

### Infrastructure

All infrastructure is defined as Terraform IaC in `deploy/terraform/`. The stack provisions:

- EC2 `g4dn.xlarge` (T4 GPU, 16 GB VRAM) — spot or on-demand via `use_spot` toggle
- 80 GB `gp3` EBS volume
- Security group: ports 22, 80, 443
- Elastic IP (static, survives stop/start)
- IAM role with SSM access

### First-time setup

**1. Install Terraform**

```bash
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
```

**2. Configure variables**

```bash
cd deploy/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — fill in ssh_public_key, repo_url, etc.
```

**3. Provision infrastructure**

```bash
terraform init
terraform apply
# Note the public_ip from outputs
```

> If you get `MaxSpotInstanceCountExceeded`, set `use_spot = false` in `terraform.tfvars` and re-apply. New AWS accounts start with 0 spot quota for G-instances. Request an increase via AWS Service Quotas → EC2 → "All G and VT Spot Instance Requests" (need 4 vCPUs).

**4. Point DNS**

In Cloudflare, add an A record:
```
recite-ayah.quranlingo.app  →  <public_ip from terraform output>
```
SSL mode must be set to **Full (Strict)**.

**5. Configure environment on the server**

```bash
ssh ubuntu@<public_ip>
cp /app/.env.example /app/.env
# Edit /app/.env — set any overrides needed
```

**6. Set up Cloudflare origin certificate (HTTPS)**

In Cloudflare: SSL/TLS → Origin Server → Create Certificate → wildcard `*.quranlingo.app` → copy the cert and key.

Then on the server:
```bash
/app/deploy/scripts/init-cloudflare-ssl.sh
```

Paste the certificate and private key when prompted. Nginx will reload with HTTPS active.

**7. Start services**

```bash
cd /app
docker compose up -d
docker compose logs -f   # watch engine download the model (~1.4 GB, one-time)
```

The engine healthcheck allows up to 10 minutes on first start for the model download.

**8. Enable CI/CD**

Add two GitHub repository secrets (Settings → Secrets → Actions):
- `EC2_HOST` — the Elastic IP from Terraform output
- `EC2_SSH_KEY` — the private SSH key matching the public key in `terraform.tfvars`

Every push to `main` (excluding `.md` files and `docs/`) will automatically SSH into the server, pull the latest code, rebuild Docker images, and restart services.

---

## Day-to-Day: Start and Stop the Instance

To save costs, stop the instance when not developing and start it when you need it. The Elastic IP stays attached, so DNS never changes.

```bash
# From the repo root on your local machine
./tools/ec2.sh start   # starts EC2, waits until running, polls /health until ready
./tools/ec2.sh stop    # stops EC2, waits until fully stopped
```

Requires AWS CLI configured locally (`aws configure`). The script looks up the instance by its `Name=quran-muaalem` tag — no instance ID to maintain.

> **Stop ≠ Terminate.** Stop pauses the instance and keeps the EBS volume. Terminate deletes everything. Always use `./tools/ec2.sh stop` or EC2 console Stop — never Terminate unless you want to tear down the whole deployment.

EBS storage is still billed while stopped (~$0.53/day for 80 GB gp3).

---

## Docker Services

| Service | Image | Port | Notes |
|---------|-------|------|-------|
| `engine` | `quran-muaalem-engine` | 8000 (internal) | GPU, Wav2Vec2-BERT |
| `app` | `quran-muaalem-app` | 8001 (internal) | CPU, FastAPI |
| `nginx` | `nginx:1.25-alpine` | 80, 443 (public) | TLS termination |

All services have `restart: unless-stopped` — they come back automatically after a stop/start cycle.

```bash
# On the server — useful commands
docker compose ps                        # service status
docker compose logs engine --tail=50     # engine logs
docker compose logs app --tail=50        # app logs
docker compose restart app               # restart one service
docker compose build && docker compose up -d   # deploy manually
```

---

## Environment Variables

Copy `.env.example` to `.env` on the server and adjust as needed. Key variables:

| Variable | Default | Notes |
|----------|---------|-------|
| `ENGINE_URL` | `http://engine:8000/predict` | Set by docker-compose, don't change |
| `ACCELERATOR` | `cuda` | `cpu` for local dev without GPU |
| `DTYPE` | `bfloat16` | `float32` on CPU |
| `MAX_AUDIO_SECONDS` | `130.0` | Hard cap on input length |
| `MODEL_NAME_OR_PATH` | `obadx/muaalem-model-v3_2` | HuggingFace model ID or local path |

Full variable reference: `src/quran_muaalem/engine/settings.py` and `src/quran_muaalem/app/settings.py`.
