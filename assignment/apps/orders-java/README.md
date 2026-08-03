# orders-java

The `orders` service, rewritten in Spring Boot 3 with [JavaMelody](https://github.com/javamelody/javamelody) attached. It replaces the Python `orders` container in the EKS lab.

## Why it exists

The lab's Python services are fine for demonstrating Kubernetes mechanics, but they give a Java monitoring tool nothing to monitor. This service exists so JavaMelody has a real JVM, a real servlet container, a real connection pool and real SQL to report on — while changing nothing else about the lab.

It is a **drop-in replacement**, deliberately:

| Contract | Kept identical to the Python service |
| --- | --- |
| HTTP endpoints | `/`, `/work`, `/data`, `/healthz`, `/readyz` |
| Environment variables | `SERVICE_NAME`, `CLUSTER_NAME`, `PORT`, `DATA_DIR`, `DOWNSTREAM_URLS`, `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` |
| Log format | One JSON object per line: `timestamp`, `level`, `service`, `cluster`, `message`, plus fields |
| Tracing | W3C `traceparent` in and out; OTLP/HTTP JSON spans to Alloy |
| Container user | UID 10001, GID 2000, non-root, read-only root filesystem |

So `frontend` still calls `http://orders:8080/work`, the chart's probes still work, and the Loki and Tempo queries in the lab are unchanged.

Added on top: `GET /monitoring` (the JavaMelody report) and `GET /monitoring?format=prometheus`.

## Layout

| File | Role |
| --- | --- |
| `OrdersController.java` | The HTTP contract above |
| `OrderService.java` | The JDBC work JavaMelody reports on — a `@Service` so it appears in the Spring tab |
| `RequestTelemetryFilter.java` | Structured access log + OTLP span + trace context, in one filter |
| `TraceContext.java` | W3C traceparent parsing and generation |
| `OtlpTraceExporter.java` | Posts one span per request to Alloy |
| `DownstreamClient.java` | Calls the next service with the trace header forwarded |
| `CollectorServerRegistrar.java` | Registers this pod with the JavaMelody collector server |
| `EventLogger.java` | JSON-per-line stdout logging matching the Python shape |
| `AppProperties.java` | Binds the `app.*` configuration |

## Configuration worth knowing

Set in `src/main/resources/application.yaml`:

- `javamelody.init-parameters.storage-directory: /tmp/javamelody` — the pod runs with `readOnlyRootFilesystem: true`, so JavaMelody's RRD files must land on the `emptyDir` mounted at `/tmp`.
- `javamelody.init-parameters.url-exclude-pattern` — drops `/healthz`, `/readyz` and `/monitoring` from the statistics. Probes fire every few seconds and would otherwise dominate the HTTP report.
- `javamelody.spring-monitoring-enabled: true` — needs `spring-boot-starter-aop` on the classpath, which the starter does **not** pull in transitively. Without it the Spring tab is silently empty.
- `app.collector.url` (env `JAVAMELODY_COLLECTOR_URL`) — leave empty to run standalone with only the per-pod UI.
- `app.collector.nodeUrl` (env `JAVAMELODY_NODE_URL`) — defaults to `http://$POD_IP:$PORT`. This is the **application root**; the collector appends `/monitoring` itself.

## Database

Embedded H2, in memory, seeded from `schema.sql` / `data.sql`. Every `/work` request runs an indexed lookup, a transactional insert, and one deliberately expensive cartesian join over a 1500-row table. The slow query has no purpose other than guaranteeing JavaMelody's slowest-SQL report is not empty during a demonstration.

## Running it locally

```bash
mvn spring-boot:run
```

Or against the built image, which is the closer match to how it runs in the cluster:

```bash
docker build -t orders-java:dev .
docker run --rm -p 8080:8080 -e DATA_DIR=/tmp/data orders-java:dev
```

Then generate traffic and look at the report:

```bash
for i in $(seq 1 20); do curl -s localhost:8080/work > /dev/null; done
open http://localhost:8080/monitoring
```

## Versions

| Component | Version | Note |
| --- | --- | --- |
| Java | 21 | Also the collector server's minimum |
| Spring Boot | 3.5.16 | Latest 3.x |
| JavaMelody starter | 2.8.0 | The Jakarta line. Spring Boot 2 (`javax`) needs 1.99.4; Spring Boot 4 uses `javamelody-spring-boot4-starter` |
