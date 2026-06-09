# Fix, WebSocket & SageMaker Migration Plan

## Context

Three independent workstreams:

1. **Dynamic padding fix** — The engine pads every audio input to `max_features` (derived from `MAX_AUDIO_SECONDS=130`), meaning a 5-second ayah uses the same GPU memory and compute as a 130-second one.

2. **WebSocket streaming endpoint** — A new `/ws/correct-recitation` endpoint that streams raw PCM audio during recording so transfer overlaps with recording time. Critical for users on poor connections. Mirrors the protocol already used in the mobile app (`ListeningSura.tsx`).

3. **SageMaker engine migration** — Move the GPU inference engine off the always-on EC2 instance onto SageMaker Serverless Inference, which scales to zero and charges per inference-second only. The App (phonetic search, verse matching) stays on a smaller always-on EC2 instance. Combined with the EC2 downgrade this drops the monthly cost from ~$115/mo (spot g4dn.xlarge) to roughly **$7–40/mo** depending on traffic.

> **Important trade-off for SageMaker Serverless:** Serverless endpoints are CPU-only. The model runs in `float32` instead of `bfloat16` on a T4. Inference for a typical 10–30s ayah takes 5–15s (vs 1–3s on GPU). This is acceptable for an async "record, then wait for feedback" flow. If GPU speed becomes necessary, SageMaker Asynchronous Inference with a `ml.g4dn.xlarge` is the upgrade path — same container, same code, different endpoint config.

---

## Change 1 — Fix Dynamic Padding in the Engine

**Scope:** `src/quran_muaalem/engine/serve.py` only.
**Risk:** Low. Pure performance improvement, no API changes.
**Deploy:** Rebuild and restart the `engine` container.
**Note:** This fix must also be present in the SageMaker container (Change 4a). Since Change 4a is built after this, it will be included automatically.

### What's wrong

In `decode_request`, every input is padded to the global `self.max_features` regardless of actual audio length:

```python
self.max_features = int(np.ceil((self.sampling_rate * self.max_audio_seconds - 400) / (160 * 2)))
# With MAX_AUDIO_SECONDS=130 → 6,499 frames

features = self.processor(
    audio_array,
    ...
    padding="max_length",
    max_length=self.max_features,   # ← always 6,499, even for 5-second audio
)
```

A 5-second ayah (749 frames) is silently padded to 6,499 frames and processed at full 130-second cost.

### Prompt to give Claude Code

```
Fix the dynamic padding bug in the Quran Muaalem engine.

File to change: src/quran_muaalem/engine/serve.py

The problem is in the `decode_request` method of `QuranMuaalemAPI`. After
`librosa.load` returns the audio array, the code calls `self.processor` with
`padding="max_length"` and `max_length=self.max_features` (a fixed global
value calculated from MAX_AUDIO_SECONDS=130, which gives 6,499 frames).
This pads every input — including short 5-second ones — to 6,499 frames,
making every request as expensive as a 130-second one.

The fix: calculate the actual frame count from the real audio array length,
clamp it to self.max_features as the upper bound, and use that as max_length.

The frame count formula, matching the one already used in __init__, is:
    actual_frames = int(np.ceil((len(audio_array) - 400) / (160 * 2)))
    actual_frames = max(1, min(actual_frames, self.max_features))

Change only the `decode_request` method. Everything else stays the same.
No new imports are needed (numpy is already imported as np).
```

---

## Change 2 — WebSocket Streaming Endpoint

**Scope:** `src/quran_muaalem/app/serve.py` only.
**Risk:** Medium. Adds a new endpoint; does not modify existing ones.
**Deploy:** Rebuild and restart the `app` container.
**Dependency:** None. Can be done before or after Change 4. However, if Change 4b (SageMaker app integration) is done first, note that `call_engine_predict` will already accept `bytes` and use boto3 — the WebSocket prompt below already accounts for that structure.

### Protocol

The protocol matches what the mobile app already uses in `ListeningSura.tsx`
(using `react-native-live-audio-stream` and the existing WebSocket infrastructure):

```
Client                                    Server
  │                                         │
  │── WS connect to /ws/correct-recitation ─▶│
  │                                         │
  │── JSON: {"rewaya": "hafs", ...}  ───────▶│  (optional MoshafAttributes,
  │         (MoshafAttributes fields)        │   same fields as HTTP form)
  │                                         │
  │── binary: <PCM chunk>  ─────────────────▶│  (16kHz, 1-channel, 16-bit
  │── binary: <PCM chunk>  ─────────────────▶│   signed-int PCM, same as
  │── binary: <PCM chunk>  ─────────────────▶│   LiveAudioStream output)
  │    ... (during recording) ...            │
  │                                         │
  │── text: "END"  ─────────────────────────▶│  (user stops recording)
  │                                         │
  │                        (server assembles PCM chunks into WAV,
  │                         calls engine / SageMaker, runs search + analysis)
  │                                         │
  │◀── JSON: {...CorrectRecitationResponse...}│  (same schema as HTTP endpoint)
  │    or JSON: {...NoMatchResponse...}       │
  │                                         │
  │◀── WS close ────────────────────────────│
```

**PCM format** (must match the mobile `LiveAudioStream` options):
- Sample rate: 16,000 Hz
- Channels: 1 (mono)
- Bit depth: 16-bit signed integer, little-endian
- Chunk size: ~4,000 bytes per chunk (125 ms of audio)

### Prompt to give Claude Code

```
Add a WebSocket streaming endpoint to the Quran Muaalem app.

File to change: src/quran_muaalem/app/serve.py

## Background

The app already has a POST /correct-recitation endpoint. You are adding a
companion WebSocket endpoint /ws/correct-recitation that accepts audio
streamed as raw PCM chunks, assembles it on the server, then runs the same
analysis pipeline and returns the result over the WebSocket.

The mobile app streams 16kHz / 1-channel / 16-bit signed-int little-endian
PCM binary frames. This is the raw output of react-native-live-audio-stream
with options: { sampleRate: 16000, channels: 1, bitsPerSample: 16 }.

## Protocol

1. Client connects to ws://.../ws/correct-recitation
2. Client optionally sends a JSON text message with MoshafAttributes fields
   (same field names as the HTTP form endpoint). If omitted, defaults apply.
3. Client sends binary messages (raw PCM chunks) while recording.
4. Client sends the text message "END" when recording stops.
5. Server assembles all PCM chunks into a WAV file (add a standard 44-byte
   RIFF/WAV header: sample_rate=16000, channels=1, bits_per_sample=16).
6. Server sends the assembled WAV bytes to the engine via call_engine_predict.
7. Server runs phonetic search and error analysis (same as HTTP path).
8. Server sends one JSON text message back with the result — either
   CorrectRecitationResponse or CorrectRecitationNoMatchResponse (same
   Pydantic models already used by the HTTP endpoint).
9. Server closes the WebSocket.

## Changes needed

### 1. Refactor call_engine_predict to accept bytes

Change the existing `call_engine_predict(audio_file: UploadFile)` to
`call_engine_predict(audio_bytes: bytes)`. Update the HTTP endpoint callers
to read the bytes from UploadFile first, then pass bytes to this function.
This lets the WebSocket path reuse the same function without creating a
fake UploadFile.

### 2. Add a PCM-to-WAV helper

Add a small function `pcm_to_wav(pcm_bytes: bytes, sample_rate=16000,
channels=1, bits_per_sample=16) -> bytes` that prepends a 44-byte RIFF WAV
header to raw PCM bytes. Use the struct module (already in stdlib) to pack
the header. This is needed because the engine expects a valid audio container,
not bare PCM.

### 3. Add the WebSocket endpoint

Add a new endpoint:

    @app.websocket("/ws/correct-recitation")
    async def ws_correct_recitation(websocket: WebSocket):

Logic:
- await websocket.accept()
- Receive messages in a loop until "END" is received:
  - If text message == "END": break
  - If text message (not "END"): parse as JSON into MoshafAttributes
    (use the existing MoshafAttributes class; default to MoshafAttributes()
    if parse fails or no JSON is sent)
  - If binary message: append to a bytearray buffer
- After "END": convert buffer to WAV using pcm_to_wav()
- Call await call_engine_predict(wav_bytes) to get predicted_phonemes
- Run run_phonetic_search in executor (same as HTTP endpoint)
- If no results: send CorrectRecitationNoMatchResponse as JSON text and close
- Otherwise run run_phonetization_and_error in executor (same as HTTP endpoint)
- Send CorrectRecitationResponse as JSON text and close

Error handling:
- Wrap the whole handler in try/except WebSocketDisconnect: silently return
- Wrap analysis errors in try/except: send {"error": str(e)} as JSON text,
  then close with code 1011

Do not modify any existing endpoint. Do not add new imports beyond what is
needed (WebSocket and WebSocketDisconnect are in fastapi, struct is stdlib).
```

---

## Change 3 — Update Browser Test Tool

**Scope:** `tools/test_api.html` only.
**Risk:** Zero. Local test tool, not deployed.

### Prompt to give Claude Code

```
Update tools/test_api.html to add a WebSocket streaming test mode alongside
the existing HTTP POST mode.

## Background

The file already has a working "Record → Stop → Analyze" flow that POSTs the
full audio file to /correct-recitation after recording stops.

Add a second mode: a toggle at the top lets the user choose between
"HTTP (full file)" and "WebSocket (stream)". In WebSocket mode, audio is
streamed in real time while recording — no waiting to upload after stopping.

## WebSocket protocol

- Connect to ws://<api-url>/ws/correct-recitation when record starts
- Stream raw PCM binary frames: Int16Array chunks, 16kHz, 1 channel
  (convert Float32 microphone samples → Int16 by multiplying by 32767)
- Send text "END" when stop is pressed
- Receive one JSON text message back (same schema as HTTP response)
- Call the existing renderResult(data) function with the parsed JSON

## Audio capture

Use AudioContext + createScriptProcessor (or AudioWorkletNode if preferred)
to capture raw PCM from the microphone at 16kHz. The MediaRecorder API used
in HTTP mode does not expose raw PCM, so this path needs a different capture
stack. Target chunk size: ~4000 samples (250 ms at 16kHz).

Steps:
1. getUserMedia({ audio: true })
2. AudioContext with sampleRate: 16000 (or resample from native rate)
3. createScriptProcessor(4096, 1, 1) to receive Float32 PCM
4. In onaudioprocess: convert Float32 → Int16, send as binary over WebSocket
5. On stop: send "END", wait for JSON message, call renderResult(), close WS

## UI changes

- Add a radio/toggle above the controls: "Mode: ○ HTTP  ● WebSocket"
- In WebSocket mode the "Analyze" button is not needed (analysis starts
  automatically after "END") — hide it
- Show the same recording indicator and timer
- Status messages should indicate streaming is in progress during recording
  (e.g. "Streaming to server…") rather than "Recording…"
- Reuse the existing renderResult() and setStatus() functions unchanged

Keep the HTTP mode fully intact. The toggle just switches which capture and
send path is active. No external dependencies — plain browser APIs only.
```

---

## Change 4 — SageMaker Engine Migration

**Goal:** Move the GPU inference engine off the always-on EC2 instance onto
SageMaker Serverless Inference. Pay only per inference-second. Drop the EC2
instance from `g4dn.xlarge` (~$115/mo spot) to `t3.medium` (~$25/mo
on-demand), with no GPU needed on EC2 at all.

**After this change, the production architecture is:**

```
Mobile App / Browser
      │
      ▼
EC2 t3.medium (app + nginx, ~$25/mo, always on)
      │  boto3 invoke_endpoint()
      ▼
SageMaker Serverless Endpoint  (pay per inference-second, scales to zero)
      └── Container: Wav2Vec2-BERT model, CPU float32
```

**Cost after migration:**

| Component | Before | After |
|---|---|---|
| EC2 (engine + app) | g4dn.xlarge spot ~$115/mo | t3.medium ~$25/mo |
| SageMaker engine | — | ~$0–30/mo (traffic-based) |
| EBS 80 GB | ~$6/mo | ~$6/mo (unchanged) |
| **Total** | **~$121/mo** | **~$31–61/mo** |

This change has two sub-prompts that must be done in order.

---

### Change 4a — SageMaker Inference Container

**Scope:** New files under `deploy/sagemaker/` only. Nothing existing is touched.
**Risk:** Zero until deployed. Fully additive.
**What it produces:** A Docker image pushed to ECR that SageMaker can run as a serverless endpoint.

#### How SageMaker custom containers work

SageMaker calls the container at two fixed routes:
- `GET /ping` → must return 200 (health check)
- `POST /invocations` → receives raw audio bytes, must return `{"phonemes": "..."}`

The container listens on **port 8080** (SageMaker's fixed port). The model is
not baked into the image — it is stored in S3 as `model.tar.gz` and SageMaker
extracts it to `/opt/ml/model/` inside the container at startup.

#### Prompt to give Claude Code

```
Create the SageMaker inference container for the Quran Muaalem engine.

This is a new set of files under deploy/sagemaker/. Do not modify any
existing files.

## What to create

### deploy/sagemaker/serve.py

A FastAPI application that:
- Listens on port 8080
- Exposes GET /ping → returns {"status": "ok"} with HTTP 200
- Exposes POST /invocations → receives raw audio bytes (any format: WAV,
  webm, mp4), runs inference, returns {"phonemes": "..."}

Model loading:
- Load the model once at startup (not per request) using a lifespan handler
- Model directory is /opt/ml/model/ (SageMaker extracts model.tar.gz here)
- Load: AutoFeatureExtractor, Wav2Vec2BertForMultilevelCTC, MultiLevelTokenizer
  — same as the existing engine/serve.py setup() method
- Use dtype=torch.float32 (CPU — SageMaker Serverless has no GPU)
- Use device="cpu"

Inference logic for POST /invocations:
- Read raw audio bytes from request body
- Convert to 16kHz mono WAV using ffmpeg subprocess (pipe:0 → pipe:1),
  same as the existing engine/serve.py decode_request method
- Load with librosa (sr=16000, mono=True, duration=130.0)
- Calculate actual_frames = max(1, min(int(ceil((len(audio)-400)/(160*2))), max_features))
  where max_features = int(ceil((16000*130-400)/320))
- Run processor with padding="max_length", max_length=actual_frames
- Run model inference with torch.inference_mode()
- Run simple CTC decode (copy the simple_ctc_decode function from
  engine/serve.py verbatim)
- Return {"phonemes": "<decoded string>"}

The classes and helper functions needed are already in the package:
- from quran_muaalem.modeling.modeling_multi_level_ctc import Wav2Vec2BertForMultilevelCTC
- from quran_muaalem.modeling.multi_level_tokenizer import MultiLevelTokenizer
Copy simple_ctc_decode from engine/serve.py directly into this file rather
than importing from engine (to keep this container self-contained).

### deploy/sagemaker/Dockerfile

Base image: python:3.11-slim

Steps:
1. Install system packages: ffmpeg libsndfile1 curl ca-certificates
2. Install CPU-only torch: pip install torch --index-url https://download.pytorch.org/whl/cpu
3. COPY the repo and pip install ".[engine]"
4. COPY deploy/sagemaker/serve.py to /opt/program/serve.py
5. Set WORKDIR /opt/program
6. EXPOSE 8080
7. ENV PYTHONUNBUFFERED=1
8. ENTRYPOINT ["uvicorn", "serve:app", "--host", "0.0.0.0", "--port", "8080"]

### deploy/sagemaker/package_model.sh

A shell script that:
1. Downloads the model from HuggingFace using huggingface-cli:
     huggingface-cli download obadx/muaalem-model-v3_2 --local-dir /tmp/muaalem-model
2. Creates model.tar.gz from that directory:
     tar -czf model.tar.gz -C /tmp/muaalem-model .
3. Uploads to S3:
     aws s3 cp model.tar.gz s3://<S3_BUCKET>/quran-muaalem/model.tar.gz
   where S3_BUCKET is read from the first script argument or env var.
4. Prints the S3 URI on success.

### deploy/sagemaker/deploy_endpoint.py

A Python script using boto3 that:
1. Creates an ECR repository named "quran-muaalem-engine" if it doesn't exist
2. Prints the docker build + push commands (does not run them — user runs manually)
3. Creates a SageMaker Model resource pointing to:
   - Image URI: <account>.dkr.ecr.<region>.amazonaws.com/quran-muaalem-engine:latest
   - ModelDataUrl: s3://<S3_BUCKET>/quran-muaalem/model.tar.gz
4. Creates a ServerlessConfig:
   - MemorySizeInMB: 6144  (maximum — model needs ~3-4 GB in float32)
   - MaxConcurrency: 5
5. Creates a SageMaker Endpoint with that config
6. Waits for endpoint to become InService
7. Prints the endpoint name

All values (region, account_id, s3_bucket, endpoint_name) read from
environment variables or argparse arguments. Add a --dry-run flag that
prints what would be created without creating anything.

No Terraform for this step — boto3 script is simpler for a one-time setup.
```

---

### Change 4b — App Integration and EC2 Downgrade

**Scope:**
- `src/quran_muaalem/app/serve.py` — `call_engine_predict` calls SageMaker
- `src/quran_muaalem/app/settings.py` — new `sagemaker_endpoint_name` setting
- `docker-compose.yml` — remove `engine` service
- `deploy/terraform/main.tf` — downgrade instance type, remove GPU block
- `.env.example` — add SageMaker env vars, remove engine-only vars

**Risk:** High (production cutover). Only run after Change 4a endpoint is live and tested.
**Dependency:** If Change 2 (WebSocket) was already applied, `call_engine_predict` already accepts `bytes` — this prompt only needs to change the implementation from httpx to boto3. If Change 2 has NOT been applied yet, include the bytes refactor from Change 2's prompt as well and apply both in one go.

#### Prompt to give Claude Code

```
Migrate the Quran Muaalem app to call SageMaker instead of the local engine.

This is a production cutover. The SageMaker endpoint is already live before
this change is applied.

## Files to change

### 1. src/quran_muaalem/app/settings.py

Add two new fields to AppSettings:
- sagemaker_endpoint_name: str — name of the deployed SageMaker endpoint
  (read from env var SAGEMAKER_ENDPOINT_NAME, no default — required)
- aws_region: str — AWS region, default "us-east-1"
  (read from env var AWS_REGION)

Keep all existing fields unchanged.

### 2. src/quran_muaalem/app/serve.py

Replace `call_engine_predict` with a SageMaker version.

Current signature (after Change 2, if already applied):
    async def call_engine_predict(audio_bytes: bytes) -> str

If Change 2 has NOT been applied yet, first refactor:
    async def call_engine_predict(audio_file: UploadFile) -> str
to:
    async def call_engine_predict(audio_bytes: bytes) -> str
and update all callers (correct_recitation, search, transcript endpoints)
to read bytes from the UploadFile before calling.

New implementation of call_engine_predict:
- Use boto3.client("sagemaker-runtime") to call invoke_endpoint
- This is a blocking boto3 call — wrap it in asyncio.get_event_loop().run_in_executor()
  using the existing search executor to avoid blocking the event loop
- Pass audio_bytes as the Body
- ContentType: "audio/wav"
- EndpointName: app_settings.sagemaker_endpoint_name
- Parse the response Body JSON and return data["phonemes"]

Add boto3 as an import. boto3 is available in the standard AWS Python
environment; add it to pyproject.toml under the app's dependencies if not
already present.

Remove the httpx import ONLY IF it is no longer used anywhere else in the
file after this change (check — it may still be used in the health endpoint).

### 3. docker-compose.yml

Remove the entire `engine` service block (the one with the GPU deploy
reservation, huggingface_cache volume mount, and Dockerfile.engine).
Remove the `huggingface_cache` volume from the volumes section.
Remove `depends_on: engine` from the `app` service.
Keep the `app` and `nginx` services unchanged.

### 4. deploy/terraform/main.tf

Change the EC2 instance type from "g4dn.xlarge" to "t3.medium".
Remove the entire `dynamic "instance_market_options"` block and the
`use_spot` variable reference (t3.medium spot savings are minimal;
on-demand is simpler).
Keep everything else (EIP, SG, IAM role, EBS, user_data) unchanged.

### 5. .env.example

Add these lines in a new "# SageMaker Engine" section:
    SAGEMAKER_ENDPOINT_NAME=quran-muaalem-engine
    AWS_REGION=us-east-1

Remove or comment out engine-only vars that no longer apply to the EC2
deployment (ACCELERATOR, DTYPE, MAX_BATCH_SIZE, WORKERS_PER_DEVICE,
BATCH_TIMEOUT) since the engine no longer runs on EC2. Keep MAX_AUDIO_SECONDS
and MODEL_NAME_OR_PATH commented out with a note that they are set inside
the SageMaker container, not here.

The EC2 instance has an IAM role with SageMaker invoke permissions already
(added via Terraform). The app uses the instance's IAM role credentials
automatically through boto3 — no AWS keys in .env.
```

#### Required IAM permission (add to Terraform before running 4b)

The EC2 instance's IAM role needs permission to call the SageMaker endpoint.
Add this inline policy to `aws_iam_role.ec2` in `deploy/terraform/main.tf`:

```hcl
resource "aws_iam_role_policy" "sagemaker_invoke" {
  name = "${var.project_name}-sagemaker-invoke"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sagemaker:InvokeEndpoint"
      Resource = "arn:aws:sagemaker:${var.aws_region}:*:endpoint/*"
    }]
  })
}
```

---

## Deployment Order

```
Phase 1 — Quick wins (current EC2, no infrastructure change)
──────────────────────────────────────────────────────────────
1. Change 1 (padding fix): deploy to engine container immediately.
   Improves all existing traffic. Zero risk.

2. Change 2 (WebSocket endpoint): deploy to app container.
   New feature, no existing endpoint affected.

3. Change 3 (test tool): update locally as needed. Never deployed.

Phase 2 — SageMaker migration (do as one coordinated cutover)
──────────────────────────────────────────────────────────────
4. Change 4a: build SageMaker container, package model, deploy endpoint.
   Test the SageMaker endpoint directly with curl before proceeding.

5. Add SageMaker invoke IAM policy to Terraform, run terraform apply
   (only the IAM resource changes — safe to apply on live instance).

6. Change 4b: update app code + docker-compose + Terraform.
   git push → CI deploys to existing g4dn.xlarge first (safe).
   Verify app health and a full test request end-to-end.

7. terraform apply to resize EC2 from g4dn.xlarge → t3.medium.
   This requires stopping the instance briefly (EIP stays attached).
   Schedule during low-traffic period.
```

**Server deploy command (same for all backend changes):**

```bash
cd /app
git pull
docker compose build <service>   # 'engine' for Change 1, 'app' for Changes 2 & 4b
docker compose up -d <service>
docker compose logs <service> --tail=30
```
