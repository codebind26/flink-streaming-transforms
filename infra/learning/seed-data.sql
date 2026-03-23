-- Step 2b: Seed historical data (medium ~1K customers, ~10K orders)
-- Run in pgAdmin Query Tool or: docker exec -i postgres-cdc psql -U postgres -d ecommerce < seed-data.sql

-- 1,000 Customers
INSERT INTO customers (name, email)
SELECT
    'Customer_' || i,
    'customer_' || i || '@example.com'
FROM generate_series(1, 1000) AS i;

-- 50 Products across 5 categories
INSERT INTO products (name, category, price)
SELECT
    'Product_' || i,
    (ARRAY['Electronics','Furniture','Stationery','Clothing','Sports'])[1 + (i % 5)],
    ROUND((10 + random() * 490)::numeric, 2)
FROM generate_series(1, 50) AS i;

-- 10,000 Orders spread over last 30 days
INSERT INTO orders (customer_id, status, order_total, order_time)
SELECT
    1 + (random() * 999)::int,
    (ARRAY['pending','shipped','cancelled'])[1 + (random() * 2)::int],
    0,  -- will update after order_items
    NOW() - (random() * INTERVAL '30 days')
FROM generate_series(1, 10000);

-- ~20,000 Order Items (1-5 items per order)
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT
    o.order_id,
    p.product_id,
    1 + (random() * 4)::int,
    p.price
FROM orders o
CROSS JOIN LATERAL (
    SELECT product_id, price
    FROM products
    ORDER BY random()
    LIMIT 1 + (random() * 4)::int
) p;

-- Update order totals from actual items
UPDATE orders o
SET order_total = sub.total
FROM (
    SELECT order_id, SUM(quantity * unit_price) AS total
    FROM order_items
    GROUP BY order_id
) sub
WHERE o.order_id = sub.order_id;

-- Payments (only for non-cancelled orders)
INSERT INTO payments (order_id, amount, method, paid_at)
SELECT
    order_id,
    order_total,
    (ARRAY['credit_card','paypal','bank_transfer'])[1 + (random() * 2)::int],
    order_time + INTERVAL '10 minutes'
FROM orders
WHERE status != 'cancelled';

-- Inventory Events: initial restock + sales over 30 days
-- Restock each product in 2 warehouses
INSERT INTO inventory_events (product_id, warehouse, quantity_change, event_time)
SELECT
    product_id,
    w.warehouse,
    500 + (random() * 500)::int,
    NOW() - INTERVAL '31 days'
FROM products
CROSS JOIN (VALUES ('warehouse-east'), ('warehouse-west')) AS w(warehouse);

-- ~15,000 sale events spread over 30 days
INSERT INTO inventory_events (product_id, warehouse, quantity_change, event_time)
SELECT
    1 + (random() * 49)::int,
    (ARRAY['warehouse-east','warehouse-west'])[1 + (random())::int],
    -(1 + (random() * 3)::int),
    NOW() - (random() * INTERVAL '30 days')
FROM generate_series(1, 15000);

-- Shipments (only for shipped orders)
INSERT INTO shipments (order_id, carrier, tracking_no, shipped_at)
SELECT
    order_id,
    (ARRAY['FedEx','UPS','DHL'])[1 + (random() * 2)::int],
    UPPER(LEFT(md5(random()::text), 10)),
    order_time + INTERVAL '1 day'
FROM orders
WHERE status = 'shipped';
