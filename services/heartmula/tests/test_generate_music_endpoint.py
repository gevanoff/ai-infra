import asyncio
from pathlib import Path
import os
import importlib.util
import torch

spec = importlib.util.spec_from_file_location("heartmula_server", Path(__file__).resolve().parents[1] / "heartmula_server.py")
heartmula = importlib.util.module_from_spec(spec)
spec.loader.exec_module(heartmula)


class FakePipeline:
    def _sanitize_parameters(self, **kwargs):
        # return (pre_kwargs, forward_kwargs, post_kwargs)
        return {}, {}, {"save_path": kwargs.get("save_path")}

    def preprocess(self, inp, **kwargs):
        # return CPU tensors mimicking typical preprocess output
        return {
            "tokens": torch.tensor([[1, 2, 3]], dtype=torch.int64),
            "tokens_mask": torch.tensor([[1, 1, 1]], dtype=torch.bool),
            "muq_embed": torch.tensor([[0.1] * 16], dtype=torch.float32),
        }

    def _forward(self, model_inputs, **kwargs):
        return {"dummy": "ok"}

    def postprocess(self, outputs, save_path):
        # write a small placeholder WAV file
        Path(save_path).write_bytes(b"RIFF....")


async def _call_generate(tmp_path):
    # set output dir
    os.environ["HEARTMULA_OUTPUT_DIR"] = str(tmp_path)

    # monkeypatch globals
    heartmula.pipeline = FakePipeline()
    heartmula.pipeline_device = "cpu"
    heartmula.pipeline_dtype = "torch.float32"

    req = heartmula.MusicGenerationRequest(prompt="smoke-test", duration=1)
    resp = await heartmula.generate_music(req)
    return resp


def test_generate_music_creates_file(tmp_path):
    resp = asyncio.run(_call_generate(tmp_path))
    assert resp.status == "completed"
    # audio_url like /audio/<id>.wav
    audio_file = tmp_path / (resp.id + ".wav")
    assert audio_file.exists()