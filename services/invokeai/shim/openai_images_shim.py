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
import hashlib
import json
import logging
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
logger = logging.getLogger("uvicorn.error")
_SHIM_BUILD = "2026-01-16e"


def _shim_file_sha256_prefix() -> Optional[str]:
    try:
        p = __file__
        with open(p, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:12]
    except Exception:
        return None


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
    debug_graph_path: Optional[str]
    model_input_mode: str
    strict_model: bool


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
        debug_graph_path=os.getenv("SHIM_DEBUG_GRAPH_PATH"),
        # Newer InvokeAI queue validation tends to be strict about model inputs.
        # Using ids is the most portable representation across versions.
        model_input_mode=os.getenv("SHIM_MODEL_INPUT_MODE", "id").strip().lower(),
        strict_model=os.getenv("SHIM_STRICT_MODEL", "false").strip().lower() in {"1", "true", "yes"},
    )


def _is_not_found(exc: HTTPException) -> bool:
    # _http_json formats 404s as: "Upstream HTTP error 404 calling <url>: <body>"
    try:
        return "HTTP error 404" in str(exc.detail)
    except Exception:
        return False


def _is_probe_miss(exc: HTTPException) -> bool:
    # Treat 404/405 as "keep trying" when probing candidate endpoints.
    try:
        s = str(exc.detail)
        return ("HTTP error 404" in s) or ("HTTP error 405" in s) or ("Not Found" in s)
    except Exception:
        return False


def _fetch_openapi_schema(base_url: str) -> Optional[dict]:
    schema_urls = (
        f"{base_url}/openapi.json",
        f"{base_url}/api/v1/openapi.json",
        f"{base_url}/api/v1/openapi",
        f"{base_url}/api/v2/openapi.json",
        f"{base_url}/api/v2/openapi",
    )
    for schema_url in schema_urls:
        try:
            out = _http_json("GET", schema_url, payload=None, timeout=10)
        except HTTPException as exc:
            if _is_probe_miss(exc):
                continue
            continue
        if isinstance(out, dict):
            return out
    return None


def _discover_queue_enqueue_endpoints(base_url: str, queue_id: str) -> List[Tuple[str, str]]:
    """Return list of (method, url) for enqueue endpoints discovered via OpenAPI."""
    schema = _fetch_openapi_schema(base_url)
    if not isinstance(schema, dict):
        return []
    paths = schema.get("paths")
    if not isinstance(paths, dict):
        return []

    discovered: List[Tuple[str, str]] = []
    for path, ops in paths.items():
        if not isinstance(path, str) or not path:
            continue
        if "enqueue" not in path.lower():
            continue
        if not isinstance(ops, dict):
            continue
        for method in ("post", "put", "patch"):
            if method not in ops:
                continue
            # Fill common placeholder variants.
            url = f"{base_url}{path}"
            url = url.replace("{queue_id}", urllib.parse.quote(queue_id))
            url = url.replace("{queueId}", urllib.parse.quote(queue_id))
            url = url.replace("{queue}", urllib.parse.quote(queue_id))
            discovered.append((method.upper(), url))

    # Prefer v2-like paths and enqueue_batch first.
    def _rank(item: Tuple[str, str]) -> Tuple[int, int, int, str]:
        method, url = item
        u = url.lower()
        return (
            0 if "/api/v2/" in u else 1,
            0 if "enqueue_batch" in u else 1,
            0 if method == "POST" else 1,
            url,
        )

    return sorted(discovered, key=_rank)


@app.on_event("startup")
def _log_startup() -> None:
    cfg = _get_config()
    logger.info(
        "Shim startup build=%s mode=%s graph=%s output_node=%s debug_graph=%s model_mode=%s",
        _SHIM_BUILD,
        cfg.mode,
        cfg.graph_template_path,
        cfg.output_node_id,
        cfg.debug_graph_path,
        cfg.model_input_mode,
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

    def _collect_candidates(obj: Any) -> List[dict]:
        out: List[dict] = []

        def _looks_like_model(d: dict) -> bool:
            if not isinstance(d, dict):
                return False
            key = d.get("key") or d.get("id") or d.get("model_key")
            name = d.get("name") or d.get("model") or d.get("model_name")
            return isinstance(key, str) and bool(key.strip()) and isinstance(name, str) and bool(name.strip())

        def _walk(x: Any, depth: int) -> None:
            if depth <= 0:
                return
            if isinstance(x, list):
                for vv in x:
                    _walk(vv, depth - 1)
                return
            if isinstance(x, dict):
                if _looks_like_model(x):
                    out.append(x)
                for vv in x.values():
                    _walk(vv, depth - 1)

        _walk(obj, 6)
        return out

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

        if not candidates:
            candidates = _collect_candidates(out)
        if candidates:
            break

    def _discover_via_openapi() -> List[dict]:
        # Some InvokeAI versions move/rename model listing endpoints.
        # As a last resort, fetch OpenAPI schema and probe GET endpoints that look model-related.
        schema_urls = (
            f"{cfg.invokeai_base_url}/openapi.json",
            f"{cfg.invokeai_base_url}/api/v1/openapi.json",
            f"{cfg.invokeai_base_url}/api/v1/openapi",
        )

        schema: Any = None
        for schema_url in schema_urls:
            try:
                schema = _http_json("GET", schema_url, payload=None, timeout=10)
                break
            except HTTPException as exc:
                detail = str(exc.detail)
                if "404" in detail or "Not Found" in detail:
                    continue
                # If schema fetch fails for other reasons, keep trying other urls.
                continue

        if not isinstance(schema, dict):
            return []

        paths = schema.get("paths")
        if not isinstance(paths, dict):
            return []

        probed: List[str] = []
        for path, ops in paths.items():
            if not isinstance(path, str) or not path or "{" in path:
                continue
            if "model" not in path.lower():
                continue
            if not isinstance(ops, dict) or "get" not in ops:
                continue
            probed.append(path)

        # Prefer shorter, list-y endpoints and avoid obviously unrelated ones.
        probed = sorted(
            set(probed),
            key=lambda p: (
                0 if p.endswith("models") or p.endswith("models/") else 1,
                len(p),
                p,
            ),
        )

        found: List[dict] = []
        for path in probed[:12]:
            url = f"{cfg.invokeai_base_url}{path}"
            try:
                out = _http_json("GET", url, payload=None, timeout=20)
            except HTTPException:
                continue
            c = _collect_candidates(out)
            if c:
                found = c
                logger.info("Discovered InvokeAI model list via %s", url)
                break
        return found

    if not candidates:
        candidates = _discover_via_openapi()

    if not candidates:
        # If model listing is unavailable, leave the graph template's model as-is.
        # Some InvokeAI deployments do not expose /api/v1/models.
        if last_error is not None:
            logger.warning("InvokeAI model list unavailable; proceeding with template model (%s)", last_error.detail)
        else:
            logger.warning("InvokeAI model list unavailable; proceeding with template model")
        return None

    needle = model.strip()
    needle_l = needle.lower()

    def _strings(item: dict) -> List[str]:
        vals: List[str] = []
        for k in (
            "key",
            "id",
            "model_key",
            "name",
            "model",
            "model_name",
            "modelName",
        ):
            v = item.get(k)
            if isinstance(v, str) and v.strip():
                vals.append(v.strip())
        return vals

    def _score(item: dict) -> int:
        svals = _strings(item)
        best = 0
        for v in svals:
            if v == needle:
                best = max(best, 100)
            vl = v.lower()
            if vl == needle_l:
                best = max(best, 90)
            if needle_l in vl or vl in needle_l:
                best = max(best, 60)
        return best

    match = None
    best_score = 0
    for m in candidates:
        if not isinstance(m, dict):
            continue
        sc = _score(m)
        if sc > best_score:
            match = m
            best_score = sc

    if best_score < 60:
        match = None

    if not match:
        # In practice, callers (e.g. the gateway) may send a model name that doesn't match
        # InvokeAI's internal registry keys. Default behavior is best-effort: keep the
        # template's model unchanged.
        if cfg.strict_model:
            raise HTTPException(
                status_code=400,
                detail=f"Model '{model}' not found in InvokeAI /api/v1/models",
            )
        logger.warning("Requested model %r not found in InvokeAI model list; proceeding with template model", model)
        return None

    # Normalize to the minimal shape used by workflow exports.
    normalized: Dict[str, Any] = {}
    # Prefer a stable key/id.
    normalized_key = match.get("key") or match.get("model_key") or match.get("id")
    if isinstance(normalized_key, str) and normalized_key.strip():
        normalized["key"] = normalized_key.strip()
    # Common descriptive fields (best-effort; InvokeAI ignores extras in most shapes).
    for src, dst in (
        ("hash", "hash"),
        ("name", "name"),
        ("model_name", "name"),
        ("model", "name"),
        ("base", "base"),
        ("base_model", "base"),
        ("type", "type"),
        ("model_type", "type"),
    ):
        v = match.get(src)
        if dst not in normalized and isinstance(v, str) and v.strip():
            normalized[dst] = v.strip()

    logger.info("Resolved InvokeAI model %r -> key=%r", model, normalized.get("key"))
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
    model_input_mode: str = "dict",
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
        model_input_mode=model_input_mode,
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
    model_input_mode: str = "dict",
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

        def _normalize_model_value(value: Any) -> Any:
            # Workflow exports usually store model selection as an object with a "key".
            # InvokeAI queue validation (6.x) can be strict; the most compatible representation
            # tends to be the workflow-style object: {key, hash, name, base, type}.
            if isinstance(value, dict):
                key = value.get("key") or value.get("id") or value.get("model_key")
                name = value.get("name") or value.get("model") or value.get("model_name")
                hash_v = value.get("hash")
                base = value.get("base") or value.get("base_model")
                typ = value.get("type") or value.get("model_type")
                if model_input_mode == "id":
                    if isinstance(key, str) and key.strip():
                        out: Dict[str, Any] = {"key": key.strip()}
                        if isinstance(hash_v, str) and hash_v.strip():
                            out["hash"] = hash_v.strip()
                        if isinstance(name, str) and name.strip():
                            out["name"] = name.strip()
                        if isinstance(base, str) and base.strip():
                            out["base"] = base.strip()
                        if isinstance(typ, str) and typ.strip():
                            out["type"] = typ.strip()
                        return out
                    if isinstance(name, str) and name.strip():
                        # Best-effort if we cannot resolve a key.
                        return {"name": name.strip()}
                    return value
                if model_input_mode == "name":
                    if isinstance(name, str) and name.strip():
                        return name.strip()
                    if isinstance(key, str) and key.strip():
                        return key.strip()
                    return value
                return value
            if isinstance(value, str):
                vv = value.strip()
                if model_input_mode == "id":
                    # Best-effort: treat a raw string as a key.
                    return {"key": vv} if vv else value
                return vv if vv else value
            return value

        # Ensure the model loader has a concrete model value when provided.
        if ntype in ("sdxl_model_loader", "model_loader"):
            if isinstance(model_info, dict):
                _set_input_value(inputs, "model", _normalize_model_value(model_info))
            else:
                model_field = inputs.get("model") if isinstance(inputs, dict) else None
                if isinstance(model_field, dict) and "value" in model_field:
                    value = model_field.get("value")
                    normalized = _normalize_model_value(value)
                    # Always write back the normalized form so the API graph conversion sees it.
                    if normalized is not None:
                        _set_input_value(inputs, "model", normalized)
            continue

        # The VAE loader has the same model-selection shape as the main model loader.
        if ntype == "vae_loader":
            if isinstance(model_info, dict):
                # Do not override the VAE model based on the requested main model.
                # Only normalize the existing template value.
                pass
            vae_field = inputs.get("vae_model") if isinstance(inputs, dict) else None
            if isinstance(vae_field, dict) and "value" in vae_field:
                normalized = _normalize_model_value(vae_field.get("value"))
                if normalized is not None:
                    _set_input_value(inputs, "vae_model", normalized)
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
    def _find_first_image_name(obj: Any) -> Optional[str]:
        if isinstance(obj, dict):
            v = obj.get("image_name")
            if isinstance(v, str) and v:
                return v
            for vv in obj.values():
                found = _find_first_image_name(vv)
                if found:
                    return found
            return None
        if isinstance(obj, list):
            for vv in obj:
                found = _find_first_image_name(vv)
                if found:
                    return found
            return None
        return None

    session = queue_item.get("session")
    if not isinstance(session, dict):
        # Some versions omit session details from the queue item; fall back to a best-effort scan.
        found = _find_first_image_name(queue_item)
        if found:
            return found
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
        found = _find_first_image_name(queue_item)
        if found:
            return found
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
        model_input_mode=cfg.model_input_mode,
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
        model_input_mode=cfg.model_input_mode,
    )

    output_node_id = (cfg.output_node_id or "").strip() or _detect_output_node_id(graph)
    if not output_node_id:
        raise HTTPException(status_code=500, detail="SHIM_OUTPUT_NODE_ID not set and could not auto-detect output node")

    graph_api = _ensure_invokeai_api_graph(graph)

    nodes_api = graph_api.get("nodes")
    if isinstance(nodes_api, dict):
        for node_id, node in nodes_api.items():
            if not isinstance(node, dict):
                continue
            if node.get("type") not in ("sdxl_model_loader", "model_loader"):
                continue
            inputs = node.get("inputs")
            model_value = inputs.get("model") if isinstance(inputs, dict) else None
            logger.info("Model loader input node_id=%s model=%s", node_id, model_value)

    if cfg.debug_graph_path:
        try:
            logger.info("Writing debug graph to %s", cfg.debug_graph_path)
            with open(cfg.debug_graph_path, "w", encoding="utf-8") as f:
                json.dump(graph_api, f, indent=2)
            logger.info("Debug graph written to %s", cfg.debug_graph_path)
        except Exception as e:
            logger.exception("Failed to write debug graph to %s", cfg.debug_graph_path)
            raise HTTPException(status_code=500, detail=f"Failed to write SHIM_DEBUG_GRAPH_PATH: {e}")

    # Preflight: ensure the model input is present for model loader nodes.
    if isinstance(nodes_api, dict):
        for node_id, node in nodes_api.items():
            if not isinstance(node, dict):
                continue
            if node.get("type") not in ("sdxl_model_loader", "model_loader"):
                continue
            inputs = node.get("inputs")
            model_value = inputs.get("model") if isinstance(inputs, dict) else None
            missing = False
            if model_value is None:
                missing = True
            elif isinstance(model_value, str) and not model_value.strip():
                missing = True
            elif isinstance(model_value, dict):
                if not model_value:
                    missing = True
                elif cfg.model_input_mode == "id":
                    key = model_value.get("key") if isinstance(model_value.get("key"), str) else None
                    if not key or not key.strip():
                        missing = True

            if missing:
                raise HTTPException(
                    status_code=500,
                    detail=(
                        "Preflight missing/empty model input in graph "
                        f"(node_id={node_id}, model_input_mode={cfg.model_input_mode}, model={model_value!r})"
                    ),
                )

    origin = f"openai-images-shim:{int(time.time() * 1000)}"

    def _extract_item_id(enqueue_result: Any) -> str:
        if not isinstance(enqueue_result, dict):
            raise HTTPException(status_code=502, detail=f"InvokeAI enqueue returned non-object: {enqueue_result}")

        # Common shapes observed across versions:
        # - {"item_ids": [123]}
        # - {"item_ids": ["123"]}
        # - {"item_id": 123}
        for key in ("item_ids", "item_id"):
            v = enqueue_result.get(key)
            if isinstance(v, list) and v:
                v0 = v[0]
                if isinstance(v0, (int, str)):
                    return str(v0)
            if isinstance(v, (int, str)):
                return str(v)

        raise HTTPException(status_code=502, detail=f"InvokeAI enqueue returned unexpected payload: {enqueue_result}")

    enqueue_body = {
        "prepend": True,
        "batch": {
            "graph": graph_api,
            "origin": origin,
            "destination": "openai-images",
            "runs": 1,
        },
    }

    discovered = _discover_queue_enqueue_endpoints(cfg.invokeai_base_url, cfg.queue_id)
    if discovered:
        enqueue_candidates: List[Tuple[str, str]] = discovered
    else:
        enqueue_candidates = [
            ("POST", f"{cfg.invokeai_base_url}/api/v2/queue/{urllib.parse.quote(cfg.queue_id)}/enqueue_batch"),
            ("POST", f"{cfg.invokeai_base_url}/api/v2/queue/{urllib.parse.quote(cfg.queue_id)}/enqueue"),
            ("POST", f"{cfg.invokeai_base_url}/api/v1/queue/{urllib.parse.quote(cfg.queue_id)}/enqueue_batch"),
            ("POST", f"{cfg.invokeai_base_url}/api/v1/queue/{urllib.parse.quote(cfg.queue_id)}/enqueue"),
        ]

    enqueue_result: Any = None
    last_exc: Optional[HTTPException] = None
    used_enqueue: Optional[Tuple[str, str]] = None
    for method, enqueue_url in enqueue_candidates:
        try:
            enqueue_result = _http_json(method, enqueue_url, enqueue_body, timeout=30)
            last_exc = None
            used_enqueue = (method, enqueue_url)
            break
        except HTTPException as exc:
            last_exc = exc
            if _is_probe_miss(exc):
                continue
            raise

    if last_exc is not None:
        raise last_exc

    if used_enqueue:
        logger.info("Enqueued InvokeAI batch via %s %s", used_enqueue[0], used_enqueue[1])

    item_id = _extract_item_id(enqueue_result)

    # Poll queue item until completion
    get_item_urls = (
        f"{cfg.invokeai_base_url}/api/v2/queue/{urllib.parse.quote(cfg.queue_id)}/i/{urllib.parse.quote(str(item_id))}",
        f"{cfg.invokeai_base_url}/api/v2/queue/{urllib.parse.quote(cfg.queue_id)}/items/{urllib.parse.quote(str(item_id))}",
        f"{cfg.invokeai_base_url}/api/v1/queue/{urllib.parse.quote(cfg.queue_id)}/i/{urllib.parse.quote(str(item_id))}",
        f"{cfg.invokeai_base_url}/api/v1/queue/{urllib.parse.quote(cfg.queue_id)}/items/{urllib.parse.quote(str(item_id))}",
    )
    deadline = time.time() + cfg.timeout_s
    last_status = None

    while time.time() < deadline:
        queue_item: Any = None
        last_exc = None
        for get_item_url in get_item_urls:
            try:
                queue_item = _http_json("GET", get_item_url, payload=None, timeout=30)
                last_exc = None
                break
            except HTTPException as exc:
                last_exc = exc
                if _is_not_found(exc):
                    continue
                raise
        if last_exc is not None:
            raise last_exc
        if not isinstance(queue_item, dict):
            raise HTTPException(status_code=502, detail=f"InvokeAI get_queue_item returned non-object: {queue_item}")

        status = queue_item.get("status")
        last_status = status

        if status == "completed":
            image_name = _extract_image_name_from_queue_item(queue_item, output_node_id)
            image_urls = (
                f"{cfg.invokeai_base_url}/api/v1/images/i/{urllib.parse.quote(image_name)}/full",
                f"{cfg.invokeai_base_url}/api/v1/images/i/{urllib.parse.quote(image_name)}",
            )
            image_bytes: Optional[bytes] = None
            last_exc = None
            for image_url in image_urls:
                try:
                    image_bytes = _http_bytes(image_url, timeout=60)
                    last_exc = None
                    break
                except HTTPException as exc:
                    last_exc = exc
                    if _is_not_found(exc):
                        continue
                    raise
            if image_bytes is None and last_exc is not None:
                raise last_exc
            if image_bytes is None:
                raise HTTPException(status_code=502, detail="InvokeAI did not return image bytes")
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
    version_urls = (
        f"{cfg.invokeai_base_url}/api/v1/app/version",
        f"{cfg.invokeai_base_url}/api/v1/version",
        f"{cfg.invokeai_base_url}/api/v1/app",
    )

    version: Any = None
    last_exc: Optional[HTTPException] = None
    for version_url in version_urls:
        try:
            version = _http_json("GET", version_url, payload=None, timeout=5)
            last_exc = None
            break
        except HTTPException as exc:
            last_exc = exc
            if _is_not_found(exc):
                continue
            raise

    if last_exc is not None:
        raise last_exc

    return {
        "status": "ok",
        "mode": cfg.mode,
        "shim_build": _SHIM_BUILD,
        "shim_file_sha256": _shim_file_sha256_prefix(),
        "shim_model_input_mode": cfg.model_input_mode,
        "invokeai_version": version,
    }


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
