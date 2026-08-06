package com.ekslab.orders;

import jakarta.annotation.PreDestroy;
import java.net.URI;
import java.net.URL;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import net.bull.javamelody.MonitoringFilter;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Registers this pod with the JavaMelody collector server.
 *
 * <p>JavaMelody keeps its counters per JVM, so four {@code orders} replicas mean
 * four independent {@code /monitoring} UIs. The collector server solves that by
 * polling every node and aggregating — but it needs to be told where the nodes
 * are, and in Kubernetes pod IPs are neither stable nor known ahead of time.
 * Each pod therefore registers its own address.
 *
 * <p>Two failure modes make a one-shot registration at startup unreliable, and
 * both are ordinary rather than exceptional:
 * <ul>
 *   <li>the collector pod may not be running yet when these replicas start;</li>
 *   <li>the collector loses its node list whenever its own pod restarts,
 *       because its storage is an emptyDir.</li>
 * </ul>
 * Either one leaves an empty aggregated UI next to four perfectly healthy pods
 * and no obvious error. Re-registering on a timer fixes both — registration is
 * idempotent per node URL — and failures are logged rather than thrown so a
 * missing collector can never stop the application from serving traffic.
 */
@Component
public class CollectorServerRegistrar {

    private final AppProperties properties;
    private final EventLogger logger;
    private final AtomicBoolean registered = new AtomicBoolean(false);

    public CollectorServerRegistrar(AppProperties properties, EventLogger logger) {
        this.properties = properties;
        this.logger = logger;
    }

    @Scheduled(initialDelay = 10_000, fixedDelay = 60_000)
    public void register() {
        String collectorUrl = properties.getCollector().getUrl();
        String nodeUrl = properties.getCollector().getNodeUrl();
        if (collectorUrl == null || collectorUrl.isBlank()) {
            return;
        }
        // The URL may carry Basic-auth credentials as userinfo; logs ship to
        // Loki, so every log site gets the sanitized form.
        String safeUrl = withoutUserInfo(collectorUrl);

        try {
            URL collector = URI.create(collectorUrl).toURL();
            // The application root, not the /monitoring path — the collector
            // appends that itself when it polls.
            URL node = URI.create(nodeUrl).toURL();
            MonitoringFilter.registerApplicationNodeInCollectServer(
                    properties.getCollector().getApplicationName(), collector, node);

            if (registered.compareAndSet(false, true)) {
                logger.info("collector_registered",
                        Map.of("collector", safeUrl, "node", nodeUrl));
            }
        } catch (Exception e) {
            // Exception messages from the HTTP client embed the full URL,
            // credentials included — scrub before logging.
            String error = scrubUserInfo(String.valueOf(e), collectorUrl);
            if (registered.compareAndSet(true, false)) {
                logger.warning("collector_registration_lost",
                        Map.of("collector", safeUrl, "error", error));
            } else if (!registered.get()) {
                logger.warning("collector_registration_failed",
                        Map.of("collector", safeUrl, "error", error));
            }
        }
    }

    private static String scrubUserInfo(String text, String url) {
        try {
            String userInfo = URI.create(url).getUserInfo();
            return userInfo == null ? text : text.replace(userInfo, "***");
        } catch (Exception e) {
            return text;
        }
    }

    private static String withoutUserInfo(String url) {
        try {
            URI u = URI.create(url);
            if (u.getUserInfo() == null) {
                return url;
            }
            return new URI(u.getScheme(), null, u.getHost(), u.getPort(),
                    u.getPath(), u.getQuery(), null).toString();
        } catch (Exception e) {
            return "<unparseable-collector-url>";
        }
    }

    @PreDestroy
    public void unregister() {
        if (!registered.get()) {
            return;
        }
        try {
            MonitoringFilter.unregisterApplicationNodeInCollectServer();
            logger.info("collector_unregistered", Map.of());
        } catch (Exception e) {
            logger.warning("collector_unregister_failed", Map.of("error", String.valueOf(e)));
        }
    }
}
