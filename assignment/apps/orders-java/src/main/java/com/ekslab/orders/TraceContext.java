package com.ekslab.orders;

import java.security.SecureRandom;
import java.util.HexFormat;
import java.util.regex.Pattern;

/**
 * Minimal W3C trace-context handling, mirroring the Python service so a single
 * trace spans both languages in Tempo.
 *
 * <p>This is deliberately hand-rolled rather than using the OpenTelemetry Java
 * agent: the agent would be the right answer in production, but it is a 20 MB
 * sidecar-ish attachment that obscures what is actually happening on the wire.
 */
public record TraceContext(String traceId, String spanId, String parentSpanId) {

    private static final Pattern TRACEPARENT =
            Pattern.compile("^[\\da-f]{2}-([\\da-f]{32})-([\\da-f]{16})-([\\da-f]{2})$",
                    Pattern.CASE_INSENSITIVE);
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final String ZERO_TRACE = "0".repeat(32);

    public static TraceContext fromHeader(String traceparent) {
        String traceId = randomHex(16);
        String parentSpanId = null;

        if (traceparent != null && !traceparent.isBlank()) {
            var matcher = TRACEPARENT.matcher(traceparent.trim());
            if (matcher.matches() && !matcher.group(1).equals(ZERO_TRACE)) {
                traceId = matcher.group(1).toLowerCase();
                parentSpanId = matcher.group(2).toLowerCase();
            }
        }
        return new TraceContext(traceId, randomHex(8), parentSpanId);
    }

    public String traceparent() {
        return "00-" + traceId + "-" + spanId + "-01";
    }

    private static String randomHex(int bytes) {
        byte[] buffer = new byte[bytes];
        RANDOM.nextBytes(buffer);
        return HexFormat.of().formatHex(buffer);
    }
}
