#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional


def _env(name: str, default: str = "") -> str:
    value = os.environ.get(name)
    if value is None:
        return default
    value = value.strip()
    return value if value else default


def _bool(v: Any) -> bool:
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v != 0
    if isinstance(v, str):
        return v.strip().lower() in {"1", "true", "yes", "y", "on"}
    return False


def _as_int(v: Any) -> Optional[int]:
    try:
        return int(v)
    except Exception:
        return None


def _as_float(v: Any) -> Optional[float]:
    try:
        return float(v)
    except Exception:
        return None


def _download_to_tmp(url: str, suffix: str) -> Path:
    import urllib.request

    tmpdir = Path(tempfile.mkdtemp(prefix="skyreels-download-"))
    dst = tmpdir / f"input{suffix}"
    with urllib.request.urlopen(url) as resp:
        dst.write_bytes(resp.read())
    return dst


def _resolve_media_path(value: str, suffix: str) -> str:
    if value.startswith("http://") or value.startswith("https://"):
        return str(_download_to_tmp(value, suffix))
    return value


def _infer_mode(payload: Dict[str, Any]) -> str:
    mode = str(payload.get("mode") or "").strip().lower()
    if mode in {"df", "diffusion_forcing", "diffusion-forcing"}:
        return "df"
    if any(k in payload for k in ("base_num_frames", "ar_step", "overlap_history", "addnoise_condition")):
        return "df"
    return "standard"


def _build_args(payload: Dict[str, Any], outdir: Path) -> List[str]:
    mode = _infer_mode(payload)
    workdir = _env("SKYREELS_WORKDIR", "/var/lib/skyreels-v2/app")
    script = "generate_video_df.py" if mode == "df" else "generate_video.py"
    script_path = Path(workdir) / script
    if not script_path.exists():
        raise RuntimeError(f"Missing SkyReels script: {script_path}")

    # Use the same interpreter running this wrapper (typically the service venv).
    # Hardcoding "python3" can accidentally use system Python and miss venv deps.
    args: List[str] = [sys.executable, str(script_path)]

    def add_flag(flag: str, value: Any) -> None:
        if value is None or value == "":
            return
        args.extend([flag, str(value)])

    # Shared required fields
    add_flag("--model_id", payload.get("model_id"))
    add_flag("--resolution", payload.get("resolution"))
    add_flag("--prompt", payload.get("prompt"))

    # Media inputs
    image = payload.get("image") or payload.get("image_path") or payload.get("start_image")
    if image:
        add_flag("--image", _resolve_media_path(str(image), ".png"))
    end_image = payload.get("end_image")
    if end_image:
        add_flag("--end_image", _resolve_media_path(str(end_image), ".png"))
    video_path = payload.get("video_path") or payload.get("video")
    if video_path:
        add_flag("--video_path", _resolve_media_path(str(video_path), ".mp4"))

    if mode == "df":
        add_flag("--ar_step", payload.get("ar_step"))
        add_flag("--base_num_frames", payload.get("base_num_frames"))
        add_flag("--num_frames", payload.get("num_frames"))
        add_flag("--overlap_history", payload.get("overlap_history"))
        add_flag("--addnoise_condition", payload.get("addnoise_condition"))
        if _as_int(payload.get("ar_step")) and _as_int(payload.get("ar_step")) > 0:
            add_flag("--causal_block_size", payload.get("causal_block_size"))
    else:
        add_flag("--num_frames", payload.get("num_frames"))
        add_flag("--guidance_scale", payload.get("guidance_scale"))
        add_flag("--shift", payload.get("shift"))
        add_flag("--fps", payload.get("fps"))
        add_flag("--seed", payload.get("seed"))
        add_flag("--outdir", str(outdir))

    # Optional flags
    if _bool(payload.get("offload")):
        args.append("--offload")
    if _bool(payload.get("teacache")):
        args.append("--teacache")
    if _bool(payload.get("use_ret_steps")):
        args.append("--use_ret_steps")
    teacache_thresh = _as_float(payload.get("teacache_thresh"))
    if teacache_thresh is not None:
        add_flag("--teacache_thresh", teacache_thresh)

    return args


def _collect_outputs(outdir: Path, workdir: Path) -> None:
    if any(outdir.glob("*.mp4")) or any(outdir.glob("*.webm")):
        return
    # Fallback: copy latest video from workdir
    candidates = list(workdir.rglob("*.mp4")) + list(workdir.rglob("*.webm"))
    if not candidates:
        return
    latest = max(candidates, key=lambda p: p.stat().st_mtime)
    shutil.copy2(latest, outdir / latest.name)


def main() -> int:
    request_json = _env("SKYREELS_REQUEST_JSON")
    output_dir = _env("SKYREELS_OUTPUT_DIR", "/var/lib/skyreels-v2/out")
    if not request_json:
        raise RuntimeError("SKYREELS_REQUEST_JSON not set")
    payload: Dict[str, Any] = json.loads(Path(request_json).read_text(encoding="utf-8"))

    outdir = Path(output_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    workdir = Path(_env("SKYREELS_WORKDIR", "/var/lib/skyreels-v2/app"))

    args = _build_args(payload, outdir)
    proc = subprocess.run(args, cwd=str(workdir))
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)

    _collect_outputs(outdir, workdir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())