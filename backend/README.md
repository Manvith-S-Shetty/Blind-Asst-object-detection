# Blind Assistant AI — Backend

FastAPI backend for a real-time object detection & navigation assistant for
blind users. Built so the **architecture and decision logic are real and
demoable today**, while the heavy AI models (YOLOv11, Depth Anything V2,
Florence-2, SAM2, Whisper, Piper TTS, etc.) are wired in through clean
interfaces you can swap real weights into.

## Why "mock" models (for the components still mocked)?

**Object detection is now real** — YOLOv11 via `ultralytics`, wired in
and on by default. The remaining components (depth, scene description,
tracking, OCR, STT, TTS) still use mock implementations, for the same
reason: they need multi-gigabyte pretrained weights (SAM2, Whisper
Large-v3, Florence-2, Depth Anything V2...) and platform-specific setup
that doesn't belong in a portable starter project. Each is behind an
interface (`app/pipeline/interfaces.py`) — implement the real version
in `app/pipeline/real/` (the YOLO one is a working template to copy)
and flip its flag in `app/core/config.py`.

## Performance note (real YOLOv11)

- **First request after server startup is now fast** (~250-300ms) — the
  model is warmed up automatically during startup (`app/main.py`), not
  on the first live frame.
- **Steady-state inference is ~120-250ms per frame on CPU** (no GPU
  needed, tested on a standard cloud VM). That's within the app's
  400ms frame interval, so live navigation works smoothly.
- If you have an NVIDIA GPU with CUDA installed, `ultralytics` will
  use it automatically and this drops to ~10-30ms per frame — no code
  changes needed.
- Detections are filtered to obstacle-relevant COCO classes (person,
  vehicles, furniture, etc. — see `RELEVANT_CLASSES` in
  `app/pipeline/real/yolo_detector.py`) so the assistant doesn't
  narrate irrelevant objects.

## Architecture

```
Flutter Mobile App
        |
        v
FastAPI Backend  (this project)
        |
        v
AI Processing Engine (app/pipeline/)
  - Detector          (YOLOv11 interface)
  - Tracker            (ByteTrack interface)
  - DepthEstimator      (Depth Anything V2 interface)
  - SceneDescriber       (Florence-2 interface)
  - OpenVocabLocator      (Locate Anything-3B interface)
  - OCRReader              (PaddleOCR interface)
  - Segmenter                (SAM2 / FastSAM interface)
  - SpeechToText                (Whisper interface)
  - TextToSpeech                  (Piper TTS interface)
        |
        v
Decision Engine (app/services/decision_engine.py)
        |
        v
Voice Navigation & Assistance (spoken guidance out over WebSocket / TTS)
```

## Project layout

```
app/
  main.py                 FastAPI app, WebSocket + REST wiring
  core/
    config.py             Settings (toggle mock vs real models)
    logging_config.py     Rotating file handler logging
  models/
    schemas.py            Pydantic schemas (Detection, Frame, Guidance...)
  pipeline/
    interfaces.py         Abstract base classes for every AI component
    mock/                 Deterministic mock implementations (default)
    real/                 Drop real model implementations here
    factory.py            Builds the pipeline from config
  services/
    decision_engine.py    Turns raw model output into spoken guidance
    session_manager.py    Tracks per-user streaming sessions
  api/
    routes.py              REST endpoints (health, session, OCR, history)
    websocket.py            Live camera-frame -> guidance streaming
  tests/
    test_decision_engine.py
    test_pipeline.py
```

## Running it

```bash
python -m venv venv && source venv/bin/activate   # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

**Heads up:** `requirements.txt` now includes `ultralytics`, which pulls
in PyTorch. This is a large install (~700MB-2GB depending on your
platform) and will take a few minutes — this is expected, not an error.

```bash
uvicorn app.main:app --reload --port 8000
```

The first time you run it, it'll also auto-download the YOLOv11 nano
weights (~5.4MB, from Ultralytics' GitHub releases) — you'll see a
download progress bar in the terminal. After that it's cached locally.

Open `http://localhost:8000/docs` for the interactive API.
Connect a WebSocket client to `ws://localhost:8000/ws/navigate/{session_id}`
and send base64 JPEG frames — you'll get back structured guidance JSON
(and can wire that straight into TTS on the Flutter side).

## Swapping in real models (for your final demo)

1. Implement the matching interface in `app/pipeline/real/`, e.g.
   `app/pipeline/real/yolo_detector.py` implementing `Detector`.
2. Set `USE_REAL_MODELS = {"detector": True, ...}` in `.env` / config.
3. `app/pipeline/factory.py` picks it up automatically — nothing else
   in the API or decision engine changes.

This is deliberately how production ML services are structured (interface
+ pluggable implementation) — worth mentioning if you're asked about
design decisions in a viva/defense.
