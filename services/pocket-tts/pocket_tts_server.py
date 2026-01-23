"""FastAPI shim for Pocket TTS.

This server exposes a minimal OpenAI-compatible endpoint for text-to-speech:
- POST /v1/audio/speech
- GET /health
- GET /v1/models
"""
from __future__ import annotations

import base64
import os
import shlex
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, Field

app = FastAPI(title="Pocket TTS")


class SpeechRequest(BaseModel):
    input: str = Field(..., min_length=1)
    model: Optional[str] = None
    voice: Optional[str] = None
    response_format: str = Field("wav", regex="^(wav|mp3)$")


class PocketTTSBackend:
    def __init__(self) -> None:
        self.backend = os.getenv("POCKET_TTS_BACKEND", "auto")
        self.command = os.getenv("POCKET_TTS_COMMAND", "pocket-tts")
        self.command_args = shlex.split(os.getenv("POCKET_TTS_COMMAND_ARGS", ""))
        self.text_arg = os.getenv("POCKET_TTS_COMMAND_TEXT_ARG", "--text")
        self.output_arg = os.getenv("POCKET_TTS_COMMAND_OUTPUT_ARG", "--output")
        self.model_arg = os.getenv("POCKET_TTS_COMMAND_MODEL_ARG", "--model")
        self.voice_arg = os.getenv("POCKET_TTS_COMMAND_VOICE_ARG", "--voice")
        self.format_arg = os.getenv("POCKET_TTS_COMMAND_FORMAT_ARG", "")
        self.model_path = os.getenv("POCKET_TTS_MODEL_PATH", "")
        self.default_voice = os.getenv("POCKET_TTS_VOICE", "default")
        self.sample_rate = int(os.getenv("POCKET_TTS_SAMPLE_RATE", "22050"))
        self._python_backend: Optional[Any] = None

    def _load_python_backend(self) -> bool:
        try:
            import pocket_tts  # type: ignore
        except Exception:
            return False

        candidate = None
        if hasattr(pocket_tts, "PocketTTS"):
            candidate = pocket_tts.PocketTTS
        elif hasattr(pocket_tts, "TTS"):
            candidate = pocket_tts.TTS
        else:
            candidate = pocket_tts

        if candidate is pocket_tts:
            self._python_backend = pocket_tts
            return True

        try:
            if self.model_path:
                try:
                    self._python_backend = candidate(self.model_path)
                except TypeError:
                    self._python_backend = candidate(model_path=self.model_path)
            else:
                self._python_backend = candidate()
            return True
        except Exception:
            return False

    def _ensure_python_backend(self) -> bool:
        if self._python_backend is not None:
            return True
        return self._load_python_backend()

    def _python_synthesize(self, text: str, voice: str, response_format: str) -> bytes:
        backend = self._python_backend
        if backend is None:
            raise RuntimeError("python backend not loaded")

        for method_name in ("synthesize", "tts", "generate", "__call__"):
            if hasattr(backend, method_name):
                method = getattr(backend, method_name)
                try:
                    result = method(
                        text=text,
                        voice=voice,
                        model_path=self.model_path or None,
                        sample_rate=self.sample_rate,
                        response_format=response_format,
                    )
                except TypeError:
                    try:
                        result = method(text, voice=voice)
                    except TypeError:
                        result = method(text)

                if isinstance(result, bytes):
                    return result
                if isinstance(result, tuple) and result:
                    maybe_audio = result[0]
                    if isinstance(maybe_audio, bytes):
                        return maybe_audio
                if isinstance(result, str):
                    # Treat as file path
                    return Path(result).read_bytes()
        raise RuntimeError("python backend did not expose a compatible synthesize method")

    def _command_synthesize(self, text: str, voice: str, response_format: str) -> bytes:
        suffix = "." + response_format
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
            output_path = Path(tmp.name)

        cmd = [self.command] + self.command_args
        if self.text_arg:
            cmd += [self.text_arg, text]
        if self.output_arg:
            cmd += [self.output_arg, str(output_path)]
        if self.model_arg and self.model_path:
            cmd += [self.model_arg, self.model_path]
        if self.voice_arg and voice:
            cmd += [self.voice_arg, voice]
        if self.format_arg:
            cmd += [self.format_arg, response_format]

        try:
            subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except FileNotFoundError as exc:
            raise RuntimeError(
                f"Pocket TTS command not found: {self.command}. Set POCKET_TTS_COMMAND to a valid binary."
            ) from exc
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(
                f"Pocket TTS command failed: {exc.stderr.decode('utf-8', errors='ignore')}"
            ) from exc

        audio = output_path.read_bytes()
        output_path.unlink(missing_ok=True)
        return audio

    def synthesize(self, text: str, voice: str, response_format: str) -> bytes:
        backend_pref = self.backend.lower()
        if backend_pref not in {"auto", "python", "command"}:
            raise RuntimeError(f"Unsupported POCKET_TTS_BACKEND={self.backend}")

        if backend_pref in {"auto", "python"}:
            if self._ensure_python_backend():
                return self._python_synthesize(text, voice, response_format)
            if backend_pref == "python":
                raise RuntimeError("POCKET_TTS_BACKEND=python but pocket_tts import failed")

        return self._command_synthesize(text, voice, response_format)


backend = PocketTTSBackend()


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/v1/models")
async def list_models() -> dict[str, Any]:
    model_name = os.getenv("POCKET_TTS_MODEL_NAME", "pocket-tts")
    return {
        "object": "list",
        "data": [
            {
                "id": model_name,
                "object": "model",
                "owned_by": "pocket-tts",
            }
        ],
    }


@app.post("/v1/audio/speech")
async def speech(req: SpeechRequest) -> Response:
    voice = req.voice or os.getenv("POCKET_TTS_VOICE", "default")
    response_format = req.response_format

    try:
        audio = backend.synthesize(req.input, voice, response_format)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    media_type = "audio/wav" if response_format == "wav" else "audio/mpeg"
    return Response(content=audio, media_type=media_type)


@app.post("/v1/audio/speech/base64")
async def speech_base64(req: SpeechRequest) -> dict[str, str]:
    voice = req.voice or os.getenv("POCKET_TTS_VOICE", "default")
    response_format = req.response_format

    try:
        audio = backend.synthesize(req.input, voice, response_format)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    encoded = base64.b64encode(audio).decode("utf-8")
    return {"audio": encoded, "format": response_format}
