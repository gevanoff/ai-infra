#!/usr/bin/env python3
import os
import subprocess
import sys
from pathlib import Path


def _env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    return value


def _fail(message: str, code: int = 2) -> None:
    print(message, file=sys.stderr)
    sys.exit(code)


def main() -> None:
    request_json = _env("LUXTTS_REQUEST_JSON")
    output_path = _env("LUXTTS_OUTPUT_PATH")
    run_command = _env("LUXTTS_INFER_COMMAND")

    if not request_json:
        _fail("LUXTTS_REQUEST_JSON is not set")
    if not output_path:
        _fail("LUXTTS_OUTPUT_PATH is not set")
    if not run_command:
        _fail("LUXTTS_INFER_COMMAND is not set")

    request_path = Path(request_json)
    if not request_path.exists():
        _fail(f"LUXTTS_REQUEST_JSON does not exist: {request_path}")

    env = os.environ.copy()
    proc = subprocess.run(
        ["/bin/bash", "-lc", run_command],
        env=env,
        cwd=env.get("LUXTTS_WORKDIR", None),
    )
    if proc.returncode != 0:
        _fail(f"LUXTTS_INFER_COMMAND failed with exit code {proc.returncode}", proc.returncode)

    out_path = Path(output_path)
    if not out_path.exists():
        _fail(f"LUXTTS_OUTPUT_PATH not written: {out_path}")
    if out_path.stat().st_size == 0:
        _fail(f"LUXTTS_OUTPUT_PATH is empty: {out_path}")


if __name__ == "__main__":
    main()
