from pathlib import Path
import importlib.util

spec = importlib.util.spec_from_file_location("heartmula_server", Path(__file__).resolve().parents[1] / "heartmula_server.py")
heartmula = importlib.util.module_from_spec(spec)
spec.loader.exec_module(heartmula)

from fastapi.testclient import TestClient

client = TestClient(heartmula.app)


def test_healthz_ok():
    r = client.get("/healthz")
    assert r.status_code == 200
    data = r.json()
    assert data.get("status") == "healthy"


def test_readyz_not_ready_when_pipeline_none():
    # ensure pipeline is None for this test
    heartmula.pipeline = None
    r = client.get("/readyz")
    assert r.status_code == 503


def test_readyz_ready_when_pipeline_present():
    # Fake pipeline present
    heartmula.pipeline = object()
    heartmula.pipeline_device = "cuda:0"
    heartmula.pipeline_dtype = "torch.float16"

    r = client.get("/readyz")
    assert r.status_code == 200
    data = r.json()
    assert data.get("status") == "ready"
    assert data.get("device") == "cuda:0"
    assert "dtype" in data
