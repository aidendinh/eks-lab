package com.ekslab.orders;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.stereotype.Component;

/**
 * Emits one JSON object per line on stdout, in exactly the shape the Python
 * services use ({@code timestamp}, {@code level}, {@code service},
 * {@code cluster}, {@code message}, plus arbitrary fields).
 *
 * <p>Keeping the shape identical means the Loki queries in the lab's telemetry
 * verification work against Java and Python pods without a second parser.
 * Spring's own framework logging still uses the default plain-text console
 * format; those startup lines land in Loki as unparsed text, which is fine.
 */
@Component
public class EventLogger {

    private final ObjectMapper mapper = new ObjectMapper();
    private final AppProperties properties;

    public EventLogger(AppProperties properties) {
        this.properties = properties;
    }

    public void log(String level, String message, Map<String, Object> fields) {
        Map<String, Object> event = new LinkedHashMap<>();
        event.put("timestamp", Instant.now().truncatedTo(ChronoUnit.MILLIS).toString());
        event.put("level", level);
        event.put("service", properties.getServiceName());
        event.put("cluster", properties.getClusterName());
        event.put("message", message);
        if (fields != null) {
            event.putAll(fields);
        }
        try {
            System.out.println(mapper.writeValueAsString(event));
        } catch (JsonProcessingException e) {
            System.out.println("{\"level\":\"error\",\"message\":\"log_serialization_failed\"}");
        }
    }

    public void info(String message, Map<String, Object> fields) {
        log("info", message, fields);
    }

    public void warning(String message, Map<String, Object> fields) {
        log("warning", message, fields);
    }

    public void error(String message, Map<String, Object> fields) {
        log("error", message, fields);
    }
}
