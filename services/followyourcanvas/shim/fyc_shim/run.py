import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional


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


def _now() -> int:
    return int(time.time())


def _load_request() -> Dict[str, Any]:
    req_path = _env("FYC_REQUEST_JSON")
    if not req_path:
        raise RuntimeError("FYC_REQUEST_JSON is not set")
    path = Path(req_path)
    return json.loads(path.read_text(encoding="utf-8"))


def _safe_relpath(p: str) -> str:
    p = p.strip().lstrip("/")
    if not p or p.startswith("..") or "/../" in p or "\\" in p:
        raise ValueError(f"unsafe path: {p!r}")
    return p


def _resolve_under_workdir(workdir: Path, rel: str) -> Path:
    rel = _safe_relpath(rel)
    full = (workdir / rel).resolve()
    workdir_resolved = workdir.resolve()
    if workdir_resolved not in full.parents and full != workdir_resolved:
        raise ValueError("path escapes workdir")
    return full


def _copy_dir(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def main() -> int:
    workdir = Path(_env("FYC_WORKDIR", "/var/lib/followyourcanvas/app") or "/var/lib/followyourcanvas/app")
    out_dir = Path(_env("FYC_OUTPUT_DIR") or "")
    if not out_dir:
        raise RuntimeError("FYC_OUTPUT_DIR is not set")

    req = _load_request()

    # If you don't specify a config in the request, you can pin one in the env.
    config_rel = req.get("config") or _env("FYC_DEFAULT_CONFIG")
    if not config_rel:
        print(
            json.dumps(
                {
                    "error": "missing_config",
                    "detail": "Provide request key 'config' (path relative to workdir) or set FYC_DEFAULT_CONFIG in the env.",
                }
            )
        )
        return 2

    mode = str(req.get("mode") or _env("FYC_MODE", "with_prompt") or "with_prompt")
    if mode not in {"with_prompt", "no_prompt"}:
        print(json.dumps({"error": "invalid_mode", "detail": "mode must be with_prompt|no_prompt"}))
        return 2

    script_rel = req.get("script")
    if script_rel:
        script_rel = str(script_rel)
    else:
        script_rel = "inference_outpainting-dir-with-prompt.py" if mode == "with_prompt" else "inference_outpainting-dir.py"

    extra_args: List[str] = []
    if isinstance(req.get("extra_args"), list):
        extra_args = [str(x) for x in req.get("extra_args")]

    python_bin = _env("FYC_PYTHON", "/var/lib/followyourcanvas/venv/bin/python") or "/var/lib/followyourcanvas/venv/bin/python"

    config_path = _resolve_under_workdir(workdir, str(config_rel))
    script_path = _resolve_under_workdir(workdir, str(script_rel))

    if not script_path.exists():
        print(json.dumps({"error": "script_not_found", "detail": str(script_path)}))
        return 2

    if not config_path.exists():
        print(json.dumps({"error": "config_not_found", "detail": str(config_path)}))
        return 2

    cmd = [python_bin, str(script_path), "--config", str(config_path)] + extra_args

    start = time.time()
    proc = subprocess.run(
        cmd,
        cwd=str(workdir),
        env=os.environ.copy(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    elapsed_ms = int((time.time() - start) * 1000)

    # Mirror upstream convention: inference scripts write to ./infer
    infer_dir = workdir / "infer"
    copied = []
    if infer_dir.exists() and infer_dir.is_dir():
        dst = out_dir / "infer"
        _copy_dir(infer_dir, dst)
        copied.append("infer/")

    # Always persist a small structured result.
    result = {
        "ok": proc.returncode == 0,
        "created": _now(),
        "elapsed_ms": elapsed_ms,
        "workdir": str(workdir),
        "script": str(script_rel),
        "config": str(config_rel),
        "command": [shlex.quote(x) for x in cmd],
        "copied": copied,
        "returncode": proc.returncode,
    }

    (out_dir / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    (out_dir / "stdout.txt").write_text(proc.stdout or "", encoding="utf-8")
    (out_dir / "stderr.txt").write_text(proc.stderr or "", encoding="utf-8")

    if proc.returncode != 0:
        # Print a short hint to stdout as well (captured by shim logs).
        print(json.dumps({"error": "inference_failed", "returncode": proc.returncode}))
        return proc.returncode

    print(json.dumps({"ok": True, "elapsed_ms": elapsed_ms}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
