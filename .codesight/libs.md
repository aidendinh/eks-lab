# Libraries

- `assignment\apps\sample-microservice\app.py`
  - function utc_timestamp: () -> str
  - function log_event: (level, message, **fields) -> None
  - function new_trace_context: (traceparent) -> TraceContext
  - function build_otlp_payload: (context, span_name, start_ns, end_ns, status_code, attributes, str]) -> dict[str, Any]
  - function export_span: (context, span_name, start_ns, end_ns, status_code, attributes, str]) -> None
  - function record_shared_event: (context) -> str
  - _...5 more_
