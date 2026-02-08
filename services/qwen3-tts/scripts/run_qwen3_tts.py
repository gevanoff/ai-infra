#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

import soundfile as sf
import torch
from qwen_tts import Qwen3TTSModel


def _env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    return value


def _fail(message: str, code: int = 2) -> None:
    print(message, file=sys.stderr)
    sys.exit(code)


def _float_env(name: str, default: float) -> float:
    raw = _env(name)
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _int_env(name: str, default: int) -> int:
    raw = _env(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _bool_env(name: str, default: bool = False) -> bool:
    raw = _env(name).lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "on"}


def _dtype(value: str) -> torch.dtype:
    value = value.strip().lower()
    if value in {"bf16", "bfloat16"}:
        return torch.bfloat16
    if value in {"f16", "float16", "fp16"}:
        return torch.float16
    if value in {"f32", "float32", "fp32"}:
        return torch.float32
    return torch.float32


def main() -> None:
    request_json = _env("QWEN3_TTS_REQUEST_JSON")
    output_path = _env("QWEN3_TTS_OUTPUT_PATH")

    if not request_json:
        _fail("QWEN3_TTS_REQUEST_JSON is not set")
    if not output_path:
        _fail("QWEN3_TTS_OUTPUT_PATH is not set")

    request_path = Path(request_json)
    if not request_path.exists():
        _fail(f"QWEN3_TTS_REQUEST_JSON does not exist: {request_path}")

    try:
        payload = json.loads(request_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        _fail(f"Failed to parse QWEN3_TTS_REQUEST_JSON: {exc}")

    text = payload.get("input") or payload.get("text")
    if not text:
        _fail("Request JSON missing 'input' text")

    task = (_env("QWEN3_TTS_TASK") or "custom_voice").strip().lower()
    model_id = _env("QWEN3_TTS_MODEL_ID") or "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
    device_map = _env("QWEN3_TTS_DEVICE_MAP") or "cpu"
    dtype = _dtype(_env("QWEN3_TTS_DTYPE") or "float32")
    attn_impl = _env("QWEN3_TTS_ATTN_IMPL")

    model_kwargs = {
        "device_map": device_map,
        "dtype": dtype,
    }
    if attn_impl:
        model_kwargs["attn_implementation"] = attn_impl

    model = Qwen3TTSModel.from_pretrained(model_id, **model_kwargs)

    if task == "voice_design":
        language = _env("QWEN3_TTS_LANGUAGE") or "Auto"
        instruct = _env("QWEN3_TTS_INSTRUCT") or ""
        wavs, sr = model.generate_voice_design(
            text=text,
            language=language,
            instruct=instruct,
        )
    elif task == "voice_clone":
        language = _env("QWEN3_TTS_LANGUAGE") or "Auto"
        ref_audio = _env("QWEN3_TTS_REF_AUDIO")
        ref_text = _env("QWEN3_TTS_REF_TEXT")
        if not ref_audio:
            _fail("QWEN3_TTS_REF_AUDIO is not set for voice_clone")
        x_vector_only = _bool_env("QWEN3_TTS_X_VECTOR_ONLY", False)
        wavs, sr = model.generate_voice_clone(
            text=text,
            language=language,
            ref_audio=ref_audio,
            ref_text=ref_text,
            x_vector_only_mode=x_vector_only,
        )
    else:
        language = _env("QWEN3_TTS_LANGUAGE") or "Auto"
        speaker = payload.get("voice") or _env("QWEN3_TTS_SPEAKER") or "Vivian"
        instruct = _env("QWEN3_TTS_INSTRUCT") or ""
        wavs, sr = model.generate_custom_voice(
            text=text,
            language=language,
            speaker=speaker,
            instruct=instruct,
        )

    if not wavs:
        _fail("QWEN3_TTS returned empty audio list")

    out_path = Path(output_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(out_path), wavs[0], sr)

    if not out_path.exists() or out_path.stat().st_size == 0:
        _fail(f"QWEN3_TTS_OUTPUT_PATH is empty: {out_path}")


if __name__ == "__main__":
    main()
