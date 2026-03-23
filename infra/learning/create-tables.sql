-- Step 2: Create source tables for CDC
-- Run with: docker exec -i postgres-cdc psql -U postgres -d ecommerce < create-tables.sql

CREATE TABLE customers (
    customer_id   SERIAL PRIMARY KEY,
    name          VARCHAR(100) NOT NULL,
    email         VARCHAR(150) UNIQUE NOT NULL,
    created_at    TIMESTAMP DEFAULT NOW()
);

CREATE TABLE products (
    product_id    SERIAL PRIMARY KEY,
    name          VARCHAR(200) NOT NULL,
    category      VARCHAR(100),
    price         NUMERIC(10,2) NOT NULL,
    created_at    TIMESTAMP DEFAULT NOW()
);

CREATE TABLE orders (
    order_id      SERIAL PRIMARY KEY,
    customer_id   INT REFERENCES customers(customer_id),
    status        VARCHAR(30) DEFAULT 'pending',  -- pending, shipped, cancelled
    order_total   NUMERIC(12,2),
    order_time    TIMESTAMP DEFAULT NOW()
);

CREATE TABLE order_items (
    item_id       SERIAL PRIMARY KEY,
    order_id      INT REFERENCES orders(order_id),
    product_id    INT REFERENCES products(product_id),
    quantity      INT NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL
);

CREATE TABLE payments (
    payment_id    SERIAL PRIMARY KEY,
    order_id      INT REFERENCES orders(order_id),
    amount        NUMERIC(12,2) NOT NULL,
    method        VARCHAR(30),   -- credit_card, paypal, bank_transfer
    paid_at       TIMESTAMP DEFAULT NOW()
);

CREATE TABLE inventory_events (
    event_id      SERIAL PRIMARY KEY,
    product_id    INT REFERENCES products(product_id),
    warehouse     VARCHAR(50) NOT NULL,
    quantity_change INT NOT NULL,  -- positive = restock, negative = sold
    event_time    TIMESTAMP DEFAULT NOW()
);

CREATE TABLE shipments (
    shipment_id   SERIAL PRIMARY KEY,
    order_id      INT REFERENCES orders(order_id),
    carrier       VARCHAR(50),
    tracking_no   VARCHAR(100),
    shipped_at    TIMESTAMP DEFAULT NOW()
);
