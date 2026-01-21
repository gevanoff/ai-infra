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
        print(f"Loading HeartMula model from: {model_path}")

        # Initialize pipeline with 3B model (smaller, more compatible)
        pipeline = HeartMuLaGenPipeline(
            model_path=model_path,
            version="3B"
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

        # Generate music
        audio_array = pipeline.generate(
            lyrics=lyrics,
            tags=tags,
            max_audio_length_ms=max_audio_length_ms,
            temperature=request.temperature,
            topk=request.top_k,
            topp=request.top_p,
            cfg_scale=1.5  # Default classifier-free guidance
        )

        # Save audio file
        # Note: HeartMula returns audio array, need to save it properly
        # This is a simplified version - you may need to adjust based on HeartMula's output format
        import soundfile as sf
        import numpy as np

        # Convert to wav first, then could convert to mp3 if needed
        wav_path = output_path.with_suffix('.wav')
        sf.write(wav_path, audio_array, 44100)  # Assuming 44.1kHz sample rate

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