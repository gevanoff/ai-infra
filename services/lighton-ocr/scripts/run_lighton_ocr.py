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
        url_str = str(image_url).strip()
        # Guard against common copy/paste placeholders like "https://…png".
        # urllib/http.client requires Latin-1 encodable host/header values.
        if "…" in url_str or "\u2026" in url_str:
            raise ValueError("image_url contains an ellipsis (…). Provide a full URL.")
        try:
            url_str.encode("ascii")
        except UnicodeEncodeError:
            raise ValueError("image_url must be ASCII. Provide a fully-qualified URL without unicode characters.")
        req = urllib.request.Request(
            url_str,
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


def _select_device_from_request(request_payload: Dict[str, Any]) -> str:
    raw = request_payload.get("device")
    if isinstance(raw, str):
        value = raw.strip().lower()
        if value in {"auto", "cpu", "cuda", "mps"}:
            return value
    return _select_device()


def _resolve_device(request_payload: Optional[Dict[str, Any]] = None) -> str:
    device = _select_device_from_request(request_payload or {})
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


def _pipeline_device_arg(device: str) -> Any:
    # transformers.pipeline accepts -1 for CPU, int device id for CUDA, or strings/torch.device.
    if device == "cpu":
        return -1
    if device == "cuda":
        return 0
    if device == "mps":
        return "mps"
    return -1


def _bool_env(name: str, default: bool = False) -> bool:
    raw = _env(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "y", "on"}


def _supported_pipeline_tasks() -> list[str]:
    try:
        from transformers.pipelines import PIPELINE_REGISTRY

        return sorted(list(PIPELINE_REGISTRY.get_supported_tasks()))
    except Exception:
        return []


def _pick_task(request_payload: Dict[str, Any]) -> list[str]:
    # Allow explicit override per-request.
    raw = request_payload.get("task") or request_payload.get("operation")
    if isinstance(raw, str) and raw.strip():
        value = raw.strip()
        if value.lower() == "auto":
            return ["image-text-to-text", "image-to-text"]
        return [value]

    env_task = (_env("LIGHTON_OCR_TASK") or "").strip()
    if env_task:
        if env_task.lower() == "auto":
            return ["image-text-to-text", "image-to-text"]
        return [env_task]

    # Transformers v5 removed/renamed several tasks; for OCR the modern choice is
    # "image-text-to-text" (image + optional prompt -> text). We keep a fallback for
    # older Transformers versions.
    return ["image-text-to-text", "image-to-text"]


def _run_ocr(image, request_payload: Dict[str, Any]) -> Dict[str, Any]:
    model_id = _env("LIGHTON_OCR_MODEL_ID", "lightonai/LightOnOCR-2-1B")
    max_tokens = _int_env("LIGHTON_OCR_MAX_TOKENS", 256)
    device = _resolve_device(request_payload)

    try:
        from transformers import pipeline
    except Exception as exc:
        raise RuntimeError(f"transformers is required for OCR: {exc}")

    if request_payload.get("list_tasks") is True:
        return {
            "tasks": _supported_pipeline_tasks(),
            "model": model_id,
        }

    if image is None:
        raise ValueError("No image input provided")

    # LightOnOCR checkpoints may use a custom Transformers architecture (e.g. model_type=mistral3).
    # Enabling trust_remote_code allows Transformers to load custom config/model code specified by the repo.
    trust_remote_code = _bool_env("LIGHTON_OCR_TRUST_REMOTE_CODE", default=str(model_id).startswith("lightonai/"))

    last_exc: Optional[BaseException] = None
    pipe = None
    selected_task: Optional[str] = None
    task_candidates = _pick_task(request_payload)
    for task in task_candidates:
        try:
            pipe = pipeline(
                task,
                model=model_id,
                trust_remote_code=trust_remote_code,
                device=_pipeline_device_arg(device),
            )
            selected_task = task
            break
        except KeyError as exc:
            # Unknown task name for this Transformers version.
            last_exc = exc
            continue
        except Exception as exc:
            # If CUDA is present but memory is exhausted (often due to other processes),
            # retry on CPU to keep the service functional.
            msg = f"{type(exc).__name__}: {exc}"
            if device != "cpu" and ("out of memory" in msg.lower() or "cuda" in msg.lower() and "memory" in msg.lower()):
                try:
                    sys.stderr.write("LightOnOCR: CUDA/MPS memory issue; retrying pipeline on CPU\n")
                except Exception:
                    pass
                device = "cpu"
                try:
                    pipe = pipeline(
                        task,
                        model=model_id,
                        trust_remote_code=trust_remote_code,
                        device=_pipeline_device_arg(device),
                    )
                    selected_task = task
                    break
                except Exception as exc2:
                    last_exc = exc2
                    continue
            last_exc = exc
            continue

    if pipe is None:
        tasks = _supported_pipeline_tasks()
        hint = f"; supported tasks: {tasks}" if tasks else ""
        raise RuntimeError(f"No usable pipeline task found (tried {task_candidates}): {last_exc}{hint}")
    # Allow callers to pass arbitrary pipeline inputs/params.
    inputs: Any
    if "inputs" in request_payload:
        inputs = request_payload.get("inputs")
    else:
        prompt = request_payload.get("prompt") or request_payload.get("text")
        prompt_str = prompt.strip() if isinstance(prompt, str) else ""

        # For Transformers v5 "image-text-to-text", text is required.
        if (selected_task or "").strip().lower() == "image-text-to-text" and not prompt_str:
            prompt_str = (_env("LIGHTON_OCR_DEFAULT_PROMPT") or "Read the text in this image.").strip()

        if prompt_str:
            inputs = {"image": image, "text": prompt_str}
        else:
            inputs = image

    params: Dict[str, Any] = {}
    if isinstance(request_payload.get("parameters"), dict):
        params.update(request_payload["parameters"])  # type: ignore[index]
    params.setdefault("max_new_tokens", max_tokens)

    result = pipe(inputs, **params)
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

    # Support a lightweight "capabilities" call without requiring image input.
    if request_payload.get("list_tasks") is True:
        response = _run_ocr(image=None, request_payload=request_payload)  # type: ignore[arg-type]
        _write_json(Path(output_path), response)
        return 0

    image_bytes = _load_image_bytes(request_payload, Path(input_path) if input_path else None)
    image = _load_image_pil(image_bytes)

    response = _run_ocr(image, request_payload)
    _write_json(Path(output_path), response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
