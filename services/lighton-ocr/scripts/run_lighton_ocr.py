#!/usr/bin/env python3
import base64
import json
import os
import sys
import urllib.request
from io import BytesIO
from pathlib import Path
from typing import Any, Dict, Optional


def _env(name: str, default: Optional[str] = None) -> Optional[str]:
    value = os.environ.get(name)
    if value is None:
        return default
    value = value.strip()
    return value if value else default


def _int_env(name: str, default: int) -> int:
    raw = _env(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _read_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")


def _load_image_bytes(request_payload: Dict[str, Any], input_path: Optional[Path]) -> bytes:
    if input_path is not None:
        if input_path.suffix == ".url":
            url = input_path.read_text(encoding="utf-8").strip()
            if not url:
                raise ValueError("LIGHTON_OCR_INPUT_PATH .url file is empty")
            req = urllib.request.Request(
                url,
                headers={
                    "User-Agent": "Mozilla/5.0 (compatible; LightOnOCR/1.0; +https://github.com/gevanoff/ai-infra)",
                    "Accept": "image/*,*/*;q=0.8",
                },
            )
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read()
        return input_path.read_bytes()

    image_b64 = request_payload.get("image")
    if image_b64:
        try:
            return base64.b64decode(image_b64)
        except Exception as exc:
            raise ValueError(f"Invalid base64 image: {exc}")

    image_url = request_payload.get("image_url")
    if image_url:
        req = urllib.request.Request(
            str(image_url),
            headers={
                "User-Agent": "Mozilla/5.0 (compatible; LightOnOCR/1.0; +https://github.com/gevanoff/ai-infra)",
                "Accept": "image/*,*/*;q=0.8",
            },
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read()

    raise ValueError("No image input provided")


def _load_image_pil(image_bytes: bytes):
    try:
        from PIL import Image
    except Exception as exc:
        raise RuntimeError(f"Pillow is required for OCR: {exc}")
    try:
        return Image.open(BytesIO(image_bytes)).convert("RGB")
    except Exception as exc:
        raise RuntimeError(f"Failed to decode image: {exc}")


def _select_device() -> str:
    device = (_env("LIGHTON_OCR_DEVICE", "auto") or "auto").lower()
    if device not in {"auto", "cpu", "cuda", "mps"}:
        return "auto"
    return device


def _resolve_device() -> str:
    device = _select_device()
    if device == "cpu":
        return "cpu"
    if device == "cuda":
        return "cuda"
    if device == "mps":
        return "mps"

    try:
        import torch

        if torch.cuda.is_available():
            return "cuda"
        if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
            return "mps"
    except Exception:
        pass

    return "cpu"


def _run_ocr(image, request_payload: Dict[str, Any]) -> Dict[str, Any]:
    model_id = _env("LIGHTON_OCR_MODEL_ID", "lightonai/LightOnOCR-2-1B")
    max_tokens = _int_env("LIGHTON_OCR_MAX_TOKENS", 256)
    device = _resolve_device()

    try:
        from transformers import pipeline
    except Exception as exc:
        raise RuntimeError(f"transformers is required for OCR: {exc}")

    pipe = pipeline("image-to-text", model=model_id)
    if device in {"cuda", "mps"}:
        try:
            pipe.model.to(device)
        except Exception:
            pass

    result = pipe(image, max_new_tokens=max_tokens)
    text = None
    if isinstance(result, list) and result:
        first = result[0]
        if isinstance(first, dict):
            text = first.get("generated_text") or first.get("text")

    if not text:
        text = str(result)

    return {
        "text": text,
        "model": model_id,
        "data": [{"text": text}],
        "raw": result,
    }


def main() -> int:
    request_path = _env("LIGHTON_OCR_REQUEST_JSON")
    output_path = _env("LIGHTON_OCR_OUTPUT_JSON")
    input_path = _env("LIGHTON_OCR_INPUT_PATH")

    if not request_path or not output_path:
        sys.stderr.write("Missing LIGHTON_OCR_REQUEST_JSON or LIGHTON_OCR_OUTPUT_JSON\n")
        return 2

    request_payload = _read_json(Path(request_path))
    image_bytes = _load_image_bytes(request_payload, Path(input_path) if input_path else None)
    image = _load_image_pil(image_bytes)

    response = _run_ocr(image, request_payload)
    _write_json(Path(output_path), response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
