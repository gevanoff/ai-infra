import asyncio
import json
import os
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Optional

import httpx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse


app = FastAPI(title="VibeVoice-ASR Shim", version="0.1")


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


def _upstream_base_url() -> Optional[str]:
    url = _env("VIBEVOICE_ASR_UPSTREAM_BASE_URL")
    if not url:
        return None
    return url.rstrip("/")


def _upstream_endpoint() -> str:
    return _env("VIBEVOICE_ASR_UPSTREAM_ENDPOINT", "/v1/audio/transcriptions") or "/v1/audio/transcriptions"


def _run_command() -> Optional[str]:
    cmd = _env("VIBEVOICE_ASR_RUN_COMMAND")
    return cmd


def _timeout_sec() -> int:
    return _int_env("VIBEVOICE_ASR_TIMEOUT_SEC", 120)


def _workdir() -> str:
    return _env("VIBEVOICE_ASR_WORKDIR", "/var/lib/vibevoice-asr/app") or "/var/lib/vibevoice-asr/app"


def _model_id() -> str:
    return _env("VIBEVOICE_ASR_MODEL", "vibevoice-asr") or "vibevoice-asr"


@app.get("/health")
def health() -> Dict[str, Any]:
    return {"ok": True, "time": _now(), "service": "vibevoice-asr-shim"}


@app.get("/v1/models")
def models() -> Dict[str, Any]:
    return {
        "object": "list",
        "data": [
            {
                "id": _model_id(),
                "object": "model",
                "owned_by": "microsoft",
            }
        ],
    }


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: Optional[str] = Form(default=None),
    language: Optional[str] = Form(default=None),
    prompt: Optional[str] = Form(default=None),
    response_format: Optional[str] = Form(default=None),
    temperature: Optional[float] = Form(default=None),
) -> Any:
    upstream = _upstream_base_url()
    if upstream:
        timeout = httpx.Timeout(connect=10.0, read=float(_timeout_sec()), write=10.0, pool=10.0)
        async with httpx.AsyncClient(timeout=timeout) as client:
            data = {
                "model": model or _model_id(),
            }
            if language:
                data["language"] = language
            if prompt:
                data["prompt"] = prompt
            if response_format:
                data["response_format"] = response_format
            if temperature is not None:
                data["temperature"] = str(temperature)

            files = {"file": (file.filename, await file.read(), file.content_type or "application/octet-stream")}
            resp = await client.post(f"{upstream}{_upstream_endpoint()}", data=data, files=files)
            if resp.status_code >= 400:
                raise HTTPException(status_code=resp.status_code, detail=resp.text)
            
            # Handle non-JSON response formats (text, srt, vtt)
            # OpenAI Whisper API returns plain text for these formats
            if response_format == "text":
                return PlainTextResponse(content=resp.text, media_type="text/plain")
            elif response_format == "srt":
                return PlainTextResponse(content=resp.text, media_type="application/x-subrip")
            elif response_format == "vtt":
                return PlainTextResponse(content=resp.text, media_type="text/vtt")
            
            # Default to JSON for json, verbose_json, or unspecified format
            return resp.json()

    cmd = _run_command()
    if not cmd:
        raise HTTPException(
            status_code=501,
            detail="VIBEVOICE_ASR_UPSTREAM_BASE_URL not set and VIBEVOICE_ASR_RUN_COMMAND not set; shim cannot transcribe.",
        )

    job_id = f"vibevoice_{uuid.uuid4().hex}"
    with tempfile.TemporaryDirectory(prefix="vibevoice-asr-") as tmpdir:
        workdir = Path(tmpdir)
        input_path = workdir / (file.filename or "audio")
        input_path.write_bytes(await file.read())
        output_json_path = workdir / "output.json"

        request_json_path = workdir / "request.json"
        request_payload = {
            "model": model or _model_id(),
            "language": language,
            "prompt": prompt,
            "response_format": response_format,
            "temperature": temperature,
        }
        request_json_path.write_text(json.dumps(request_payload, ensure_ascii=False, indent=2), encoding="utf-8")

        env = os.environ.copy()
        env["VIBEVOICE_ASR_JOB_ID"] = job_id
        env["VIBEVOICE_ASR_INPUT_PATH"] = str(input_path)
        env["VIBEVOICE_ASR_REQUEST_JSON"] = str(request_json_path)
        env["VIBEVOICE_ASR_OUTPUT_JSON"] = str(output_json_path)

        proc = await asyncio.create_subprocess_exec(
            "/bin/bash",
            "-lc",
            cmd,
            cwd=_workdir(),
            env=env,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout_bytes, stderr_bytes = await asyncio.wait_for(proc.communicate(), timeout=float(_timeout_sec()))
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
            raise HTTPException(
                status_code=504,
                detail={
                    "error": "vibevoice-asr subprocess timed out",
                    "job_id": job_id,
                    "timeout_sec": _timeout_sec(),
                },
            )

        if proc.returncode != 0:
            raise HTTPException(
                status_code=502,
                detail={
                    "error": "vibevoice-asr subprocess failed",
                    "returncode": proc.returncode,
                    "stdout": (stdout_bytes or b"").decode(errors="ignore")[-4000:],
                    "stderr": (stderr_bytes or b"").decode(errors="ignore")[-4000:],
                },
            )

        if not output_json_path.exists():
            raise HTTPException(status_code=502, detail="VIBEVOICE_ASR_OUTPUT_JSON not written by subprocess.")

        return json.loads(output_json_path.read_text(encoding="utf-8"))


@app.get("/readyz")
def readyz() -> JSONResponse:
    if _upstream_base_url() or _run_command():
        return JSONResponse(status_code=200, content={"ok": True})
    return JSONResponse(
        status_code=503,
        content={
            "ok": False,
            "reason": "missing_configuration",
            "detail": "Set VIBEVOICE_ASR_UPSTREAM_BASE_URL or VIBEVOICE_ASR_RUN_COMMAND.",
        },
    )
