#!/usr/bin/env python3
"""Dependency-free HTTP microservice used by the EKS assignment."""

from __future__ import annotations

import json
import os
import re
import secrets
import signal
import threading
import time
import urllib.error
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


SERVICE_NAME = os.getenv("SERVICE_NAME", "sample")
CLUSTER_NAME = os.getenv("CLUSTER_NAME", "eks-workload")
PORT = int(os.getenv("PORT", "8080"))
DATA_DIR = Path(os.getenv("DATA_DIR", "/data"))
OTLP_TRACES_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "")
DOWNSTREAM_URLS = [
    value.strip()
    for value in os.getenv("DOWNSTREAM_URLS", "").split(",")
    if value.strip()
]
TRACEPARENT_PATTERN = re.compile(
    r"^[\da-f]{2}-([\da-f]{32})-([\da-f]{16})-([\da-f]{2})$",
    re.IGNORECASE,
)


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def log_event(level: str, message: str, **fields: Any) -> None:
    event = {
        "timestamp": utc_timestamp(),
        "level": level,
        "service": SERVICE_NAME,
        "cluster": CLUSTER_NAME,
        "message": message,
        **fields,
    }
    print(json.dumps(event, separators=(",", ":")), flush=True)


@dataclass(frozen=True)
class TraceContext:
    trace_id: str
    span_id: str
    parent_span_id: str | None

    @property
    def traceparent(self) -> str:
        return f"00-{self.trace_id}-{self.span_id}-01"


def new_trace_context(traceparent: str | None = None) -> TraceContext:
    parent_span_id = None
    trace_id = secrets.token_hex(16)
    if traceparent:
        match = TRACEPARENT_PATTERN.match(traceparent.strip())
        if match and match.group(1) != "0" * 32:
            trace_id = match.group(1).lower()
            parent_span_id = match.group(2).lower()

    return TraceContext(
        trace_id=trace_id,
        span_id=secrets.token_hex(8),
        parent_span_id=parent_span_id,
    )


def build_otlp_payload(
    context: TraceContext,
    span_name: str,
    start_ns: int,
    end_ns: int,
    status_code: int,
    attributes: dict[str, str],
) -> dict[str, Any]:
    span: dict[str, Any] = {
        "traceId": context.trace_id,
        "spanId": context.span_id,
        "name": span_name,
        "kind": 2,
        "startTimeUnixNano": str(start_ns),
        "endTimeUnixNano": str(end_ns),
        "attributes": [
            {"key": key, "value": {"stringValue": value}}
            for key, value in sorted(attributes.items())
        ],
        "status": {
            "code": 1 if status_code < 500 else 2
        },
    }
    if context.parent_span_id:
        span["parentSpanId"] = context.parent_span_id

    return {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": [
                        {
                            "key": "service.name",
                            "value": {"stringValue": SERVICE_NAME},
                        },
                        {
                            "key": "k8s.cluster.name",
                            "value": {"stringValue": CLUSTER_NAME},
                        },
                    ]
                },
                "scopeSpans": [
                    {
                        "scope": {"name": "eks-lab.sample", "version": "0.1.0"},
                        "spans": [span],
                    }
                ],
            }
        ]
    }


def export_span(
    context: TraceContext,
    span_name: str,
    start_ns: int,
    end_ns: int,
    status_code: int,
    attributes: dict[str, str],
) -> None:
    if not OTLP_TRACES_ENDPOINT:
        return

    payload = build_otlp_payload(
        context, span_name, start_ns, end_ns, status_code, attributes
    )
    request = urllib.request.Request(
        OTLP_TRACES_ENDPOINT,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=1.0) as response:
            response.read(1)
    except (OSError, urllib.error.URLError) as error:
        log_event("warning", "trace_export_failed", error=str(error))


class Metrics:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._requests: defaultdict[tuple[str, int], int] = defaultdict(int)
        self._duration_sum: defaultdict[str, float] = defaultdict(float)
        self._duration_count: defaultdict[str, int] = defaultdict(int)

    def observe(self, path: str, status: int, duration_seconds: float) -> None:
        with self._lock:
            self._requests[(path, status)] += 1
            self._duration_sum[path] += duration_seconds
            self._duration_count[path] += 1

    def render(self) -> str:
        lines = [
            "# HELP sample_requests_total Total HTTP requests.",
            "# TYPE sample_requests_total counter",
        ]
        with self._lock:
            for (path, status), count in sorted(self._requests.items()):
                lines.append(
                    'sample_requests_total{service="%s",path="%s",status="%s"} %d'
                    % (SERVICE_NAME, path, status, count)
                )
            lines.extend(
                [
                    "# HELP sample_request_duration_seconds Request duration.",
                    "# TYPE sample_request_duration_seconds summary",
                ]
            )
            for path in sorted(self._duration_count):
                labels = f'service="{SERVICE_NAME}",path="{path}"'
                lines.append(
                    f"sample_request_duration_seconds_sum{{{labels}}} "
                    f"{self._duration_sum[path]:.6f}"
                )
                lines.append(
                    f"sample_request_duration_seconds_count{{{labels}}} "
                    f"{self._duration_count[path]}"
                )
        return "\n".join(lines) + "\n"


METRICS = Metrics()


def record_shared_event(context: TraceContext) -> str:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    target = DATA_DIR / f"{SERVICE_NAME}-events.jsonl"
    event = {
        "timestamp": utc_timestamp(),
        "service": SERVICE_NAME,
        "pod": os.getenv("HOSTNAME", "local"),
        "trace_id": context.trace_id,
    }
    with target.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(event, separators=(",", ":")) + "\n")
    return str(target)


def call_downstream(url: str, context: TraceContext) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={"traceparent": context.traceparent, "User-Agent": SERVICE_NAME},
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=2.0) as response:
            body = json.loads(response.read().decode("utf-8"))
            return {
                "url": url,
                "status": response.status,
                "duration_ms": round((time.monotonic() - started) * 1000, 2),
                "response": body,
            }
    except (OSError, ValueError, urllib.error.URLError) as error:
        return {
            "url": url,
            "status": HTTPStatus.BAD_GATEWAY,
            "duration_ms": round((time.monotonic() - started) * 1000, 2),
            "error": str(error),
        }


class RequestHandler(BaseHTTPRequestHandler):
    server_version = "eks-lab-sample/0.1.0"

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - inherited API name
        started_ns = time.time_ns()
        started = time.monotonic()
        path = urlparse(self.path).path
        context = new_trace_context(self.headers.get("traceparent"))
        status = HTTPStatus.OK

        try:
            if path in ("/healthz", "/readyz"):
                self._send_json(status, {"status": "ok", "service": SERVICE_NAME})
            elif path == "/metrics":
                body = METRICS.render().encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "text/plain; version=0.0.4")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif path == "/data":
                files = []
                if DATA_DIR.exists():
                    files = sorted(item.name for item in DATA_DIR.glob("*.jsonl"))
                self._send_json(status, {"service": SERVICE_NAME, "files": files})
            elif path == "/work":
                try:
                    shared_file = record_shared_event(context)
                except OSError as error:
                    shared_file = "unavailable"
                    log_event("warning", "shared_write_failed", error=str(error))

                downstream = [
                    call_downstream(url, context) for url in DOWNSTREAM_URLS
                ]
                self._send_json(
                    status,
                    {
                        "service": SERVICE_NAME,
                        "pod": os.getenv("HOSTNAME", "local"),
                        "trace_id": context.trace_id,
                        "shared_file": shared_file,
                        "downstream": downstream,
                    },
                )
            elif path == "/":
                self._send_json(
                    status,
                    {
                        "service": SERVICE_NAME,
                        "cluster": CLUSTER_NAME,
                        "pod": os.getenv("HOSTNAME", "local"),
                        "endpoints": ["/work", "/data", "/metrics", "/healthz"],
                    },
                )
            else:
                status = HTTPStatus.NOT_FOUND
                self._send_json(status, {"error": "not_found", "path": path})
        except (BrokenPipeError, ConnectionResetError):
            status = 499
        except Exception as error:  # defensive boundary for a disposable lab
            status = HTTPStatus.INTERNAL_SERVER_ERROR
            log_event("error", "request_failed", path=path, error=repr(error))
            self._send_json(status, {"error": "internal_error"})
        finally:
            duration = time.monotonic() - started
            METRICS.observe(path, int(status), duration)
            log_event(
                "info",
                "request_complete",
                method="GET",
                path=path,
                status=int(status),
                duration_ms=round(duration * 1000, 2),
                trace_id=context.trace_id,
                span_id=context.span_id,
            )
            export_span(
                context=context,
                span_name=f"GET {path}",
                start_ns=started_ns,
                end_ns=time.time_ns(),
                status_code=int(status),
                attributes={
                    "cluster": CLUSTER_NAME,
                    "http.request.method": "GET",
                    "http.response.status_code": str(int(status)),
                    "url.path": path,
                },
            )


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), RequestHandler)

    def stop_server(signum: int, _frame: Any) -> None:
        log_event("info", "shutdown_requested", signal=signum)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop_server)
    signal.signal(signal.SIGINT, stop_server)
    log_event("info", "service_started", port=PORT, downstreams=DOWNSTREAM_URLS)
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()
        log_event("info", "service_stopped")


if __name__ == "__main__":
    main()
