#!/usr/bin/env python3
"""
HeartMula FastAPI shim - provides HTTP API for HeartMula music generation
"""
import os
import tempfile
import uuid
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
import uvicorn
import torch
import logging

# Configure logging to suppress torchtune warnings
logging.getLogger("torchtune.modules.attention").setLevel(logging.ERROR)

# Optional triton check (triton is an optional acceleration library; absence is expected on CPU-only systems)
try:
    import triton  # type: ignore
    _triton_available = True
except Exception:
    _triton_available = False
    print("Optional dependency 'triton' not found. This is expected on CPU-only systems. HeartMuLa may still work but with reduced performance. To use triton, install it on a supported Linux/CUDA environment.")

# Import HeartMula after environment setup
try:
    from heartlib import HeartMuLaGenPipeline
except ImportError as e:
    print(f"Error importing HeartMula: {e}")
    print("Make sure HeartMula is installed: pip install -e .")
    exit(1)

app = FastAPI(title="HeartMula Music Generation API")

class MusicGenerationRequest(BaseModel):
    prompt: Optional[str] = None  # For backward compatibility
    lyrics: Optional[str] = None
    style: Optional[str] = None  # Style description for tags
    duration: Optional[int] = 30  # seconds
    temperature: Optional[float] = 1.0
    top_k: Optional[int] = 50
    top_p: Optional[float] = None
    tags: Optional[str] = "electronic,ambient"

class MusicGenerationResponse(BaseModel):
    id: str
    status: str
    audio_url: str
    duration: int
    prompt: str

# Global pipeline instance
pipeline: Optional[HeartMuLaGenPipeline] = None
pipeline_device: Optional[str] = None
pipeline_dtype: Optional[str] = None


def align_tensors_to_device(obj, device: torch.device, target_dtype: Optional[torch.dtype] = None):
    """Recursively move tensors in nested dict/list structures to `device` and cast
    floating-point tensors to `target_dtype` if provided.

    This is a module-level helper to allow unit testing of device/dtype alignment.
    """
    if isinstance(obj, torch.Tensor):
        t = obj.to(device)
        if target_dtype is not None and t.is_floating_point():
            try:
                t = t.to(target_dtype)
            except Exception:
                pass
        return t
    if isinstance(obj, dict):
        return {k: align_tensors_to_device(v, device, target_dtype) for k, v in obj.items()}
    if isinstance(obj, list):
        return [align_tensors_to_device(v, device, target_dtype) for v in obj]
    return obj


def get_model_path() -> str:
    """Get the model path from environment or default"""
    return os.environ.get("HEARTMULA_MODEL_PATH", "./ckpt")

def get_output_dir() -> Path:
    """Get output directory for generated audio"""
    output_dir = Path(os.environ.get("HEARTMULA_OUTPUT_DIR", "/tmp/heartmula_output"))
    output_dir.mkdir(exist_ok=True, parents=True)
    return output_dir

def load_heartmula_pipeline():
    """Load the HeartMula pipeline with current config"""
    global pipeline, pipeline_device, pipeline_dtype
    try:
        model_path = get_model_path()
        version = os.environ.get("HEARTMULA_VERSION", "3B")
        dtype_env = os.environ.get("HEARTMULA_DTYPE", "float32")

        # Device selection: allow override with HEARTMULA_DEVICE; default to CUDA if available, otherwise CPU.
        dev_override = os.environ.get("HEARTMULA_DEVICE", "").strip().lower()
        device = None
        if dev_override:
            if dev_override == "cpu":
                device = torch.device("cpu")
            elif dev_override == "cuda":
                if torch.cuda.is_available():
                    device = torch.device("cuda")
                else:
                    print("WARN: HEARTMULA_DEVICE=cuda requested but no CUDA available; falling back to CPU")
                    device = torch.device("cpu")
            else:
                print(f"WARN: unknown HEARTMULA_DEVICE='{dev_override}'; falling back to auto-detect")
        if device is None:
            if torch.cuda.is_available():
                device = torch.device("cuda")
            else:
                device = torch.device("cpu")

        # dtype: use fp16 only on CUDA devices when requested
        if device.type == "cuda" and dtype_env in ("float16", "fp16"):
            dtype = torch.float16
        else:
            dtype = torch.float32

        print(f"Loading HeartMuLa model from: {model_path} (version={version}, device={device}, dtype={dtype})")

        # Check for lazy loading
        lazy = os.environ.get("HEARTMULA_LAZY_LOAD", "false").lower() in ("true", "1", "yes")

        # Use from_pretrained classmethod to load checkpoints from a directory
        pipeline = HeartMuLaGenPipeline.from_pretrained(
            model_path,
            device=device,
            dtype=dtype,
            version=version,
        )  # store detected device/dtype for logging in handlers
        pipeline_device = str(device)
        pipeline_dtype = str(dtype)

        # Enable lazy loading if requested
        if lazy:
            pipeline.lazy_load = True
            print("Enabled lazy loading for HeartMula pipeline")

        print("HeartMula pipeline initialized successfully")
        return True
    except Exception as e:
        print(f"Failed to initialize HeartMula pipeline: {e}")
        return False

@app.on_event("startup")
async def startup_event():
    """Initialize HeartMula pipeline on startup"""
    if not load_heartmula_pipeline():
        raise RuntimeError("Failed to load HeartMula pipeline on startup")

@app.post("/v1/music/generations", response_model=MusicGenerationResponse)
async def generate_music(request: MusicGenerationRequest):
    global pipeline
    """Generate music using HeartMula"""
    if pipeline is None:
        raise HTTPException(status_code=503, detail="HeartMula pipeline not initialized")

    try:
        # Generate unique ID for this request
        generation_id = str(uuid.uuid4())

        # Prepare lyrics and tags
        lyrics = request.lyrics or ""
        tags = request.tags or "electronic,ambient"
        # Note: style conditioning may not be supported by HeartMula, tags are used for genre but may be ignored

        if request.style and not lyrics:
            # If style provided but no lyrics, use style as lyrics for better conditioning
            lyrics = request.style

        # Backward compatibility: if no lyrics but prompt provided, use heuristic
        if not lyrics and request.prompt:
            prompt = request.prompt.strip()
            if "\n" in prompt or len(prompt.split()) > 20:  # heuristic: if multiline or long, treat as lyrics
                lyrics = prompt
            else:  # treat as style description, use for tags
                tags = f"{prompt},{tags}"

        # Convert duration to milliseconds, limit for lyrics to save memory
        requested_duration = request.duration or 30
        # Removed duration limit with lyrics - use lazy_load or monitor memory instead
        max_audio_length_ms = requested_duration * 1000

        # Generate output path
        output_dir = get_output_dir()
        output_path = output_dir / f"{generation_id}.mp3"

        print(f"Generating music: {lyrics[:50]}... (duration: {request.duration}s)")
        print(f"Pipeline device={pipeline_device}, dtype={pipeline_dtype}")

        # Clear CUDA cache before generation to free memory
        if torch.cuda.is_available():
            torch.cuda.empty_cache()

        # Generate music using pipeline internals (preprocess -> forward -> postprocess)
        pre_kwargs, forward_kwargs, post_kwargs = pipeline._sanitize_parameters(
            cfg_scale=1.5,
            max_audio_length_ms=max_audio_length_ms,
            temperature=request.temperature,
            topk=request.top_k,
            save_path=str(output_path.with_suffix('.wav')),
        )

        # Write lyrics and tags to temp files as expected by preprocess
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as lyrics_file:
            lyrics_file.write(lyrics)
            lyrics_path = lyrics_file.name
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as tags_file:
            tags_file.write(tags)
            tags_path = tags_file.name

        try:
            model_inputs = pipeline.preprocess({"lyrics": lyrics_path, "tags": tags_path}, **pre_kwargs)
        finally:
            # Clean up temp files
            os.unlink(lyrics_path)
            os.unlink(tags_path)

        # Align tensors to the model device/dtype to avoid device mismatch errors.
        device = torch.device(pipeline_device or ("cuda" if torch.cuda.is_available() else "cpu"))
        target_dtype = None
        if pipeline_dtype and "float16" in pipeline_dtype:
            target_dtype = torch.float16
        elif pipeline_dtype and "float32" in pipeline_dtype:
            target_dtype = torch.float32

        # Optional debug printing of devices (enable with HEARTMULA_DEBUG=1)
        if os.environ.get("HEARTMULA_DEBUG", "") == "1":
            print("model_inputs devices BEFORE move:")
            def dbg(o, prefix=""):
                if isinstance(o, torch.Tensor):
                    print(prefix, type(o), o.device, o.dtype, o.shape)
                elif isinstance(o, dict):
                    for k,v in o.items(): dbg(v, prefix+f"{k}.")
                elif isinstance(o, list):
                    for i,v in enumerate(o): dbg(v, prefix+f"[{i}].")
            dbg(model_inputs)

        model_inputs = align_tensors_to_device(model_inputs, device, target_dtype)

        if os.environ.get("HEARTMULA_DEBUG", "") == "1":
            print("model_inputs devices AFTER move:")
            dbg(model_inputs)

        model_outputs = pipeline._forward(model_inputs, **forward_kwargs)
        # Postprocess will write the file at save_path
        pipeline.postprocess(model_outputs, save_path=str(output_path.with_suffix('.wav')))

        # Aggressive memory cleanup
        del model_inputs
        del model_outputs
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        import gc
        gc.collect()

        # Reload pipeline to free any remaining memory
        print("Reloading HeartMula pipeline to free memory...")
        del pipeline
        pipeline = None
        gc.collect()
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        load_heartmula_pipeline()

        # Confirm file exists
        wav_path = output_path.with_suffix('.wav')
        if not wav_path.exists():
            raise RuntimeError("Generation did not produce output file")

        # For now, return the WAV file
        # You could add MP3 conversion here if desired
        final_path = wav_path

        # Create response
        effective_prompt = request.style or request.lyrics or request.prompt or "instrumental"
        response = MusicGenerationResponse(
            id=generation_id,
            status="completed",
            audio_url=f"/audio/{generation_id}.wav",  # Serve via FastAPI
            duration=requested_duration,
            prompt=effective_prompt
        )

        print(f"Music generated successfully: {generation_id}")
        return response

    except Exception as e:
        print(f"Error generating music: {e}")
        raise HTTPException(status_code=500, detail=f"Music generation failed: {str(e)}")

@app.get("/audio/{filename}")
async def get_audio(filename: str):
    """Serve generated audio files"""
    output_dir = get_output_dir()
    file_path = output_dir / filename

    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Audio file not found")

    return FileResponse(
        path=file_path,
        media_type="audio/wav",
        filename=filename
    )

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {"status": "healthy", "service": "heartmula"}


@app.get("/healthz")
async def healthz():
    """Liveness check (compatible with gateway expectations)."""
    return {"status": "healthy", "service": "heartmula"}


@app.get("/readyz")
async def readyz():
    """Readiness check: returns 200 when pipeline is initialized and ready to serve.

    Returns 503 if the pipeline is not yet initialized.
    """
    if pipeline is None:
        # Not ready yet
        from fastapi import HTTPException

        raise HTTPException(status_code=503, detail={"status": "not ready", "service": "heartmula"})

    # Optionally include device/dtype info for debugging
    info = {"status": "ready", "service": "heartmula"}
    try:
        if pipeline_device:
            info["device"] = pipeline_device
        if pipeline_dtype:
            info["dtype"] = pipeline_dtype
    except Exception:
        pass
    return info

if __name__ == "__main__":
    # Get port from environment or default to 9920
    port = int(os.environ.get("HEARTMULA_PORT", "9920"))
    # Default to 0.0.0.0 so the service can be reached from gateway hosts like ada2.
    # Be cautious: binding to all interfaces exposes the service to the network —
    # ensure firewall rules or network ACLs restrict access to trusted hosts only.
    host = os.environ.get("HEARTMULA_HOST", "0.0.0.0")

    print(f"Starting HeartMula API server on {host}:{port}")
    if host == "0.0.0.0":
        print("WARNING: HeartMula is binding to 0.0.0.0 (all network interfaces). Ensure firewall/ACLs restrict access to trusted hosts such as the gateway.")

    uvicorn.run(app, host=host, port=port)
