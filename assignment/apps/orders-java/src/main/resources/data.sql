-- The database is in-memory and created fresh on every pod start, so these
-- scripts always run against empty tables. No idempotency guards: a
-- WHERE NOT EXISTS referencing the table being inserted into is
-- engine-dependent, and any error here fails the Spring context outright
-- (spring.sql.init.continue-on-error defaults to false), which surfaces as a
-- CrashLoopBackOff that looks like a probe problem rather than a SQL problem.

INSERT INTO customers (id, name, tier)
SELECT X, CONCAT('customer-', X), CASE MOD(X, 3) WHEN 0 THEN 'gold' WHEN 1 THEN 'silver' ELSE 'bronze' END
FROM SYSTEM_RANGE(1, 50);

INSERT INTO orders (customer_id, status, total_cents)
SELECT MOD(X, 50) + 1,
       CASE MOD(X, 4) WHEN 0 THEN 'NEW' WHEN 1 THEN 'PAID' WHEN 2 THEN 'SHIPPED' ELSE 'CANCELLED' END,
       (X * 137) % 90000 + 1000
FROM SYSTEM_RANGE(1, 500);

INSERT INTO order_items (order_id, sku, quantity)
SELECT MOD(X, 500) + 1, CONCAT('SKU-', MOD(X, 40)), MOD(X, 5) + 1
FROM SYSTEM_RANGE(1, 1500);

-- 300 rows => 90k pairs in the self-join used by OrderService.expensiveReport().
-- Enough to be the clear top entry in JavaMelody's slowest-SQL report while
-- staying in the tens of milliseconds. Do not raise this casually: the join is
-- quadratic and runs on every /work request, and the Python frontend calls this
-- service with a hard 2-second timeout.
INSERT INTO numbers (n)
SELECT X FROM SYSTEM_RANGE(1, 300);
