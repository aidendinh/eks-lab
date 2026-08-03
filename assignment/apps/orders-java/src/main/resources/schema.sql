CREATE TABLE IF NOT EXISTS customers (
    id      INT PRIMARY KEY,
    name    VARCHAR(64) NOT NULL,
    tier    VARCHAR(16) NOT NULL
);

CREATE TABLE IF NOT EXISTS orders (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    customer_id INT NOT NULL,
    status      VARCHAR(16) NOT NULL,
    total_cents INT NOT NULL,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS order_items (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    order_id INT NOT NULL,
    sku      VARCHAR(32) NOT NULL,
    quantity INT NOT NULL
);

-- Used only to build a deliberately expensive join so that JavaMelody's
-- "slowest requests / SQL" report has something interesting in it.
CREATE TABLE IF NOT EXISTS numbers (
    n INT PRIMARY KEY
);
