import base64
import io
import os
import time
from typing import Any, Dict, Optional

import torch
from diffusers import AutoPipelineForText2Image
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


app = FastAPI(title="SDXL Turbo Shim", version="0.1")

_PIPELINE = None
_PIPELINE_DEVICE = None
_PIPELINE_MODEL_ID = None


class GenerateRequest(BaseModel):
    prompt: str = Field(..., description="Text prompt for SDXL Turbo")
    negative_prompt: Optional[str] = Field(None, description="Optional negative prompt")
    num_inference_steps: Optional[int] = Field(None, ge=1, le=8)
    guidance_scale: Optional[float] = Field(None, ge=0.0)
    width: Optional[int] = Field(None, ge=64, le=2048)
    height: Optional[int] = Field(None, ge=64, le=2048)
    seed: Optional[int] = Field(None, ge=0)


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


def _float_env(name: str, default: float) -> float:
    raw = _env(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _bool_env(name: str, default: bool = False) -> bool:
    raw = _env(name)
    if raw is None:
        return default
    return raw.lower() in {"1", "true", "yes", "on"}


def _now() -> int:
    return int(time.time())


def _resolve_device() -> str:
    configured = (_env("SDXL_TURBO_DEVICE", "auto") or "auto").lower()
    if configured == "auto":
        return "cuda" if torch.cuda.is_available() else "cpu"
    if configured == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("SDXL_TURBO_DEVICE=cuda but no CUDA device is available.")
    return configured


def _resolve_dtype(device: str) -> torch.dtype:
    configured = (_env("SDXL_TURBO_DTYPE", "auto") or "auto").lower()
    if configured in {"auto", ""}:
        return torch.float16 if device == "cuda" else torch.float32
    if configured in {"fp16", "float16"}:
        return torch.float16
    if configured in {"bf16", "bfloat16"}:
        return torch.bfloat16
    return torch.float32


def _default_steps() -> int:
    return _int_env("SDXL_TURBO_NUM_INFERENCE_STEPS", 1)


def _default_guidance() -> float:
    return _float_env("SDXL_TURBO_GUIDANCE_SCALE", 0.0)


def _default_width() -> int:
    return _int_env("SDXL_TURBO_WIDTH", 512)


def _default_height() -> int:
    return _int_env("SDXL_TURBO_HEIGHT", 512)


def _default_seed() -> Optional[int]:
    seed = _int_env("SDXL_TURBO_SEED", -1)
    return None if seed < 0 else seed


def _ensure_pipeline() -> AutoPipelineForText2Image:
    global _PIPELINE, _PIPELINE_DEVICE, _PIPELINE_MODEL_ID
    if _PIPELINE is not None:
        return _PIPELINE

    model_id = _env("SDXL_TURBO_MODEL_ID", "stabilityai/sdxl-turbo")
    cache_dir = _env("SDXL_TURBO_CACHE_DIR")
    variant = _env("SDXL_TURBO_VARIANT", "fp16")

    device = _resolve_device()
    dtype = _resolve_dtype(device)

    kwargs: Dict[str, Any] = {"torch_dtype": dtype}
    if cache_dir:
        kwargs["cache_dir"] = cache_dir
    if variant:
        kwargs["variant"] = variant

    pipeline = AutoPipelineForText2Image.from_pretrained(model_id, **kwargs)
    pipeline.to(device)
    pipeline.set_progress_bar_config(disable=True)

    if _bool_env("SDXL_TURBO_ENABLE_ATTENTION_SLICING", False):
        pipeline.enable_attention_slicing()
    if _bool_env("SDXL_TURBO_ENABLE_XFORMERS", False):
        pipeline.enable_xformers_memory_efficient_attention()

    _PIPELINE = pipeline
    _PIPELINE_DEVICE = device
    _PIPELINE_MODEL_ID = model_id
    return pipeline


@app.get("/health")
def health() -> Dict[str, Any]:
    return {"ok": True, "time": _now(), "service": "sdxl-turbo-shim"}


@app.get("/readyz")
def readyz() -> Dict[str, Any]:
    try:
        _ensure_pipeline()
    except Exception as exc:
        raise HTTPException(status_code=503, detail=str(exc))
    return {"ok": True, "time": _now()}


@app.get("/v1/models")
def models() -> Dict[str, Any]:
    model_id = _env("SDXL_TURBO_MODEL_ID", "stabilityai/sdxl-turbo")
    return {
        "object": "list",
        "data": [
            {
                "id": model_id,
                "object": "model",
                "owned_by": "stabilityai",
            }
        ],
    }


@app.post("/v1/generate")
def generate(payload: GenerateRequest) -> Dict[str, Any]:
    pipeline = _ensure_pipeline()
    device = _PIPELINE_DEVICE or "cpu"

    seed = payload.seed if payload.seed is not None else _default_seed()
    generator = None
    if seed is not None:
        generator = torch.Generator(device=device).manual_seed(seed)

    result = pipeline(
        prompt=payload.prompt,
        negative_prompt=payload.negative_prompt,
        num_inference_steps=payload.num_inference_steps or _default_steps(),
        guidance_scale=payload.guidance_scale if payload.guidance_scale is not None else _default_guidance(),
        width=payload.width or _default_width(),
        height=payload.height or _default_height(),
        generator=generator,
    )

    image = result.images[0]
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    encoded = base64.b64encode(buffer.getvalue()).decode("utf-8")

    return {
        "created": _now(),
        "model": _PIPELINE_MODEL_ID,
        "data": [{"b64_json": encoded}],
        "seed": seed,
    }
