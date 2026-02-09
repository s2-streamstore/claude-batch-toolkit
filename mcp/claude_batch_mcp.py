#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "mcp",
#     "requests",
# ]
# ///
"""
claude_batch_mcp.py — One-file "send to batch" tool (Anthropic Message Batches + Vertex BatchPredictionJobs)
for use with Claude Code via MCP *or* as a plain CLI.

What you get:
- Durable on-disk state: ~/.claude/batches/jobs.json
- Results written to:      ~/.claude/batches/results/<job_id>.md (+meta)
- Backends:
  - Anthropic Message Batches (direct REST)
  - Vertex AI BatchPredictionJob for Anthropic Claude partner models (REST + GCS upload/download)
- Optional MCP server mode (if `mcp` package is installed): exposes tools:
    send_to_batch, batch_status, batch_fetch, batch_list

Env vars (minimum):
Anthropic:
  ANTHROPIC_API_KEY=...

Vertex:
  VERTEX_PROJECT=your-gcp-project-id
  VERTEX_LOCATION=us-central1   # must support your model
  VERTEX_GCS_BUCKET=your-bucket # used for input upload + output prefix

Optional:
  VERTEX_GCS_PREFIX=claude-batch     # default folder prefix in the bucket
  CLAUDE_BATCH_DIR=~/.claude/batches # override local state dir
  CLAUDE_MODEL=claude-opus-4-6       # default model name (both backends use same model string)
  CLAUDE_MAX_TOKENS=8192             # default max_tokens
  CLAUDE_THINKING=enabled            # passed through to Anthropic Messages schema where supported
  CLAUDE_THINKING_BUDGET=4096        # optional; depends on model/features
  ANTHROPIC_VERSION=2023-06-01       # default header for Anthropic REST

NOTE:
- Vertex batch input must be JSONL in GCS following the Anthropic Claude API schema:
  each line: {"custom_id": "...", "request": {"messages":[...], "anthropic_version":"vertex-2023-10-16", "max_tokens":...}}
  See Google doc: https://docs.cloud.google.com/vertex-ai/generative-ai/docs/partner-models/claude/batch
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import io
import json
import os
import random
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple, Literal

# ---------- constants / defaults ----------

DEFAULT_LOCAL_DIR = os.path.expanduser(os.getenv("CLAUDE_BATCH_DIR", "~/.claude/batches"))
RESULTS_DIRNAME = "results"
JOBS_FILENAME = "jobs.json"

DEFAULT_MODEL = os.getenv("CLAUDE_MODEL", "claude-opus-4-6")
DEFAULT_MAX_TOKENS = int(os.getenv("CLAUDE_MAX_TOKENS", "8192"))
DEFAULT_ANTHROPIC_VERSION = os.getenv("ANTHROPIC_VERSION", "2023-06-01")

ANTHROPIC_API_BASE = "https://api.anthropic.com"
VERTEX_ANTHROPIC_VERSION = "vertex-2023-10-16"

BackendName = Literal["anthropic", "vertex"]


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_text(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def ensure_dirs(base_dir: str) -> Tuple[Path, Path]:
    base = Path(base_dir).expanduser().resolve()
    results = base / RESULTS_DIRNAME
    results.mkdir(parents=True, exist_ok=True)
    base.mkdir(parents=True, exist_ok=True)
    return base, results


def atomic_write_json(path: Path, obj: Any) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    data = json.dumps(obj, indent=2, sort_keys=True)
    tmp.write_text(data, encoding="utf-8")
    # best-effort fsync
    try:
        fd = os.open(tmp, os.O_RDONLY)
        os.fsync(fd)
        os.close(fd)
    except Exception:
        pass
    tmp.replace(path)


def load_jobs(base_dir: str) -> Dict[str, Any]:
    base, _ = ensure_dirs(base_dir)
    p = base / JOBS_FILENAME
    if not p.exists():
        return {"version": 1, "jobs": {}}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        raise RuntimeError(f"Failed to read jobs file {p}: {e}") from e


def save_jobs(base_dir: str, jobs_obj: Dict[str, Any]) -> None:
    base, _ = ensure_dirs(base_dir)
    p = base / JOBS_FILENAME
    atomic_write_json(p, jobs_obj)


def backoff_next_delay_s(attempt: int, base: float = 15.0, factor: float = 1.7, cap: float = 300.0, jitter: float = 0.25) -> float:
    """Jittered exponential backoff."""
    raw = min(cap, base * (factor ** max(0, attempt)))
    j = 1.0 + random.uniform(-jitter, jitter)
    return max(1.0, raw * j)


# ---------- HTTP helpers ----------

def _require_requests() -> Any:
    try:
        import requests  # type: ignore
        return requests
    except ImportError as e:
        raise RuntimeError("Missing dependency: requests. Install with: pip install requests") from e


def _require_google_auth() -> Any:
    try:
        import google.auth  # type: ignore
        import google.auth.transport.requests  # type: ignore
        return google.auth, google.auth.transport.requests
    except ImportError as e:
        raise RuntimeError("Missing dependency: google-auth. Install with: pip install google-auth") from e


def _require_gcs() -> Any:
    try:
        from google.cloud import storage  # type: ignore
        return storage
    except ImportError as e:
        raise RuntimeError("Missing dependency: google-cloud-storage. Install with: pip install google-cloud-storage") from e


# ---------- Models ----------

@dataclass
class JobRecord:
    job_id: str
    backend: BackendName
    label: Optional[str]
    created_at: str
    state: str  # submitted|running|succeeded|failed
    packet_sha256: str
    result_path: str
    meta_path: str
    attempt: int = 0
    next_poll_at: Optional[str] = None

    # Anthropic specific
    anthropic_custom_id: Optional[str] = None

    # Vertex specific
    vertex_project: Optional[str] = None
    vertex_location: Optional[str] = None
    gcs_input_uri: Optional[str] = None
    gcs_output_uri_prefix: Optional[str] = None


def _job_to_dict(j: JobRecord) -> Dict[str, Any]:
    return dataclasses.asdict(j)


def _job_from_dict(d: Dict[str, Any]) -> JobRecord:
    return JobRecord(**d)


# ---------- Backends ----------

class AnthropicBatchBackend:
    """Direct REST calls for Anthropic Message Batches."""
    def __init__(self, api_key: str, anthropic_version: str = DEFAULT_ANTHROPIC_VERSION):
        self.api_key = api_key
        self.anthropic_version = anthropic_version
        self.requests = _require_requests()

    def _headers(self) -> Dict[str, str]:
        return {
            "x-api-key": self.api_key,
            "anthropic-version": self.anthropic_version,
            "content-type": "application/json",
        }

    def submit_one(self, *, prompt_text: str, model: str = DEFAULT_MODEL, max_tokens: int = DEFAULT_MAX_TOKENS,
                   thinking: Optional[Dict[str, Any]] = None, custom_id: Optional[str] = None) -> str:
        if custom_id is None:
            custom_id = f"cc-{int(time.time())}-{random.randint(1000,9999)}"
        params: Dict[str, Any] = {
            "model": model,
            "max_tokens": max_tokens,
            "messages": [{"role": "user", "content": prompt_text}],
        }
        if thinking:
            params["thinking"] = thinking

        payload = {"requests": [{"custom_id": custom_id, "params": params}]}
        url = f"{ANTHROPIC_API_BASE}/v1/messages/batches"
        r = self.requests.post(url, headers=self._headers(), data=json.dumps(payload), timeout=120)
        if r.status_code >= 300:
            raise RuntimeError(f"Anthropic batch submit failed ({r.status_code}): {r.text}")
        return r.json()["id"]

    def retrieve(self, batch_id: str) -> Dict[str, Any]:
        url = f"{ANTHROPIC_API_BASE}/v1/messages/batches/{batch_id}"
        r = self.requests.get(url, headers=self._headers(), timeout=60)
        if r.status_code >= 300:
            raise RuntimeError(f"Anthropic batch retrieve failed ({r.status_code}): {r.text}")
        return r.json()

    def fetch_results_jsonl(self, batch_id: str) -> str:
        url = f"{ANTHROPIC_API_BASE}/v1/messages/batches/{batch_id}/results"
        r = self.requests.get(url, headers=self._headers(), timeout=300, stream=True)
        if r.status_code >= 300:
            raise RuntimeError(f"Anthropic batch results failed ({r.status_code}): {r.text}")
        buf = io.StringIO()
        for chunk in r.iter_content(chunk_size=64 * 1024, decode_unicode=True):
            if chunk:
                buf.write(chunk if isinstance(chunk, str) else chunk.decode("utf-8"))
        return buf.getvalue()

    @staticmethod
    def extract_text_from_jsonl(jsonl: str, custom_id: Optional[str] = None) -> str:
        out_chunks: List[str] = []
        for line in jsonl.splitlines():
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            cid = obj.get("custom_id")
            if custom_id and cid != custom_id:
                continue
            result = obj.get("result", {})
            if result.get("type") != "succeeded":
                if custom_id and cid == custom_id:
                    return json.dumps(obj, indent=2)
                continue
            message = result.get("message", {})
            content = message.get("content", [])
            texts = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    texts.append(block.get("text", ""))
            if texts:
                out_chunks.append("\n".join(texts))
        return "\n\n".join(out_chunks).strip()


class VertexBatchBackend:
    """Vertex AI BatchPredictionJob via REST + GCS upload/download."""
    def __init__(self, project: str, location: str, bucket: str, prefix: str = "claude-batch"):
        self.project = project
        self.location = location
        self.bucket = bucket
        self.prefix = prefix.strip("/")

        self.requests = _require_requests()
        google_auth, google_auth_transport = _require_google_auth()
        self.google_auth = google_auth
        self.google_auth_transport = google_auth_transport

        storage = _require_gcs()
        self.storage_client = storage.Client()

        self.session = None  # AuthorizedSession

    def _authorized_session(self):
        if self.session is None:
            creds, _ = self.google_auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
            self.session = self.google_auth_transport.requests.AuthorizedSession(creds)
        return self.session

    def _endpoint(self) -> str:
        return f"https://{self.location}-aiplatform.googleapis.com/v1"

    def _job_parent(self) -> str:
        return f"projects/{self.project}/locations/{self.location}"

    def _job_collection_url(self) -> str:
        return f"{self._endpoint()}/{self._job_parent()}/batchPredictionJobs"

    def _job_url(self, job_name: str) -> str:
        return f"{self._endpoint()}/{job_name}"

    def _gcs_uri(self, *parts: str) -> str:
        path = "/".join([p.strip("/") for p in parts if p])
        return f"gs://{self.bucket}/{path}"

    def _upload_text_to_gcs(self, text: str, gcs_uri: str) -> None:
        _, rest = gcs_uri.split("gs://", 1)
        bname, obj = rest.split("/", 1)
        blob = self.storage_client.bucket(bname).blob(obj)
        blob.upload_from_string(text.encode("utf-8"), content_type="application/jsonl")

    def _list_gcs_objects(self, gcs_prefix_uri: str) -> List[str]:
        _, rest = gcs_prefix_uri.split("gs://", 1)
        if "/" in rest:
            bname, prefix = rest.split("/", 1)
        else:
            bname, prefix = rest, ""
        bucket = self.storage_client.bucket(bname)
        blobs = list(self.storage_client.list_blobs(bucket, prefix=prefix))
        return [f"gs://{bname}/{b.name}" for b in blobs if not b.name.endswith("/")]

    def _download_gcs_text(self, gcs_uri: str) -> str:
        _, rest = gcs_uri.split("gs://", 1)
        bname, obj = rest.split("/", 1)
        blob = self.storage_client.bucket(bname).blob(obj)
        return blob.download_as_text(encoding="utf-8")

    def submit_one(self, *, prompt_text: str, model: str = DEFAULT_MODEL, max_tokens: int = DEFAULT_MAX_TOKENS,
                   label: Optional[str] = None) -> Tuple[str, str, str]:
        ts = int(time.time())
        rid = f"cc-{ts}-{random.randint(1000,9999)}"
        vertex_model = f"publishers/anthropic/models/{model}"

        input_obj = {
            "custom_id": rid,
            "request": {
                "messages": [{"role": "user", "content": prompt_text}],
                "anthropic_version": VERTEX_ANTHROPIC_VERSION,
                "max_tokens": max_tokens,
            },
        }
        input_jsonl = json.dumps(input_obj, ensure_ascii=False) + "\n"

        gcs_input_uri = self._gcs_uri(self.prefix, "inputs", f"{rid}.jsonl")
        gcs_output_prefix = self._gcs_uri(self.prefix, "outputs", rid)

        self._upload_text_to_gcs(input_jsonl, gcs_input_uri)

        display_name = label or f"claude-batch-{rid}"
        body = {
            "displayName": display_name,
            "model": vertex_model,
            "inputConfig": {
                "instancesFormat": "jsonl",
                "gcsSource": {"uris": [gcs_input_uri]},
            },
            "outputConfig": {
                "predictionsFormat": "jsonl",
                "gcsDestination": {"outputUriPrefix": gcs_output_prefix},
            },
        }

        sess = self._authorized_session()
        r = sess.post(
            self._job_collection_url(),
            headers={"Content-Type": "application/json; charset=utf-8"},
            data=json.dumps(body),
            timeout=120,
        )
        if r.status_code >= 300:
            raise RuntimeError(f"Vertex batch submit failed ({r.status_code}): {r.text}")
        data = r.json()
        return data["name"], gcs_input_uri, gcs_output_prefix

    def retrieve(self, job_name: str) -> Dict[str, Any]:
        sess = self._authorized_session()
        r = sess.get(self._job_url(job_name), timeout=60)
        if r.status_code >= 300:
            raise RuntimeError(f"Vertex batch retrieve failed ({r.status_code}): {r.text}")
        return r.json()

    def fetch_output_text(self, gcs_output_prefix: str) -> str:
        objs = self._list_gcs_objects(gcs_output_prefix)
        objs = [o for o in objs if o.endswith(".jsonl")] or objs
        if not objs:
            raise RuntimeError(f"No output objects found under {gcs_output_prefix}")
        parts = [self._download_gcs_text(uri) for uri in sorted(objs)]
        return "\n".join(parts)

    @staticmethod
    def extract_text_from_vertex_jsonl(jsonl: str) -> str:
        out: List[str] = []
        for line in jsonl.splitlines():
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            payload = obj.get("response") or obj.get("predictions") or obj.get("prediction") or obj
            if isinstance(payload, dict):
                content = payload.get("content")
                if isinstance(content, list):
                    texts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
                    if any(t.strip() for t in texts):
                        out.append("\n".join([t for t in texts if t.strip()]))
                        continue
            out.append(json.dumps(obj, ensure_ascii=False))
        return "\n\n".join(out).strip()


# ---------- Core operations ----------

def read_packet(packet_path: Optional[str], packet_text: Optional[str]) -> str:
    if packet_text and packet_text.strip():
        return packet_text
    if not packet_path:
        raise ValueError("Provide either packet_path or packet_text.")
    p = Path(packet_path).expanduser().resolve()
    return p.read_text(encoding="utf-8")


def make_result_paths(results_dir: Path, job_id: str) -> Tuple[str, str]:
    safe_id = job_id.replace("/", "_")
    result_path = str((results_dir / f"{safe_id}.md").resolve())
    meta_path = str((results_dir / f"{safe_id}.meta.json").resolve())
    return result_path, meta_path


def choose_backend(requested: str) -> BackendName:
    req = requested.lower()
    if req in ("anthropic", "vertex"):
        return req  # type: ignore
    has_vertex = bool(os.getenv("VERTEX_PROJECT") and os.getenv("VERTEX_LOCATION") and os.getenv("VERTEX_GCS_BUCKET"))
    has_anthropic = bool(os.getenv("ANTHROPIC_API_KEY"))
    if has_vertex:
        return "vertex"
    if has_anthropic:
        return "anthropic"
    raise RuntimeError("No backend creds found. Set VERTEX_PROJECT/VERTEX_LOCATION/VERTEX_GCS_BUCKET or ANTHROPIC_API_KEY.")


def submit_job(packet: str, backend_choice: str, label: Optional[str], base_dir: str) -> JobRecord:
    _, results_dir = ensure_dirs(base_dir)
    jobs_obj = load_jobs(base_dir)

    packet_hash = sha256_text(packet)
    backend = choose_backend(backend_choice)

    model = DEFAULT_MODEL
    max_tokens = DEFAULT_MAX_TOKENS

    thinking_cfg = None
    if os.getenv("CLAUDE_THINKING", "").lower() in ("1", "true", "yes", "enabled"):
        budget = os.getenv("CLAUDE_THINKING_BUDGET")
        thinking_cfg = {"type": "enabled", **({"budget_tokens": int(budget)} if budget else {})}

    if backend == "anthropic":
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            raise RuntimeError("ANTHROPIC_API_KEY is required for anthropic backend.")
        b = AnthropicBatchBackend(api_key=api_key)
        custom_id = f"cc-{int(time.time())}-{random.randint(1000,9999)}"
        batch_id = b.submit_one(prompt_text=packet, model=model, max_tokens=max_tokens, thinking=thinking_cfg, custom_id=custom_id)
        job_id = batch_id
        result_path, meta_path = make_result_paths(results_dir, job_id)
        rec = JobRecord(
            job_id=job_id,
            backend="anthropic",
            label=label,
            created_at=utc_now_iso(),
            state="submitted",
            packet_sha256=packet_hash,
            result_path=result_path,
            meta_path=meta_path,
            attempt=0,
            next_poll_at=utc_now_iso(),
            anthropic_custom_id=custom_id,
        )
    else:
        project = os.environ.get("VERTEX_PROJECT")
        location = os.environ.get("VERTEX_LOCATION")
        bucket = os.environ.get("VERTEX_GCS_BUCKET")
        prefix = os.environ.get("VERTEX_GCS_PREFIX", "claude-batch")
        if not (project and location and bucket):
            raise RuntimeError("VERTEX_PROJECT, VERTEX_LOCATION, VERTEX_GCS_BUCKET are required for vertex backend.")
        vb = VertexBatchBackend(project=project, location=location, bucket=bucket, prefix=prefix)
        job_name, gcs_input_uri, gcs_output_prefix = vb.submit_one(prompt_text=packet, model=model, max_tokens=max_tokens, label=label)
        job_id = job_name
        result_path, meta_path = make_result_paths(results_dir, job_id)
        rec = JobRecord(
            job_id=job_id,
            backend="vertex",
            label=label,
            created_at=utc_now_iso(),
            state="submitted",
            packet_sha256=packet_hash,
            result_path=result_path,
            meta_path=meta_path,
            attempt=0,
            next_poll_at=utc_now_iso(),
            vertex_project=project,
            vertex_location=location,
            gcs_input_uri=gcs_input_uri,
            gcs_output_uri_prefix=gcs_output_prefix,
        )

    jobs_obj["jobs"][rec.job_id] = _job_to_dict(rec)
    save_jobs(base_dir, jobs_obj)
    Path(rec.meta_path).write_text(json.dumps(_job_to_dict(rec), indent=2, sort_keys=True), encoding="utf-8")
    return rec


def get_job(job_id: str, base_dir: str) -> JobRecord:
    jobs_obj = load_jobs(base_dir)
    d = jobs_obj.get("jobs", {}).get(job_id)
    if not d:
        raise KeyError(f"Unknown job_id: {job_id}")
    return _job_from_dict(d)


def update_job(rec: JobRecord, base_dir: str) -> None:
    jobs_obj = load_jobs(base_dir)
    jobs_obj["jobs"][rec.job_id] = _job_to_dict(rec)
    save_jobs(base_dir, jobs_obj)
    Path(rec.meta_path).write_text(json.dumps(_job_to_dict(rec), indent=2, sort_keys=True), encoding="utf-8")


def status_job(rec: JobRecord) -> Dict[str, Any]:
    if rec.backend == "anthropic":
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            raise RuntimeError("ANTHROPIC_API_KEY missing.")
        b = AnthropicBatchBackend(api_key=api_key)
        info = b.retrieve(rec.job_id)
        return {
            "backend": "anthropic",
            "processing_status": info.get("processing_status"),
            "request_counts": info.get("request_counts", {}),
            "raw": info,
        }
    project = os.environ.get("VERTEX_PROJECT")
    location = os.environ.get("VERTEX_LOCATION")
    bucket = os.environ.get("VERTEX_GCS_BUCKET")
    if not (project and location and bucket):
        raise RuntimeError("VERTEX_PROJECT/VERTEX_LOCATION/VERTEX_GCS_BUCKET missing.")
    vb = VertexBatchBackend(project=project, location=location, bucket=bucket, prefix=os.environ.get("VERTEX_GCS_PREFIX", "claude-batch"))
    info = vb.retrieve(rec.job_id)
    return {"backend": "vertex", "state": info.get("state"), "raw": info}


def fetch_job(rec: JobRecord, base_dir: str, force: bool = False) -> str:
    rp = Path(rec.result_path)
    if rp.exists() and not force:
        return rp.read_text(encoding="utf-8")

    if rec.backend == "anthropic":
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            raise RuntimeError("ANTHROPIC_API_KEY missing.")
        b = AnthropicBatchBackend(api_key=api_key)
        info = b.retrieve(rec.job_id)
        if info.get("processing_status") != "ended":
            raise RuntimeError(f"Batch not ended yet (processing_status={info.get('processing_status')}).")
        jsonl = b.fetch_results_jsonl(rec.job_id)

        _, results_dir = ensure_dirs(base_dir)
        safe_id = rec.job_id.replace("/", "_")
        raw_path = results_dir / f"{safe_id}.raw.jsonl"
        raw_path.write_text(jsonl, encoding="utf-8")

        text = b.extract_text_from_jsonl(jsonl, custom_id=rec.anthropic_custom_id)
        rp.write_text(text + "\n", encoding="utf-8")
        rec.state = "succeeded" if text.strip() else "failed"
        update_job(rec, base_dir)
        return text

    project = os.environ.get("VERTEX_PROJECT")
    location = os.environ.get("VERTEX_LOCATION")
    bucket = os.environ.get("VERTEX_GCS_BUCKET")
    if not (project and location and bucket):
        raise RuntimeError("VERTEX_PROJECT/VERTEX_LOCATION/VERTEX_GCS_BUCKET missing.")
    vb = VertexBatchBackend(project=project, location=location, bucket=bucket, prefix=os.environ.get("VERTEX_GCS_PREFIX", "claude-batch"))
    info = vb.retrieve(rec.job_id)
    state = info.get("state")
    done_states = {"JOB_STATE_SUCCEEDED", "JOB_STATE_FAILED", "JOB_STATE_CANCELLED", "JOB_STATE_PAUSED"}
    if state not in done_states:
        raise RuntimeError(f"Vertex job not completed yet (state={state}).")

    if not rec.gcs_output_uri_prefix:
        try:
            rec.gcs_output_uri_prefix = info["outputConfig"]["gcsDestination"]["outputUriPrefix"]
        except Exception:
            raise RuntimeError("Missing gcs_output_uri_prefix; cannot fetch output.")

    out_jsonl = vb.fetch_output_text(rec.gcs_output_uri_prefix)
    text = vb.extract_text_from_vertex_jsonl(out_jsonl)
    rp.write_text(text + "\n", encoding="utf-8")
    rec.state = "succeeded" if state == "JOB_STATE_SUCCEEDED" else "failed"
    update_job(rec, base_dir)
    return text


def list_jobs(base_dir: str, state: str = "all") -> List[JobRecord]:
    jobs_obj = load_jobs(base_dir)
    jobs: List[JobRecord] = []
    for d in jobs_obj.get("jobs", {}).values():
        rec = _job_from_dict(d)
        if state != "all" and rec.state != state:
            continue
        jobs.append(rec)
    jobs.sort(key=lambda r: r.created_at, reverse=True)
    return jobs


def poll_once(base_dir: str) -> List[str]:
    completed: List[str] = []
    now = datetime.now(timezone.utc)

    for rec in list_jobs(base_dir, state="all"):
        if rec.state in ("succeeded", "failed"):
            continue

        due = True
        if rec.next_poll_at:
            try:
                due_time = datetime.fromisoformat(rec.next_poll_at)
                due = now >= due_time
            except Exception:
                due = True
        if not due:
            continue

        try:
            st = status_job(rec)
            if rec.backend == "anthropic":
                ps = st.get("processing_status")
                if ps == "ended":
                    fetch_job(rec, base_dir, force=False)
                    completed.append(rec.job_id)
                    continue
                rec.state = "running"
            else:
                state = st.get("state")
                if state in ("JOB_STATE_SUCCEEDED", "JOB_STATE_FAILED", "JOB_STATE_CANCELLED", "JOB_STATE_PAUSED"):
                    fetch_job(rec, base_dir, force=False)
                    completed.append(rec.job_id)
                    continue
                rec.state = "running"
        except Exception:
            # swallow and retry later
            pass

        delay = backoff_next_delay_s(rec.attempt)
        rec.attempt += 1
        rec.next_poll_at = (datetime.now(timezone.utc) + timedelta(seconds=delay)).isoformat()
        update_job(rec, base_dir)

    return completed


# ---------- CLI ----------

def cmd_submit(args: argparse.Namespace) -> None:
    packet = read_packet(args.packet_path, args.packet_text)
    rec = submit_job(packet, args.backend, args.label, args.base_dir)
    print(json.dumps({
        "job_id": rec.job_id,
        "backend": rec.backend,
        "result_path": rec.result_path,
        "meta_path": rec.meta_path,
    }, indent=2))


def cmd_status(args: argparse.Namespace) -> None:
    rec = get_job(args.job_id, args.base_dir)
    st = status_job(rec)
    print(json.dumps(st, indent=2))


def cmd_fetch(args: argparse.Namespace) -> None:
    rec = get_job(args.job_id, args.base_dir)
    txt = fetch_job(rec, args.base_dir, force=args.force)
    if args.print:
        print(txt)
    else:
        print(json.dumps({"job_id": rec.job_id, "result_path": rec.result_path}, indent=2))


def cmd_list(args: argparse.Namespace) -> None:
    jobs = list_jobs(args.base_dir, state=args.state)
    rows = [{
        "job_id": j.job_id,
        "backend": j.backend,
        "state": j.state,
        "label": j.label,
        "created_at": j.created_at,
        "result_path": j.result_path,
    } for j in jobs]
    print(json.dumps(rows, indent=2))


def cmd_poll(args: argparse.Namespace) -> None:
    if args.daemon:
        print("poller: running (Ctrl+C to stop)", file=sys.stderr)
        while True:
            done = poll_once(args.base_dir)
            if done:
                print(f"poller: fetched {len(done)} job(s): {done}", file=sys.stderr)
            time.sleep(args.sleep)
    else:
        done = poll_once(args.base_dir)
        print(json.dumps({"completed": done}, indent=2))


# ---------- MCP server mode (optional) ----------

def maybe_run_mcp(base_dir: str) -> None:
    try:
        from mcp.server.fastmcp import FastMCP  # type: ignore
    except Exception as e:
        raise RuntimeError("MCP mode requires the 'mcp' package. Install with: pip install mcp") from e

    mcp = FastMCP("claude-batch")

    @mcp.tool()
    def send_to_batch(packet_path: Optional[str] = None,
                      packet_text: Optional[str] = None,
                      backend: str = "auto",
                      label: Optional[str] = None) -> Dict[str, Any]:
        packet = read_packet(packet_path, packet_text)
        rec = submit_job(packet, backend, label, base_dir)
        return {"job_id": rec.job_id, "backend": rec.backend, "result_path": rec.result_path, "meta_path": rec.meta_path}

    @mcp.tool()
    def batch_status(job_id: str) -> Dict[str, Any]:
        rec = get_job(job_id, base_dir)
        return status_job(rec)

    @mcp.tool()
    def batch_fetch(job_id: str, force: bool = False) -> Dict[str, Any]:
        rec = get_job(job_id, base_dir)
        txt = fetch_job(rec, base_dir, force=force)
        return {"job_id": rec.job_id, "result_path": rec.result_path, "text": txt}

    @mcp.tool()
    def batch_list(state: str = "all") -> List[Dict[str, Any]]:
        return [{
            "job_id": j.job_id,
            "backend": j.backend,
            "state": j.state,
            "label": j.label,
            "created_at": j.created_at,
            "result_path": j.result_path,
        } for j in list_jobs(base_dir, state=state)]

    @mcp.tool()
    def batch_poll_once() -> Dict[str, Any]:
        return {"completed": poll_once(base_dir)}

    mcp.run()


def build_argparser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Claude Batch helper (Anthropic + Vertex) with durable disk state.")
    p.add_argument("--base-dir", default=DEFAULT_LOCAL_DIR, help=f"State dir (default: {DEFAULT_LOCAL_DIR})")
    p.add_argument("--mcp", action="store_true", help="Run as an MCP stdio server (requires pip install mcp).")

    sub = p.add_subparsers(dest="cmd", required=False)

    sp = sub.add_parser("submit", help="Submit one batch job from packet path or inline text.")
    sp.add_argument("--backend", default="auto", choices=["auto", "anthropic", "vertex"])
    sp.add_argument("--label", default=None)
    g = sp.add_mutually_exclusive_group(required=True)
    g.add_argument("--packet-path", default=None)
    g.add_argument("--packet-text", default=None)
    sp.set_defaults(func=cmd_submit)

    sp = sub.add_parser("status", help="Get cloud status for a job_id.")
    sp.add_argument("job_id")
    sp.set_defaults(func=cmd_status)

    sp = sub.add_parser("fetch", help="Fetch and write result locally (requires job completed).")
    sp.add_argument("job_id")
    sp.add_argument("--force", action="store_true", help="Ignore local result cache and re-fetch.")
    sp.add_argument("--print", action="store_true", help="Print result text to stdout.")
    sp.set_defaults(func=cmd_fetch)

    sp = sub.add_parser("list", help="List jobs in local registry.")
    sp.add_argument("--state", default="all", help="Filter by local state: all|submitted|running|succeeded|failed")
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("poll", help="Poll pending jobs and fetch completed outputs.")
    sp.add_argument("--daemon", action="store_true", help="Run continuously.")
    sp.add_argument("--sleep", type=float, default=5.0, help="Daemon loop sleep seconds.")
    sp.set_defaults(func=cmd_poll)

    return p


def main() -> None:
    args = build_argparser().parse_args()
    if args.mcp:
        maybe_run_mcp(args.base_dir)
        return
    if not args.cmd:
        print("No command specified. Use --help.", file=sys.stderr)
        sys.exit(2)
    args.func(args)


if __name__ == "__main__":
    main()

