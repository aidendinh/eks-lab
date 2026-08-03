package com.ekslab.orders;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * Drop-in replacement for the Python {@code orders} service.
 *
 * <p>It keeps the same HTTP contract ({@code /}, {@code /work}, {@code /data},
 * {@code /healthz}, {@code /readyz}), the same environment variables and the
 * same JSON log shape, so the rest of the lab — the frontend's downstream call,
 * the Helm chart's probes, the Loki queries — does not change. What it adds is a
 * JVM for JavaMelody to monitor.
 */
@SpringBootApplication
@EnableScheduling
public class OrdersApplication {

    public static void main(String[] args) {
        SpringApplication.run(OrdersApplication.class, args);
    }
}
