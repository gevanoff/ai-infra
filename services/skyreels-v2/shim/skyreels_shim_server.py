import asyncio
import json
import os
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Optional

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse


app = FastAPI(title="SkyReels-V2 Shim", version="0.1")


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


def _bool_env(name: str, default: bool = False) -> bool:
    raw = _env(name)
    if raw is None:
        return default
    return raw.lower() in {"1", "true", "yes", "y", "on"}


def _now() -> int:
    return int(time.time())


def _default_out_dir() -> str:
    return "/var/lib/skyreels-v2/out"


def _upstream_base_url() -> Optional[str]:
    url = _env("SKYREELS_UPSTREAM_BASE_URL")
    if not url:
        return None
    return url.rstrip("/")


def _run_command() -> Optional[str]:
    cmd = _env("SKYREELS_RUN_COMMAND")
    return cmd


def _workdir() -> str:
    return _env("SKYREELS_WORKDIR", "/var/lib/skyreels-v2/app") or "/var/lib/skyreels-v2/app"


def _timeout_sec() -> int:
    return _int_env("SKYREELS_TIMEOUT_SEC", 3600)


def _max_concurrency() -> int:
    return max(1, _int_env("SKYREELS_MAX_CONCURRENCY", 1))


def _list_files(root: Path) -> list[str]:
    files: list[str] = []
    if not root.exists():
        return files
    for p in root.rglob("*"):
        if p.is_file():
            files.append(str(p.relative_to(root)))
    files.sort()
    return files


_semaphore = asyncio.Semaphore(_max_concurrency())


@app.get("/healthz")
def healthz() -> Dict[str, Any]:
    return {"ok": True, "time": _now(), "service": "skyreels-v2-shim"}


@app.get("/readyz")
def readyz() -> JSONResponse:
    upstream = _upstream_base_url()
    cmd = _run_command()

    if not upstream and not cmd:
        return JSONResponse(
            status_code=503,
            content={
                "ok": False,
                "reason": "missing_configuration",
                "detail": "Set SKYREELS_UPSTREAM_BASE_URL to proxy an existing server, or set SKYREELS_RUN_COMMAND to run generation via subprocess.",
            },
        )

    return JSONResponse(status_code=200, content={"ok": True})


@app.post("/v1/videos/generations")
async def generate_videos(payload: Dict[str, Any]) -> Any:
    upstream = _upstream_base_url()

    if upstream:
        timeout = httpx.Timeout(connect=10.0, read=float(_timeout_sec()), write=10.0, pool=10.0)
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(f"{upstream}/v1/videos/generations", json=payload)
            try:
                data = resp.json()
            except Exception:
                data = {"raw": resp.text}
            if resp.status_code >= 400:
                raise HTTPException(status_code=resp.status_code, detail=data)
            return data

    cmd = _run_command()
    if not cmd:
        raise HTTPException(
            status_code=501,
            detail="SKYREELS_UPSTREAM_BASE_URL not set and SKYREELS_RUN_COMMAND not set; shim cannot generate.",
        )

    out_root = Path(_env("SKYREELS_OUT_DIR", _default_out_dir()) or _default_out_dir())
    job_id = f"skyreels_{uuid.uuid4().hex}"
    job_dir = out_root / job_id
    job_dir.mkdir(parents=True, exist_ok=True)

    request_json_path = job_dir / "request.json"
    request_json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    stdout_path = job_dir / "stdout.log"
    stderr_path = job_dir / "stderr.log"

    env = os.environ.copy()
    env["SKYREELS_JOB_ID"] = job_id
    env["SKYREELS_REQUEST_JSON"] = str(request_json_path)
    env["SKYREELS_OUTPUT_DIR"] = str(job_dir)

    start = time.time()

    async with _semaphore:
        stdout_f = stdout_path.open("wb")
        stderr_f = stderr_path.open("wb")
        try:
            proc = await asyncio.create_subprocess_exec(
                "/bin/bash",
                "-lc",
                cmd,
                cwd=_workdir(),
                env=env,
                stdout=stdout_f,
                stderr=stderr_f,
            )
        finally:
            try:
                stdout_f.flush()
            except Exception:
                pass
            try:
                stderr_f.flush()
            except Exception:
                pass
            stdout_f.close()
            stderr_f.close()

        try:
            await asyncio.wait_for(proc.wait(), timeout=float(_timeout_sec()))
        except TimeoutError:
            try:
                proc.terminate()
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(proc.wait(), timeout=10.0)
            except TimeoutError:
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass
                try:
                    await asyncio.wait_for(proc.wait(), timeout=10.0)
                except TimeoutError:
                    pass

            raise HTTPException(
                status_code=504,
                detail={
                    "error": "skyreels-v2 subprocess timed out",
                    "job_id": job_id,
                    "timeout_sec": _timeout_sec(),
                    "stdout": str(stdout_path),
                    "stderr": str(stderr_path),
                },
            )

        if proc.returncode != 0:
            raise HTTPException(
                status_code=502,
                detail={
                    "error": "skyreels-v2 subprocess failed",
                    "returncode": proc.returncode,
                    "job_id": job_id,
                    "stdout": str(stdout_path),
                    "stderr": str(stderr_path),
                },
            )

    elapsed_ms = int((time.time() - start) * 1000)

    return {
        "id": job_id,
        "object": "video.generation",
        "created": _now(),
        "status": "succeeded",
        "output_dir": str(job_dir),
        "files": _list_files(job_dir),
        "_shim": {
            "mode": "subprocess",
            "elapsed_ms": elapsed_ms,
            "workdir": _workdir(),
            "command": cmd if _bool_env("SKYREELS_INCLUDE_COMMAND_IN_RESPONSE", False) else "<redacted>",
        },
    }
