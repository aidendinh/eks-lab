package com.ekslab.orders;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;
import java.util.stream.Stream;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * The same HTTP surface the Python services expose, so nothing downstream of
 * this pod has to know it is now a JVM.
 */
@RestController
public class OrdersController {

    private final AppProperties properties;
    private final OrderService orders;
    private final DownstreamClient downstream;
    private final EventLogger logger;
    private final ObjectMapper mapper = new ObjectMapper();

    public OrdersController(AppProperties properties, OrderService orders,
                            DownstreamClient downstream, EventLogger logger) {
        this.properties = properties;
        this.orders = orders;
        this.downstream = downstream;
        this.logger = logger;
    }

    @GetMapping("/healthz")
    public Map<String, Object> healthz() {
        return Map.of("status", "ok", "service", properties.getServiceName());
    }

    @GetMapping("/readyz")
    public Map<String, Object> readyz() {
        return Map.of("status", "ok", "service", properties.getServiceName());
    }

    @GetMapping("/")
    public Map<String, Object> root() {
        return Map.of(
                "service", properties.getServiceName(),
                "cluster", properties.getClusterName(),
                "pod", podName(),
                "runtime", "java-" + Runtime.version().feature(),
                "endpoints", List.of("/work", "/data", "/monitoring", "/healthz"));
    }

    /**
     * The endpoint {@code frontend} calls. Every request touches the database
     * several times so JavaMelody's SQL, JDBC-pool and Spring-service reports
     * fill up under the load the lab already generates.
     */
    @GetMapping("/work")
    public Map<String, Object> work(HttpServletRequest request) {
        TraceContext context =
                (TraceContext) request.getAttribute(RequestTelemetryFilter.TRACE_ATTRIBUTE);

        int newOrders = orders.countByStatus("NEW");
        int orderId = orders.recordOrder(ThreadLocalRandom.current().nextInt(1, 51), 4999);
        List<Map<String, Object>> recent = orders.findRecentOrders(5);
        long reportRows = orders.expensiveReport();

        String sharedFile;
        try {
            sharedFile = recordSharedEvent(context);
        } catch (IOException e) {
            sharedFile = "unavailable";
            logger.warning("shared_write_failed", Map.of("error", String.valueOf(e)));
        }

        List<Map<String, Object>> results = new ArrayList<>();
        for (String url : properties.downstreamUrlList()) {
            results.add(downstream.call(url, context));
        }

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("service", properties.getServiceName());
        body.put("pod", podName());
        body.put("trace_id", context == null ? "none" : context.traceId());
        body.put("shared_file", sharedFile);
        body.put("db", Map.of(
                "new_orders", newOrders,
                "created_order_id", orderId,
                "recent", recent,
                "report_rows", reportRows));
        body.put("downstream", results);
        return body;
    }

    /** Lists what is visible on the shared volume — the EFS/RWX demonstration. */
    @GetMapping("/data")
    public Map<String, Object> data() {
        List<String> files = new ArrayList<>();
        Path dir = Path.of(properties.getDataDir());
        if (Files.isDirectory(dir)) {
            try (Stream<Path> stream = Files.list(dir)) {
                files = stream.map(path -> path.getFileName().toString())
                        .filter(name -> name.endsWith(".jsonl"))
                        .sorted(Comparator.naturalOrder())
                        .toList();
            } catch (IOException e) {
                logger.warning("data_listing_failed", Map.of("error", String.valueOf(e)));
            }
        }
        return Map.of("service", properties.getServiceName(), "files", files);
    }

    private String recordSharedEvent(TraceContext context) throws IOException {
        Path dir = Path.of(properties.getDataDir());
        Files.createDirectories(dir);
        Path target = dir.resolve(properties.getServiceName() + "-events.jsonl");

        Map<String, Object> event = new LinkedHashMap<>();
        event.put("timestamp", Instant.now().truncatedTo(ChronoUnit.MILLIS).toString());
        event.put("service", properties.getServiceName());
        event.put("pod", podName());
        event.put("trace_id", context == null ? "none" : context.traceId());

        Files.writeString(target, mapper.writeValueAsString(event) + System.lineSeparator(),
                StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        return target.toString();
    }

    private String podName() {
        String hostname = System.getenv("HOSTNAME");
        return hostname == null ? "local" : hostname;
    }
}
