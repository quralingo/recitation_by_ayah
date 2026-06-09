# App service — FastAPI REST API (no GPU required)
#
# CPU-only torch keeps this image ~2 GB lighter than the engine image.
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg libsndfile1 portaudio19-dev \
        curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# CPU-only torch — the app never runs inference directly, it calls the engine over HTTP.
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir \
        "torch>=2.7.0" \
        --index-url https://download.pytorch.org/whl/cpu

COPY . .
RUN pip install --no-cache-dir ".[engine]"

ENV ENGINE_URL=http://engine:8000/predict
ENV PORT=8001
ENV HOST=0.0.0.0

EXPOSE 8001

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8001/health || exit 1

CMD ["quran-muaalem-app"]
