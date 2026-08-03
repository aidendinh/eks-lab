package com.ekslab.orders;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.stereotype.Component;

/**
 * Calls the next service in the chain, forwarding the {@code traceparent} header
 * so Tempo stitches the spans into one trace. Unused when {@code orders} is a
 * leaf service, but kept so the Java image is a true drop-in for any of the
 * Python services.
 */
@Component
public class DownstreamClient {

    private final HttpClient client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(2))
            .build();
    private final ObjectMapper mapper = new ObjectMapper();
    private final AppProperties properties;

    public DownstreamClient(AppProperties properties) {
        this.properties = properties;
    }

    public Map<String, Object> call(String url, TraceContext context) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("url", url);
        long started = System.nanoTime();
        try {
            HttpRequest request = HttpRequest.newBuilder(URI.create(url))
                    .header("traceparent", context.traceparent())
                    .header("User-Agent", properties.getServiceName())
                    .timeout(Duration.ofSeconds(2))
                    .GET()
                    .build();
            HttpResponse<String> response =
                    client.send(request, HttpResponse.BodyHandlers.ofString());
            result.put("status", response.statusCode());
            result.put("duration_ms", elapsedMillis(started));
            result.put("response", mapper.readValue(response.body(), Map.class));
        } catch (Exception e) {
            result.put("status", 502);
            result.put("duration_ms", elapsedMillis(started));
            result.put("error", String.valueOf(e));
        }
        return result;
    }

    private double elapsedMillis(long startedNanos) {
        return Math.round((System.nanoTime() - startedNanos) / 1_000_000.0 * 100.0) / 100.0;
    }
}
