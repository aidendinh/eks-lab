package com.ekslab.orders;

import java.util.List;
import java.util.Map;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * The JDBC work that gives JavaMelody something to report on.
 *
 * <p>Being a {@code @Service} also makes every public method here show up under
 * JavaMelody's "Spring" statistics tab (mean time, hits, errors per method),
 * which is why {@code javamelody.spring-monitoring-enabled} and
 * {@code spring-boot-starter-aop} are both switched on.
 */
@Service
public class OrderService {

    private final JdbcTemplate jdbc;

    public OrderService(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** Cheap indexed lookup — the common case in the SQL report. */
    public List<Map<String, Object>> findRecentOrders(int limit) {
        return jdbc.queryForList(
                "SELECT o.id, o.status, o.total_cents, c.name AS customer, c.tier "
                        + "FROM orders o JOIN customers c ON c.id = o.customer_id "
                        + "ORDER BY o.id DESC LIMIT ?",
                limit);
    }

    public int countByStatus(String status) {
        Integer count = jdbc.queryForObject(
                "SELECT COUNT(*) FROM orders WHERE status = ?", Integer.class, status);
        return count == null ? 0 : count;
    }

    @Transactional
    public int recordOrder(int customerId, int totalCents) {
        jdbc.update("INSERT INTO orders (customer_id, status, total_cents) VALUES (?, 'NEW', ?)",
                customerId, totalCents);
        Integer id = jdbc.queryForObject("SELECT MAX(id) FROM orders", Integer.class);
        int orderId = id == null ? 0 : id;
        jdbc.update("INSERT INTO order_items (order_id, sku, quantity) VALUES (?, ?, ?)",
                orderId, "SKU-" + (customerId % 40), (customerId % 5) + 1);
        return orderId;
    }

    /**
     * A deliberately expensive cartesian join. Its only purpose is to be the
     * obvious top entry in JavaMelody's "slowest SQL" report so that report is
     * not empty during the demonstration.
     *
     * <p>The cost is quadratic in the size of {@code numbers} (seeded to 300
     * rows, so 90k pairs) and this runs on every {@code /work} request. The
     * Python {@code frontend} calls this service with a hard 2-second timeout,
     * so growing that table turns the whole service chain into 502s. Time
     * {@code /work} locally after any change to it.
     */
    public long expensiveReport() {
        Long value = jdbc.queryForObject(
                "SELECT COUNT(*) FROM numbers a JOIN numbers b ON MOD(a.n * b.n, 97) = 0",
                Long.class);
        return value == null ? 0L : value;
    }
}
