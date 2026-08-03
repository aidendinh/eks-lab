package com.ekslab.orders;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Component;

/**
 * Posts a single OTLP/HTTP JSON span to Grafana Alloy, which forwards it to
 * Tempo on the observability cluster. Same payload shape as the Python service.
 */
@Component
public class OtlpTraceExporter {

    private final HttpClient client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(1))
            .build();
    private final ObjectMapper mapper = new ObjectMapper();
    private final AppProperties properties;
    private final EventLogger logger;

    public OtlpTraceExporter(AppProperties properties, EventLogger logger) {
        this.properties = properties;
        this.logger = logger;
    }

    public void export(TraceContext context, String spanName, long startNanos, long endNanos,
                       int statusCode, Map<String, String> attributes) {
        String endpoint = properties.getOtlpTracesEndpoint();
        if (endpoint == null || endpoint.isBlank()) {
            return;
        }

        try {
            String body = mapper.writeValueAsString(
                    payload(context, spanName, startNanos, endNanos, statusCode, attributes));
            HttpRequest request = HttpRequest.newBuilder(URI.create(endpoint))
                    .header("Content-Type", "application/json")
                    .timeout(Duration.ofSeconds(1))
                    .POST(HttpRequest.BodyPublishers.ofString(body))
                    .build();
            client.send(request, HttpResponse.BodyHandlers.discarding());
        } catch (Exception e) {
            // Telemetry must never take the request path down with it.
            logger.warning("trace_export_failed", Map.of("error", String.valueOf(e)));
        }
    }

    private Map<String, Object> payload(TraceContext context, String spanName, long startNanos,
                                        long endNanos, int statusCode,
                                        Map<String, String> attributes) {
        List<Map<String, Object>> spanAttributes = new ArrayList<>();
        attributes.entrySet().stream()
                .sorted(Map.Entry.comparingByKey())
                .forEach(entry -> spanAttributes.add(
                        Map.of("key", entry.getKey(),
                               "value", Map.of("stringValue", entry.getValue()))));

        Map<String, Object> span = new LinkedHashMap<>();
        span.put("traceId", context.traceId());
        span.put("spanId", context.spanId());
        if (context.parentSpanId() != null) {
            span.put("parentSpanId", context.parentSpanId());
        }
        span.put("name", spanName);
        span.put("kind", 2);
        span.put("startTimeUnixNano", String.valueOf(startNanos));
        span.put("endTimeUnixNano", String.valueOf(endNanos));
        span.put("attributes", spanAttributes);
        span.put("status", Map.of("code", statusCode < 500 ? 1 : 2));

        return Map.of("resourceSpans", List.of(Map.of(
                "resource", Map.of("attributes", List.of(
                        Map.of("key", "service.name",
                               "value", Map.of("stringValue", properties.getServiceName())),
                        Map.of("key", "k8s.cluster.name",
                               "value", Map.of("stringValue", properties.getClusterName())))),
                "scopeSpans", List.of(Map.of(
                        "scope", Map.of("name", "eks-lab.orders-java", "version", "0.1.0"),
                        "spans", List.of(span))))));
    }
}
