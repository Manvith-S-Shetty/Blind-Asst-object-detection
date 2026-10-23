"""
Mock SpeechToText and TextToSpeech.

Swap for real:
  SpeechToText -> Whisper Large-v3 (openai-whisper or faster-whisper)
  TextToSpeech -> Piper TTS (piper-tts, runs fully offline/on-device)
"""
from app.pipeline.interfaces import SpeechToText, TextToSpeech
from app.models.schemas import TranscriptResult


class MockSpeechToText(SpeechToText):
    async def transcribe(self, audio_bytes: bytes) -> TranscriptResult:
        # Real Whisper call would be:
        #   result = whisper_model.transcribe(audio_path)
        # Here we just acknowledge receipt with a placeholder command so the
        # rest of the voice-command flow (routing to an action) is testable.
        if len(audio_bytes) == 0:
            return TranscriptResult(text="", confidence=0.0)
        return TranscriptResult(text="what is in front of me", confidence=0.9)


class MockTextToSpeech(TextToSpeech):
    async def synthesize(self, text: str) -> bytes:
        # Real Piper call would render a WAV. We return a tiny valid WAV
        # header + silence so the audio contract (bytes out) is honored.
        import struct
        sample_rate = 16000
        num_samples = sample_rate // 4  # 0.25s of silence as a placeholder
        data = b"\x00\x00" * num_samples
        header = struct.pack(
            "<4sI4s4sIHHIIHH4sI",
            b"RIFF", 36 + len(data), b"WAVE", b"fmt ", 16, 1, 1,
            sample_rate, sample_rate * 2, 2, 16, b"data", len(data),
        )
        return header + data
