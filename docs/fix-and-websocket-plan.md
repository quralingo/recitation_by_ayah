# Fix & WebSocket Implementation Plan

## Context

Two changes are needed:

1. **Dynamic padding fix** — The engine currently pads every audio input to `max_features` (derived from `MAX_AUDIO_SECONDS=130`), meaning a 5-second ayah uses the same GPU memory and compute as a 130-second one. This tanks throughput for all requests.

2. **WebSocket streaming endpoint** — A new `/ws/correct-recitation` endpoint that lets the client stream raw PCM audio while recording, so transfer overlaps with recording time. This is especially important for users on poor connections. The endpoint mirrors the existing HTTP `/correct-recitation` but over WebSocket using the same streaming protocol already in use in the mobile app (`ListeningSura.tsx`).

The two changes are independent and can be deployed in either order.

---

## Change 1 — Fix Dynamic Padding in the Engine

**Scope:** `src/quran_muaalem/engine/serve.py` only.  
**Risk:** Low. Pure performance improvement, no API or protocol changes.  
**Deploy:** Rebuild and restart the `engine` container.

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
  │                         calls engine, runs search + analysis)
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

### What needs to change in `serve.py`

1. **Refactor `call_engine_predict`** to accept raw `bytes` instead of `UploadFile`, so both the HTTP endpoint and the WebSocket endpoint can reuse it. The HTTP endpoint wraps the file bytes and calls the refactored function.

2. **Add a PCM-to-WAV helper** that wraps raw PCM bytes in a proper WAV header (44-byte RIFF header: sample rate 16000, channels 1, bits 16). This allows librosa/ffmpeg on the engine to receive a valid WAV instead of bare PCM.

3. **Add the WebSocket endpoint** at `/ws/correct-recitation`.

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
6. Server sends the assembled WAV bytes to the engine (same as HTTP path).
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
This lets the WebSocket path reuse the same function.

### 2. Add a PCM-to-WAV helper

Add a small function `pcm_to_wav(pcm_bytes: bytes, sample_rate=16000,
channels=1, bits_per_sample=16) -> bytes` that prepends a 44-byte RIFF WAV
header to raw PCM bytes. Use the struct module (already in stdlib) to pack
the header. This is needed because librosa on the engine expects a valid
audio container, not bare PCM.

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

### What to add

A second mode in the test page that:
- Opens a WebSocket to `/ws/correct-recitation`
- Streams raw PCM via the browser's `AudioWorklet` or `ScriptProcessorNode`
  (16kHz, mono, 16-bit signed-int, same format as the mobile app)
- Sends "END" when the stop button is pressed
- Renders the result with the existing `renderResult()` function

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

## Deployment Order

Both changes are independent. Recommended order:

```
1. Deploy Change 1 (padding fix) first — immediate throughput improvement,
   zero risk, benefits all existing traffic including HTTP endpoint.

2. Deploy Change 2 (WebSocket endpoint) — new feature, no impact on
   existing HTTP endpoint.

3. Update Change 3 (test tool) locally as needed for testing — never deployed.
```

For each backend change, the deploy sequence on the server is:

```bash
cd /app
git pull
docker compose build <service>   # 'engine' for Change 1, 'app' for Change 2
docker compose up -d <service>
docker compose logs <service> --tail=30
```
