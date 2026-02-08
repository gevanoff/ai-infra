#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

import soundfile as sf
import torch
from zipvoice.luxvoice import LuxTTS


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


def _device() -> str:
    device = _env("LUXTTS_DEVICE") or "auto"
    if device != "auto":
        return device
    if torch.cuda.is_available():
        return "cuda"
    if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def main() -> None:
    request_json = _env("LUXTTS_REQUEST_JSON")
    output_path = _env("LUXTTS_OUTPUT_PATH")

    if not request_json:
        _fail("LUXTTS_REQUEST_JSON is not set")
    if not output_path:
        _fail("LUXTTS_OUTPUT_PATH is not set")

    request_path = Path(request_json)
    if not request_path.exists():
        _fail(f"LUXTTS_REQUEST_JSON does not exist: {request_path}")

    try:
        payload = json.loads(request_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        _fail(f"Failed to parse LUXTTS_REQUEST_JSON: {exc}")

    text = payload.get("input") or payload.get("text")
    if not text:
        _fail("Request JSON missing 'input' text")

    prompt_audio = _env("LUXTTS_PROMPT_AUDIO") or payload.get("prompt_audio")
    if not prompt_audio:
        _fail("LUXTTS_PROMPT_AUDIO is not set")

    model_id = _env("LUXTTS_MODEL_ID") or "YatharthS/LuxTTS"
    device = _device()
    threads = _int_env("LUXTTS_CPU_THREADS", 0)

    if device == "cpu" and threads > 0:
        lux_tts = LuxTTS(model_id, device=device, threads=threads)
    else:
        lux_tts = LuxTTS(model_id, device=device)

    rms = _float_env("LUXTTS_RMS", 0.01)
    ref_duration = _int_env("LUXTTS_REF_DURATION", 0)
    if ref_duration > 0:
        encoded_prompt = lux_tts.encode_prompt(prompt_audio, duration=ref_duration, rms=rms)
    else:
        encoded_prompt = lux_tts.encode_prompt(prompt_audio, rms=rms)

    num_steps = _int_env("LUXTTS_NUM_STEPS", 4)
    t_shift = _float_env("LUXTTS_T_SHIFT", 0.9)
    speed = _float_env("LUXTTS_SPEED", 1.0)
    return_smooth = _bool_env("LUXTTS_RETURN_SMOOTH", False)

    final_wav = lux_tts.generate_speech(
        text,
        encoded_prompt,
        num_steps=num_steps,
        t_shift=t_shift,
        speed=speed,
        return_smooth=return_smooth,
    )
    final_wav = final_wav.numpy().squeeze()

    out_path = Path(output_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(out_path), final_wav, 48000)

    if not out_path.exists() or out_path.stat().st_size == 0:
        _fail(f"LUXTTS_OUTPUT_PATH is empty: {out_path}")


if __name__ == "__main__":
    main()
