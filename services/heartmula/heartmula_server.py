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

# Import HeartMula after environment setup
try:
    from heartlib import HeartMuLaGenPipeline
except ImportError as e:
    print(f"Error importing HeartMula: {e}")
    print("Make sure HeartMula is installed: pip install -e .")
    exit(1)

app = FastAPI(title="HeartMula Music Generation API")

class MusicGenerationRequest(BaseModel):
    prompt: str
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

def get_model_path() -> str:
    """Get the model path from environment or default"""
    return os.environ.get("HEARTMULA_MODEL_PATH", "./ckpt")

def get_output_dir() -> Path:
    """Get output directory for generated audio"""
    output_dir = Path(os.environ.get("HEARTMULA_OUTPUT_DIR", "/tmp/heartmula_output"))
    output_dir.mkdir(exist_ok=True, parents=True)
    return output_dir

@app.on_event("startup")
async def startup_event():
    """Initialize HeartMula pipeline on startup"""
    global pipeline
    try:
        model_path = get_model_path()
        version = os.environ.get("HEARTMULA_VERSION", "3B")
        dtype_env = os.environ.get("HEARTMULA_DTYPE", "float32")
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        dtype = torch.float16 if dtype_env in ("float16", "fp16") else torch.float32

        print(f"Loading HeartMuLa model from: {model_path} (version={version}, device={device}, dtype={dtype})")

        # Use from_pretrained classmethod to load checkpoints from a directory
        pipeline = HeartMuLaGenPipeline.from_pretrained(
            model_path,
            device=device,
            dtype=dtype,
            version=version,
        )
        print("HeartMula pipeline initialized successfully")
    except Exception as e:
        print(f"Failed to initialize HeartMula pipeline: {e}")
        raise

@app.post("/v1/music/generations", response_model=MusicGenerationResponse)
async def generate_music(request: MusicGenerationRequest):
    """Generate music using HeartMula"""
    if pipeline is None:
        raise HTTPException(status_code=503, detail="HeartMula pipeline not initialized")

    try:
        # Generate unique ID for this request
        generation_id = str(uuid.uuid4())

        # Prepare lyrics (use prompt as lyrics)
        lyrics = request.prompt

        # Prepare tags
        tags = request.tags or "electronic,ambient"

        # Convert duration to milliseconds
        max_audio_length_ms = request.duration * 1000 if request.duration else 30000

        # Generate output path
        output_dir = get_output_dir()
        output_path = output_dir / f"{generation_id}.mp3"

        print(f"Generating music: {lyrics[:50]}... (duration: {request.duration}s)")

        # Generate music using pipeline internals (preprocess -> forward -> postprocess)
        pre_kwargs, forward_kwargs, post_kwargs = pipeline._sanitize_parameters(
            cfg_scale=1.5,
            max_audio_length_ms=max_audio_length_ms,
            temperature=request.temperature,
            topk=request.top_k,
            save_path=str(output_path.with_suffix('.wav')),
        )

        model_inputs = pipeline.preprocess({"tags": tags, "lyrics": lyrics}, **pre_kwargs)
        model_outputs = pipeline._forward(model_inputs, **forward_kwargs)
        # Postprocess will write the file at save_path
        pipeline.postprocess(model_outputs, save_path=str(output_path.with_suffix('.wav')))

        # Confirm file exists
        wav_path = output_path.with_suffix('.wav')
        if not wav_path.exists():
            raise RuntimeError("Generation did not produce output file")

        # For now, return the WAV file
        # You could add MP3 conversion here if desired
        final_path = wav_path

        # Create response
        response = MusicGenerationResponse(
            id=generation_id,
            status="completed",
            audio_url=f"/audio/{generation_id}.wav",  # Serve via FastAPI
            duration=request.duration,
            prompt=request.prompt
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

if __name__ == "__main__":
    # Get port from environment or default to 9920
    port = int(os.environ.get("HEARTMULA_PORT", "9920"))
    host = os.environ.get("HEARTMULA_HOST", "127.0.0.1")

    print(f"Starting HeartMula API server on {host}:{port}")
    uvicorn.run(app, host=host, port=port)