# flink-streaming-transforms

Multi-stage streaming transformation pipeline that reads CDC data from a Paimon lakehouse and produces enriched business models using Apache Flink SQL and DataStream API.

## Architecture

```
┌─────────────────────┐
│   Paimon Lakehouse   │
│   (from flink-cdc-   │
│    ingestion repo)   │
│                      │
│ • orders             │
│ • order_items        │
│ • customers          │
│ • products           │
│ • payments           │
│ • inventory_events   │
│ • shipments          │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────────────────────────────────────────┐
│                    Flink Transform Jobs                    │
│                                                           │
│  ┌─────────────────────┐                                  │
│  │ OrderEnrichmentJob   │  Temporal joins: orders +       │
│  │                      │  customers + products            │
│  └──────────┬───────────┘                                  │
│             │                                              │
│             ▼                                              │
│  ┌─────────────────────┐    ┌──────────────────────┐      │
│  │ OrderAnalyticsJob    │───▶│ Side Output:          │      │
│  │                      │    │ • shipped_orders      │      │
│  │ (ProcessFunction +   │    │ • cancelled_orders    │      │
│  │  OutputTag)          │    │ • high_value_orders   │      │
│  └──────────┬───────────┘    └──────────────────────┘      │
│             │                                              │
│             ▼                                              │
│  ┌─────────────────────┐    ┌──────────────────────┐      │
│  │ InventoryJob         │    │ RevenueJob            │      │
│  │                      │    │                       │      │
│  │ Streaming aggregation│    │ Windowed aggregation  │      │
│  │ (real-time stock)    │    │ (revenue per category │      │
│  │                      │    │  per 5-min window)    │      │
│  └──────────────────────┘    └──────────────────────┘      │
│                                                           │
└───────────────────────────┬───────────────────────────────┘
                            │
                            ▼
                   ┌─────────────────────┐
                   │   Paimon Lakehouse   │
                   │   (enriched tables)  │
                   │                      │
                   │ • enriched_orders    │
                   │ • shipped_orders     │
                   │ • cancelled_orders   │
                   │ • inventory_levels   │
                   │ • revenue_by_category│
                   └─────────────────────┘
```

### How It Works

The pipeline is a chain of Flink jobs, each reading from the previous job's output:

1. **OrderEnrichmentJob** — Reads raw `orders` changelog stream from Paimon, enriches each order with customer and product details using **temporal joins** (`FOR SYSTEM_TIME AS OF`). Temporal joins look up the dimension value at the exact time the event occurred — critical in streaming because dimension tables are constantly changing.

2. **OrderAnalyticsJob** — Reads enriched orders and uses Flink **side outputs** (`ProcessFunction` + `OutputTag`) to fan the stream into multiple paths based on order status. One input stream produces multiple output tables simultaneously.

3. **InventoryJob** — Reads `inventory_events` and maintains a **stateful streaming aggregation** — a continuously updating view of current stock per product per warehouse. Unlike batch where you re-aggregate the full dataset, streaming aggregations update incrementally as each event arrives.

4. **RevenueJob** — Uses **tumble windows** to compute revenue by product category in 5-minute time buckets. Windows are a streaming-native concept for grouping events by time.

### Transformation Patterns Used

| Pattern | What It Does | SQL File |
|---------|-------------|----------|
| Temporal Join | Point-in-time lookup against a changing dimension table | `OrderEnrichment.sql` |
| Side Output | Split one stream into multiple based on conditions | N/A (DataStream API) |
| Streaming Aggregation | Continuously updating GROUP BY with state | `InventoryTracking.sql` |
| Windowed Aggregation | GROUP BY over fixed time intervals | `RevenueByCategory.sql` |

## Prerequisites

The `flink-cdc-ingestion` repo must be running — this repo reads from the Paimon tables that the CDC pipeline writes.

## Project Structure

```
flink-streaming-transforms/
├── infra/
│   └── docker-compose.yml                          # Optional separate Flink cluster
├── src/main/
│   ├── java/com/learning/transforms/
│   │   ├── jobs/                                    # One class per Flink job
│   │   ├── config/                                  # Application config, job selection
│   │   ├── util/                                    # Schema inference, table creation
│   │   └── pojo/                                    # Data type classes (define table schemas)
│   └── resources/
│       ├── sql/                                     # SQL transformation queries
│       │   ├── OrderEnrichment.sql                  # Temporal join
│       │   ├── InventoryTracking.sql                # Streaming aggregation
│       │   └── RevenueByCategory.sql                # Windowed aggregation
│       ├── application-dev.yaml                     # Dev config (local Paimon warehouse)
│       └── log4j.properties
└── pom.xml
```

## Key Concepts

| Concept | Batch Equivalent (Spark) | Streaming Difference |
|---------|-------------------------|---------------------|
| Temporal Join | Regular JOIN | Looks up dimension value at event time, not current time |
| Changelog Stream | DataFrame | Each row is tagged as INSERT, UPDATE_BEFORE, UPDATE_AFTER, or DELETE |
| Side Output | Multiple writes from same DF | Single pass through data, zero re-reads |
| Streaming Aggregation | GROUP BY | Maintains state, updates incrementally, runs forever |
| Tumble Window | Partition by date | Fixed-size non-overlapping time buckets on unbounded stream |
| Checkpointing | Job retry | Periodic state snapshot, enables exactly-once without re-processing |
| State Backend (RocksDB) | No equivalent | On-disk state store for aggregations that exceed memory |
