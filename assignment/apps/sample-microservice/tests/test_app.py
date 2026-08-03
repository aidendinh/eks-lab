import os
import sys
import tempfile
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app  # noqa: E402


class TraceTests(unittest.TestCase):
    def test_valid_traceparent_is_continued(self):
        parent = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
        context = app.new_trace_context(parent)
        self.assertEqual(context.trace_id, "0123456789abcdef0123456789abcdef")
        self.assertEqual(context.parent_span_id, "0123456789abcdef")
        self.assertEqual(len(context.span_id), 16)

    def test_invalid_traceparent_starts_new_trace(self):
        context = app.new_trace_context("invalid")
        self.assertEqual(len(context.trace_id), 32)
        self.assertIsNone(context.parent_span_id)

    def test_otlp_payload_uses_resource_attributes(self):
        context = app.new_trace_context()
        payload = app.build_otlp_payload(
            context, "test", 1, 2, 200, {"url.path": "/work"}
        )
        resource = payload["resourceSpans"][0]["resource"]
        keys = {attribute["key"] for attribute in resource["attributes"]}
        self.assertIn("service.name", keys)
        self.assertIn("k8s.cluster.name", keys)

        span = payload["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
        self.assertEqual(span["traceId"], context.trace_id)
        self.assertEqual(span["spanId"], context.span_id)
        self.assertEqual(span["kind"], 2)
        self.assertEqual(span["status"]["code"], 1)


class MetricsTests(unittest.TestCase):
    def test_metrics_are_prometheus_text(self):
        metrics = app.Metrics()
        metrics.observe("/work", 200, 0.25)
        rendered = metrics.render()
        self.assertIn("sample_requests_total", rendered)
        self.assertIn('path="/work"', rendered)
        self.assertIn("sample_request_duration_seconds_count", rendered)


class PersistenceTests(unittest.TestCase):
    def test_event_is_written_to_configured_directory(self):
        original = app.DATA_DIR
        try:
            with tempfile.TemporaryDirectory() as temporary:
                app.DATA_DIR = Path(temporary)
                target = app.record_shared_event(app.new_trace_context())
                self.assertTrue(Path(target).exists())
                self.assertIn("trace_id", Path(target).read_text(encoding="utf-8"))
        finally:
            app.DATA_DIR = original


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), app.RequestHandler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def test_health_and_metrics_endpoints(self):
        port = self.server.server_address[1]
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/healthz", timeout=2
        ) as response:
            self.assertEqual(response.status, 200)

        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/metrics", timeout=2
        ) as response:
            metrics = response.read().decode("utf-8")
            self.assertIn("sample_requests_total", metrics)


if __name__ == "__main__":
    unittest.main()
