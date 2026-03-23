# Learning Guide: Step-by-Step CDC Streaming with Flink

Hands-on walkthrough of building a CDC streaming pipeline from scratch — PostgreSQL → Flink CDC → Paimon → Flink Transforms.

---

## Step 1: PostgreSQL with Docker

Set up Postgres with **logical replication** enabled (required for CDC).

```bash
cd infra/learning
docker compose -f docker-compose-postgres.yml up -d
```

**Key config flags:**

| Flag | Why |
|------|-----|
| `wal_level=logical` | Enables logical decoding — lets CDC tools read row-level changes (INSERT/UPDATE/DELETE) as structured events. Default `replica` only supports physical replication. |
| `max_replication_slots=4` | Each CDC consumer needs a slot to track its position in the WAL |
| `max_wal_senders=4` | Max concurrent processes streaming WAL data to consumers |

**Verify:**
```bash
docker exec postgres-cdc psql -U postgres -c "SHOW wal_level;"
# Should return: logical
```

**pgAdmin** is included at http://localhost:5050
- Login: `admin@admin.com` / `admin`
- Add server → Host: `postgres`, Port: `5432`, User: `postgres`, Password: `postgres`
- Run SQL via **Tools → Query Tool**

---

## Step 2: Create Tables & Seed Data

### 2a. Create tables

Run `create-tables.sql` in pgAdmin Query Tool (or via CLI):

```bash
docker exec -i postgres-cdc psql -U postgres -d ecommerce < create-tables.sql
```

**7 tables created:**

| Table | Purpose |
|-------|---------|
| `customers` | Dimension table — customer details |
| `products` | Dimension table — product catalog with categories |
| `orders` | Fact table — orders with status (pending/shipped/cancelled) |
| `order_items` | Fact table — line items per order |
| `payments` | Fact table — payment records per order |
| `inventory_events` | Event table — stock changes (restock +, sale -) per warehouse |
| `shipments` | Event table — shipping records for shipped orders |

### 2b. Seed historical data

Run `seed-data.sql` in pgAdmin Query Tool. This generates:

| Table | ~Row Count |
|-------|-----------|
| customers | 1,000 |
| products | 50 |
| orders | 10,000 |
| order_items | 20,000 |
| payments | 7,400 |
| inventory_events | 15,100 |
| shipments | 4,900 |

**Verify counts:**
```sql
SELECT 
    (SELECT COUNT(*) FROM customers) AS customers,
    (SELECT COUNT(*) FROM products) AS products,
    (SELECT COUNT(*) FROM orders) AS orders,
    (SELECT COUNT(*) FROM order_items) AS order_items,
    (SELECT COUNT(*) FROM payments) AS payments,
    (SELECT COUNT(*) FROM inventory_events) AS inventory_events,
    (SELECT COUNT(*) FROM shipments) AS shipments;
```

---

## Step 3: Create Replication Slot

A replication slot tells Postgres to **retain WAL changes** for a specific CDC consumer. Without it, Postgres may discard WAL entries before your consumer reads them.

```sql
SELECT pg_create_logical_replication_slot('flink_slot', 'pgoutput');
```

- `flink_slot` — name our Flink CDC connector will reference
- `pgoutput` — built-in logical decoding plugin in Postgres 15

**Verify:**
```sql
SELECT slot_name, plugin, slot_type, active FROM pg_replication_slots;
```

Should show: `flink_slot | pgoutput | logical | f` (active = false until Flink connects)

> ⚠️ **Production note:** Replication slots retain WAL data until consumed. If a consumer goes down for a long time, WAL files pile up and can fill your disk. Monitor `pg_replication_slots` for `restart_lsn` lag.

---

## Step 3b: Publication & Replica Identity

Two additional Postgres configs required before Flink CDC can stream changes:

### Publication

The `pgoutput` plugin needs a **publication** to know which tables to include in the logical replication stream.

```sql
CREATE PUBLICATION flink_publication FOR ALL TABLES;
```

### Replica Identity

By default, Postgres only includes the **primary key** in the "before" image of UPDATE/DELETE WAL events. Flink CDC needs the **full row** to generate proper changelog events (`-U` update before, `+U` update after).

```sql
ALTER TABLE orders REPLICA IDENTITY FULL;
ALTER TABLE customers REPLICA IDENTITY FULL;
ALTER TABLE products REPLICA IDENTITY FULL;
ALTER TABLE order_items REPLICA IDENTITY FULL;
ALTER TABLE payments REPLICA IDENTITY FULL;
ALTER TABLE inventory_events REPLICA IDENTITY FULL;
ALTER TABLE shipments REPLICA IDENTITY FULL;
```

> Without `REPLICA IDENTITY FULL`, Flink CDC will crash on UPDATE/DELETE with: `The "before" field of UPDATE/DELETE message is null`

---

## Step 4: Setting up Flink

Start the Flink cluster (JobManager + TaskManager):

```bash
cd infra/learning
docker compose -f docker-compose-flink.yml up -d
```

**Flink Web UI:** http://localhost:8081 — should show 1 TaskManager, 4 task slots.

**Key components:**

| Component | Role |
|-----------|------|
| JobManager | Brain — coordinates scheduling, checkpointing, failure recovery. Web UI runs here. |
| TaskManager | Worker — executes actual data processing. 4 task slots = 4 parallel subtasks. |
| RocksDB state backend | Stores streaming state on disk instead of memory. Essential for large state. |
| Checkpointing (60s) | Periodic state snapshots. Enables exactly-once processing on failure recovery. |

### Install CDC Connector

Download the Flink CDC Postgres connector jar into both containers:

```bash
docker exec flink-jobmanager bash -c "wget -P /opt/flink/lib https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-postgres-cdc/3.2.0/flink-sql-connector-postgres-cdc-3.2.0.jar"
docker exec flink-taskmanager bash -c "wget -P /opt/flink/lib https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-postgres-cdc/3.2.0/flink-sql-connector-postgres-cdc-3.2.0.jar"
```

Restart to pick up the jar:

```bash
docker compose -f docker-compose-flink.yml restart
```

### Fix checkpoint directory permissions

```bash
docker exec flink-jobmanager mkdir -p /opt/flink/checkpoints && docker exec flink-jobmanager chmod 777 /opt/flink/checkpoints
docker exec flink-taskmanager mkdir -p /opt/flink/checkpoints && docker exec flink-taskmanager chmod 777 /opt/flink/checkpoints
```

### Open Flink SQL CLI

```bash
docker exec -it flink-jobmanager ./bin/sql-client.sh
```

> Note: Tables created in the SQL CLI are **ephemeral** — they live in memory only for that session. Restarting the CLI or the containers loses them.

---

## Step 5: First CDC Query

In the Flink SQL CLI, create a CDC source table:

```sql
CREATE TABLE orders_cdc (
    order_id INT,
    customer_id INT,
    status STRING,
    order_total DECIMAL(12,2),
    order_time TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'postgres-cdc',
    'hostname' = 'postgres-cdc',
    'port' = '5432',
    'username' = 'postgres',
    'password' = 'postgres',
    'database-name' = 'ecommerce',
    'schema-name' = 'public',
    'table-name' = 'orders',
    'slot.name' = 'flink_slot',
    'decoding.plugin.name' = 'pgoutput',
    'debezium.publication.name' = 'flink_publication'
);
```

### Test real-time CDC

Switch to changelog mode to see raw CDC events:

```sql
SET 'sql-client.execution.result-mode' = 'changelog';
SELECT order_id, status, order_total FROM orders_cdc WHERE order_id = 10001;
```

While the query is running, go to **pgAdmin** and update the row:

```sql
UPDATE orders SET status = 'cancelled' WHERE order_id = 10001;
```

In the Flink shell you'll see:
- `+I` — initial snapshot row
- `-U` — old version of the row (before update)
- `+U` — new version of the row (after update)

This changelog stream is the foundation of everything — temporal joins, streaming aggregations, and windowed analytics all consume these events.

**Verify replication slot is active** (in pgAdmin while Flink query is running):

```sql
SELECT slot_name, active, active_pid FROM pg_replication_slots;
```

Should show `active = true`.

---

## Useful psql Commands

| Command | What it does |
|---------|-------------|
| `\dt` | List all tables |
| `\d tablename` | Show columns/types for a table |
| `\dt+` | List tables with size info |
| `\l` | List all databases |
| `\dn` | List schemas |
| `\?` | Show all meta-commands |

## Step 6: Building the Full Pipeline

_Coming next..._

---

## Files in this directory

| File | Purpose |
|------|---------|
| `docker-compose-postgres.yml` | Postgres + pgAdmin containers |
| `docker-compose-flink.yml` | Flink JobManager + TaskManager |
| `create-tables.sql` | DDL for all 7 source tables |
| `seed-data.sql` | Generate ~50K rows of historical data |
| `LEARNING.md` | This file |
