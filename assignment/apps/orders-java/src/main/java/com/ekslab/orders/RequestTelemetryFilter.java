package com.ekslab.orders;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * One servlet filter covering the three signals the lab forwards: a structured
 * JSON access log for Loki, an OTLP span for Tempo, and the W3C trace context
 * that ties them together.
 *
 * <p>JavaMelody's own filter handles the fourth signal (its metrics and reports)
 * and is registered separately by the starter — the two do not overlap.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class RequestTelemetryFilter extends OncePerRequestFilter {

    static final String TRACE_ATTRIBUTE = "eks-lab.traceContext";

    private final AppProperties properties;
    private final EventLogger logger;
    private final OtlpTraceExporter exporter;

    public RequestTelemetryFilter(AppProperties properties, EventLogger logger,
                                  OtlpTraceExporter exporter) {
        this.properties = properties;
        this.logger = logger;
        this.exporter = exporter;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        TraceContext context = TraceContext.fromHeader(request.getHeader("traceparent"));
        request.setAttribute(TRACE_ATTRIBUTE, context);

        long startNanos = System.nanoTime();
        long startEpochNanos = System.currentTimeMillis() * 1_000_000L;
        try {
            chain.doFilter(request, response);
        } finally {
            long durationNanos = System.nanoTime() - startNanos;
            String path = request.getRequestURI();
            int status = response.getStatus();

            Map<String, Object> fields = new LinkedHashMap<>();
            fields.put("method", request.getMethod());
            fields.put("path", path);
            fields.put("status", status);
            fields.put("duration_ms", Math.round(durationNanos / 1_000_000.0 * 100.0) / 100.0);
            fields.put("trace_id", context.traceId());
            fields.put("span_id", context.spanId());
            logger.info("request_complete", fields);

            exporter.export(context, request.getMethod() + " " + path,
                    startEpochNanos, startEpochNanos + durationNanos, status,
                    Map.of("cluster", properties.getClusterName(),
                           "http.request.method", request.getMethod(),
                           "http.response.status_code", String.valueOf(status),
                           "url.path", path));
        }
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI();
        // Probes fire every few seconds and JavaMelody's own UI is chatty; neither
        // is interesting as a log line or a trace.
        return path.startsWith("/healthz") || path.startsWith("/readyz")
                || path.startsWith("/monitoring");
    }
}
