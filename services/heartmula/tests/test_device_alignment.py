import torch
from pathlib import Path

# Provide a fake 'heartlib' module so importing the server doesn't exit during tests
import sys, types
fake_heartlib = types.ModuleType("heartlib")
class HeartMuLaGenPipeline: pass
fake_heartlib.HeartMuLaGenPipeline = HeartMuLaGenPipeline
sys.modules["heartlib"] = fake_heartlib

# Import helper via importlib to avoid package import issues in tests
import importlib.util
spec = importlib.util.spec_from_file_location("heartmula_server", Path(__file__).resolve().parents[1] / "heartmula_server.py")
heartmula = importlib.util.module_from_spec(spec)
spec.loader.exec_module(heartmula)


def test_align_preserves_int_and_casts_float():
    int_t = torch.tensor([1, 2, 3], dtype=torch.int64)
    float_t = torch.tensor([0.1, 0.2], dtype=torch.float32)
    obj = {"idx": int_t, "vec": [float_t], "nested": {"f": float_t.clone()}}

    out = heartmula.align_tensors_to_device(obj, torch.device("cpu"), target_dtype=torch.float16)

    assert out["idx"].dtype == torch.int64
    assert out["vec"][0].dtype == torch.float16
    assert out["nested"]["f"].dtype == torch.float16


def test_align_preserves_structure_and_devices():
    float_t = torch.tensor([0.5, 0.6], dtype=torch.float32)
    obj = [float_t, {"a": float_t.clone()}]

    out = heartmula.align_tensors_to_device(obj, torch.device("cpu"), target_dtype=torch.float32)
    assert isinstance(out, list)
    assert out[0].device.type == "cpu"
    assert out[1]["a"].device.type == "cpu"