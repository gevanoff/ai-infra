"""OpenAI Images API shim for InvokeAI.

Purpose
- Expose POST /v1/images/generations with an OpenAI-ish response body containing data[].b64_json.
- Designed to sit behind nginx on ada2 and translate requests into InvokeAI's queue + images APIs.

Modes
- SHIM_MODE=stub (default): returns a tiny PNG for end-to-end contract testing.
- SHIM_MODE=invokeai_queue: enqueues a user-provided InvokeAI graph template and returns the resulting image.

Graph templates
- Provide SHIM_GRAPH_TEMPLATE_PATH pointing to a JSON file.
    - This may be either an InvokeAI API Graph, or an InvokeAI "workflow export" JSON.
- Provide SHIM_OUTPUT_NODE_ID identifying the output node id in that graph.
- Template supports simple placeholders in any string field:
    - {{prompt}}, {{negative_prompt}}

Notes
- Many InvokeAI “workflow export” JSON files store width/height/seed as numbers, not strings.
    In invokeai_queue mode this shim also applies best-effort overrides to common node types
    (noise, rand_int, sdxl_compel_prompt, denoise_latents) so you can use exported workflows
    as templates without needing numeric placeholders.
"""

from __future__ import annotations

import base64
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


app = FastAPI(title="InvokeAI OpenAI Images Shim", version="0.1")


class ImagesGenerationsRequest(BaseModel):
    prompt: str = Field(min_length=1)
    n: int = Field(default=1, ge=1, le=10)
    size: Optional[str] = None  # e.g. "1024x1024"
    response_format: Optional[str] = None  # expected: "b64_json"
    model: Optional[str] = None
    user: Optional[str] = None
    seed: Optional[int] = None
    negative_prompt: Optional[str] = None
    steps: Optional[int] = None
    cfg_scale: Optional[float] = None
    scheduler: Optional[str] = None


@dataclass(frozen=True)
class ShimConfig:
    mode: str
    invokeai_base_url: str
    queue_id: str
    shim_port: int
    poll_interval_s: float
    timeout_s: float
    graph_template_path: Optional[str]
    output_node_id: Optional[str]
    default_model: Optional[str]


def _get_config() -> ShimConfig:
    return ShimConfig(
        mode=os.getenv("SHIM_MODE", "stub").strip().lower(),
        invokeai_base_url=os.getenv("INVOKEAI_BASE_URL", "http://127.0.0.1:9090").rstrip("/"),
        queue_id=os.getenv("INVOKEAI_QUEUE_ID", "default"),
        shim_port=int(os.getenv("SHIM_PORT", "9091")),
        poll_interval_s=float(os.getenv("SHIM_POLL_INTERVAL_S", "0.25")),
        timeout_s=float(os.getenv("SHIM_TIMEOUT_S", "300")),
        graph_template_path=os.getenv("SHIM_GRAPH_TEMPLATE_PATH"),
        output_node_id=os.getenv("SHIM_OUTPUT_NODE_ID"),
        default_model=os.getenv("INVOKEAI_DEFAULT_MODEL"),
    )


# 1x1 PNG (transparent)
_STUB_PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB"
    "gQWZ8l8AAAAASUVORK5CYII="
)


def _parse_size(size: Optional[str]) -> Tuple[int, int]:
    if not size:
        return (1024, 1024)
    try:
        w_s, h_s = size.lower().split("x", 1)
        w, h = int(w_s), int(h_s)
        if w <= 0 or h <= 0:
            raise ValueError("non-positive")
        return (w, h)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid size '{size}' (expected WxH): {e}")


def _http_json(method: str, url: str, payload: Optional[dict] = None, timeout: float = 30) -> Any:
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, method=method.upper(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            if not body:
                return None
            return json.loads(body)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else ""
        raise HTTPException(status_code=502, detail=f"Upstream HTTP error {e.code} calling {url}: {raw}")
    except urllib.error.URLError as e:
        raise HTTPException(status_code=502, detail=f"Upstream URL error calling {url}: {e}")


def _http_bytes(url: str, timeout: float = 30) -> bytes:
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else ""
        raise HTTPException(status_code=502, detail=f"Upstream HTTP error {e.code} calling {url}: {raw}")
    except urllib.error.URLError as e:
        raise HTTPException(status_code=502, detail=f"Upstream URL error calling {url}: {e}")


def _resolve_model_info(model: Optional[str], *, cfg: ShimConfig) -> Optional[dict]:
    if not model:
        return None

    model = model.strip()
    if not model:
        return None

    candidates: List[dict] = []
    models_urls = (
        f"{cfg.invokeai_base_url}/api/v1/models",
        f"{cfg.invokeai_base_url}/api/v1/model/list",
        f"{cfg.invokeai_base_url}/api/v1/model",
        f"{cfg.invokeai_base_url}/api/v1/models/list",
    )
    last_error: Optional[HTTPException] = None

    for models_url in models_urls:
        try:
            out = _http_json("GET", models_url, payload=None, timeout=20)
        except HTTPException as exc:
            last_error = exc
            detail = str(exc.detail)
            if "404" in detail or "Not Found" in detail:
                continue
            raise

        if isinstance(out, list):
            candidates = [m for m in out if isinstance(m, dict)]
        elif isinstance(out, dict):
            for key in ("models", "items", "data"):
                maybe = out.get(key)
                if isinstance(maybe, list):
                    candidates = [m for m in maybe if isinstance(m, dict)]
                    break
        if candidates:
            break

    if not candidates:
        # If model listing is unavailable, fall back to a minimal model identifier.
        # Some InvokeAI deployments do not expose /api/v1/models.
        return {"key": model, "name": model}

    def _matches(item: dict, needle: str) -> bool:
        for k in ("key", "name", "id", "model"):
            v = item.get(k)
            if isinstance(v, str) and v.strip():
                if v == needle:
                    return True
                if v.lower() == needle.lower():
                    return True
        return False

    match = next((m for m in candidates if _matches(m, model)), None)
    if not match:
        raise HTTPException(
            status_code=400,
            detail=f"Model '{model}' not found in InvokeAI /api/v1/models",
        )

    # Normalize to the minimal shape used by workflow exports.
    normalized = {k: match.get(k) for k in ("key", "hash", "name", "base", "type") if k in match}
    return normalized or match


def _deep_replace_placeholders(value: Any, mapping: Dict[str, str]) -> Any:
    if isinstance(value, str):
        for k, v in mapping.items():
            value = value.replace(f"{{{{{k}}}}}", v)
        return value
    if isinstance(value, list):
        return [_deep_replace_placeholders(v, mapping) for v in value]
    if isinstance(value, dict):
        return {k: _deep_replace_placeholders(v, mapping) for k, v in value.items()}
    return value


def _load_graph_from_template(
    path: str,
    *,
    prompt: str,
    width: int,
    height: int,
    seed: Optional[int],
    model_info: Optional[dict],
) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as f:
            graph = json.load(f)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to load graph template '{path}': {e}")

    mapping = {
        "prompt": prompt,
        "negative_prompt": "",
    }

    out = _deep_replace_placeholders(graph, mapping)
    _apply_invokeai_workflow_overrides(
        out,
        prompt=prompt,
        negative_prompt="",
        width=width,
        height=height,
        seed=seed,
        model_info=model_info,
    )
    return out


def _detect_output_node_id(graph: dict) -> Optional[str]:
    nodes = graph.get("nodes")
    if isinstance(nodes, dict):
        for node_id, node in nodes.items():
            if isinstance(node, dict) and node.get("type") in ("image_output", "canvas_output"):
                return str(node_id)
        return None

    # Workflow export format: nodes is a list of objects with node['id'] and node['data'].
    if isinstance(nodes, list):
        # Prefer the final latents->image node when present.
        for node in nodes:
            if not isinstance(node, dict):
                continue
            data = node.get("data")
            if not isinstance(data, dict):
                continue
            if data.get("type") == "l2i" and data.get("isIntermediate") is False:
                node_id = node.get("id")
                return str(node_id) if isinstance(node_id, str) and node_id else None

        # Fallback: any explicit output node type.
        for node in nodes:
            if not isinstance(node, dict):
                continue
            data = node.get("data")
            if not isinstance(data, dict):
                continue
            if data.get("type") in ("image_output", "canvas_output"):
                node_id = node.get("id")
                return str(node_id) if isinstance(node_id, str) and node_id else None

    return None


def _apply_invokeai_workflow_overrides(
    graph: dict,
    *,
    prompt: str,
    negative_prompt: str,
    width: int,
    height: int,
    seed: Optional[int],
    steps: Optional[int] = None,
    cfg_scale: Optional[float] = None,
    scheduler: Optional[str] = None,
    model_info: Optional[dict] = None,
) -> None:
    nodes = graph.get("nodes")
    if not isinstance(nodes, list):
        return

    def _set_input_value(inputs: Any, key: str, value: Any) -> None:
        if not isinstance(inputs, dict):
            return
        obj = inputs.get(key)
        if isinstance(obj, dict) and "value" in obj:
            obj["value"] = value

    for node in nodes:
        if not isinstance(node, dict):
            continue
        data = node.get("data")
        if not isinstance(data, dict):
            continue

        ntype = data.get("type")
        label = (data.get("label") or "").strip()
        inputs = data.get("inputs")

        # Common prompt fields in the default SDXL workflow exports.
        if ntype == "string" and label in ("Positive Prompt", "Negative Prompt"):
            val_obj = inputs.get("value") if isinstance(inputs, dict) else None
            if isinstance(val_obj, dict) and "value" in val_obj:
                if label == "Positive Prompt":
                    val_obj["value"] = prompt
                else:
                    val_obj["value"] = negative_prompt or ""
            continue

        # Keep SDXL compel nodes consistent with the requested output size.
        if ntype == "sdxl_compel_prompt":
            _set_input_value(inputs, "original_width", int(width))
            _set_input_value(inputs, "original_height", int(height))
            _set_input_value(inputs, "target_width", int(width))
            _set_input_value(inputs, "target_height", int(height))
            continue

        # The latent noise node carries width/height.
        if ntype == "noise":
            _set_input_value(inputs, "width", int(width))
            _set_input_value(inputs, "height", int(height))
            # seed is often wired from a rand_int node; leave as-is unless the graph uses the literal input.
            if seed is not None:
                _set_input_value(inputs, "seed", int(seed))
            continue

        # The default workflow uses a rand_int node to generate a seed.
        if ntype == "rand_int" and label == "Random Seed" and seed is not None:
            _set_input_value(inputs, "low", int(seed))
            _set_input_value(inputs, "high", int(seed))
            continue

        # Ensure the model loader has a concrete model value when provided.
        if model_info and ntype in ("sdxl_model_loader", "model_loader"):
            _set_input_value(inputs, "model", model_info)
            continue

        # Basic quality knobs when present.
        if ntype == "denoise_latents":
            if steps is not None:
                _set_input_value(inputs, "steps", int(steps))
            if cfg_scale is not None:
                _set_input_value(inputs, "cfg_scale", float(cfg_scale))
            if scheduler:
                _set_input_value(inputs, "scheduler", str(scheduler))
            continue


def _workflow_export_to_api_graph(workflow_export: dict) -> dict:
    """Convert an InvokeAI workflow export (ReactFlow-ish) to an API Graph.

    InvokeAI's queue API expects:
      - graph.nodes: dict[node_id -> invocation]
      - graph.edges: list[{source:{node_id,field}, destination:{node_id,field}}]

    Workflow exports contain:
      - nodes: list[{id, data:{id,type,version,inputs:{field:{...,value:...}}}}]
      - edges: list[{source,target,sourceHandle,targetHandle,...}]
    """
    nodes_in = workflow_export.get("nodes")
    edges_in = workflow_export.get("edges")
    if not isinstance(nodes_in, list) or not isinstance(edges_in, list):
        raise HTTPException(status_code=500, detail="Workflow export is missing nodes/edges lists")

    nodes_out: Dict[str, Any] = {}
    for node in nodes_in:
        if not isinstance(node, dict):
            continue
        node_id = node.get("id")
        data = node.get("data")
        if not isinstance(node_id, str) or not node_id:
            continue
        if not isinstance(data, dict):
            continue

        inv_type = data.get("type")
        if not isinstance(inv_type, str) or not inv_type:
            continue

        # Workflow export inputs include UI metadata; the API expects raw values.
        inputs_in = data.get("inputs")
        inputs_out: Dict[str, Any] = {}
        if isinstance(inputs_in, dict):
            for k, v in inputs_in.items():
                if not isinstance(k, str) or not k:
                    continue
                if isinstance(v, dict) and "value" in v:
                    inputs_out[k] = v.get("value")

        inv: Dict[str, Any] = {
            "id": node_id,
            "type": inv_type,
            "inputs": inputs_out,
        }
        version = data.get("version")
        if isinstance(version, str) and version:
            inv["version"] = version

        nodes_out[node_id] = inv

    edges_out: List[Dict[str, Any]] = []
    for e in edges_in:
        if not isinstance(e, dict):
            continue
        source = e.get("source")
        target = e.get("target")
        source_handle = e.get("sourceHandle")
        target_handle = e.get("targetHandle")

        # Ignore non-data edges (e.g. collapsed edges) that lack handles.
        if not (
            isinstance(source, str)
            and isinstance(target, str)
            and isinstance(source_handle, str)
            and isinstance(target_handle, str)
            and source
            and target
            and source_handle
            and target_handle
        ):
            continue

        edges_out.append(
            {
                "source": {"node_id": source, "field": source_handle},
                "destination": {"node_id": target, "field": target_handle},
            }
        )

    return {"nodes": nodes_out, "edges": edges_out}


def _ensure_invokeai_api_graph(graph: dict) -> dict:
    """Return a Graph suitable for InvokeAI's queue API."""
    nodes = graph.get("nodes")
    edges = graph.get("edges")
    if isinstance(nodes, dict) and isinstance(edges, list):
        return graph
    if isinstance(nodes, list) and isinstance(edges, list):
        return _workflow_export_to_api_graph(graph)
    raise HTTPException(status_code=500, detail="Graph template must be an InvokeAI API Graph or a workflow export")


def _extract_image_name_from_queue_item(queue_item: dict, output_node_id: str) -> str:
    session = queue_item.get("session")
    if not isinstance(session, dict):
        raise HTTPException(status_code=502, detail="InvokeAI queue item missing session")

    source_prepared_mapping = session.get("source_prepared_mapping")
    if not isinstance(source_prepared_mapping, dict):
        raise HTTPException(status_code=502, detail="InvokeAI session missing source_prepared_mapping")

    prepared_ids = source_prepared_mapping.get(output_node_id)
    if not isinstance(prepared_ids, list) or not prepared_ids:
        raise HTTPException(
            status_code=502,
            detail=f"InvokeAI session missing prepared mapping for output node '{output_node_id}'",
        )

    prepared_id = prepared_ids[0]
    results = session.get("results")
    if not isinstance(results, dict):
        raise HTTPException(status_code=502, detail="InvokeAI session missing results")

    result = results.get(prepared_id)
    if not isinstance(result, dict):
        raise HTTPException(status_code=502, detail=f"InvokeAI session missing result for '{prepared_id}'")

    image = result.get("image")
    if not isinstance(image, dict):
        raise HTTPException(status_code=502, detail="InvokeAI result missing image field")

    image_name = image.get("image_name")
    if not isinstance(image_name, str) or not image_name:
        raise HTTPException(status_code=502, detail="InvokeAI result missing image.image_name")

    return image_name


def _invokeai_generate_b64(req: ImagesGenerationsRequest, *, cfg: ShimConfig) -> str:
    if not cfg.graph_template_path:
        raise HTTPException(status_code=500, detail="SHIM_GRAPH_TEMPLATE_PATH is required for invokeai_queue mode")

    width, height = _parse_size(req.size)

    model_name = (req.model or "").strip() or (cfg.default_model or "").strip()
    model_info = _resolve_model_info(model_name, cfg=cfg) if model_name else None

    graph = _load_graph_from_template(
        cfg.graph_template_path,
        prompt=req.prompt,
        width=width,
        height=height,
        seed=req.seed,
        model_info=model_info,
    )
    _apply_invokeai_workflow_overrides(
        graph,
        prompt=req.prompt,
        negative_prompt=(req.negative_prompt or "").strip(),
        width=width,
        height=height,
        seed=req.seed,
        steps=req.steps,
        cfg_scale=req.cfg_scale,
        scheduler=(req.scheduler or "").strip() or None,
        model_info=model_info,
    )

    output_node_id = (cfg.output_node_id or "").strip() or _detect_output_node_id(graph)
    if not output_node_id:
        raise HTTPException(status_code=500, detail="SHIM_OUTPUT_NODE_ID not set and could not auto-detect output node")

    graph_api = _ensure_invokeai_api_graph(graph)

    origin = f"openai-images-shim:{int(time.time() * 1000)}"

    enqueue_url = f"{cfg.invokeai_base_url}/api/v1/queue/{urllib.parse.quote(cfg.queue_id)}/enqueue_batch"
    enqueue_body = {
        "prepend": True,
        "batch": {
            "graph": graph_api,
            "origin": origin,
            "destination": "openai-images",
            "runs": 1,
        },
    }
    enqueue_result = _http_json("POST", enqueue_url, enqueue_body, timeout=30)

    item_ids = enqueue_result.get("item_ids") if isinstance(enqueue_result, dict) else None
    if not isinstance(item_ids, list) or not item_ids or not isinstance(item_ids[0], int):
        raise HTTPException(status_code=502, detail=f"InvokeAI enqueue_batch returned unexpected item_ids: {enqueue_result}")

    item_id = item_ids[0]

    # Poll queue item until completion
    get_item_url = f"{cfg.invokeai_base_url}/api/v1/queue/{urllib.parse.quote(cfg.queue_id)}/i/{item_id}"
    deadline = time.time() + cfg.timeout_s
    last_status = None

    while time.time() < deadline:
        queue_item = _http_json("GET", get_item_url, payload=None, timeout=30)
        if not isinstance(queue_item, dict):
            raise HTTPException(status_code=502, detail=f"InvokeAI get_queue_item returned non-object: {queue_item}")

        status = queue_item.get("status")
        last_status = status

        if status == "completed":
            image_name = _extract_image_name_from_queue_item(queue_item, output_node_id)
            image_url = f"{cfg.invokeai_base_url}/api/v1/images/i/{urllib.parse.quote(image_name)}/full"
            image_bytes = _http_bytes(image_url, timeout=60)
            return base64.b64encode(image_bytes).decode("ascii")

        if status == "failed":
            error_type = queue_item.get("error_type")
            error_message = queue_item.get("error_message")
            raise HTTPException(status_code=502, detail=f"InvokeAI generation failed: {error_type}: {error_message}")

        if status == "canceled":
            raise HTTPException(status_code=502, detail="InvokeAI generation canceled")

        time.sleep(cfg.poll_interval_s)

    raise HTTPException(status_code=504, detail=f"Timed out waiting for InvokeAI completion (last_status={last_status})")


@app.get("/healthz")
def healthz() -> Dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> Dict[str, Any]:
    cfg = _get_config()
    # If InvokeAI isn't reachable, we are not ready.
    version_url = f"{cfg.invokeai_base_url}/api/v1/app/version"
    version = _http_json("GET", version_url, payload=None, timeout=5)
    return {"status": "ok", "mode": cfg.mode, "invokeai_version": version}


@app.post("/v1/images/generations")
def images_generations(body: ImagesGenerationsRequest) -> Dict[str, Any]:
    cfg = _get_config()

    # Gateway forces this; be lenient but ensure output is always b64_json.
    if body.response_format and body.response_format != "b64_json":
        raise HTTPException(status_code=400, detail="Only response_format='b64_json' is supported")

    created = int(time.time())

    if cfg.mode == "stub":
        data = [{"b64_json": _STUB_PNG_B64} for _ in range(body.n)]
        return {"created": created, "data": data}

    if cfg.mode == "invokeai_queue":
        outputs: List[Dict[str, str]] = []
        for _ in range(body.n):
            b64_json = _invokeai_generate_b64(body, cfg=cfg)
            outputs.append({"b64_json": b64_json})
        return {"created": created, "data": outputs}

    raise HTTPException(status_code=500, detail=f"Unknown SHIM_MODE '{cfg.mode}'")
